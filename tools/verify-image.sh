#!/bin/bash
# SPDX-License-Identifier: MIT
# 离线校验 Armbian 出的镜像：分区几何、GPT 身份、p2 内容、rootfs 定制与服务使能。
#
# 用法（容器里，需要 --privileged：要 losetup/mount）：
#   bash /w/tools/verify-image.sh <镜像文件>
#   不给路径则自动找 armbian-build/output/images/ 下最新的
#
# ## 这一步在验什么
#
# 真机刷写才是最终判据，但那要接 USB、按针孔、有人在场。这里把**能在离线判定的**
# 都判掉，免得为了发现一个拼错的路径去刷一次机：
#
#   * 分区几何必须逐扇区对上（p2@24576、p3@1073152）—— 错了设备找不到 bootfs
#   * p2 必须带 LegacyBIOSBootable —— 厂商 U-Boot 走 distro boot 靠它找 boot.scr，
#     **缺了不启动**，而 Armbian 默认不设任何分区属性
#   * GPT 身份必须是钉住的那组 —— 让镜像可复现、与救砖文档对得上
#   * rootfs 定制文件必须真的到位、服务必须真的使能 —— 钩子写错了不会报错，
#     只是镜像里什么都没有
set -uo pipefail

W="${W132D_ROOT:-/w}"
IMG="${1:-}"
if [ -z "$IMG" ]; then
  IMG=$(ls -t /build/armbian-build/output/images/*.img 2>/dev/null | head -1)
fi
[ -n "$IMG" ] && [ -f "$IMG" ] || { echo "❌ 找不到镜像：$IMG"; exit 1; }

for t in sfdisk losetup sgdisk mount; do
  command -v "$t" >/dev/null || { echo "❌ 缺 $t（apt-get install fdisk gdisk mount）"; exit 1; }
done

FAIL=0
ok(){ printf '  ✅ %s\n' "$*"; }
bad(){ printf '  ❌ %s\n' "$*"; FAIL=1; }

echo "镜像: $IMG ($(stat -c %s "$IMG") B)"

echo
echo "── 1. 分区几何 ──"
LAYOUT=$(sfdisk -d "$IMG" 2>/dev/null)
# sfdisk 的行首是**完整镜像路径**加分区号，不是 "p2"；而 BOOTCONFIG=none 下
# Armbian 只建两个分区（bootfs、rootfs），对应设备上的 p2、p3。所以按名字取。
boot_start=$(sed -n 's|.*start= *\([0-9]*\).*name="bootfs".*|\1|p' <<<"$LAYOUT" | tr -d ' ')
root_start=$(sed -n 's|.*start= *\([0-9]*\).*name="rootfs".*|\1|p' <<<"$LAYOUT" | tr -d ' ')
[ "$boot_start" = "24576" ]   && ok "bootfs 起点 24576 扇区（12 MiB）" \
                              || bad "bootfs 起点是 ${boot_start:-?}，应为 24576"
[ "$root_start" = "1073152" ] && ok "rootfs 起点 1073152 扇区（524 MiB）" \
                              || bad "rootfs 起点是 ${root_start:-?}，应为 1073152"

echo
echo "── 2. GPT 身份与 p2 属性 ──"
GPT=$(sgdisk -p "$IMG" 2>/dev/null)
grep -qi "9460D758-5782-409D-ACD6-FE1596D204B3" <<<"$(sgdisk -p "$IMG" 2>/dev/null; sfdisk -d "$IMG" 2>/dev/null)" \
  && ok "GPT label-id 是钉住的那个" || bad "GPT label-id 不对（应为 9460D758-…）"
if grep -q "LegacyBIOSBootable" <<<"$LAYOUT"; then
  ok "bootfs 带 LegacyBIOSBootable"
else
  bad "bootfs 缺 LegacyBIOSBootable —— 厂商 U-Boot 扫不到 boot.scr，设备起不来"
fi

echo
echo "── 3. bootfs 内容 ──"
LOOP=$(losetup -f --show -P "$IMG") || { echo "❌ losetup 失败"; exit 1; }
trap 'umount /mnt/vp2 /mnt/vp3 2>/dev/null; losetup -d "$LOOP" 2>/dev/null' EXIT
mkdir -p /mnt/vp2 /mnt/vp3

# 容器里没有 udev，`losetup -P` 之后 /dev/loopNpM 不会自动出现，`partx -a` 也建不了。
# 但**宿主的 /dev 里有**（内核已经扫过分区表），所以按 Armbian 的办法（loop.sh:27）
# 从挂进来的宿主 /dev 里读设备号、mknod 复制过来。
#   docker run --privileged -v /dev:/tmp/dev ...
for n in 1 2; do
  [ -b "${LOOP}p${n}" ] && continue
  hostnode="/tmp/dev/$(basename "$LOOP")p${n}"
  if [ -b "$hostnode" ]; then
    mknod -m0660 "${LOOP}p${n}" b \
      "0x$(stat -c '%t' "$hostnode")" "0x$(stat -c '%T' "$hostnode")" 2>/dev/null \
      && echo "  （已从宿主 /dev 复制 $(basename "$LOOP")p${n} 设备节点）"
  fi
done
if mount -o ro "${LOOP}p1" /mnt/vp2 2>/dev/null; then
  find /mnt/vp2 -maxdepth 2 -type f | sed 's|/mnt/vp2|    |' | head -12
  [ -f /mnt/vp2/boot.scr ] || [ -f /mnt/vp2/extlinux/extlinux.conf ] \
    && ok "有引导脚本（boot.scr 或 extlinux.conf）" \
    || bad "bootfs 上没有任何引导脚本"
  # 走 extlinux（厂商 U-Boot 上验证过的路径）：路径与参数全写死，没有 U-Boot 脚本逻辑
  EX=/mnt/vp2/extlinux/extlinux.conf
  if [ -f "$EX" ]; then
    ok "extlinux/extlinux.conf 在"
    grep -q '^  kernel /Image$' "$EX"   && ok "extlinux: kernel /Image"   || bad "extlinux 缺 kernel /Image"
    grep -q '^  initrd /uInitrd$' "$EX" && ok "extlinux: initrd /uInitrd" || bad "extlinux 缺 initrd /uInitrd"
    grep -q '^  fdt /dtb/rockchip/rk3528-w132d.dtb$' "$EX" && ok "extlinux: fdt 指向本板 DTB" || bad "extlinux 的 fdt 不是本板 DTB"
    grep -q '^  append root=UUID=' "$EX" && ok "extlinux: root=UUID=…" || bad "extlinux 缺 root=UUID"
    grep -q 'console=ttyS0,115200' "$EX" && ok "extlinux: console=ttyS0,115200" || bad "extlinux 缺 console=ttyS0"
    [ -f /mnt/vp2/boot.scr ] && bad "boot.scr 还在 —— 厂商 U-Boot 会先找 extlinux，但两者并存容易糊涂" || true
  else
    bad "缺 extlinux/extlinux.conf —— 板级配置的 SRC_EXTLINUX 没生效"
  fi
  ls /mnt/vp2/dtb*/rockchip/rk3528-w132d.dtb >/dev/null 2>&1 \
    || ls /mnt/vp2/rockchip/rk3528-w132d.dtb >/dev/null 2>&1 \
    && ok "板级 DTB 在 bootfs 上" || bad "bootfs 上找不到 rk3528-w132d.dtb"
  umount /mnt/vp2
else
  bad "挂不上 bootfs"
fi

echo
echo "── 4. rootfs 定制与服务 ──"
if mount -o ro "${LOOP}p2" /mnt/vp3 2>/dev/null; then
  n=0; miss=0
  while IFS= read -r rel; do
    if [ -e "/mnt/vp3/$rel" ]; then n=$((n+1)); else
      [ "$miss" -lt 5 ] && echo "    缺: /$rel"; miss=$((miss+1)); fi
  done < <(cd "$W/userpatches/overlay/bsp-cli" && find . -type f -not -name .DS_Store -not -path '*/__pycache__/*' | sed 's|^\./||')
  # 宿主 macOS 的垃圾不该进镜像
  n=$(find /mnt/vp3/etc /mnt/vp3/usr/local /mnt/vp3/lib/firmware \( -name .DS_Store -o -name __pycache__ \) 2>/dev/null | wc -l)
  [ "$n" = 0 ] && ok "镜像里没有 .DS_Store / __pycache__" || bad "镜像里混进了 $n 个 .DS_Store/__pycache__"
  [ "$miss" = 0 ] && ok "overlay $n 个文件全部到位" \
                  || bad "overlay 缺 $miss 个（到位 $n 个）"

  for u in w132d-wireless w132d-bluetooth w132d-ble-remote w132d-ir-keymap \
           w132d-led-status w132d-soft-standby; do
    if ls /mnt/vp3/etc/systemd/system/multi-user.target.wants/"$u".service >/dev/null 2>&1; then
      ok "$u.service 已使能"
    else
      bad "$u.service 未使能"
    fi
  done
  # unit 里 Exec*= 指到的每个可执行文件、Requires=/After= 引用的每个 w132d unit
  # 都必须真的在镜像里。dpkg 装 unit 不会检查这些，systemd 到开机才报——
  # 实测第一版镜像 ExecStartPre 指向一个根本没铺进去的脚本、drop-in Requires 一个
  # 早已删除的 unit，离线校验全绿。
  for u in "$W"/userpatches/overlay/bsp-cli/etc/systemd/system/*.service \
           "$W"/userpatches/overlay/bsp-cli/etc/systemd/system/*.d/*.conf; do
    while IFS= read -r exe; do
      [ -n "$exe" ] || continue
      [ -x "/mnt/vp3$exe" ] && ok "$(basename "$u"): $exe 在" \
                             || bad "$(basename "$u") 用到的 $exe 不在镜像里"
    done < <(sed -n 's/^Exec[A-Za-z]*=-\{0,1\}\(\/[^ ]*\).*/\1/p' "$u" | sort -u)
    while IFS= read -r dep; do
      [ -n "$dep" ] || continue
      [ -f "/mnt/vp3/etc/systemd/system/$dep" ] || [ -f "/mnt/vp3/lib/systemd/system/$dep" ] \
        && ok "$(basename "$u") 依赖的 $dep 在" || bad "$(basename "$u") 依赖的 $dep 不存在"
    done < <(grep -ohE '^(Requires|After|Before|Wants|PartOf)=.*' "$u" | grep -oE 'w132d-[a-z0-9-]+\.service' | sort -u)
  done
  # 脚本的运行时依赖包（板级配置 PACKAGE_LIST_BOARD 装的）
  for p in bluez ir-keytable python3-dbus python3-gi rfkill; do
    grep -q "^Package: $p\$" /mnt/vp3/var/lib/dpkg/status && ok "包 $p 已装" || bad "包 $p 没装"
  done
  ls -d /mnt/vp3/usr/lib/python3/dist-packages/dbus /mnt/vp3/usr/lib/python3/dist-packages/gi >/dev/null 2>&1 \
    && ok "python3 的 dbus / gi 模块在" || bad "python3 缺 dbus 或 gi 模块 —— BLE 桥接起不来"

  # extension 编出来的原生工具：必须在、必须是 aarch64（e_machine 0xB7）
  for t in w132d-btattach w132d-bl31-cookie; do
    f="/mnt/vp3/usr/local/sbin/$t"
    if [ -x "$f" ]; then
      m=$(od -An -tx1 -j18 -N2 "$f" | tr -d ' \n')
      [ "$m" = "b700" ] && ok "$t 已编译（aarch64）" || bad "$t 不是 aarch64 ELF（e_machine=$m）"
    else
      bad "$t 不在镜像里"
    fi
  done
  # 编完工具链必须卸掉，否则 minimal 镜像平白多近百 MB
  [ -e /mnt/vp3/usr/bin/gcc ] && bad "gcc 还留在镜像里（extension 没卸干净工具链）" \
                              || ok "编译工具链已卸掉"

  # 内核包与 Armbian 官方同名：没有这条 pin，官方版本号追上来的那天 apt upgrade 把设备打死
  grep -q 'Pin: origin apt.armbian.com' /mnt/vp3/etc/apt/preferences.d/w132d-kernel 2>/dev/null \
    && ok "apt pin：官方源的同名内核包被挡住" || bad "缺 /etc/apt/preferences.d/w132d-kernel —— apt upgrade 会装上官方内核"

  # ⚠️ BL31 cookie（实验性绕过）挂在 sysinit.target 下
  ls /mnt/vp3/etc/systemd/system/sysinit.target.wants/w132d-bl31-cookie.service >/dev/null 2>&1 \
    && ok "w132d-bl31-cookie.service 已使能（sysinit.target）" \
    || bad "w132d-bl31-cookie.service 未使能"

  ls /mnt/vp3/etc/systemd/system/sysinit.target.wants/w132d-vendor-mac.service >/dev/null 2>&1 \
    && ok "w132d-vendor-mac.service 已使能（出厂 MAC）" || bad "w132d-vendor-mac.service 未使能 —— 每次重刷 MAC 都变"

  # getty 必须在 UART0（ttyS0）上，ttyS2 本板没使能
  ls /mnt/vp3/etc/systemd/system/getty.target.wants/serial-getty@ttyS0.service >/dev/null 2>&1 \
    && ok "serial-getty@ttyS0 已使能" || bad "serial-getty@ttyS0 未使能（SERIALCON 没生效？）"
  ls /mnt/vp3/etc/systemd/system/getty.target.wants/serial-getty@ttyS2.service >/dev/null 2>&1 \
    && bad "serial-getty@ttyS2 仍然使能 —— 那个串口不存在，开机会白等 90 秒" || true

  # WCN 固件：bsp 包从 CoreELEC 钉住的提交装的 W23.03.2，DTS 指向它；sha256 必须就是那份。
  # 三天线 RF 配置由 overlay 装、根目录有软链（驱动到 /lib/firmware 根目录找）。
  # 唯一允许的 divert：本机 customize-image 把包内 W23 改道到 .w23、主文件换成私有的
  # 出厂 W25（这种镜像不是公开构建）；其它任何 uwe5622 的 divert 都是没删干净的旧东西。
  fw=/mnt/vp3/lib/firmware/uwe5622
  WCN_SHA=d84724b2e442a79d3999c630e5a13a418ef3f1b0a5ecafcf1ce031b3ede758cb
  wcn_ver() { grep -ao 'MARLIN3E_[^[:cntrl:]]*' "$1" 2>/dev/null | head -1 | cut -c1-24; }
  if grep -q "wcnmodem-marlin3e.bin.w23" /mnt/vp3/var/lib/dpkg/diversions 2>/dev/null; then
    [ "$(sha256sum "$fw/wcnmodem-marlin3e.bin.w23" 2>/dev/null | cut -d' ' -f1)" = "$WCN_SHA" ] \
      && grep -qa "MARLIN3E_" "$fw/wcnmodem-marlin3e.bin" \
      && ok "本机覆盖：wcnmodem-marlin3e.bin = $(wcn_ver "$fw/wcnmodem-marlin3e.bin")，包内 W23 改道在 .w23（此镜像含私有固件，不是公开构建）" \
      || bad "固件改道了，但 .w23 不是钉住的 W23 或主文件不是 Marlin3E 固件"
  else
    [ "$(sha256sum "$fw/wcnmodem-marlin3e.bin" 2>/dev/null | cut -d' ' -f1)" = "$WCN_SHA" ] \
      && ok "wcnmodem-marlin3e.bin 在且 sha256 是钉住的那份（$(wcn_ver "$fw/wcnmodem-marlin3e.bin")）" \
      || bad "缺 wcnmodem-marlin3e.bin 或 sha256 不对 —— WiFi/蓝牙起不来"
    grep -q "uwe5622" /mnt/vp3/var/lib/dpkg/diversions 2>/dev/null \
      && bad "还有 uwe5622 的 dpkg-divert —— 私有固件那套没删干净" \
      || ok "没有固件 divert（公开构建，固件就是包里那份）"
  fi
  [ -f "$fw/wifi_56630001_3ant.ini" ] && ok "三天线 RF 配置 uwe5622/wifi_56630001_3ant.ini 在" \
                                       || bad "缺 uwe5622/wifi_56630001_3ant.ini"
  [ -f /mnt/vp3/lib/firmware/wifi_56630001_3ant.ini ] \
    && ok "/lib/firmware/wifi_56630001_3ant.ini 可达（驱动在根目录找）" \
    || bad "/lib/firmware/wifi_56630001_3ant.ini 不可达 —— 驱动找不到 RF 配置"
  umount /mnt/vp3
else
  bad "挂不上 rootfs"
fi

echo
[ "$FAIL" = 0 ] && echo "IMAGE_VERIFY_OK" || { echo "IMAGE_VERIFY_FAILED"; exit 1; }
