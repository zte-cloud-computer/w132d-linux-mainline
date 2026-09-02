#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""W132D 蓝牙语音遥控 -> uhid 桥接。

遥控器不响应 HID Report Map (0x2A4B) 读取，BlueZ 的 HoG 因此建不出输入设备；
但它的 Report 特征会推送标准 8 字节引导键盘报文，所以绕开 HOGP：
    GATT 通知 -> /dev/uhid 合成输入设备

配对流程复刻原厂 Android 的 com.android.stb.bt.auto.AutoParingService
（配合 com.changhong.bleaidl.BLEAIDLService），其日志串给出的顺序是：

    startLeScan
      -> onLeScan: device.getName()=
      -> "!device.name == null, go on scan !"
      -> 名字前缀匹配 -> ") MATCHED, stop LE scan and bind to device"
      -> createBond -> Bond state change(10 none / 11 bonding / 12 bonded)
      -> "------------device boned, start connect------------"
      -> connectDevice -> "BLE connect mBluetoothHidHost"

对齐要点：
  * **按名字前缀匹配，不认地址**。原厂全程用 getName()，地址随便变都能认出来。
    早期版本把 MAC 与 D-Bus 路径写死，遥控器一换地址就永远等不到。
  * **用 ObjectManager 的 InterfacesAdded 捕获新发现的设备**（等价于原厂的
    onLeScan 回调）。RemoveDevice 之后 BlueZ 会销毁设备对象，此时 PropertiesChanged
    无从发起——早期版本只订阅了后者，"解绑后重新发现"这条路是断的。
  * **特征按 UUID 定位**（Report=0x2A4D，语音=0xFD02），不认 charXXXX 句柄编号，
    那是按发现顺序分配的，重新配对后会变。
  * 匹配到目标先 stopLeScan 再 createBond：同时扫描与建连会在 UWE5622 上抢时隙。
  * 已绑定则不扫描，直接连（原厂 "has device bonded, not connect"）。
  * 配对成功立即关闭配对窗口（原厂配对完即 stopLeScan 并结束服务），
    否则下一轮会把刚建立的绑定当旧记录解掉。
  * 配对在途绝不插手断开——那会在 SMP 握手中途掐断自己。

