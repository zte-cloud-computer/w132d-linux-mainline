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
UP="$HERE/cache/upstream"

# 上游板级仓库，钉在 PR #2 的合并点。
#
# **不跟 main 的最新提交**：紧随其后的 1283062a 把 eMMC 从 HS400 降回 52MHz，
# 而 HS400 配合 rk3528-dwcmshc-hs400 补丁是实测可用的。
# tools/verify-dtb.sh 会把这类回退当硬失败拦下来。
PORT_URL=https://github.com/zte-cloud-computer/w132d-linux-mainline
PORT_COMMIT=e07492b5b10b55d2f2d304179628ec694d0ad6fe

mkdir -p "$SRC" "$UP"

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

PORT="$UP/w132d-port"
[ -d "$PORT/.git" ] || git clone -q --depth 50 "$PORT_URL" "$PORT"
git -C "$PORT" fetch -q --depth 50 origin 2>/dev/null || true
git -C "$PORT" checkout -q --detach "$PORT_COMMIT" 2>/dev/null || {
  echo "  固定提交不在浅克隆里，重新完整克隆 ..."
  rm -rf "$PORT"; git clone -q "$PORT_URL" "$PORT"
  git -C "$PORT" checkout -q --detach "$PORT_COMMIT"
}
got=$(git -C "$PORT" rev-parse HEAD)
[ "$got" = "$PORT_COMMIT" ] || { echo "❌ 上游提交漂移：$got"; exit 1; }
echo "✅ 上游板级仓库 @ ${got:0:12} $(git -C "$PORT" log -1 --format=%s)"

# 我们只用其中 4 个补丁 + 板级 DTS，缺任何一个都别开始构建
for p in rk3528-audio rk3528-dwcmshc-hs400 rk3528-rkvdec rk3528-tsadc; do
  [ -s "$PORT/patches/$p-7.1.patch" ] || { echo "❌ 上游缺补丁 $p"; exit 1; }
done
[ -s "$PORT/board/rk3528-w132d.dts" ] || { echo "❌ 上游缺板级 DTS"; exit 1; }
echo "✅ 4 个内核补丁与板级 DTS 齐全"

echo
echo "FETCH_OK  下一步："
echo "  python3 tools/make-board-dts.py $PORT/board/rk3528-w132d.dts \\"
echo "      userpatches/kernel/archive/rockchip64-7.2/rk3528-w132d.dts"
echo "  docker run --rm -v w132d-72:/build -v \"\$PWD\":/w -v \"\$PWD/cache/src\":/src:ro \\"
echo "      debian:13 bash /w/tools/build-dtb.sh"
