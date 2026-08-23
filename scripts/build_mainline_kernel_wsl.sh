#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
WIN_DIR="${W132D_MAINLINE_DIR:-$(cd -- "$SCRIPT_DIR/.." && pwd)}"
KERNEL_DIR="${W132D_MAINLINE_KERNEL_DIR:-/root/w132d-build/linux-v7.1}"
ARCH=arm64
CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
OUT_DIR="$WIN_DIR/out"

"$WIN_DIR/scripts/build_mainline_dtb_wsl.sh"
echo '=== build Linux v7.1 Image ==='
make -C "$KERNEL_DIR" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" LOCALVERSION= Image -j"$(nproc)"
mkdir -p "$OUT_DIR"
cp -f "$KERNEL_DIR/arch/$ARCH/boot/Image" "$OUT_DIR/Image"
printf 'MAINLINE_KERNEL_DONE %s\n' "$OUT_DIR/Image"
