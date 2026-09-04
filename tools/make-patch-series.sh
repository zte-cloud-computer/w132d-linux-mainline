#!/bin/bash
# SPDX-License-Identifier: MIT
# 把 patches/ 里的内核改动在内核树上重放成一串 git 提交，并由它产出两样东西：
#   1. 可以直接 git send-email 投给 LKML 的补丁（纯净基线）
#   2. Armbian 补丁目录的内容（userpatches/kernel/archive/rockchip64-<ver>/）
#
# 用法（容器里）：
#   bash /w/tools/make-patch-series.sh [内核版本] [--on-armbian]
#     不带 --on-armbian：基线是纯净内核，产物用于投 LKML
#     带  --on-armbian：基线是"纯净内核 + Armbian 的 rockchip64-7.2 补丁栈"，
#                       产物写进 Armbian 的补丁目录（提交进仓库的就是这份）
#
# ## 输入：patches/ 是唯一的源头
#
#   patches/NNNN-*.patch        完整的 git 补丁（From / Subject / 正文 / Signed-off-by /
#                               diff），可直接 `git am` 到干净主线 —— 这就是投 LKML 的形态
#   patches/rk3528-w132d.dts    第 5 个补丁的源。板级 DTS 必须以补丁形式进 Armbian
#                               的补丁目录（那里只应用 *.patch，丢个裸 .dts 进去是
#                               **静默无效**的），所以由本脚本把它做成最后一个提交
#   patches/NNNN-*.msg          最后一个补丁（板级 DTS）的提交信息，编号最大
#
# ## 为什么是 git 提交，不是散装 .patch
#
#   * **漂了只能看 .rej 猜。** 换成 git 之后，`git rebase` 到新内核会直接指出
#     哪个提交、哪个 hunk 冲突 —— 这就是防漂机制本身。
#   * **投不出去。** 主线要求每个补丁一个逻辑改动、带 Subject、带正文说明"为什么"、
#     带 Signed-off-by。
#
# 每上游成功一个，漂移面就小一块 —— 这是唯一能真正终结漂移的办法。
#
# ## 为什么要两个基线
#
# 主线和 Armbian 是**不同的基线**，同一份 diff 不可能同时打进两边：投 LKML 的必须打在
# 纯净 mainline 上；进 Armbian 的必须打在它那 224 个补丁之后。
#
# 实测踩到过：我们的 mmc 补丁在 `int revision;` 后面插字段，而 Armbian 自己的
# rk3576-0013-mmc-sdhci-dwcmshc-rk3576-dll-tap-calibration 在**同一个位置**插
# `bool needs_hs400_dll_calibration;`。按文件名排序我们的排在前面、先应用，于是把
# 人家的挤失败了 —— 225 个补丁里唯一失败的那个是 Armbian 自己的。所以 --on-armbian
# 模式下 0002 不走 git am，而是由 tools/rebase-mmc-onto-armbian.py 按新上下文重做。
#
# ## 产物可复现
#
# format-patch 带 --zero-commit --no-signature：From 行的 sha 归零、不带 git 版本签名，
# 作者日期来自源补丁 —— 输入不变则产物逐字节不变，仓库里的 Armbian 目录不会白白抖动。
#
# ## 文件名前缀
#
# Armbian 的补丁目录里大家都带前缀（rk3576-*、board-nanopi-r3s-*、general-*），
# 一是分类，二是决定应用顺序。我们用 `w132d-`，字典序排在 `rk3576-` 之后。
#
# ## 产物在哪
#
#   $B/series/                                   投 LKML 用（纯净基线）
#   userpatches/kernel/archive/rockchip64-<ver>/   Armbian 用（--on-armbian）
#
# ## 两类补丁
#
#   w132d-0NNN-*.patch          由本脚本从 patches/ 生成，勿手改
#   w132d-armbian-NNNN-*.patch  只对 Armbian 补丁栈的补丁（Armbian 自己加进来的树外驱动，
#                               主线没有那些文件，进不了 patches/），手工维护，
#                               目标是投给对应的 Armbian 仓库后删掉
set -euo pipefail

