#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""W132D BLE voice remote to UHID bridge.

The supplied remote never answers HID Report Map reads. Route its GATT
notifications to a fixed UHID descriptor instead. Pairing follows the vendor
sequence: scan by name prefix, stop scanning, bond, then connect. A bounded
window is opened by w132d-ble-pair. UUIDs and Report Reference descriptors
identify channels; addresses and charXXXX handles are not stable identifiers.
Bonded devices reconnect through the kernel accept list. Never disconnect an
in-flight SMP exchange. All D-Bus calls run on the GLib main-loop thread."""
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
UUID_RPT_REF = "00002908"          # Report Reference descriptor
RPT_KEYBOARD = 0x01                # Standard 8-byte boot keyboard input
RPT_CONSUMER = 0x03                # Consumer Control Input report
RPT_VOICE_IN = 0xFC                # Voice input report ID
RPT_VOICE_CTL = 0xFB               # Recording control output report ID
RPT_KEYEVENT = 0xF8               # Vendor key-event channel
RPT_IFLY = 0xF9                   # IFLY vendor channel
VOICE_KEY = 3                      # Measured voice-key subcode on this remote
ICODEC = "/usr/lib/w132d/icodec"
ICOLIB = "/usr/lib/w132d/libicocodec.patched.so"
VOICE_WAV_DIR = "/run"
VOICE_WAV_KEEP = 20
VOICE_RAW_MAX = 16 * 1024 * 1024
VOICE_MAX_FRAMES = 50 * 120          # Hard limit: 120 seconds per utterance
VOICE_START_TIMEOUT = 2.0            # Timeout after starting with no audio received

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
        log("uhid: CMIOT_REMOTE created (descriptor %d bytes)" % len(RDESC))

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
            log("uhid write failed:", e)


bus = None
uhid = None
stats = {"kb": 0, "cc": 0, "voice": 0}
# Measured 0x2908 report map; avoid fifteen reads during the short connection window.

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


# buf must be bytearray; assigning slices to a dict silently creates slice keys in Python 3.12+.
# Initialize seq/frag before the first voice report accesses them.
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


# Launch external commands asynchronously: btmgmt can block until the controller reappears.
# Blocking GLib would discard key notifications while the command waits.
_kids = []


def reap():
    for p in _kids[:]:
        if p.poll() is not None:
            _kids.remove(p)


def spawn(cmd):
    """Start an external command without blocking the main loop."""
    reap()
    try:
        _kids.append(subprocess.Popen(cmd, stdout=subprocess.DEVNULL,
                                      stderr=subprocess.DEVNULL))
    except OSError as e:
        log("spawn failed %s: %s" % (cmd[0], e))


def btmgmt_bg(*args):
    spawn(["timeout", "-k", "2", "8", "btmgmt"] + [str(a) for a in args])


class Agent(dbus.service.Object):
    """NoInputNoOutput agent with automatic pairing confirmation."""
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
        log("Automatically confirming pairing (passkey %06d)" % passkey)
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
    """Find report and voice characteristics by UUID, not handle number."""
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
        token = fields[1] if len(fields) > 1 else fields[0]  # Accept the legacy session format.
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
        log("Stale pairing callback cannot close new session %s" % current[1][:8])
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
        log("Failed to record pairing phase: %s" % e)
        return False


def set_pairable(on):
    if state.get("pairable") == on:
        return
    try:
        dbus.Interface(bus.get_object("org.bluez", ADAPTER),
                       "org.freedesktop.DBus.Properties").Set(
            "org.bluez.Adapter1", "Pairable", dbus.Boolean(on))
        state["pairable"] = on
        log("Adapter pairable: %s" % ("yes" if on else "no"))
    except dbus.exceptions.DBusException as e:
        state["pairable"] = None
        log("Failed to set Pairable: %s" % e.get_dbus_name().rsplit(".", 1)[-1])


def set_discovery(on):
    """Toggle LE discovery and reconcile the actual BlueZ Discovering property.

Failed and NotReady are controller failures; leave them eligible for retry."""
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
        log("LE scan: %s" % ("on" if on else "off"))
    except dbus.exceptions.DBusException as e:
        n = e.get_dbus_name()
        if on and "InProgress" in n:
            state["discovering"] = on
            log("LE scan: on (BlueZ returned InProgress)")
        elif not on and actual is False:
            state["discovering"] = False
        else:
            # Do not cache failure as success; the next tick retries.
            state["discovering"] = None
            log("LE scan %s failed: %s (retrying next tick)"
                % ("start" if on else "stop", n.rsplit(".", 1)[-1]))


def arm_notify(dev):
    """Subscribe to all notifying characteristics and map their Report Reference IDs.

