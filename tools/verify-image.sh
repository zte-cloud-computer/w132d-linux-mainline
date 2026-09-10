#!/bin/bash
# SPDX-License-Identifier: MIT
# 离线校验 Armbian 出的镜像：分区几何、GPT 身份、引导链、bootfs 内容、rootfs 定制与服务使能。
# 真机刷写才是最终判据，这里把能离线判掉的都判掉：钩子写错了 Armbian 不报错，只是镜像里什么都没有。
# 用法（容器里，需要 --privileged -v /dev:/tmp/dev：要 losetup/mount）：bash /w/tools/verify-image.sh [镜像文件]
#   不给路径则自动找 armbian-build/output/images/ 下最新的
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
# Armbian 镜像只有 bootfs、rootfs 两个分区（对应设备上的 p2、p3；三分区 GPT 由 make-release.sh 生成），
# sfdisk 行首是完整镜像路径加分区号，所以按分区名取
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
  bad "bootfs 缺 LegacyBIOSBootable"
fi

echo
echo "── 2b. 引导链（主线 U-Boot，Armbian 构建时写进镜像）──"
magic() { dd if="$IMG" bs=512 skip="$1" count=1 status=none | head -c 4 | od -An -tx1 | tr -d ' \n'; }
[ "$(magic 64)" = "524b4e53" ] && ok "扇区 64 是 idbloader（RKNS：rkbin DDR + 主线 SPL）" \
                                || bad "扇区 64 不是 idbloader（$(magic 64)）—— write_uboot_platform 没跑？"
[ "$(magic 16384)" = "d00dfeed" ] && ok "扇区 16384 是 u-boot.itb（FIT）" || bad "扇区 16384 不是 FIT（$(magic 16384)）"
nz=$(dd if="$IMG" bs=512 skip=7168 count=3072 status=none | tr -d '\0' | wc -c)
[ "$nz" = 0 ] && ok "7168–10239（vendor storage / RKSS 位置）全零" || bad "7168–10239 有 $nz 个非零字节 —— 镜像里不该有任何机器的 vendor storage"
nz=$(dd if="$IMG" bs=512 skip=404 count=6764 status=none | tr -d '\0' | wc -c)
[ "$nz" = 0 ] && ok "idbloader 之后到 7168 全零（idbloader 没长到 vendor storage）" || bad "扇区 404–7167 有 $nz 个非零字节"

echo
echo "── 3. bootfs 内容 ──"
LOOP=$(losetup -f --show -P "$IMG") || { echo "❌ losetup 失败"; exit 1; }
trap 'umount /mnt/vp2 /mnt/vp3 2>/dev/null; losetup -d "$LOOP" 2>/dev/null' EXIT
mkdir -p /mnt/vp2 /mnt/vp3

