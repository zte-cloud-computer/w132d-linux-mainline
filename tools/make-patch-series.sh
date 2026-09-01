#!/bin/bash
# SPDX-License-Identifier: MIT
# 把本项目对内核的改动维护成"内核树上的一串 git 提交"，并由它产出两样东西：
#   1. Armbian 的补丁目录内容（userpatches/kernel/archive/rockchip64-<ver>/）
#   2. 可以直接 git send-email 投给 LKML 的补丁
#
# 用法（容器里）：
#   bash /w/tools/make-patch-series.sh [内核版本]      # 默认 7.2.2
#
# ## 为什么是 git 提交，不是散装 .patch
#
# 散装 .patch 有两个治不好的毛病：
#
#   * **漂了只能看 .rej 猜。** 换成 git 之后，`git rebase` 到新内核会直接指出
#     哪个提交、哪个 hunk 冲突，冲突长什么样 —— 这就是防漂机制本身。
#
#   * **投不出去。** 主线要求每个补丁一个逻辑改动、带 Subject、带正文说明"为什么"、
#     带 Signed-off-by。我们导入的这批原本是裸 `diff --git`，一样都没有。
#     提交信息写在 patches-src/messages/ 里，由本脚本贴到提交上。
#
# 每上游成功一个，漂移面就小一块 —— 这是唯一能真正终结漂移的办法。
#
# ## 产物在哪
#
#   $B/series/            git format-patch 输出（投主线用，带 From/Subject/S-o-b）
#   userpatches/kernel/archive/rockchip64-<ver>/   Armbian 用（同一批，改名加序号）
set -euo pipefail

W="${W132D_ROOT:-/w}"
B=/build
KVER="${1:-7.2.2}"
KSERIES="${KVER%.*}"                      # 7.2.2 -> 7.2
TREE="$B/series-tree"
SERIES="$B/series"
ARMBIAN_DIR="$W/userpatches/kernel/archive/rockchip64-$KSERIES"
MSGS="$W/patches-src/messages"
SRCPATCH="$W/patches-src/import"

# 提交作者：投主线时 Signed-off-by 必须是真实身份
GIT_NAME="${W132D_GIT_NAME:-wenziwanka}"
GIT_EMAIL="${W132D_GIT_EMAIL:-tech@wenziwanka.com}"

step(){ echo; echo "########## $* ##########"; }

export DEBIAN_FRONTEND=noninteractive
apt-get -qq update >/dev/null 2>&1
apt-get -qq install -y --no-install-recommends \
  git ca-certificates patch xz-utils python3 curl >/dev/null 2>&1

step "1/4 准备内核树（linux-$KVER）"
TB="$B/tarballs/linux-$KVER.tar.xz"
mkdir -p "$B/tarballs"
[ -f "$TB" ] || curl -sfL -o "$TB" \
  "https://cdn.kernel.org/pub/linux/kernel/v${KVER%%.*}.x/linux-$KVER.tar.xz"
rm -rf "$TREE"; mkdir -p "$TREE"
tar -xf "$TB" -C "$TREE" --strip-components=1
git -C "$TREE" init -q
git -C "$TREE" config user.name  "$GIT_NAME"
git -C "$TREE" config user.email "$GIT_EMAIL"
git -C "$TREE" add -A
git -C "$TREE" commit -qm "linux $KVER (base)"
BASE=$(git -C "$TREE" rev-parse HEAD)
echo "  基线提交 ${BASE:0:12}"

step "2/4 逐个应用并提交"
n=0
for f in "$SRCPATCH"/*.patch; do
  name=$(basename "$f" .patch)          # 例如 0001-rkvdec
  msg="$MSGS/$name.msg"
  [ -f "$msg" ] || { echo "  ❌ 缺提交信息 $msg"; exit 1; }
  out=$(patch -d "$TREE" -p1 --forward --batch < "$f" 2>&1) || {
    echo "  ❌ $name 打不上（内核 $KVER 已漂）"; sed 's/^/     /' <<<"$out"; exit 1
  }
  if grep -q 'with fuzz' <<<"$out"; then
    echo "  ⚠️  $name 带 fuzz 应用 —— 重新锚定的机会就是现在"
  fi
  find "$TREE" -name '*.orig' -delete; find "$TREE" -name '*.rej' -delete
  git -C "$TREE" add -A
  git -C "$TREE" commit -q --file="$msg" --signoff
  n=$((n+1))
  printf '  ✅ %-22s %s\n' "$name" "$(git -C "$TREE" log -1 --format=%s)"
done
echo "  共 $n 个补丁提交"

# 板级 DTS 也必须是补丁：Armbian 的补丁目录只应用 *.patch，
# 往那里丢一个裸 .dts 文件是**静默无效**的 —— 不会报错，只是永远不生效。
step "2b/4 板级 DTS 作为最后一个提交"
DTS="$W/userpatches/board/rk3528-w132d.dts"
[ -f "$DTS" ] || { echo "  ❌ 缺板级 DTS：$DTS"; exit 1; }
cp -f "$DTS" "$TREE/arch/arm64/boot/dts/rockchip/"
MK="$TREE/arch/arm64/boot/dts/rockchip/Makefile"
grep -qxF 'dtb-$(CONFIG_ARCH_ROCKCHIP) += rk3528-w132d.dtb' "$MK" \
  || printf '\ndtb-$(CONFIG_ARCH_ROCKCHIP) += rk3528-w132d.dtb\n' >> "$MK"
git -C "$TREE" add -A
git -C "$TREE" commit -q --file="$MSGS/0005-board-dts.msg" --signoff
n=$((n+1))
echo "  ✅ $(git -C "$TREE" log -1 --format=%s)"

step "3/4 产出投主线用的补丁"
rm -rf "$SERIES"; mkdir -p "$SERIES"
git -C "$TREE" format-patch -q -o "$SERIES" "$BASE" >/dev/null
ls "$SERIES" | sed 's/^/  /'
# 主线补丁必须带 Signed-off-by，缺了 maintainer 直接退回
for p in "$SERIES"/*.patch; do
  grep -q '^Signed-off-by:' "$p" || { echo "  ❌ $(basename "$p") 缺 Signed-off-by"; exit 1; }
done
echo "  ✅ 全部带 Signed-off-by"

step "4/4 同步到 Armbian 补丁目录"
mkdir -p "$ARMBIAN_DIR"
rm -f "$ARMBIAN_DIR"/*.patch
cp "$SERIES"/*.patch "$ARMBIAN_DIR/"
ls "$ARMBIAN_DIR" | sed 's/^/  /'

echo
echo "SERIES_OK  基线 linux-$KVER，$n 个提交"
echo "  投主线：$SERIES/（git send-email 可直接用）"
echo "  Armbian：$ARMBIAN_DIR/"