线程约定：dbus-python 非线程安全，所有 D-Bus 调用都在 GLib 主循环线程内。
"""
import os
import struct
import subprocess
import time

import dbus
import dbus.service
import dbus.mainloop.glib
from gi.repository import GLib

NAME_PREFIXES = ("CMCC_Voice", "IFLY", "YYYKQ", "电信")
ADAPTER = "/org/bluez/hci0"
AGENT_PATH = "/w132d/agent"
VOICE_FILE = "/run/w132d-ble-voice.bin"
PAIR_FLAG = "/run/w132d-ble-pair-until"

UUID_REPORT = "00002a4d"
UUID_VOICE = "0000fd02"
UUID_RPT_REF = "00002908"          # Report Reference 描述符
RPT_KEYBOARD = 0x01                # 标准 8 字节引导键盘 Input report
RPT_CONSUMER = 0x03                # Consumer Control Input report
RPT_VOICE_IN = 0xFC                # 语音数据 Input report id
RPT_VOICE_CTL = 0xFB               # 录音开关 Output report id
RPT_KEYEVENT = 0xF8               # 厂商按键事件通道
RPT_IFLY = 0xF9                   # 讯飞私有通道
VOICE_KEY = 3                      # 0xF8 子码：实机定点确认的语音键
ICODEC = "/usr/local/bin/icodec"
ICOLIB = "/usr/local/lib/w132d/libicocodec.patched.so"
VOICE_WAV_DIR = "/run"
VOICE_WAV_KEEP = 20
VOICE_RAW_MAX = 16 * 1024 * 1024
VOICE_MAX_FRAMES = 50 * 120          # 单句硬上限 120 秒
VOICE_START_TIMEOUT = 2.0            # 写开始成功后仍无音频的收口时间

UHID_CREATE2, UHID_INPUT2 = 11, 12

_KEYBOARD = ("0501" "0906" "a101" "8501" "0507"
             "19e0" "29e7" "1500" "2501" "7501" "9508" "8102"
             "9501" "7508" "8101"
             "9506" "7508" "1500" "26ff00" "0507" "1900" "29ff" "8100" "c0")
_CONSUMER = ("050c" "0901" "a101" "8502"
             "1500" "26ff03" "1900" "2aff03" "7510" "9501" "8100" "c0")
RDESC = bytes.fromhex(_KEYBOARD + _CONSUMER)


def log(*a):
    print(time.strftime("%H:%M:%S"), *a, flush=True)


class Uhid:
    def __init__(self):
        self.fd = os.open("/dev/uhid", os.O_RDWR | os.O_NONBLOCK)
        os.write(self.fd, struct.pack("<I", UHID_CREATE2) + struct.pack(
            "<128s64s64sHHIIII4096s",
            b"CMIOT_REMOTE", b"w132d-ble-bridge", b"w132d",
            len(RDESC), 0x0005, 0x7966, 0x3002, 0x0001, 0, RDESC))
        GLib.io_add_watch(self.fd, GLib.IO_IN, self._drain)
        log("uhid: CMIOT_REMOTE 已创建 (描述符 %d 字节)" % len(RDESC))

    def _drain(self, *_):
        try:
            os.read(self.fd, 4380)
        except OSError:
            pass
        return True

    def send(self, data):
        try:
            os.write(self.fd, struct.pack("<IH", UHID_INPUT2, len(data)) + data)
        except OSError as e:
            log("uhid 写入失败:", e)


bus = None
uhid = None
stats = {"kb": 0, "cc": 0, "voice": 0}
# dev: 当前锁定的设备 D-Bus 路径（动态，不写死 MAC）
# 实测得到的 report map（2026-08-27，未加密链路读 0x2908 得到）。
# 遥控器只给约 10.7 秒就会 Remote User Terminated (0x13) 主动挂断，
# 而重读一遍要 15 次 GATT 读、耗掉 4 秒——足以把配对窗口吃掉。
# 所以默认用这张已知表，只有 charXXXX 编号对不上时才重新发现。
KNOWN_REPORTS = {
    "char002b": (0x01, 1), "char002f": (0x03, 1), "char0033": (0xFC, 1),
    "char0037": (0xFB, 2), "char003a": (0xF8, 1), "char003e": (0xFA, 2),
    "char0041": (0xF9, 1), "char0045": (0x04, 1),
}
rmap = {"by_id": {}, "by_path": {}}


def clear_report_map():
    """Drop paths that belong to a previous BlueZ device/GATT object tree."""
    rmap["by_id"].clear()
    rmap["by_path"].clear()


def seed_known_report_map(dev):
    """Populate the fixed report table from the current managed-object snapshot.

    This performs no ATT I/O.  In particular it also records Output reports,
    which can never self-populate through a notification.
    """
    hit = 0
    for path, ifaces in managed().items():
        if not path.startswith(dev + "/"):
            continue
        if "org.bluez.GattCharacteristic1" not in ifaces:
            continue
        ent = KNOWN_REPORTS.get(path.rsplit("/", 1)[-1])
        if ent:
            rmap["by_id"][ent] = path
            rmap["by_path"][path] = ent
            hit += 1
    return hit


# buf 必须是 bytearray：切片赋值到 dict 会在 py3.12+ 静默塞进一个 slice 键。
# seq/frag 必须预置：on_voice_report 首包就会读，缺了直接 KeyError。
voice = {"proc": None, "frames": 0, "buf": bytearray(48),
         "seq": -1, "frag": -1, "vol": 0, "codec_failed": False,
         "write_tested": False, "fails": 0, "nwav": 0, "last_frame": 0.0,
         "recording": False, "recording_since": 0.0, "ctl_seq": 0}

state = {"dev": None, "busy": False, "busy_until": 0.0, "pairs": 0, "armed_n": -1,
         "retry_after": 0.0, "connected": None, "dead": 0,
         "probe_at": 0.0, "probing": False, "discovering": None,
         "conn_since": None, "resched_after": 0.0,
         "dumped": False, "pairable": None, "pair_token": None,
         "unbound_token": None, "completed_token": None,
         "ready_logged": False}


def reset_gatt_runtime():
    """Forget per-connection state without discarding persistent pairing intent."""
    clear_report_map()
    state["armed_n"] = -1
    state["ready_logged"] = False
    state["dead"] = 0
    state["probing"] = False
    state["conn_since"] = None
    state.setdefault("notify_pending", set()).clear()


def adopt_device(path):
    """Switch the active BlueZ device and invalidate every old object path."""
    if path != state.get("dev"):
        if state.get("dev") is not None and (voice.get("recording") or
                                              voice.get("proc") is not None or
                                              voice.get("frames", 0)):
            voice["recording"] = False
            voice_close()
        voice["write_tested"] = False
        voice["codec_failed"] = False
        voice["fails"] = 0
        reset_gatt_runtime()
        state["connected"] = None
        state["dev"] = path


# btmgmt 会阻塞等 mgmt index 重新 added（sprd_pskey 关掉 HCI_CHANNEL_USER 之后
# 尤其明显，实测每次吃满 timeout）。早期版本用 os.system() 同步调它，而
# os.system 阻塞在 wait4 上 —— GLib 主循环因此每 3 秒被冻住 8 秒，arm_notify()
# 被推迟到连接后 30 秒开外。BlueZ 只把 Value 变化投递给已经 StartNotify 的
# 客户端，所以那段时间遥控器推来的按键通知全部被丢弃（btmon 里能看到通知，
# 桥接日志里一条没有）。一律改成非阻塞起进程 + 惰性回收。
_kids = []


def reap():
    for p in _kids[:]:
        if p.poll() is not None:
            _kids.remove(p)


def spawn(cmd):
    """非阻塞地起一个外部命令；绝不在主循环里等它。"""
    reap()
    try:
        _kids.append(subprocess.Popen(cmd, stdout=subprocess.DEVNULL,
                                      stderr=subprocess.DEVNULL))
    except OSError as e:
        log("spawn 失败 %s: %s" % (cmd[0], e))


def btmgmt_bg(*args):
    spawn(["timeout", "-k", "2", "8", "btmgmt"] + [str(a) for a in args])


class Agent(dbus.service.Object):
    """NoInputNoOutput 代理，自动确认配对（等价 persist.sys.ch.bt.autopair=1）。"""
    @dbus.service.method("org.bluez.Agent1", in_signature="", out_signature="")
    def Release(self): pass

    @dbus.service.method("org.bluez.Agent1", in_signature="os", out_signature="")
    def AuthorizeService(self, device, uuid): return

    @dbus.service.method("org.bluez.Agent1", in_signature="o", out_signature="s")
    def RequestPinCode(self, device): return "0000"

    @dbus.service.method("org.bluez.Agent1", in_signature="o", out_signature="u")
    def RequestPasskey(self, device): return dbus.UInt32(0)

    @dbus.service.method("org.bluez.Agent1", in_signature="ouq", out_signature="")
    def DisplayPasskey(self, device, passkey, entered): pass

    @dbus.service.method("org.bluez.Agent1", in_signature="os", out_signature="")
    def DisplayPinCode(self, device, pincode): pass

    @dbus.service.method("org.bluez.Agent1", in_signature="ou", out_signature="")
    def RequestConfirmation(self, device, passkey):
        log("自动确认配对 (passkey %06d)" % passkey)
        return

    @dbus.service.method("org.bluez.Agent1", in_signature="o", out_signature="")
    def RequestAuthorization(self, device): return

    @dbus.service.method("org.bluez.Agent1", in_signature="", out_signature="")
    def Cancel(self): pass


def obj(path, iface):
    return dbus.Interface(bus.get_object("org.bluez", path), iface)


def prop(path, iface, name):
    return dbus.Interface(bus.get_object("org.bluez", path),
                          "org.freedesktop.DBus.Properties").Get(iface, name)


def name_matches(n):
    return bool(n) and any(str(n).startswith(p) for p in NAME_PREFIXES)


def managed():
    try:
        return dbus.Interface(bus.get_object("org.bluez", "/"),
                              "org.freedesktop.DBus.ObjectManager"
                              ).GetManagedObjects()
    except dbus.exceptions.DBusException:
        return {}


def find_device():
    """Find the best matching device, preferring connected/bonded entries."""
    matches = []
    for path, ifaces in managed().items():
        d = ifaces.get("org.bluez.Device1")
        if d and name_matches(d.get("Name") or d.get("Alias")):
            score = (2 if bool(d.get("Connected", False)) else 0) + \
                    (1 if bool(d.get("Paired", False)) else 0)
            matches.append((score, path))
    return max(matches)[1] if matches else None


def chars_of(dev):
    """按 UUID 找 Report / 语音特征，不认 charXXXX 编号。"""
    reports, voice = [], []
    for path, ifaces in managed().items():
        if not path.startswith(dev + "/"):
            continue
        c = ifaces.get("org.bluez.GattCharacteristic1")
        if not c:
            continue
        u = str(c.get("UUID", "")).lower()
        flags = [str(f) for f in c.get("Flags", [])]
        if "notify" not in flags:
            continue
        if u.startswith(UUID_REPORT):
            reports.append(path)
        elif u.startswith(UUID_VOICE):
            voice.append(path)
    return reports, voice


def read_pair_session():
    try:
        with open(PAIR_FLAG) as f:
            fields = f.read().strip().split()
        deadline = float(fields[0])
        token = fields[1] if len(fields) > 1 else fields[0]  # 兼容旧格式
        phase = fields[2] if len(fields) > 2 else "fresh"
        return deadline, token, phase
    except (OSError, ValueError, IndexError):
        return None


def pairing_session():
    session = read_pair_session()
    if session is None:
        return None
    if time.time() < session[0]:
        return session
    close_window(session[1])
    return None


def close_window(token=None):
    """Close only the session whose Pair() callback we are handling."""
    current = read_pair_session()
    if token is not None and current is not None and current[1] != token:
        log("旧配对回调不关闭新会话 %s" % current[1][:8])
        return False
    try:
        os.remove(PAIR_FLAG)
    except OSError:
        return False
    return True


def mark_pair_phase(token, phase):
    """Persist pairing progress so a bridge/bluetoothd restart is harmless."""
    current = read_pair_session()
    if current is None or current[1] != token:
        return False
    tmp = "%s.%d" % (PAIR_FLAG, os.getpid())
    try:
        with open(tmp, "w") as f:
            f.write("%s %s %s\n" % (int(current[0]), token, phase))
        os.replace(tmp, PAIR_FLAG)
        return True
    except OSError as e:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        log("记录配对阶段失败: %s" % e)
        return False


def set_pairable(on):
    if state.get("pairable") == on:
        return
    try:
        dbus.Interface(bus.get_object("org.bluez", ADAPTER),
                       "org.freedesktop.DBus.Properties").Set(
            "org.bluez.Adapter1", "Pairable", dbus.Boolean(on))
        state["pairable"] = on
        log("适配器可配对: %s" % ("是" if on else "否"))
    except dbus.exceptions.DBusException as e:
        state["pairable"] = None
        log("设置 Pairable 失败: %s" % e.get_dbus_name().rsplit(".", 1)[-1])


def set_discovery(on):
    """开/关 LE 扫描。

    同时核对 Adapter1.Discovering 与本地意图。BlueZ 会在连接期间自动
    停扫，所以只看上次请求会把扫描永久卡在关闭。Failed/NotReady
    是真的控制器错误，不能当作成功缓存。
    """
    # Intent alone is not enough: BlueZ automatically stops discovery while
    # connecting.  If that happened behind our back, retry StartDiscovery even
    # when the last requested intent was already True.
    try:
        actual = bool(prop(ADAPTER, "org.bluez.Adapter1", "Discovering"))
    except dbus.exceptions.DBusException:
        actual = None
    if state["discovering"] == on and actual == on:
        return
    a = obj(ADAPTER, "org.bluez.Adapter1")
    try:
        if on:
            try:
                a.SetDiscoveryFilter({"Transport": "le"})
            except dbus.exceptions.DBusException:
                pass
            a.StartDiscovery()
        else:
            a.StopDiscovery()
        state["discovering"] = on
        log("LE 扫描: %s" % ("开" if on else "关"))
    except dbus.exceptions.DBusException as e:
        n = e.get_dbus_name()
        if on and "InProgress" in n:
            state["discovering"] = on
            log("LE 扫描: 开 (BlueZ 回 InProgress，已在扫描)")
        elif not on and actual is False:
            state["discovering"] = False
        else:
            # Failed/NotReady can be real controller failures.  Do not cache
            # them as success; the next one-second health tick will retry.
            state["discovering"] = None
            log("LE 扫描%s失败: %s（下轮重试）"
                % ("开启" if on else "停止", n.rsplit(".", 1)[-1]))


def arm_notify(dev):
    """订阅所有带 notify 的特征，并建立 report id 映射。

    早期版本只订 0x2A4D 与 0xFD02，且按 payload 长度猜报告类型 —— 语音那条
    (id=0xFC) 的 20 字节包因此被当成"未知报文"丢弃。现在改为：
      * 订阅**全部** notify 特征（没有代价，还能看清厂商通道有没有在推）
      * 读每个 Report 特征的 0x2908 描述符建立 report_id 映射
    """
    snap = managed()
    targets = {}
    for path, ifaces in snap.items():
        if not path.startswith(dev + "/"):
            continue
        c = ifaces.get("org.bluez.GattCharacteristic1")
        if c and "notify" in [str(f) for f in c.get("Flags", [])]:
            targets[path] = bool(c.get("Notifying", False))
    if not targets:
        return 0

    # StartNotify 必须【异步】发。它会真往对端写 CCCD 并等 Write Response；
    # 任一特征不应答时，同步调用就会把 GLib 主循环堵到 ATT 超时。
    #
    # 2026-08-27 交接后更正：07:12 抓包里那段 30 秒空窗后来确认主要来自
    # BlueZ 的独立 `hog` 插件（旧配置只禁用了 `input`）。hog-lib 写完 6 个
    # HID CCCD 后读取必超时的 0x2A4B，并把 ServicesResolved 拖住。服务现用
    # --noplugin=input,hog；这里保留异步调用作为独立的防阻塞措施。
    pend = state.setdefault("notify_pending", set())
    for p2, already in targets.items():
        if already or p2 in pend:
            continue
        pend.add(p2)

        def _nok(path=p2):
            pend.discard(path)

        def _nfail(e, path=p2):
            pend.discard(path)

        try:
            obj(p2, "org.bluez.GattCharacteristic1").StartNotify(
                reply_handler=_nok, error_handler=_nfail, timeout=40)
        except dbus.exceptions.DBusException:
            pend.discard(p2)

    # ok 只统计 BlueZ 真正标成 Notifying 的那些。StartNotify 返回成功证明
    # 不了什么——死链路上它照样成功（probe_link 的注释里早写明了）。
    ok = sum(1 for v in targets.values() if v)
    if ok != state["armed_n"]:
        log("通知已武装 %d/%d" % (ok, len(targets)))
        state["armed_n"] = ok
    # The first keyboard notification can arrive before all StartNotify calls
    # settle.  dispatch_notification() then seeds just char002b.  "map is
    # non-empty" is therefore not a completeness test: Output reports never
    # notify and cannot repair themselves later.  Keep this outside the
    # armed-count-change branch so clearing stale paths on an unusual reconnect
    # ordering is repaired on the very next health tick.
    expected = set(KNOWN_REPORTS.values())
    if ok and not expected.issubset(rmap["by_id"]):
        build_report_map(dev)
        # 诊断转储要做 15 次 GATT 读、约 4 秒，会吃掉遥控器只给的 10.7 秒
        # 连接窗口。改为按需：touch /run/w132d-ble-dump 才做一次。
        if os.path.exists("/run/w132d-ble-dump") and not state.get("dumped"):
            state["dumped"] = True
            try:
                os.remove("/run/w132d-ble-dump")
            except OSError:
                pass
            try:
                dump_gatt(dev)
            except Exception as e:
                log("GATT 转储失败: %s" % e)
    complete = expected.issubset(rmap["by_id"])
    if ok == len(targets) and complete and not state.get("ready_logged"):
        try:
            paired = bool(prop(dev, "org.bluez.Device1", "Paired"))
        except dbus.exceptions.DBusException:
            paired = False
        if paired:
            state["ready_logged"] = True
            log("遥控器就绪: 已绑定，通知 %d/%d，report map %d/%d"
                % (ok, len(targets), len(expected), len(expected)))
    return ok


def readable_char(dev):
    """找一个可读特征做存活探针，优先电池 0x2A19。"""
    best = None
    for path, ifaces in managed().items():
        if not path.startswith(dev + "/"):
            continue
        c = ifaces.get("org.bluez.GattCharacteristic1")
        if not c or "read" not in [str(f) for f in c.get("Flags", [])]:
            continue
        u = str(c.get("UUID", "")).lower()
        if u.startswith("00002a19"):
            return path
        best = best or path
    return best


def probe_link(dev):
    """异步 GATT 读取验证链路真伪。

    BlueZ 在这颗 UWE5622 上会把 Device1.Connected 卡在 True，而实际 ACL 已断
    （btmgmt/hcitool con 为空、RX bytes 不再增长）。此时 tick 一直走"已连接"
    分支什么也不做 -> 桥接假死。
    StartNotify 不能当判据：它只写 BlueZ 自己的缓存，链路死了照样返回成功。
    只有真正的 ReadValue 会打到对端，失败即链路已死。
    """
    p = readable_char(dev)
    if not p:
        return
    state["probing"] = True

    def ok(_v):
        state["probing"] = False
        state["dead"] = 0

    def err(_e):
        state["probing"] = False
        # 「链路还没就绪」和「链路死了」必须区分开。ACL 建立(Connected=True)
        # 与 ATT 通道挂载之间隔着独立一轮事件 + LTK 重加密，这段窗口里
        # BlueZ 的 characteristic_read_value() 会直接回
        # org.bluez.Error.Failed "Not connected"（src/gatt-client.c:991）。
        # 早期版本对任何异常一律 dead += 1，于是刚回连的健康链路被判死刑。
        n = ""
        try:
            n = _e.get_dbus_name() or ""
            msg = str(_e)
        except Exception:
            msg = str(_e)
        # 只放过 InProgress（同一时刻已有一笔 ATT 事务在飞）。
        # 【修正】早先这里连 "Not connected" 也放过——那是错的：探测现在
        # 已经以 resolved 为前置，resolved=1 却回 "Not connected" 恰恰是
        # 僵尸链路的确证（bluetoothd 的 client->gatt 已为 NULL），
        # 放过它等于让僵尸永远清不掉。实测正是这条把自愈堵死了。
        if "InProgress" in n:
            return
        state["dead"] += 1
        if state["dead"] >= 2:
            log("链路假死（Connected=True 但 GATT 读取失败）-> 强制断开重连")
            state["dead"] = 0
            state["armed_n"] = -1
            try:
                obj(dev, "org.bluez.Device1").Disconnect()
            except dbus.exceptions.DBusException:
                pass

            # 升级恢复。实测这颗 UWE5622 会出现三层状态互相矛盾：
            #   控制器仍持有 ACL 句柄（Read Remote Version 回 Success）
            #   内核 L2CAP 层已无该连接（debugfs 只剩监听项）
            #   bluetoothd 的 Connected 卡在 True，且 ATT socket 已销毁
            #     （ReadValue 失败且全程发不出一个 HCI 报文）
            # 此时 Device1.Disconnect() 清不掉，唯一有效的是重启 bluetoothd。
            # 带冷却，避免异常时变成重启风暴。
            def _escalate():
                try:
                    if not bool(prop(dev, "org.bluez.Device1", "Connected")):
                        return False       # Disconnect 生效了，无需升级
                except dbus.exceptions.DBusException:
                    return False
                if time.time() < state.get("resched_after", 0):
                    log("僵尸仍在，但重启冷却中，跳过")
                    return False
                state["resched_after"] = time.time() + 300.0
                log("Disconnect 无效 -> 重启 bluetoothd 清理僵尸状态")
                spawn(["systemctl", "restart", "bluetooth.service"])
                return False
            GLib.timeout_add_seconds(6, _escalate)

    try:
        obj(p, "org.bluez.GattCharacteristic1").ReadValue(
            {}, reply_handler=ok, error_handler=err, timeout=8)
    except dbus.exceptions.DBusException:
        state["probing"] = False


def build_report_map(dev):
    """建立 report_id <-> 特征 映射。

    优先用 KNOWN_REPORTS（实测所得）；只有特征路径对不上时才真去读 0x2908。
    原因见 KNOWN_REPORTS 注释：遥控器只给约 10.7 秒，重读会吃掉配对窗口。
    """
    clear_report_map()
    hit = seed_known_report_map(dev)
    expected = set(KNOWN_REPORTS.values())
    if expected.issubset(rmap["by_id"]):
        log("report map: 用已知表 %d 项（未重读 0x2908，省下配对窗口）" % hit)
        return
    if hit:
        log("report map: 已知表只匹配 %d/%d 项，读取 0x2908 补全"
            % (hit, len(expected)))
    # 兜底：真去读描述符
    for path, ifaces in managed().items():
        if not path.startswith(dev + "/"):
            continue
        d = ifaces.get("org.bluez.GattDescriptor1")
        if not d or not str(d.get("UUID", "")).lower().startswith(UUID_RPT_REF):
            continue
        chpath = path.rsplit("/", 1)[0]
        try:
            v = bytes(obj(path, "org.bluez.GattDescriptor1").ReadValue({}))
        except dbus.exceptions.DBusException as e:
            log("0x2908 读取失败 %s: %s" % (path, e.get_dbus_name()))
            continue
        if len(v) < 2:
            continue
        rmap["by_id"][(v[0], v[1])] = chpath
        rmap["by_path"][chpath] = (v[0], v[1])
    log("report map 共 %d 项（实读）" % len(rmap["by_path"]))

def voice_ctl(on):
    """开/停录音：往 (0xFB, Output) 特征写 1 个字节。"""
    p = rmap["by_id"].get((RPT_VOICE_CTL, 2))
    if not p and state.get("dev"):
        # Last-resort, zero-I/O repair for startup ordering races.  Output
        # reports never emit Value notifications, so waiting cannot fix them.
        seed_known_report_map(state["dev"])
        p = rmap["by_id"].get((RPT_VOICE_CTL, 2))
    if not p:
        log("没有 (0xFB,Output) 特征，无法控制录音")             
        return False
    val = dbus.Array([dbus.Byte(1 if on else 0)], signature="y")
    c = obj(p, "org.bluez.GattCharacteristic1")
    voice["ctl_seq"] += 1
    ctl_seq = voice["ctl_seq"]

    # 必须异步。同步 WriteValue 同样要等对端 Write Response，而原本还要
    # 顺序试 request / command 两种写类型 —— 最坏把主循环堵死 60 秒。
    def _wok():
        log("录音 %s (写 0x%02X=%d)"
            % ("开始" if on else "停止", RPT_VOICE_CTL, int(on)))

    def _wfail(e):
        log("写录音控制失败: %s" % e.get_dbus_name().rsplit(".", 1)[-1])
        # voice_ctl() reports successful dispatch before the asynchronous ATT
        # result exists.  Roll back only if this is still the newest command;
        # a late failure from Start must not undo a later Stop/Start sequence.
        if on and ctl_seq == voice["ctl_seq"]:
            voice["recording"] = False
            voice_close()

    try:
        c.WriteValue(val, {"type": dbus.String("request")},
                     reply_handler=_wok, error_handler=_wfail, timeout=20)
        return True
    except dbus.exceptions.DBusException as e:
        log("写录音控制发起失败: %s" % e.get_dbus_name().rsplit(".", 1)[-1])
        return False


def prune_voice_wavs():
    """Keep /run bounded; it is tmpfs and must not grow without limit."""
    try:
        files = [os.path.join(VOICE_WAV_DIR, name)
                 for name in os.listdir(VOICE_WAV_DIR)
                 if name.startswith("w132d-voice-") and name.endswith(".wav")]
        files.sort(key=os.path.getmtime)
        for path in files[:max(0, len(files) - VOICE_WAV_KEEP + 1)]:
            os.unlink(path)
    except OSError as e:
        log("语音: 清理旧 WAV 失败: %s" % e)


def append_raw_voice(frame):
    try:
        if os.path.getsize(VOICE_FILE) >= VOICE_RAW_MAX:
            os.replace(VOICE_FILE, VOICE_FILE + ".1")
            log("语音: 裸帧文件达到 %d MiB，已轮转" % (VOICE_RAW_MAX // 1024 // 1024))
    except FileNotFoundError:
        pass
    except OSError as e:
        log("语音: 检查裸帧文件失败: %s" % e)
    try:
        with open(VOICE_FILE, "ab") as f:
            f.write(frame)
    except OSError as e:
        log("语音: 写裸帧失败: %s" % e)


def voice_open():
    # poll() 不为 None = 子进程已退出。早期版本只看 voice["proc"] 是否为真，
    # 于是解码器一崩就每帧(20ms)重开一次 = 50Hz fork 循环，而 wav 名只精确到
    # 秒，同秒重开会把刚录好的那段直接截断覆盖。
    if voice["proc"] is not None and voice["proc"].poll() is None:
        return
    if voice["proc"] is not None:
        voice["fails"] = voice.get("fails", 0) + 1
        voice["proc"] = None
        if voice["fails"] >= 3:
            voice["codec_failed"] = True
            log("语音: icodec 连续 %d 次异常退出，停用解码器（继续存裸帧）"
                % voice["fails"])
    if voice["codec_failed"]:
        return
    voice["nwav"] = voice.get("nwav", 0) + 1
    ts = "%s-%d-%d" % (time.strftime("%Y%m%d-%H%M%S"), os.getpid(), voice["nwav"])
    wav = "/run/w132d-voice-%s.wav" % ts
    try:
        prune_voice_wavs()
        # icodec.c 的用法是 `icodec <libicocodec.so> [out.wav]`，
        # argv[1] 会被 dlopen——传 wav 进去必然失败。
        voice["proc"] = subprocess.Popen([ICODEC, ICOLIB, wav],
                                         stdin=subprocess.PIPE)
        log("语音: 解码器已启动 -> %s" % wav)
    except Exception as e:
        voice["proc"] = None
        voice["codec_failed"] = True      # 闩锁：否则每帧(20ms)重试一次 fork
        log("语音: 无法启动 icodec (%s)，只存裸帧" % e)


def voice_close():
    p = voice["proc"]
    voice["proc"] = None
    if p:
        # 两条语句必须拆开：写在同一行时 stdin.close() 抛异常会连带跳过
        # wait()，留下僵尸。wait 也不能等 5 秒——这是 GLib 主循环。
        try:
            p.stdin.close()
        except Exception:
            pass
        try:
            p.wait(timeout=0.2)
        except Exception:
            try:
                p.kill(); p.wait(timeout=0.2)
            except Exception:
                pass
    log("语音: 本轮 %d 帧 (%.2f 秒)" % (voice["frames"],          
                                        voice["frames"] * 0.02))
    voice["frames"] = 0
    voice["seq"] = -1
    voice["frag"] = -1
    # 不再无条件清 codec_failed：那会让「已判定停用」在下一句话立刻复活，
    # 重新进入 fork 循环。只有连接状态变化才重置（见 on_props）。


def on_voice_report(body):
    """报告 0xFC：body 恰好 20 字节。复刻 libiflyblesvc 0x28d4。"""
    # 松开语音键后，0xFB=0 的 Write Response 生效前可能还尾随一个音频帧。
    # release 处理已先把 recording 清零；这里丢弃尾帧，避免为它新建一个
    # 只有 0.02 秒的孤立 WAV。
    if not voice["recording"]:
        return
    if len(body) != 20:
        log("0xFC 长度异常 %d，丢弃" % len(body))                  
        return
    seq = body[0] | (body[1] << 8)
    idx = body[2]
    if seq != voice["seq"]:                 # 新帧：必须从分片 0 开始
        voice["seq"] = seq
        if idx != 0:
            voice["frag"] = -1
            return
        voice["frag"] = 0
    else:                                   # 同帧：分片号必须连续 +1
        if idx != voice["frag"] + 1:
            voice["frag"] = -1
            return
        voice["frag"] = idx
    voice["buf"][idx * 16:idx * 16 + 16] = body[4:20]
    if idx != 2:
        return
    # 第 3 片只有 8 字节有效音频；body[12] 是音量。buf[0..39] 才是 ICO 帧。
    voice["vol"] = body[12]
    frame = bytes(voice["buf"][:40])
    voice["frames"] += 1
    voice["last_frame"] = time.time()
    voice_open()
    if voice["proc"]:
        try:
            voice["proc"].stdin.write(frame); voice["proc"].stdin.flush()
        except (BrokenPipeError, OSError):
            voice["fails"] = voice.get("fails", 0) + 1
            if voice["fails"] >= 3:
                voice["codec_failed"] = True
            voice_close()      # 不能只置 None：会留僵尸进程并泄漏 stdin 的 fd
    append_raw_voice(frame)
    if voice["frames"] % 50 == 1:
        log("语音: 第 %d 帧 seq=%d vol=%d %s"                      
            % (voice["frames"], seq, voice["vol"], frame[:8].hex()))
    if voice["frames"] >= VOICE_MAX_FRAMES:
        log("语音: 单句达到 120 秒上限，强制停止")
        voice["recording"] = False
        voice_ctl(False)
        voice_close()


# --------------------------------------------------------------------------
# on_props() 里 GattCharacteristic1/Value 分支替换成这一段
# --------------------------------------------------------------------------
def dispatch_notification(path, data):
    ent = rmap["by_path"].get(path)
    if ent is None:
        # rmap 还没建起来时不能直接丢：KNOWN_REPORTS 是纯查表、零 I/O，
        # 这里现查一次即可，别让连接后最初几条按键掉在地上。
        ent = KNOWN_REPORTS.get(path.rsplit("/", 1)[-1])
        if ent:
            rmap["by_path"][path] = ent
            rmap["by_id"][ent] = path
    if ent is None:                      # 映射没建起来时的兜底（旧行为）
        log("未映射特征 %s len=%d %s"                              
            % (path.rsplit("/", 1)[-1], len(data), data.hex()))
        return
    rid, _rtype = ent
    if rid == RPT_VOICE_IN:
        on_voice_report(data)
    elif rid == RPT_KEYEVENT:
        # 0xF8。注意偏移基准：libiflyblesvc 的 0xF8/0x05 分支用的是**含 report id
        # 的原始缓冲**([sp,#24])，而 0xFC 分支用的是**去掉 report id 的 body**。
        # GATT 通知里没有 report id，所以这里全部按 body 下标 -1：
        #   原始 buf[1] = body[0] = 子码；buf[2..4] = body[1..3] = 按键三参数
        log("厂商按键事件 %s" % data.hex())                        
        if len(data) >= 4 and data[0] == 0x82:
            k, action, extra = data[1], data[2], data[3]
            log("  on recv key event, %d, %d, %d" % (k, action, extra))
            # 定点实测：k=3，action=1 是按下、0 是松开。旧注释把动作语义
            # 写反了；时间线上 1 始终先于 0，且覆盖用户实际按住的时长。
            if k == VOICE_KEY:
                if action == 1 and not voice["recording"]:
                    voice["recording"] = True
                    voice["recording_since"] = time.time()
                    voice["last_frame"] = 0.0
                    if not voice_ctl(True):
                        voice["recording"] = False
                elif action == 0:
                    if voice["recording"]:
                        voice["recording"] = False
                        voice_ctl(False)
                    voice_close()
        elif len(data) >= 1 and data[0] in (0x49, 0x01):
            log("  ack signal")                                     
    elif rid == RPT_IFLY:
        log("IFLY 通道 %s" % data.hex())                           
    elif rid == RPT_KEYBOARD:
        # 必须按 report id 路由，不能按长度猜。0x03 Consumer 在这支遥控器
        # 上也可能带 8 字节 payload；旧代码会把它误送成键盘报告。
        if len(data) != 8:
            log("键盘报告长度异常 len=%d %s" % (len(data), data.hex()))
            return
        stats["kb"] += 1
        log("键盘报告 #%d %s" % (stats["kb"], data.hex()))
        uhid.send(b"\x01" + data)
    elif rid == RPT_CONSUMER:
        if not data:
            log("消费类报告长度异常 len=0")
            return
        stats["cc"] += 1
        log("消费类报告 #%d %s" % (stats["cc"], data.hex()))
        # 遥控器的 GATT report id 是 0x03；本桥接的硬编码 uhid 描述符把
        # Consumer Control 暴露为 report id 0x02，因此在这里转换。
        uhid.send(b"\x02" + data[:2].ljust(2, b"\x00"))
    else:
        log("report 0x%02X len=%d %s" % (rid, len(data), data.hex()))


# --------------------------------------------------------------------------
# 一次性诊断转储：只在连接建立后跑一次，把该问的全问掉（省实机次数）
# --------------------------------------------------------------------------
DIAG = "/run/w132d-ble-diag.txt"


def dump_gatt(dev):
    lines = []
    def w(s):
        lines.append(s); log(s)                                    
    w("=== GATT dump %s ===" % dev)
    for path, ifaces in sorted(managed().items()):                 
        if not path.startswith(dev):
            continue
        for iface in ("org.bluez.GattService1", "org.bluez.GattCharacteristic1",
                      "org.bluez.GattDescriptor1"):
            o = ifaces.get(iface)
            if not o:
                continue
            u = str(o.get("UUID", ""))
            fl = ",".join(str(x) for x in o.get("Flags", []))
            w("%-46s %-8s %s %s" % (path.rsplit("/dev_", 1)[-1],
                                    iface.rsplit(".", 1)[-1][4:], u, fl))
    # 明确要读的几条。绝不读 0x2A4B Report Map：这支遥控器不会应答，
    # 会把 ATT 堵满 30 秒。
    for want, label in ((("00002a50"), "PnP ID (VID/PID)"),
                        (("00002a4a"), "HID Information"),
                        (("00002a19"), "Battery")):
        for path, ifaces in managed().items():                     
            c = ifaces.get("org.bluez.GattCharacteristic1")
            if not c or not path.startswith(dev):
                continue
            if str(c.get("UUID", "")).lower().startswith(want):
                try:
                    v = bytes(obj(path, "org.bluez.GattCharacteristic1")   
                              .ReadValue({}))
                    w("%-18s = %s  (%d B)" % (label, v.hex(), len(v)))
                except dbus.exceptions.DBusException as e:          
                    w("%-18s = 读失败 %s" % (label, e.get_dbus_name()))
    with open(DIAG, "w") as f:
        f.write("\n".join(lines) + "\n")
    w("诊断已写入 " + DIAG)


def _finish_pair(token):
    """Finish exactly one pairing session; safe to call more than once."""
    current = read_pair_session()
    if current is not None and current[1] != token:
        log("忽略旧配对会话 %s 的迟到成功回调" % token[:8])
        return
    if state.get("completed_token") == token:
        return
    state["completed_token"] = token
    state["busy"] = False
    state["pair_token"] = None
    state["pairs"] += 1
    closed = close_window(token)       # 原厂配对完即结束扫描/服务
    set_pairable(False)
    set_discovery(False)
    log("配对成功 (第 %d 次)%s，正在武装按键通知"
        % (state["pairs"], "，配对窗口已关闭" if closed else ""))
    dev = state["dev"]
    if dev:
        try:
            dbus.Interface(bus.get_object("org.bluez", dev),
                           "org.freedesktop.DBus.Properties").Set(
                "org.bluez.Device1", "Trusted", dbus.Boolean(True))
        except dbus.exceptions.DBusException:
            pass
    # input/hog 插件按设计被禁用，ConnectProfile(HID) 没有接收者，
    # 同步调用会把 GLib 主循环卡住 20+秒。通知订阅由本桥接管；
    # 配对成功后只需要恢复控制器接受列表。
    _autoconnect_once()


def _pair_ok(token):
    def cb():
        _finish_pair(token)
    return cb


def _err(what, token=None):
    def cb(e):
        state["busy"] = False
        if what == "配对" and (token is None or state.get("pair_token") == token):
            state["pair_token"] = None
        n = e.get_dbus_name().rsplit(".", 1)[-1] if hasattr(e, "get_dbus_name") else str(e)
        if n == "InProgress":
            state["retry_after"] = time.time() + 25.0
            return
        # 配对失败必须显式取消，否则会在遥控器那侧留下半开的 SMP 会话。
        # 原厂 AutoParingService 有对应动作 cancelBondProcess，配合
        # MSG_CHECK_IS_UNBOND / MSG_CHECK_DISCONNECTING 做带确认的收尾。
        # 我们早期几十次失败的 Pair() 一次都没取消过，累积的半开会话极可能
        # 就是遥控器「配对后两条通路全静默、只能拔电池」的成因。
        if what == "配对":
            dev = state.get("dev")
            if dev:
                try:
                    dbus.Interface(bus.get_object("org.bluez", dev),
                                   "org.bluez.Device1").CancelPairing()
                    log("已取消未完成的配对（避免留下半开 SMP 会话）")
                except dbus.exceptions.DBusException:
                    pass
            state["retry_after"] = time.time() + 8.0   # 失败后退避久一点
            state["discovering"] = None
            if pairing_session() is not None:
                set_discovery(True)
        else:
            state["retry_after"] = time.time() + 3.0
        log("%s 失败: %s" % (what, n))
    return cb

def on_iface_added(path, ifaces):
    """等价于原厂的 onLeScan 回调。"""
    d = ifaces.get("org.bluez.Device1")
    if not d:
        return
    n = d.get("Name") or d.get("Alias")
    if not name_matches(n):
        return                      # 原厂: name==null 或不匹配 -> go on scan
    if state["dev"] == path:
        return
    # 不能无条件改写：当前设备正连着时，另一支同前缀设备（第二只遥控器、
    # 邻居的机顶盒遥控）出现就会把 state["dev"] 抢走，之后 on_props 的
    # Value 分支在路径前缀比对处直接 return，已连设备的按键全部静默丢弃。
    cur = state["dev"]
    if cur:
        try:
            if bool(prop(cur, "org.bluez.Device1", "Connected")):
                log("忽略新设备 %s（当前 %s 仍在连接中）"
                    % (path.rsplit("/", 1)[-1], cur.rsplit("/", 1)[-1]))
                return
        except dbus.exceptions.DBusException:
            pass                      # 当前对象已消失，可以接管
    adopt_device(path)
    log("MATCHED: %s @ %s" % (n, path.rsplit("/", 1)[-1]))


def connection_changed(connected):
    """Apply one connection transition even if its D-Bus signal was missed."""
    connected = bool(connected)
    if connected == state.get("connected"):
        return
    state["connected"] = connected
    reset_gatt_runtime()
    state["probe_at"] = time.time() + 15.0
    state["conn_since"] = time.time() if connected else None
    log("连接状态:", "已连接" if connected else "断开")
    if not connected:
        # icodec 在 EOF 后才回写 WAV 长度，链路断开必须收口。
        if voice.get("recording") or voice.get("proc") is not None or voice.get("frames", 0):
            voice_close()
        voice["recording"] = False
        voice["write_tested"] = False
        voice["codec_failed"] = False
        voice["fails"] = 0


def on_props(iface, changed, invalidated, path=None):
    if iface == "org.bluez.GattCharacteristic1" and "Value" in changed:
        leaf = path.rsplit("/", 1)[-1]
        # Battery/FD02 等非 HID 特征也会因为自身 profile 或存活探针更新
        # Value。它们不是报告通道，不应每 10 秒刷一条“未映射特征”。
        if leaf not in KNOWN_REPORTS and path not in rmap["by_path"]:
            return
        dev = state["dev"]
        if dev and not path.startswith(dev + "/"):
            return
        # 设备对象还没被认领时，靠上面的已知特征名放行，避免首批通知被丢。
        # 按 Report Reference(0x2908) 给出的 report id 分发，而不是猜 payload 长度。
        # 语音正是 (id=0xFC, Input) 推来的 20 字节包，早先被长度分支当"未知报文"丢掉。
        dispatch_notification(path, bytes(changed["Value"]))
        return

    if iface == "org.bluez.Device1":
        if state["dev"] is None and path.startswith(ADAPTER + "/dev_"):
            # 设备对象尚未被 find_device() 认领时也要接管 ServicesResolved，
            # 否则订阅只能等下一轮 tick，而那时按键早丢光了。
            try:
                if name_matches(prop(path, "org.bluez.Device1", "Name")):
                    adopt_device(path)
                    log("认领设备(信号): %s" % path.rsplit("/", 1)[-1])
            except dbus.exceptions.DBusException:
                pass
        if path != state["dev"]:
            return
        if "Connected" in changed:
            connection_changed(changed["Connected"])
        if changed.get("ServicesResolved"):
            arm_notify(path)


def _autoconnect_once():
    """把已绑定的遥控器放进内核接受列表，由控制器后台守着自动建连。

    这是原厂 Android 的机制：AutoParingService 在 hasRcInBondedList 命中后走
    connectDevice -> mBluetoothHidHost.connect()，其底层是
    connectGatt(autoConnect=true)，即内核接受列表的后台连接。

    为什么必须用它：这支遥控器的广播窗口极短（实测 90 秒只有 3 次），
    用户态主动扫描 + Device1.Connect() 的占空比根本抓不住；而接受列表由
    控制器持续守着，见到广播立刻发 LE Extended Create Connection。
    早期版本删掉过这条（当时误以为它导致 7ms 掉线，真凶其实是 LL Privacy），
    删掉后就再没抓到过遥控器的广播。
    """
    dev = state["dev"] or find_device()
    if not dev:
        return True                     # 还没发现，下轮再试
    try:
        if not bool(prop(dev, "org.bluez.Device1", "Paired")):
            return True
    except dbus.exceptions.DBusException:
        return True
    addr = dev.rsplit("dev_", 1)[-1].replace("_", ":")
    btmgmt_bg("add-device", "-a", 2, "-t", 1, addr)
    if addr != state.get("wl_addr"):
        state["wl_addr"] = addr      # 只在地址变化时记一次，避免周期性刷屏
        log("已加入内核自动连接列表: %s" % addr)
    return True                         # 保持周期性重下：mgmt unpair 会失效条目


def tick():
    """主循环。整体裹 try/except：早期版本一次 DBusException 就会让
    GLib 把这个 timeout source 移除，进程还活着但再也不 tick，
    而 service 的 Restart=on-failure 救不回来（进程没退出）。"""
    try:
        return _tick()
    except Exception as e:
        state["busy"] = False          # 别让异常把 busy 永久锁死
        log("tick 异常: %s: %s" % (type(e).__name__, e))
        return True


def _tick():
    session = pairing_session()
    pairing = session is not None
    set_pairable(pairing)

    dev = state["dev"] or find_device()
    if dev != state["dev"]:
        adopt_device(dev)

    if dev is None:
        # 平时不扫描：已绑定设备由控制器接受列表后台守候。
        # 只有显式配对窗口才开 LE 扫，避免长期扫描功耗。
        set_discovery(pairing)
        return True

    try:
        connected = bool(prop(dev, "org.bluez.Device1", "Connected"))
        paired = bool(prop(dev, "org.bluez.Device1", "Paired"))
        resolved = bool(prop(dev, "org.bluez.Device1", "ServicesResolved"))
    except dbus.exceptions.DBusException:
        adopt_device(None)
        return True

    # 服务启动时连接可能已经存在；即使丢了 PropertiesChanged
    # 信号，一秒健康检查也必须重建所有每连接状态。
    connection_changed(connected)

    # busy 必须带截止时间：早期版本只在 reply/error 回调里清它，
    # 一旦 D-Bus 回调丢失就把主循环永久锁死。
    if state["busy"] and time.time() >= state["busy_until"]:
        state["busy"] = False
        log("busy 超时自动解除")

    # Pair() 的 reply 可能在 bluetoothd/桥接重启时丢失。当前
    # 会话若已记录“旧密钥已删”，又观察到 Paired=True，
    # 就是新绑定完成，绝不能因窗口仍在而再删一次。
    if pairing and paired and (session[2] == "unbound" or
                               state.get("pair_token") == session[1]):
        _finish_pair(session[1])
        pairing = False
        session = None

    # ★ 订阅必须先于 busy 门。BlueZ 只把 Value 变化投递给已经 StartNotify
    # 的客户端；连接建立后每晚订阅一秒，就白丢一秒内的全部按键。
    # 之前 Device1.Connect() 把 busy 顶满 25 秒，arm_notify() 因此推迟到
    # 连接后第 34 秒 —— 抓包里两条真实按键通知就是这样掉的。
    if connected and resolved:
        set_discovery(False)
        arm_notify(dev)

    if state["busy"] or time.time() < state["retry_after"]:
        return True

    # ── 配对窗口：先解绑再配对 ──
    # w132d-ble-pair 脚本一直宣称"会解绑旧记录"，但 Python 里 RemoveDevice
    # 只存在于注释中，这个功能从未实现过。已绑定时直接 Pair() 会被 BlueZ
    # 顶回 AlreadyExists，进入 CancelPairing -> 重试的无限循环。
    if pairing and paired:
        token = session[1]
        set_discovery(False)
        try:
            obj(ADAPTER, "org.bluez.Adapter1").RemoveDevice(dev)
            log("配对窗口: 已解绑（磁盘+内核）")
            mark_pair_phase(token, "unbound")
            state["unbound_token"] = token
        except dbus.exceptions.DBusException as e:
            log("解绑失败: %s" % e.get_dbus_name().rsplit(".", 1)[-1])
            state["retry_after"] = time.time() + 3.0
            return True
        # RemoveDevice 已同时删 BlueZ 密钥与内核绑定。旧版本又并发
        # btmgmt unpair/add-device，结果取决于两个子进程的先后，
        # 可能刚加入接受列表又被 unpair 删掉。新条目只在
        # 配对成功后添加。
        adopt_device(None)
        state["discovering"] = None
        state["retry_after"] = time.time() + 3.0
        return True

    if connected:
        set_discovery(False)
        if resolved:
            arm_notify(dev)
            # 连上后立刻试写一次 0xFB 开录音。这一步与配对成败无关，
            # 用来单独验证 ExportClaimedServices 是否真的打开了写通道
            # （BlueZ 对 hog 插件 claim 的 0x1812 服务默认拒绝 WriteValue，
            #  而 StartNotify 没有该检查——所以"订阅成功"证明不了写能成功）。
            # 【已移除】早期这里连上就写 0xFB=0x01 打开遥控器录音，用来验证
            # ExportClaimedServices。但全文件没有任何 voice_ctl(False)，唯一
            # 的关闭时机是断链——等于每次回连都把遥控器永久置于录音态，
            # 既拿不到按句切分的 wav，也白耗遥控器电量。
            # 录音的开/关一律只由 0xF8 厂商按键事件驱动（见
            # dispatch_notification 的 RPT_KEYEVENT 分支）。
            pass
        # 配对判断必须放在 connected 分支内部：接受列表的后台自动连接
        # 会让设备在开窗口时早已是 Connected=True，早期版本的 Pair() 在
        # connected 分支 return 之后，永远走不到。
        # 以 ServicesResolved 为前置：att 通道未就绪时 bt_att_set_security()
        # 返回 -ENOTCONN，BlueZ 会误判成功并静默设置 bonding。
        if pairing and not paired and resolved:
            token = session[1]
            set_discovery(False)
            state["busy"] = True
            state["busy_until"] = time.time() + 50.0
            state["pair_token"] = token
            log("配对窗口: 发起配对（已连接且服务已解析）")
            try:
                obj(dev, "org.bluez.Device1").Pair(
                    reply_handler=_pair_ok(token),
                    error_handler=_err("配对", token), timeout=45)
            except dbus.exceptions.DBusException as e:
                state["busy"] = False
                state["pair_token"] = None
                log("配对发起失败: %s" % e.get_dbus_name().rsplit(".", 1)[-1])
        # 僵尸链路兜底。ACL 早断了而 bluetoothd 的 Connected 卡在 True 时，
        # ServicesResolved 会一直是 False —— 而 probe_link 现在要求 resolved
        # 才探测，于是僵尸永远清不掉。健康链路 1~2 秒内必然 resolved，
        # 所以「连上 25 秒还没解析」就按假死处理，强制断开让它重连。
        if not resolved:
            if state.get("conn_since") is None:
                state["conn_since"] = time.time()
            elif time.time() - state["conn_since"] > 25.0:
                log("连接 25 秒仍未解析服务 -> 判为假死，强制断开重连")
                state["conn_since"] = None
                state["armed_n"] = -1
                try:
                    obj(dev, "org.bluez.Device1").Disconnect()
                except dbus.exceptions.DBusException:
                    pass
                return True
        else:
            state["conn_since"] = None

        # 静音兜底：遥控器不保证会发「松开」事件，超过 0.4 秒收不到 0xFC
        # 帧就自行收口。否则 wav 一直开到断链，得到的是「一个连接周期一段
        # 录音」而不是「一句话一段录音」。
        now = time.time()
        no_first_frame = (voice["recording"] and not voice.get("last_frame") and
                          now - voice.get("recording_since", now) > VOICE_START_TIMEOUT)
        stream_stalled = (voice["recording"] and voice.get("last_frame", 0) and
                          now - voice["last_frame"] > 0.4)
        if no_first_frame or stream_stalled:
            log("语音: %s，收口"
                % ("开录后未收到音频" if no_first_frame else "静音超时"))
            voice["recording"] = False
            voice_ctl(False)
            voice_close()
        # 必须等 resolved：未解析时 ReadValue 必回 Not connected，
        # 那不是链路死了，是还没就绪。
        if resolved and not state["probing"] and time.time() >= state["probe_at"]:
            state["probe_at"] = time.time() + 10.0
            probe_link(dev)
        return True

    # ── 未连接 ──
    if not pairing:
        # 不主动 Connect()：这支遥控器的广播窗口极短，内核
        # 接受列表能在控制器端持续守候，不会堵塞 GLib 主循环。
        set_discovery(False)
        return True

    token = session[1]
    set_discovery(False)                  # 先停扫再建立 SMP 连接
    state["busy"] = True
    state["busy_until"] = time.time() + 50.0
    state["pair_token"] = token
    try:
        d = dbus.Interface(bus.get_object("org.bluez", dev), "org.bluez.Device1")
        log("配对窗口: 开始配对（已停止扫描）")
        d.Pair(reply_handler=_pair_ok(token),
               error_handler=_err("配对", token), timeout=45)
    except dbus.exceptions.DBusException as e:
        state["busy"] = False
        state["pair_token"] = None
        state["retry_after"] = time.time() + 3.0
        log("发起失败: %s" % e.get_dbus_name().rsplit(".", 1)[-1])
    return True


def main():
    global bus, uhid
    dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
    bus = dbus.SystemBus()
    uhid = Uhid()
    Agent(bus, AGENT_PATH)
    am = obj("/org/bluez", "org.bluez.AgentManager1")
    am.RegisterAgent(AGENT_PATH, "NoInputNoOutput")
    am.RequestDefaultAgent(AGENT_PATH)
    log("配对代理已注册 (NoInputNoOutput)")
    # 只在用户显式打开的有限窗口内允许配对。
    set_pairable(pairing_session() is not None)
    bus.add_signal_receiver(on_props,
                            dbus_interface="org.freedesktop.DBus.Properties",
                            signal_name="PropertiesChanged", path_keyword="path")
    # 绑定已存在时直接注册，不必等扫描发现（遥控器可能长时间不广播）
    import glob as _g
    for info in _g.glob("/var/lib/bluetooth/*/*:*:*:*:*:*/info"):
        try:
            with open(info) as f:
                name = next((line[5:].strip() for line in f
                             if line.startswith("Name=")), "")
        except OSError:
            continue
        if not name_matches(name):
            continue
        a = info.rsplit("/", 2)[-2]
        btmgmt_bg("add-device", "-a", 2, "-t", 1, a)
        log("已加入遥控器自动连接列表: %s" % a)
    # 60 秒足够：接受列表条目只在 mgmt unpair 之后才会失效。
    GLib.timeout_add_seconds(60, _autoconnect_once)
    bus.add_signal_receiver(on_iface_added,
                            dbus_interface="org.freedesktop.DBus.ObjectManager",
                            signal_name="InterfacesAdded")
    GLib.timeout_add_seconds(1, tick)
    log("桥接启动, 名字前缀:", "/".join(NAME_PREFIXES))
    GLib.MainLoop().run()


if __name__ == "__main__":
    main()