# 容器里没有 udev，losetup -P 之后 /dev/loopNpM 不会出现（partx -a 也建不了），但宿主 /dev 里有：
# 按 Armbian 的办法（loop.sh）从挂进来的宿主 /dev（/tmp/dev）读设备号 mknod 复制过来
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
  # 本板只用 extlinux（板级配置 SRC_EXTLINUX）：路径与参数全写死，没有 U-Boot 脚本逻辑
  EX=/mnt/vp2/extlinux/extlinux.conf
  if [ -f "$EX" ]; then
    ok "extlinux/extlinux.conf 在"
    grep -q '^  kernel /Image$' "$EX"   && ok "extlinux: kernel /Image"   || bad "extlinux 缺 kernel /Image"
    grep -q '^  initrd /uInitrd$' "$EX" && ok "extlinux: initrd /uInitrd" || bad "extlinux 缺 initrd /uInitrd"
    grep -q '^  fdt /dtb/rockchip/rk3528-w132d.dtb$' "$EX" && ok "extlinux: fdt 指向本板 DTB" || bad "extlinux 的 fdt 不是本板 DTB"
    grep -q '^  append root=UUID=' "$EX" && ok "extlinux: root=UUID=…" || bad "extlinux 缺 root=UUID"
    grep -q 'console=ttyS0,115200' "$EX" && ok "extlinux: console=ttyS0,115200" || bad "extlinux 缺 console=ttyS0"
    [ -f /mnt/vp2/boot.scr ] && bad "boot.scr 还在 —— 本板只用 extlinux，两者并存容易糊涂" || true
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

  for u in w132d-wireless w132d-ble-remote w132d-ir-keymap \
           w132d-led-status w132d-soft-standby; do
    if ls /mnt/vp3/etc/systemd/system/multi-user.target.wants/"$u".service >/dev/null 2>&1; then
      ok "$u.service 已使能"
    else
      bad "$u.service 未使能"
    fi
  done
  # unit 里 Exec*= 指到的可执行文件、Requires=/After= 引用的 w132d unit 都必须真的在镜像里：
  # dpkg 装 unit 不检查这些，systemd 到开机才报
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
  grep -q "^Package: linux-u-boot-w132d-edge$" /mnt/vp3/var/lib/dpkg/status && ok "包 linux-u-boot-w132d-edge 已装（apt 可升级 U-Boot）" || bad "rootfs 里没装 linux-u-boot-w132d-edge"
  itb=/mnt/vp3/usr/lib/linux-u-boot-edge-w132d/u-boot.itb
  if [ -f "$itb" ]; then
    n=$(stat -c %s "$itb")
    dd if="$IMG" bs=512 skip=16384 count=$(( (n + 511) / 512 )) status=none | head -c "$n" | cmp -s - "$itb" \
      && ok "镜像 16384 处的 u-boot.itb 与包里那份逐字节一致" || bad "镜像里的 u-boot.itb 与包里的不一致"
    grep -qa "saradc@ffae0000" "$itb" && ok "U-Boot DT 的 saradc 节点叫 saradc@ffae0000（针孔可用）" || bad "U-Boot DT 里没有 saradc@ffae0000 —— 针孔无效"
  else
    bad "rootfs 里没有 u-boot.itb"
  fi
  # 脚本的运行时依赖包（板级配置 PACKAGE_LIST_BOARD 装的）
  for p in bluez ir-keytable python3-dbus python3-gi rfkill; do
    grep -q "^Package: $p\$" /mnt/vp3/var/lib/dpkg/status && ok "包 $p 已装" || bad "包 $p 没装"
  done
  ls -d /mnt/vp3/usr/lib/python3/dist-packages/dbus /mnt/vp3/usr/lib/python3/dist-packages/gi >/dev/null 2>&1 \
    && ok "python3 的 dbus / gi 模块在" || bad "python3 缺 dbus 或 gi 模块 —— BLE 桥接起不来"

  # 镜像里不该有用户态蓝牙 attach 工具（hci0 由内核驱动直接注册），也不该有编译器
  [ -e /mnt/vp3/usr/local/sbin/w132d-btattach ] && bad "w132d-btattach 还在（蓝牙由内核驱动注册 hci0，不需要它）" || ok "没有用户态 attach 工具"
  [ -e /mnt/vp3/usr/bin/gcc ] && bad "gcc 留在镜像里" || ok "镜像里没有编译器"

  # 所有外部内核都要封禁（包括发行版的 linux-image-arm64），只允许 Origin: W132D 的板级包。
  pin=/mnt/vp3/etc/apt/preferences.d/w132d-kernel
  allow_line=$(grep -n '^Package: linux-image-edge-rockchip64 ' "$pin" 2>/dev/null | cut -d: -f1)
  deny_line=$(grep -n '^Package: linux-image-\*' "$pin" 2>/dev/null | cut -d: -f1)
  [ -n "$allow_line" ] && [ -n "$deny_line" ] && [ "$allow_line" -lt "$deny_line" ] \
    && grep -q '^Pin: version \*$' "$pin" \
    && grep -q '^Pin: release o=W132D$' "$pin" \
    && ok "apt pin：所有外部内核被挡住，只放行 W132D 源" \
    || bad "缺完整的 W132D 内核锁 —— apt upgrade 可能装上不兼容内核"

  # getty 必须在 UART0（ttyS0）上，ttyS2 本板没使能
  ls /mnt/vp3/etc/systemd/system/getty.target.wants/serial-getty@ttyS0.service >/dev/null 2>&1 \
    && ok "serial-getty@ttyS0 已使能" || bad "serial-getty@ttyS0 未使能（SERIALCON 没生效？）"
  ls /mnt/vp3/etc/systemd/system/getty.target.wants/serial-getty@ttyS2.service >/dev/null 2>&1 \
    && bad "serial-getty@ttyS2 仍然使能 —— 那个串口不存在，开机会白等 90 秒" || true

  # WCN 固件：bsp 包装的是从 CoreELEC 钉住提交取的 W23.03.2，sha256 必须一致；三天线 RF 配置由 overlay 装，
  # 根目录留软链（驱动到 /lib/firmware 根目录找）。唯一允许的 divert 是本机 customize-image 把包内 W23
  # 改道到 .w23、主文件换成出厂 W25（这种镜像是私有构建）；其它 uwe5622 的 divert 都是残留。
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
      && bad "还有 uwe5622 的 dpkg-divert —— 残留的固件改道" \
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
