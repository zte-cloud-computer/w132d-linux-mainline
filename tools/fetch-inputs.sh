#!/bin/bash
# SPDX-License-Identifier: MIT
# 拉取构建输入到 cache/：内核源码，以及刷机用的 rkbin SPL loader。
#
# 用法: tools/fetch-inputs.sh
#
# cache/ 整个不入库 —— 里面的东西都能重新获取，而且体积大。这个脚本就是"重新获取"
# 的唯一权威定义：换台机器、或者 cache/ 被清掉，跑一遍就能回到可构建状态。
#
# 本项目已经没有私有输入：WiFi 固件用 Armbian 包自带的，RF 配置随 overlay。
# 若将来又出现不可再分发的东西，另开不入库的目录，别混进 cache/。
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
KVER="${KVER:-7.2.2}"
SRC="$HERE/cache/src"

mkdir -p "$SRC"

TARBALL="$SRC/linux-$KVER.tar.xz"
if [ -f "$TARBALL" ]; then
  echo "✅ 内核源码已在位：linux-$KVER.tar.xz"
else
  MAJOR="${KVER%%.*}"
  URL="https://cdn.kernel.org/pub/linux/kernel/v${MAJOR}.x/linux-$KVER.tar.xz"
  echo "下载 $URL ..."
  curl -fL --progress-bar -o "$TARBALL.part" "$URL"
  mv "$TARBALL.part" "$TARBALL"
  echo "✅ linux-$KVER.tar.xz（$(du -h "$TARBALL" | cut -f1)）"
fi

# ## 刷机用的 SPL loader（rkbin，按 RKBOOT/RK3528MINIALL.ini 用 boot_merger 打包）
#
# 按针孔进的 Loader 是设备自己 idbloader 里的**厂商 miniloader**，它写大文件会静默
# 截断（2026-09-04 实测：报 100%，eMMC 上只有前 16–24 MB 对，后面全 0xCC）。刷写必须
# 换成 rkbin 的 usbplug：flash.sh 用 `rd 3` 把设备从 Loader 复位进 MaskROM，`db` 这个
# 文件，再写。它只在刷机那台电脑上用，不进镜像、不随发布物分发（rkbin 许可允许原样使用）。
# boot_merger 是 x86_64 Linux 二进制，在 linux/amd64 容器里跑一下即可（Apple Silicon 走 Rosetta）。
RKBIN_COMMIT="3e288fe814e059dd06833495f845cab04ac20a5c"
RKBIN="$HERE/cache/rkbin"
LOADER="$RKBIN/rk3528_loader_v1.13.107.bin"
if [ -f "$LOADER" ]; then
  echo "✅ SPL loader 已在位：$(basename "$LOADER")"
else
  mkdir -p "$RKBIN/bin/rk35" "$RKBIN/RKBOOT" "$RKBIN/tools"
  for f in bin/rk35/rk3528_ddr_1056MHz_v1.14.bin bin/rk35/rk3528_usbplug_v1.04.bin \
           bin/rk35/rk3528_spl_v1.07.bin RKBOOT/RK3528MINIALL.ini tools/boot_merger; do
    echo "下载 rkbin/$f ..."
    curl -fsSL -o "$RKBIN/$f" "https://raw.githubusercontent.com/rockchip-linux/rkbin/$RKBIN_COMMIT/$f"
  done
  chmod +x "$RKBIN/tools/boot_merger"
  docker run --rm --platform linux/amd64 -v "$RKBIN":/rk -w /rk debian:13 \
    ./tools/boot_merger RKBOOT/RK3528MINIALL.ini | tail -2
  [ -f "$LOADER" ] || { echo "❌ boot_merger 没有产出 $(basename "$LOADER")"; exit 1; }
  echo "✅ $(basename "$LOADER")（$(du -h "$LOADER" | cut -f1)）"
fi

echo
echo "FETCH_OK  下一步："
echo "  docker run --rm -v w132d-72:/build -v \"\$PWD\":/w -v \"\$PWD/cache/src\":/src:ro \\"
echo "      debian:13 bash /w/tools/build-dtb.sh"
echo "  刷机：W132D_SPL_LOADER=$LOADER tools/flash.sh out/release"