Voice reports share UUIDs with other reports; payload length is not an ID."""
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

    # StartNotify writes the remote CCCD; use asynchronous calls to avoid blocking GLib.
    
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

    # Count only characteristics BlueZ marks Notifying; an accepted request alone is insufficient.
    ok = sum(1 for v in targets.values() if v)
    if ok != state["armed_n"]:
        log("Notifications armed %d/%d" % (ok, len(targets)))
        state["armed_n"] = ok
    # A keyboard notification may create a partial map before all subscriptions finish.
    # Output reports never notify, so repair the complete map independently of the armed count.
    
    expected = set(KNOWN_REPORTS.values())
    if ok and not expected.issubset(rmap["by_id"]):
        build_report_map(dev)
        # Only dump GATT on demand; descriptor reads consume the short connection window.
        
        if os.path.exists("/run/w132d-ble-dump") and not state.get("dumped"):
            state["dumped"] = True
            try:
                os.remove("/run/w132d-ble-dump")
            except OSError:
                pass
            try:
                dump_gatt(dev)
            except Exception as e:
                log("GATT dump failed: %s" % e)
    complete = expected.issubset(rmap["by_id"])
    if ok == len(targets) and complete and not state.get("ready_logged"):
        try:
            paired = bool(prop(dev, "org.bluez.Device1", "Paired"))
        except dbus.exceptions.DBusException:
            paired = False
        if paired:
            state["ready_logged"] = True
            log("Remote ready: bonded, notifications %d/%d, report map %d/%d"
                % (ok, len(targets), len(expected), len(expected)))
    return ok


def readable_char(dev):
    """Find a readable characteristic for a liveness probe, preferring battery level."""
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
    """Probe the actual link with an asynchronous GATT read.

BlueZ may retain Connected=True after the ACL disappears. StartNotify alone
can succeed against cached state; ReadValue reaches the peer."""
    p = readable_char(dev)
    if not p:
        return
    state["probing"] = True

    def ok(_v):
        state["probing"] = False
        state["dead"] = 0

    def err(_e):
        state["probing"] = False
        # Wait for ServicesResolved: encryption and ATT setup lag behind ACL connection.
        
        n = ""
        try:
            n = _e.get_dbus_name() or ""
            msg = str(_e)
        except Exception:
            msg = str(_e)
        # Only InProgress is transient here. Not connected after resolution means a stale link.
        
        if "InProgress" in n:
            return
        state["dead"] += 1
        if state["dead"] >= 2:
            log("Stale link (Connected=True but GATT read failed); disconnecting for reconnection")
            state["dead"] = 0
            state["armed_n"] = -1
            try:
                obj(dev, "org.bluez.Device1").Disconnect()
            except dbus.exceptions.DBusException:
                pass

            # If Disconnect cannot clear stale controller/kernel/BlueZ state, restart BlueZ with cooldown.
            
            
            def _escalate():
                try:
                    if not bool(prop(dev, "org.bluez.Device1", "Connected")):
                        return False       # Disconnect worked; no escalation needed.
                except dbus.exceptions.DBusException:
                    return False
                if time.time() < state.get("resched_after", 0):
                    log("Stale link persists; restart cooldown is active")
                    return False
                state["resched_after"] = time.time() + 300.0
                log("Disconnect had no effect; restarting BlueZ to clear stale state")
                spawn(["systemctl", "restart", "bluetooth.service"])
                return False
            GLib.timeout_add_seconds(6, _escalate)

    try:
        obj(p, "org.bluez.GattCharacteristic1").ReadValue(
            {}, reply_handler=ok, error_handler=err, timeout=8)
    except dbus.exceptions.DBusException:
        state["probing"] = False


def build_report_map(dev):
    """Build the report ID to characteristic map.