W="${W132D_ROOT:-/w}"
B=/build
KVER="${1:-7.2.2}"
ON_ARMBIAN=0
[ "${2:-}" = "--on-armbian" ] && ON_ARMBIAN=1
ARMBIAN="$B/armbian-build"
KSERIES="${KVER%.*}"                      # 7.2.2 -> 7.2
TREE="$B/series-tree"
SERIES="$B/series"
ARMBIAN_DIR="$W/userpatches/kernel/archive/rockchip64-$KSERIES"
PATCHES="$W/patches"
DTS="$PATCHES/rk3528-w132d.dts"

# 提交作者：投主线时 Signed-off-by 必须是真实身份（源补丁里已带；这里只用于基线提交）
GIT_NAME="${W132D_GIT_NAME:-wenziwanka}"
GIT_EMAIL="${W132D_GIT_EMAIL:-tech@wenziwanka.com}"

step(){ echo; echo "########## $* ##########"; }
die(){ echo "  ❌ $*" >&2; exit 1; }
# shellcheck source=tools/lib.sh
. "$(dirname "$0")/lib.sh"

# 把已暂存的改动按某个源补丁的作者 / 日期 / 提交信息提交（0002 在 Armbian 基线上
# 走不了 git am，diff 是重做的，但提交信息必须和源补丁一致）
commit_with_patch_message() {
  local f="$1" tmp; tmp=$(mktemp -d)
  local info; info=$(git -C "$TREE" mailinfo "$tmp/msg" "$tmp/diff" < "$f")
  local subject author email date
  subject=$(sed -n 's/^Subject: //p' <<<"$info")
  author=$(sed -n 's/^Author: //p' <<<"$info")
  email=$(sed -n 's/^Email: //p' <<<"$info")
  date=$(sed -n 's/^Date: //p' <<<"$info")
  [ -n "$subject" ] && [ -n "$email" ] && [ -n "$date" ] || die "$f 缺 Subject/From/Date 头"
  { echo "$subject"; echo; cat "$tmp/msg"; } > "$tmp/full"
  GIT_AUTHOR_DATE="$date" git -C "$TREE" commit -q --author="$author <$email>" --file="$tmp/full"
  rm -rf "$tmp"
}

export DEBIAN_FRONTEND=noninteractive
apt-get -qq update >/dev/null 2>&1
apt-get -qq install -y --no-install-recommends \
  git ca-certificates patch xz-utils python3 curl >/dev/null 2>&1

