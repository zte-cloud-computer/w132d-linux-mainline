#!/bin/bash
# SPDX-License-Identifier: MIT
# 把 Armbian 构建出的内核 deb 包转成 ophub/fnnas 的内核格式。
# ophub/fnnas 的 renas 脚本要求四个 tar.gz：
#   boot-<platform>-<kver>.tar.gz     vmlinuz + config + System.map
#   dtb-<platform>-<kver>.tar.gz      所有 dtb 文件
#   modules-<platform>-<kver>.tar.gz  /lib/modules/<kver>/
#   header-<platform>-<kver>.tar.gz   内核头文件
# 以及一份 sha256sums。
#
# 用法：bash tools/deb-to-ophub-kernel.sh <debs目录> <输出目录> [platform]
#   debs目录  包含 linux-image-*.deb、linux-dtb-*.deb、linux-headers-*.deb
#   输出目录  产出 ophub 格式的 tar.gz 和 sha256sums
#   platform  ophub 平台名，默认 rockchip
set -euo pipefail

DEBS="${1:?用法: $0 <debs目录> <输出目录> [platform]}"
OUT="${2:?用法: $0 <debs目录> <输出目录> [platform]}"
PLATFORM="${3:-rockchip}"

die(){ echo "❌ $*" >&2; exit 1; }
step(){ echo; echo "########## $* ##########"; }

# 找到各个 deb
img_deb=$(ls "$DEBS"/linux-image-*.deb 2>/dev/null | head -1)
dtb_deb=$(ls "$DEBS"/linux-dtb-*.deb 2>/dev/null | head -1)
hdr_deb=$(ls "$DEBS"/linux-headers-*.deb 2>/dev/null | head -1)

[ -f "$img_deb" ] || die "找不到 linux-image deb：$DEBS/linux-image-*.deb"
[ -f "$dtb_deb" ] || die "找不到 linux-dtb deb：$DEBS/linux-dtb-*.deb"
[ -f "$hdr_deb" ] || die "找不到 linux-headers deb：$DEBS/linux-headers-*.deb"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

step "1/5 解压 deb 包"
mkdir -p "$TMP"/{img,dtb,hdr}
dpkg-deb -x "$img_deb" "$TMP/img"
dpkg-deb -x "$dtb_deb" "$TMP/dtb"
dpkg-deb -x "$hdr_deb" "$TMP/hdr"

# 确定内核版本号（从 /lib/modules 目录名取）
KVER=$(ls "$TMP/img/lib/modules/" 2>/dev/null | head -1)
[ -n "$KVER" ] || die "无法从 linux-image deb 确定内核版本"
echo "  内核版本: $KVER"

mkdir -p "$OUT"

step "2/5 打 boot tar.gz"
# ophub 的 boot tar.gz 包含 vmlinuz-<kver>、config-<kver>、System.map-<kver>
BOOT_DIR="$TMP/boot-pack"
mkdir -p "$BOOT_DIR"
# Armbian 的 linux-image 把内核放在 /boot/vmlinuz-<kver>
for f in vmlinuz config System.map; do
  src=$(find "$TMP/img/boot" -maxdepth 1 -name "${f}-*" -type f 2>/dev/null | head -1)
  [ -f "$src" ] && cp "$src" "$BOOT_DIR/"
done
# 确保至少有 vmlinuz
ls "$BOOT_DIR"/vmlinuz-* >/dev/null 2>&1 || die "boot 目录里没有 vmlinuz"
(cd "$BOOT_DIR" && tar -czf "$OUT/boot-${PLATFORM}-${KVER}.tar.gz" ./)
echo "  ✅ boot-${PLATFORM}-${KVER}.tar.gz"

step "3/5 打 dtb tar.gz"
# Armbian 的 linux-dtb 把 dtb 放在 /usr/lib/linux-image-<kver>/rockchip/
DTB_SRC=$(find "$TMP/dtb" -type d -name "rockchip" | head -1)
[ -d "$DTB_SRC" ] || DTB_SRC=$(find "$TMP/dtb/usr/lib" -type d -name "linux-image-*" | head -1)
[ -d "$DTB_SRC" ] || die "找不到 dtb 文件目录"
# ophub 期望 dtb 直接是 *.dtb 文件（会被解压到 /boot/dtb/<platform>/）
DTB_PACK="$TMP/dtb-pack"
mkdir -p "$DTB_PACK"
find "$DTB_SRC" -name '*.dtb' -exec cp {} "$DTB_PACK/" \;
n=$(find "$DTB_PACK" -name '*.dtb' | wc -l)
[ "$n" -gt 0 ] || die "没有找到 dtb 文件"
(cd "$DTB_PACK" && tar -czf "$OUT/dtb-${PLATFORM}-${KVER}.tar.gz" ./)
echo "  ✅ dtb-${PLATFORM}-${KVER}.tar.gz（$n 个 dtb）"

step "4/5 打 modules tar.gz"
# ophub 期望解压后直接是 <kver>/ 目录（会被解压到 /usr/lib/modules/）
MOD_SRC="$TMP/img/lib/modules/$KVER"
[ -d "$MOD_SRC" ] || die "找不到模块目录 $MOD_SRC"
(cd "$TMP/img/lib/modules" && tar -czf "$OUT/modules-${PLATFORM}-${KVER}.tar.gz" "$KVER")
echo "  ✅ modules-${PLATFORM}-${KVER}.tar.gz"

step "5/5 打 header tar.gz"
# ophub 期望解压后直接是头文件目录内容（会被解压到 /usr/src/linux-headers-<kver>/）
HDR_SRC=$(find "$TMP/hdr/usr/src" -maxdepth 1 -type d -name "linux-headers-*" | head -1)
[ -d "$HDR_SRC" ] || die "找不到头文件目录"
(cd "$HDR_SRC" && tar -czf "$OUT/header-${PLATFORM}-${KVER}.tar.gz" ./)
echo "  ✅ header-${PLATFORM}-${KVER}.tar.gz"

# 生成 sha256sums
(cd "$OUT" && sha256sum boot-*.tar.gz dtb-*.tar.gz modules-*.tar.gz header-*.tar.gz > sha256sums)
echo
echo "  sha256sums:"
cat "$OUT/sha256sums" | sed 's/^/    /'

echo
echo "OPHUB_KERNEL_VER=$KVER"
echo "DEB_TO_OPHUB_OK"