Prefer the measured KNOWN_REPORTS table. Re-reading fifteen descriptors costs
about four seconds of the remote's 10.7-second connection window."""
    clear_report_map()
    hit = seed_known_report_map(dev)
    expected = set(KNOWN_REPORTS.values())
    if expected.issubset(rmap["by_id"]):
        log("report map: using %d known entries without re-reading 0x2908" % hit)
        return
    if hit:
        log("report map: known table matched %d/%d; reading missing descriptors"
            % (hit, len(expected)))
    # Fallback: read Report Reference descriptors.
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
            log("0x2908 read failed %s: %s" % (path, e.get_dbus_name()))
            continue
        if len(v) < 2:
            continue
        rmap["by_id"][(v[0], v[1])] = chpath
        rmap["by_path"][chpath] = (v[0], v[1])
    log("report map: %d entries read" % len(rmap["by_path"]))

def voice_ctl(on):
    """Write one byte to the voice control Output characteristic."""
    p = rmap["by_id"].get((RPT_VOICE_CTL, 2))
    if not p and state.get("dev"):
        # Output reports never notify; use the known map without I/O.
        seed_known_report_map(state["dev"])
        p = rmap["by_id"].get((RPT_VOICE_CTL, 2))
    if not p:
        log("Missing (0xFB,Output) characteristic; recording control is unavailable")             
        return False
    val = dbus.Array([dbus.Byte(1 if on else 0)], signature="y")
    c = obj(p, "org.bluez.GattCharacteristic1")
    voice["ctl_seq"] += 1
    ctl_seq = voice["ctl_seq"]

    # Write asynchronously; a lost response can otherwise block GLib for 60 seconds.
    def _wok():
        log("Recording %s (write 0x%02X=%d)"
            % ("start" if on else "stop", RPT_VOICE_CTL, int(on)))

    def _wfail(e):
        log("Recording control write failed: %s" % e.get_dbus_name().rsplit(".", 1)[-1])
        # Roll back only the latest command; a late Start failure must not undo a newer Stop/Start.
        if on and ctl_seq == voice["ctl_seq"]:
            voice["recording"] = False
            voice_close()

    try:
        c.WriteValue(val, {"type": dbus.String("request")},
                     reply_handler=_wok, error_handler=_wfail, timeout=20)
        return True
    except dbus.exceptions.DBusException as e:
        log("Failed to initiate recording control write: %s" % e.get_dbus_name().rsplit(".", 1)[-1])
        return False


def prune_voice_wavs():
    """Keep /run bounded; it is tmpfs and must not grow without limit."""
    try:
        files = [os.path.join(VOICE_WAV_DIR, name)
                 for name in os.listdir(VOICE_WAV_DIR)
                 if name.startswith("w132d-voice-") and name.endswith(".wav")]
        files.sort(key=os.path.getmtime)
        for path in files[:max(0, len(files) - VOICE_WAV_KEEP)]:
            os.unlink(path)
    except OSError as e:
        log("Voice: failed to clean old WAV files: %s" % e)


