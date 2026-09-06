#!/bin/bash
# SPDX-License-Identifier: MIT
# 拉取构建输入到 cache/（不入库，丢了重跑即可）：内核源码 tarball，以及刷机用的 rkbin loader。
# 用法: tools/fetch-inputs.sh [--loader-only]
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
KVER="${KVER:-7.2.2}"
SRC="$HERE/cache/src"

mkdir -p "$SRC"

TARBALL="$SRC/linux-$KVER.tar.xz"
if [ "${1:-}" = "--loader-only" ]; then
  :
elif [ -f "$TARBALL" ]; then
  echo "✅ 内核源码已在位：linux-$KVER.tar.xz"
else
  MAJOR="${KVER%%.*}"
  URL="https://cdn.kernel.org/pub/linux/kernel/v${MAJOR}.x/linux-$KVER.tar.xz"
  echo "下载 $URL ..."
  curl -fL --progress-bar -o "$TARBALL.part" "$URL"
  mv "$TARBALL.part" "$TARBALL"
  echo "✅ linux-$KVER.tar.xz（$(du -h "$TARBALL" | cut -f1)）"
fi

# 刷机 loader：rkbin 的 DDR blob + usbplug + SPL，按 RKBOOT/RK3528MINIALL.ini 用 boot_merger 打包。
# 必须用它而不是设备自带的厂商 miniloader：后者写大文件报 100% 却只写前十几 MB（flash.sh 用 rd 3 换掉它）。
# 只在刷机电脑上用，不进镜像，随发布包一起分发（rkbin 许可允许原样使用）。boot_merger 是 x86_64 二进制。
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
  # x86 或装了 qemu-user-static 的机器直接跑，否则经 Docker（Apple Silicon 走 Rosetta）
  if [ "$(uname -m)" = x86_64 ] || command -v qemu-x86_64-static >/dev/null; then
    (cd "$RKBIN" && ./tools/boot_merger RKBOOT/RK3528MINIALL.ini | tail -2)
  else
    docker run --rm --platform linux/amd64 -v "$RKBIN":/rk -w /rk debian:13 \
      ./tools/boot_merger RKBOOT/RK3528MINIALL.ini | tail -2
  fi
  [ -f "$LOADER" ] || { echo "❌ boot_merger 没有产出 $(basename "$LOADER")"; exit 1; }
  echo "✅ $(basename "$LOADER")（$(du -h "$LOADER" | cut -f1)）"
fi

[ "${1:-}" = "--loader-only" ] && exit 0
echo
echo "FETCH_OK  下一步："
echo "  docker run --rm --privileged -v /dev:/tmp/dev -v w132d-armbian:/build -v \"\$PWD\":/w \\"
echo "      debian:13 bash -c 'bash /w/tools/armbian-kernel.sh build && bash /w/tools/verify-image.sh && bash /w/tools/make-release.sh'"
echo "  刷机：flash/flash.sh out/release   （loader 从 cache/rkbin 自动找到）"
