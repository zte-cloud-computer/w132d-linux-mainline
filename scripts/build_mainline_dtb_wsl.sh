#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
WIN_DIR="${W132D_MAINLINE_DIR:-$(cd -- "$SCRIPT_DIR/.." && pwd)}"
KERNEL_DIR="${W132D_MAINLINE_KERNEL_DIR:-/root/w132d-build/linux-v7.1}"
ARCH=arm64
CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
DTS_NAME=rk3528-w132d
DTS_SRC="${W132D_MAINLINE_DTS_SRC:-$WIN_DIR/board/${DTS_NAME}.dts}"
DTS_DST="$KERNEL_DIR/arch/arm64/boot/dts/rockchip/${DTS_NAME}.dts"
DTB="$KERNEL_DIR/arch/arm64/boot/dts/rockchip/${DTS_NAME}.dtb"
MAKEFILE="$KERNEL_DIR/arch/arm64/boot/dts/rockchip/Makefile"
OUT_DIR="$WIN_DIR/out"

[ -d "$KERNEL_DIR" ] || { echo "ERROR: kernel checkout not found: $KERNEL_DIR" >&2; exit 1; }
[ -f "$DTS_SRC" ] || { echo "ERROR: W132D DTS not found: $DTS_SRC" >&2; exit 1; }
command -v "$CROSS_COMPILE"gcc >/dev/null || {
	echo "ERROR: missing cross compiler: ${CROSS_COMPILE}gcc" >&2
	exit 1
}

cp -f "$DTS_SRC" "$DTS_DST"
if ! grep -qxF "dtb-\$(CONFIG_ARCH_ROCKCHIP) += ${DTS_NAME}.dtb" "$MAKEFILE"; then
	printf '\ndtb-$(CONFIG_ARCH_ROCKCHIP) += %s.dtb\n' "$DTS_NAME" >> "$MAKEFILE"
fi

"$WIN_DIR/scripts/prepare_mainline_kernel_wsl.sh"
echo '=== build W132D mainline DTB ==='
make -C "$KERNEL_DIR" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" LOCALVERSION= \
	"rockchip/${DTS_NAME}.dtb" -j"$(nproc)"

mkdir -p "$OUT_DIR"
cp -f "$DTB" "$OUT_DIR/${DTS_NAME}.dtb"
cp -f "$DTS_DST" "$OUT_DIR/${DTS_NAME}.dts"
printf 'MAINLINE_DTB_DONE %s\n' "$OUT_DIR/${DTS_NAME}.dtb"
