#!/bin/bash
# SPDX-License-Identifier: MIT
# 校验一批 deb（CI 或本机 armbian/build 产出的）：装到设备之前能离线判掉的都判掉。
#
# 用法：bash tools/verify-debs.sh <放 deb 的目录>
#
# 和 verify-image.sh 是一个思路：产出"有"不等于"对"。内核包少了板级 DTB 设备起不来；
# 少了 rk3528 音频模块没声音；config 里 PSTORE_CONSOLE 没开硬挂零现场 —— 这些构建
# 都不会报错。这里把每一条都对应到一个真实后果。
set -uo pipefail
DIR="${1:?用法: verify-debs.sh <deb 目录>}"
HERE="$(cd "$(dirname "$0")" && pwd)"
FAIL=0
ok(){ printf '  ✅ %s\n' "$*"; }
bad(){ printf '  ❌ %s\n' "$*"; FAIL=1; }
# 同一目录里可能躺着多轮构建的同名包（版本串相同、哈希不同），取最新的那个
one(){ ls -t "$DIR"/"$1"_*.deb 2>/dev/null | head -1; }

command -v dpkg-deb >/dev/null || { echo "❌ 缺 dpkg-deb"; exit 1; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

echo "── linux-dtb ──"
DTB=$(one linux-dtb-edge-rockchip64)
if [ -n "$DTB" ]; then
  dpkg-deb -x "$DTB" "$T/dtb"
  f=$(find "$T/dtb" -name rk3528-w132d.dtb | head -1)
  if [ -n "$f" ]; then
    ok "rk3528-w132d.dtb 在包里（$(stat -c %s "$f") B）"
    # 关键属性 16 条：DTS 改坏了 DTB 照样编得出来
    if bash "$HERE/verify-dtb.sh" "$f" >"$T/dtb.log" 2>&1; then
      ok "DTB 关键属性校验通过"
    else
      bad "DTB 关键属性校验未通过"; grep '❌' "$T/dtb.log" | head -5 | sed 's/^/     /'
    fi
  else
    bad "包里没有 rk3528-w132d.dtb —— 设备起不来"
  fi
else
  bad "缺 linux-dtb-edge-rockchip64 deb"
fi

echo "── linux-image ──"
IMG=$(one linux-image-edge-rockchip64)
if [ -n "$IMG" ]; then
  dpkg-deb --fsys-tarfile "$IMG" > "$T/image.tar"
  tar -tf "$T/image.tar" > "$T/image.list"
  for m in snd-soc-rk3528.ko snd-soc-es7202.ko sprdwl_ng.ko uwe5622_bsp_sdio.ko sprdbt_tty.ko \
           rockchip-vdec.ko lima.ko gpio-ir-recv.ko; do
    grep -q "/$m\$" "$T/image.list" && ok "模块 $m" || bad "缺模块 $m"
  done
  tar -xOf "$T/image.tar" --wildcards './boot/config-*' > "$T/config"
  for c in CONFIG_PSTORE_CONSOLE=y CONFIG_PSTORE_RAM=y CONFIG_SND_SOC_RK3528=m CONFIG_SND_SOC_ES7202=m; do
    grep -qx "$c" "$T/config" && ok "config $c" || bad "config 缺 $c"
  done
else
  bad "缺 linux-image-edge-rockchip64 deb"
fi

echo "── linux-u-boot ──"
UB=$(one linux-u-boot-w132d-edge)
if [ -n "$UB" ]; then
  dpkg-deb -c "$UB" > "$T/ub.list"
  for f in usr/lib/linux-u-boot-edge-w132d/idbloader.img usr/lib/linux-u-boot-edge-w132d/u-boot.itb; do
    grep -q " \./$f\$" "$T/ub.list" && ok "u-boot 含 $f" || bad "u-boot 缺 $f"
  done
  dpkg-deb --fsys-tarfile "$UB" | tar -xOf - ./usr/lib/linux-u-boot-edge-w132d/u-boot.itb > "$T/u-boot.itb" 2>/dev/null
  head -c 4 "$T/u-boot.itb" | od -An -tx1 | grep -q "d0 0d fe ed" && ok "u-boot.itb 是 FIT" || bad "u-boot.itb 不是 FIT"
  # 针孔下载键：节点必须叫 saradc@…（主线只认这个名字前缀），代码也得编进去
  grep -qa "saradc@ffae0000" "$T/u-boot.itb" && ok "U-Boot DT 里 saradc 节点叫 saradc@ffae0000（针孔可用）" || bad "U-Boot DT 里没有 saradc@ffae0000 —— 针孔无效"
  grep -qa "download key pressed" "$T/u-boot.itb" && ok "U-Boot 编进了下载键检查（ADC 打开）" || bad "U-Boot 没编下载键检查（CONFIG_ADC 没开？）"
  dpkg-deb --fsys-tarfile "$UB" | tar -xOf - ./usr/lib/linux-u-boot-edge-w132d/idbloader.img > "$T/idbloader.img" 2>/dev/null
  sz=$(stat -c %s "$T/idbloader.img" 2>/dev/null || echo 0)
  [ "$sz" -gt 0 ] && [ "$sz" -lt $((7104*512)) ] && ok "idbloader.img $sz B（写到扇区 64，不会碰到 7168 的 vendor storage）" || bad "idbloader.img 大小异常：$sz"
else
  bad "缺 linux-u-boot-w132d-edge deb"
fi

echo "── armbian-bsp-cli ──"
BSP=$(one armbian-bsp-cli-w132d-edge)
if [ -n "$BSP" ]; then
  dpkg-deb -c "$BSP" > "$T/bsp.list"
  for f in etc/apt/preferences.d/w132d-kernel etc/rc_keymaps/w132d.toml usr/local/bin/w132d-bt-smp-ensure \
           lib/firmware/uwe5622/wifi_56630001_3ant.ini lib/firmware/wifi_56630001_3ant.ini \
           lib/firmware/uwe5622/wcnmodem-marlin3e.bin; do
    # dpkg-deb -c 对软链打印 "path -> target"，所以不能要求行尾就是路径
    grep -qE " \./$f( -> |\$)" "$T/bsp.list" && ok "bsp 含 $f" || bad "bsp 缺 $f"
  done
  # WCN 固件必须是钉住的那份（CoreELEC/uwe5631-aml @ 82f0b4a1，MARLIN3E_20A_W23.03.2）
  WCN_SHA=d84724b2e442a79d3999c630e5a13a418ef3f1b0a5ecafcf1ce031b3ede758cb
  got=$(dpkg-deb --fsys-tarfile "$BSP" | tar -xOf - ./lib/firmware/uwe5622/wcnmodem-marlin3e.bin 2>/dev/null | { sha256sum 2>/dev/null || shasum -a 256; } | cut -d' ' -f1)
  [ "$got" = "$WCN_SHA" ] && ok "bsp 里的 wcnmodem-marlin3e.bin sha256 是钉住的那份" || bad "bsp 里的 wcnmodem-marlin3e.bin sha256 不对（$got）"
  # BL31 uartdbg 的 cookie 由 U-Boot preboot 写，U-Boot 包里必须带这条命令
  grep -qa "mw.l 0xff370220 0x2b4d1f7a" "$T/u-boot.itb" && ok "U-Boot preboot 带 BL31 cookie 写入" || bad "U-Boot 里没有 BL31 cookie 的 preboot 命令 —— 32 分钟后会挂死"
else
  bad "缺 armbian-bsp-cli-w132d-edge deb"
fi

echo
[ "$FAIL" = 0 ] && echo "DEBS_VERIFY_OK $DIR" || { echo "DEBS_VERIFY_FAILED"; exit 1; }