def append_raw_voice(frame):
    try:
        if os.path.getsize(VOICE_FILE) >= VOICE_RAW_MAX:
            os.replace(VOICE_FILE, VOICE_FILE + ".1")
            log("Voice: raw frames reached %d MiB; rotated file" % (VOICE_RAW_MAX // 1024 // 1024))
    except FileNotFoundError:
        pass
    except OSError as e:
        log("Voice: failed to inspect raw frame file: %s" % e)
    try:
        with open(VOICE_FILE, "ab") as f:
            f.write(frame)
    except OSError as e:
        log("Voice: raw frame write failed: %s" % e)


def voice_open():
    # Inspect poll(), not just the process object, to prevent a 50 Hz decoder restart loop.
    if voice["proc"] is not None and voice["proc"].poll() is None:
        return
    if voice["proc"] is not None:
        voice["fails"] = voice.get("fails", 0) + 1
        voice["proc"] = None
        if voice["fails"] >= 3:
            voice["codec_failed"] = True
            log("Voice: icodec failed %d times; decoder disabled, raw capture continues"
                % voice["fails"])
    if voice["codec_failed"]:
        return
    voice["nwav"] = voice.get("nwav", 0) + 1
    ts = "%s-%d-%d" % (time.strftime("%Y%m%d-%H%M%S"), os.getpid(), voice["nwav"])
    wav = "/run/w132d-voice-%s.wav" % ts
    try:
        prune_voice_wavs()
        # icodec expects a shared library as argv[1], followed by the output WAV path.
        
        voice["proc"] = subprocess.Popen([ICODEC, ICOLIB, wav],
                                         stdin=subprocess.PIPE)
        log("Voice: decoder started -> %s" % wav)
    except Exception as e:
        voice["proc"] = None
        voice["codec_failed"] = True      # Latch failure to avoid forking once per audio frame.
        log("Voice: cannot start icodec (%s); saving raw frames only" % e)


def voice_close():
    p = voice["proc"]
    voice["proc"] = None
    if p:
        # Close and wait separately: a close error must not leave a zombie. Never block GLib.
        
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
    log("Voice: captured %d frames (%.2f seconds)" % (voice["frames"],          
                                        voice["frames"] * 0.02))
    voice["frames"] = 0
    voice["seq"] = -1
    voice["frag"] = -1
    # Keep decoder failures latched until connection state changes.
    


def on_voice_report(body):
    """Reassemble 20-byte report 0xFC bodies following the vendor frame format."""
    # Discard trailing audio after key release to avoid creating a stray 20 ms WAV.
    
    
    if not voice["recording"]:
        return
    if len(body) != 20:
        log("Invalid 0xFC length %d; discarded" % len(body))                  
        return
    seq = body[0] | (body[1] << 8)
    idx = body[2]
    if seq != voice["seq"]:                 # A new frame must start at fragment zero.
        voice["seq"] = seq
        if idx != 0:
            voice["frag"] = -1
            return
        voice["frag"] = 0
    else:                                   # Fragments in the same frame must be consecutive.
        if idx != voice["frag"] + 1:
            voice["frag"] = -1
            return
        voice["frag"] = idx
    voice["buf"][idx * 16:idx * 16 + 16] = body[4:20]
    if idx != 2:
        return
    # Fragment three has eight valid audio bytes; body[12] holds volume. buf[0:40] is ICO audio.
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
            voice_close()      # Close and reap the decoder; assigning None would leak the process and pipe.
    append_raw_voice(frame)
    if voice["frames"] % 50 == 1:
        log("Voice: frame %d seq=%d vol=%d %s"                      
            % (voice["frames"], seq, voice["vol"], frame[:8].hex()))
    if voice["frames"] >= VOICE_MAX_FRAMES:
        log("Voice: utterance reached 120 seconds; stopping")
        voice["recording"] = False
        voice_ctl(False)
        voice_close()


# --------------------------------------------------------------------------
# Route notifications by Report Reference ID, never payload size.
# --------------------------------------------------------------------------
def dispatch_notification(path, data):
    ent = rmap["by_path"].get(path)
    if ent is None:
        # Use the known map immediately so initial key notifications are not lost.
        
        ent = KNOWN_REPORTS.get(path.rsplit("/", 1)[-1])
        if ent:
            rmap["by_path"][path] = ent
            rmap["by_id"][ent] = path
    if ent is None:
        log("Unmapped characteristic %s len=%d %s"                              
            % (path.rsplit("/", 1)[-1], len(data), data.hex()))
        return
    rid, _rtype = ent
    if rid == RPT_VOICE_IN:
        on_voice_report(data)
    elif rid == RPT_KEYEVENT:
        # Vendor 0xF8 offsets include the report ID; GATT body offsets exclude it.
        
        
        # body[0] is the subcode; body[1:4] holds the three key parameters.
        log("Vendor key event %s" % data.hex())                        
        if len(data) >= 4 and data[0] == 0x82:
            k, action, extra = data[1], data[2], data[3]
            log("  on recv key event, %d, %d, %d" % (k, action, extra))
            # Measured key protocol: k=3 voice, action=1 press and action=0 release.
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
        log("IFLY channel %s" % data.hex())                           
    elif rid == RPT_KEYBOARD:
        # Consumer reports can also be eight bytes; route strictly by report ID.
        if len(data) != 8:
            log("Invalid keyboard report length len=%d %s" % (len(data), data.hex()))
            return
        stats["kb"] += 1
        log("Keyboard report #%d %s" % (stats["kb"], data.hex()))
        uhid.send(b"\x01" + data)
    elif rid == RPT_CONSUMER:
        if not data:
            log("Invalid consumer report length len=0")
            return
        stats["cc"] += 1
        log("Consumer report #%d %s" % (stats["cc"], data.hex()))
        # Translate remote Consumer Control ID 0x03 to this UHID descriptor's ID 0x02.
        
        uhid.send(b"\x02" + data[:2].ljust(2, b"\x00"))
    else:
        log("report 0x%02X len=%d %s" % (rid, len(data), data.hex()))


# --------------------------------------------------------------------------
# On-demand diagnostic snapshot after connection.
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
    # Never read Report Map 0x2A4B: this remote does not answer and blocks ATT for 30 seconds.
    
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
                    w("%-18s = read failed %s" % (label, e.get_dbus_name()))
    with open(DIAG, "w") as f:
        f.write("\n".join(lines) + "\n")
    w("Diagnostics written to " + DIAG)


def _finish_pair(token):
    """Finish exactly one pairing session; safe to call more than once."""
    current = read_pair_session()
    if current is not None and current[1] != token:
        log("Ignoring late success callback from old pairing session %s" % token[:8])
        return
    if state.get("completed_token") == token:
        return
    state["completed_token"] = token
    state["busy"] = False
    state["pair_token"] = None
    state["pairs"] += 1
    closed = close_window(token)       # End the pairing window immediately after bonding.
    set_pairable(False)
    set_discovery(False)
    log("Pairing succeeded (attempt %d)%s; arming key notifications"
        % (state["pairs"], "; pairing window closed" if closed else ""))
    dev = state["dev"]
    if dev:
        try:
            dbus.Interface(bus.get_object("org.bluez", dev),
                           "org.freedesktop.DBus.Properties").Set(
                "org.bluez.Device1", "Trusted", dbus.Boolean(True))
        except dbus.exceptions.DBusException:
            pass
    # input/hog are disabled; ConnectProfile(HID) has no receiver and would block GLib.
    # This bridge subscribes to GATT; restore the controller accept list after bonding.
    
    _autoconnect_once()


def _pair_ok(token):
    def cb():
        _finish_pair(token)
    return cb


def _err(what, token=None):
    def cb(e):
        state["busy"] = False
        if what == "pairing" and (token is None or state.get("pair_token") == token):
            state["pair_token"] = None
        n = e.get_dbus_name().rsplit(".", 1)[-1] if hasattr(e, "get_dbus_name") else str(e)
        if n == "InProgress":
            state["retry_after"] = time.time() + 25.0
            return
        # Cancel failed bonding explicitly to avoid accumulating half-open SMP sessions on the remote.
        
        if what == "pairing":
            dev = state.get("dev")
            if dev:
                try:
                    dbus.Interface(bus.get_object("org.bluez", dev),
                                   "org.bluez.Device1").CancelPairing()
                    log("Cancelled incomplete pairing to avoid half-open SMP sessions")
                except dbus.exceptions.DBusException:
                    pass
            state["retry_after"] = time.time() + 8.0   # Back off after a pairing failure.
            state["discovering"] = None
            if pairing_session() is not None:
                set_discovery(True)
        else:
            state["retry_after"] = time.time() + 3.0
        log("%s failed: %s" % (what, n))
    return cb

def on_iface_added(path, ifaces):
    """Handle a matching device discovered by LE scanning."""
    d = ifaces.get("org.bluez.Device1")
    if not d:
        return
    n = d.get("Name") or d.get("Alias")
    if not name_matches(n):
        return                      # Keep scanning if the name is absent or does not match.
    if state["dev"] == path:
        return
    # Do not let a second matching remote steal the current connected device object.
    
    
    cur = state["dev"]
    if cur:
        try:
            if bool(prop(cur, "org.bluez.Device1", "Connected")):
                log("Ignoring new device %s (current %s is still connected)"
                    % (path.rsplit("/", 1)[-1], cur.rsplit("/", 1)[-1]))
                return
        except dbus.exceptions.DBusException:
            pass                      # The previous object disappeared; the new device can be adopted.
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
    log("Connection state:", "connected" if connected else "disconnected")
    if not connected:
        # The decoder finalizes WAV lengths at EOF; close recording when the link ends.
        if voice.get("recording") or voice.get("proc") is not None or voice.get("frames", 0):
            voice_close()
        voice["recording"] = False
        voice["write_tested"] = False
        voice["codec_failed"] = False
        voice["fails"] = 0


def on_props(iface, changed, invalidated, path=None):
    if iface == "org.bluez.GattCharacteristic1" and "Value" in changed:
        leaf = path.rsplit("/", 1)[-1]
        # Ignore non-report Value changes from battery/profile updates and liveness probes.
        
        if leaf not in KNOWN_REPORTS and path not in rmap["by_path"]:
            return
        dev = state["dev"]
        if dev and not path.startswith(dev + "/"):
            return
        # Allow known handles before find_device adopts the device, preserving early notifications.
        dispatch_notification(path, bytes(changed["Value"]))
        return

    if iface == "org.bluez.Device1":
        if state["dev"] is None and path.startswith(ADAPTER + "/dev_"):
            # Adopt ServicesResolved signals immediately so subscription does not wait for the next tick.
            
            try:
                if name_matches(prop(path, "org.bluez.Device1", "Name")):
                    adopt_device(path)
                    log("Adopting device from signal: %s" % path.rsplit("/", 1)[-1])
            except dbus.exceptions.DBusException:
                pass
        if path != state["dev"]:
            return
        if "Connected" in changed:
            connection_changed(changed["Connected"])
        if changed.get("ServicesResolved"):
            arm_notify(path)


def _autoconnect_once():
    """Keep bonded remotes in the kernel automatic connection accept list.

Their short advertising windows are easy to miss with userspace scanning.
The controller can listen continuously and connect immediately."""
    dev = state["dev"] or find_device()
    if not dev:
        return True                     # Device not yet discovered; retry next tick.
    try:
        if not bool(prop(dev, "org.bluez.Device1", "Paired")):
            return True
    except dbus.exceptions.DBusException:
        return True
    addr = dev.rsplit("dev_", 1)[-1].replace("_", ":")
    btmgmt_bg("add-device", "-a", 2, "-t", 1, addr)
    if addr != state.get("wl_addr"):
        state["wl_addr"] = addr      # Log only address changes.
        log("Added to kernel automatic connection list: %s" % addr)
    return True                         # Refresh periodically because mgmt unpair invalidates the accept-list entry.


def tick():
    """Keep the GLib timeout alive after a recoverable tick exception."""
    try:
        return _tick()
    except Exception as e:
        state["busy"] = False          # An exception must not leave busy latched forever.
        log("Tick exception: %s: %s" % (type(e).__name__, e))
        return True


def _tick():
    session = pairing_session()
    pairing = session is not None
    set_pairable(pairing)

    dev = state["dev"] or find_device()
    if dev != state["dev"]:
        adopt_device(dev)

    if dev is None:
        # Bonded devices use the controller accept list; scan only during explicit pairing windows.
        
        set_discovery(pairing)
        return True

    try:
        connected = bool(prop(dev, "org.bluez.Device1", "Connected"))
        paired = bool(prop(dev, "org.bluez.Device1", "Paired"))
        resolved = bool(prop(dev, "org.bluez.Device1", "ServicesResolved"))
    except dbus.exceptions.DBusException:
        adopt_device(None)
        return True

    # Rebuild connection state on the health tick if startup missed PropertiesChanged.
    
    connection_changed(connected)

    # Bound busy with a deadline in case a D-Bus callback is lost.
    if state["busy"] and time.time() >= state["busy_until"]:
        state["busy"] = False
        log("Busy deadline expired; cleared")

    # A missing Pair reply after restart must not delete a newly established bond.
    
    
    if pairing and paired and (session[2] == "unbound" or
                               state.get("pair_token") == session[1]):
        _finish_pair(session[1])
        pairing = False
        session = None

    # Subscribe before checking busy so initial Value notifications reach this client.
    
    if connected and resolved:
        set_discovery(False)
        arm_notify(dev)

    if state["busy"] or time.time() < state["retry_after"]:
        return True

    # Pairing window: remove the old bond before starting a new one.
    # Pair on an existing bond returns AlreadyExists and causes a retry loop.
    if pairing and paired:
        token = session[1]
        set_discovery(False)
        try:
            obj(ADAPTER, "org.bluez.Adapter1").RemoveDevice(dev)
            log("Pairing window: removed disk and kernel bond")
            mark_pair_phase(token, "unbound")
            state["unbound_token"] = token
        except dbus.exceptions.DBusException as e:
            log("Unpair failed: %s" % e.get_dbus_name().rsplit(".", 1)[-1])
            state["retry_after"] = time.time() + 3.0
            return True
        # RemoveDevice already removes BlueZ and kernel keys; do not race it with mgmt unpair.
        
        adopt_device(None)
        state["discovering"] = None
        state["retry_after"] = time.time() + 3.0
        return True

    if connected:
        set_discovery(False)
        if resolved:
            arm_notify(dev)
            # Only vendor key events control recording; do not start recording merely on connection.
            
            pass
        # Check pairing inside the connected path because accept-list reconnection may already have run.
        # Wait for ServicesResolved so ATT security has a valid channel.
        if pairing and not paired and resolved:
            token = session[1]
            set_discovery(False)
            state["busy"] = True
            state["busy_until"] = time.time() + 50.0
            state["pair_token"] = token
            log("Pairing window: initiating pairing on a resolved connection")
            try:
                obj(dev, "org.bluez.Device1").Pair(
                    reply_handler=_pair_ok(token),
                    error_handler=_err("pairing", token), timeout=45)
            except dbus.exceptions.DBusException as e:
                state["busy"] = False
                state["pair_token"] = None
                log("Failed to initiate pairing: %s" % e.get_dbus_name().rsplit(".", 1)[-1])
        # If Connected stays true without resolution for 25 seconds, disconnect the stale link.
        
        if not resolved:
            if state.get("conn_since") is None:
                state["conn_since"] = time.time()
            elif time.time() - state["conn_since"] > 25.0:
                log("Services unresolved after 25 seconds; disconnecting stale link")
                state["conn_since"] = None
                state["armed_n"] = -1
                try:
                    obj(dev, "org.bluez.Device1").Disconnect()
                except dbus.exceptions.DBusException:
                    pass
                return True
        else:
            state["conn_since"] = None

        # Close after 0.4 seconds without audio: the remote may omit the release event.
        
        
        now = time.time()
        no_first_frame = (voice["recording"] and not voice.get("last_frame") and
                          now - voice.get("recording_since", now) > VOICE_START_TIMEOUT)
        stream_stalled = (voice["recording"] and voice.get("last_frame", 0) and
                          now - voice["last_frame"] > 0.4)
        if no_first_frame or stream_stalled:
            log("Voice: %s; closing recording"
                % ("no audio after recording started" if no_first_frame else "silence timeout"))
            voice["recording"] = False
            voice_ctl(False)
            voice_close()
        # Before resolution, Not connected means ATT is not ready, not a dead link.
        
        if resolved and not state["probing"] and time.time() >= state["probe_at"]:
            state["probe_at"] = time.time() + 10.0
            probe_link(dev)
        return True

    # Disconnected state.
    if not pairing:
        # Let the controller accept list reconnect; avoid blocking GLib with Connect().
        
        set_discovery(False)
        return True

    token = session[1]
    set_discovery(False)                  # Stop scanning before initiating SMP.
    state["busy"] = True
    state["busy_until"] = time.time() + 50.0
    state["pair_token"] = token
    try:
        d = dbus.Interface(bus.get_object("org.bluez", dev), "org.bluez.Device1")
        log("Pairing window: starting pairing after stopping scan")
        d.Pair(reply_handler=_pair_ok(token),
               error_handler=_err("pairing", token), timeout=45)
    except dbus.exceptions.DBusException as e:
        state["busy"] = False
        state["pair_token"] = None
        state["retry_after"] = time.time() + 3.0
        log("Initiation failed: %s" % e.get_dbus_name().rsplit(".", 1)[-1])
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
    log("Pairing agent registered (NoInputNoOutput)")
    # Allow pairing only during the explicit bounded user window.
    set_pairable(pairing_session() is not None)
    bus.add_signal_receiver(on_props,
                            dbus_interface="org.freedesktop.DBus.Properties",
                            signal_name="PropertiesChanged", path_keyword="path")
    # Register existing bonds immediately; the remote may not advertise for a long time.
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
        log("Added remote to automatic connection list: %s" % a)
    # Refresh every 60 seconds; only mgmt unpair normally invalidates the entry.
    GLib.timeout_add_seconds(60, _autoconnect_once)
    bus.add_signal_receiver(on_iface_added,
                            dbus_interface="org.freedesktop.DBus.ObjectManager",
                            signal_name="InterfacesAdded")
    GLib.timeout_add_seconds(1, tick)
    log("Bridge started, name prefixes:", "/".join(NAME_PREFIXES))
    GLib.MainLoop().run()


if __name__ == "__main__":
    main()