[ -f "$DTS" ] || die "缺板级 DTS：$DTS"
# DTS 永远是最后一个提交：取编号最大的那个 .msg
DTS_MSG=$(ls "$PATCHES"/[0-9][0-9][0-9][0-9]-*.msg 2>/dev/null | sort | tail -1)
[ -n "$DTS_MSG" ] || die "缺 $PATCHES/NNNN-*.msg（板级 DTS 的提交信息）"

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
if [ "$ON_ARMBIAN" = 1 ]; then
  [ -d "$ARMBIAN/patch/kernel/archive/rockchip64-$KSERIES" ] \
    || die "缺 armbian/build 克隆：先跑一次 tools/armbian-kernel.sh"
  echo "  叠加 Armbian 的 rockchip64-$KSERIES 补丁栈作为基线"
  na=0; skipped=0
  for f in "$ARMBIAN/patch/kernel/archive/rockchip64-$KSERIES"/*.patch; do
    if patch -d "$TREE" -p1 --forward --batch --dry-run < "$f" >/dev/null 2>&1; then
      patch -d "$TREE" -p1 --forward --batch < "$f" >/dev/null 2>&1
      na=$((na+1))
    else
      skipped=$((skipped+1))   # Armbian 自己也有打不上的（其构建日志里 5 个 needs_rebase）
    fi
  done
  find "$TREE" -name '*.orig' -delete; find "$TREE" -name '*.rej' -delete
  git -C "$TREE" add -A
  git -C "$TREE" commit -qm "armbian rockchip64-$KSERIES patch stack ($na patches)"
  echo "  Armbian 补丁：应用 $na，跳过 $skipped"
fi
BASE=$(git -C "$TREE" rev-parse HEAD)
echo "  基线提交 ${BASE:0:12}"

step "2/4 逐个 git am"
n=0
for f in "$PATCHES"/[0-9][0-9][0-9][0-9]-*.patch; do
  name=$(basename "$f" .patch)
  if [ "$ON_ARMBIAN" = 1 ] && [[ "$name" == 0002-mmc-* ]]; then
    # `patch --forward` 本来就是「能打的打上、打不上的留 .rej」：6 个 hunk 里加
    # rk3528 pdata 与 of_match 条目那两个在两种基线上都能打，先让它们落地；
    # 剩下改 struct 与 HS400 分支的四个由重锚脚本按新上下文重做。
    patch -d "$TREE" -p1 --forward --batch < "$f" >/dev/null 2>&1 || true
    find "$TREE" -name '*.rej' -delete; find "$TREE" -name '*.orig' -delete
    python3 "$W/tools/rebase-mmc-onto-armbian.py" \
      "$TREE/drivers/mmc/host/sdhci-of-dwcmshc.c" || exit 1
    git -C "$TREE" add -A
    commit_with_patch_message "$f"
    printf '  ✅ %-12s %s（重锚到 Armbian 基线）\n' "${name:0:12}" "$(git -C "$TREE" log -1 --format=%s)"
  else
    # git am 不做 fuzz：上下文对不齐就是失败。这正是要的 —— 今天的 fuzz 就是明天的 fail，
    # 源补丁一旦打不上就该重新锚定，而不是让它带着 fuzz 混过去。
    if ! out=$(git -C "$TREE" am -q "$f" 2>&1); then
      echo "  ❌ $name 打不上（内核 $KVER 已漂）"
      sed 's/^/     /' <<<"$out" | head -20
      git -C "$TREE" am --abort 2>/dev/null || true
      exit 1
    fi
    printf '  ✅ %-12s %s\n' "${name:0:12}" "$(git -C "$TREE" log -1 --format=%s)"
  fi
  n=$((n+1))
done
[ "$n" -gt 0 ] || die "$PATCHES 里没有 000N-*.patch"

step "2b/4 板级 DTS 作为最后一个提交"
w132d_place_dts "$TREE" "$DTS"
git -C "$TREE" add -A
# 作者日期取上一个提交的：DTS 没有自己的"Date:"，又不能每次生成都变
GIT_AUTHOR_DATE="$(git -C "$TREE" log -1 --format=%aD)" \
  git -C "$TREE" commit -q --author="$GIT_NAME <$GIT_EMAIL>" --file="$DTS_MSG" --signoff
n=$((n+1))
echo "  ✅ $(git -C "$TREE" log -1 --format=%s)"

step "3/4 format-patch"
rm -rf "$SERIES"; mkdir -p "$SERIES"
git -C "$TREE" format-patch -q --zero-commit --no-signature -o "$SERIES" "$BASE" >/dev/null
ls "$SERIES" | sed 's/^/  /'
# 主线补丁必须带 Signed-off-by，缺了 maintainer 直接退回
for p in "$SERIES"/*.patch; do
  grep -q '^Signed-off-by:' "$p" || die "$(basename "$p") 缺 Signed-off-by"
done
echo "  ✅ 全部带 Signed-off-by"

step "4/4 落盘"
if [ "$ON_ARMBIAN" = 1 ]; then
  mkdir -p "$ARMBIAN_DIR"
  # 只清由本脚本生成的编号补丁。w132d-armbian-* 是**只对 Armbian 补丁栈**的补丁
  # （改的是 Armbian 自己加进来的树外驱动，主线没有那些文件），手工维护、不在 patches/。
  rm -f "$ARMBIAN_DIR"/w132d-0[0-9][0-9][0-9]-*.patch
  for f in "$SERIES"/*.patch; do
    cp "$f" "$ARMBIAN_DIR/w132d-$(basename "$f")"
  done
  ls "$ARMBIAN_DIR" | sed 's/^/  /'
  echo
  echo "SERIES_OK  基线 linux-$KVER + Armbian 补丁栈，$n 个提交"
  echo "  Armbian：$ARMBIAN_DIR/（w132d- 前缀保证在 rk3576-* 之后应用）"
else
  echo "  投主线用的补丁在 $SERIES/"
  echo
  echo "SERIES_OK  基线纯净 linux-$KVER，$n 个提交"
  echo "  git send-email 可直接用；要生成 Armbian 那份请加 --on-armbian"
fi
