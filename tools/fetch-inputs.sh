#!/bin/bash
# SPDX-License-Identifier: MIT
# 拉取构建输入到 cache/：内核源码与上游板级仓库。
#
# 用法: tools/fetch-inputs.sh
#
# cache/ 整个不入库 —— 里面的东西都能重新获取，而且体积大。这个脚本就是"重新获取"
# 的唯一权威定义：换台机器、或者 cache/ 被清掉，跑一遍就能回到可构建状态。
#
# ⚠️ 逐机数据（BL31 原版、RF 校准、SN/MAC）**不要**放这里 —— 那些不可再生，
# 归 private/ 管，且绝不可提交。
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

echo
echo "FETCH_OK  下一步："
echo "  docker run --rm -v w132d-72:/build -v \"\$PWD\":/w -v \"\$PWD/cache/src\":/src:ro \\"
echo "      debian:13 bash /w/tools/build-dtb.sh"
