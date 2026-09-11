#!/bin/bash
# SPDX-License-Identifier: MIT
# 把 patches/ 里的内核改动在内核树上重放成 git 提交，再 format-patch 出两份产物：
#   1. 投 LKML 的补丁系列（纯净内核基线）→ /build/series/
#   2. Armbian 补丁目录 userpatches/kernel/archive/rockchip64-<ver>/（--on-armbian：基线是纯净内核 +
#      Armbian 的 rockchip64 补丁栈；提交进仓库的是这份）
#
# 用法（容器里）：bash /w/tools/make-patch-series.sh [内核版本] [--on-armbian]
#
# 输入（patches/ 是唯一源头）：
#   NNNN-*.patch       完整 git 补丁（From/Subject/正文/Signed-off-by/diff），可直接 git am 到干净主线
#   rk3528-w132d.dts   板级 DTS 源文件，由本脚本做成最后一个提交 —— Armbian 补丁目录只应用 *.patch，
#                      裸 .dts 放进去是静默无效的
#   NNNN-*.msg         板级 DTS 那个提交的提交信息（编号最大）
# 两个基线不能共用一份 diff：
#   - 我们的 mmc 补丁（0002）与 Armbian 的 rk3576-0014 改同一处（引入 rockchip_emmc_data 架构），
#     由 tools/rebase-mmc-onto-armbian.py 重做
#   - 我们的 vop2 补丁（0008）与 Armbian 的 rk3562-0010 改同一处（引入 rk3562-vop），
#     由 tools/rebase-vop-onto-armbian.py 重做
# 所以 --on-armbian 下 0002 和 0008 不走普通 git am，由重锚脚本按新上下文重做。
# 产物可复现：format-patch 带 --zero-commit --no-signature、作者日期取自源补丁，输入不变则逐字节不变。
# Armbian 目录里两类文件：w132d-0NNN-* 由本脚本生成勿手改（w132d- 前缀让它排在 rk3576-* 之后应用）；
# w132d-armbian-NNNN-* 只针对 Armbian 补丁栈里的树外驱动、主线没有那些文件，手工维护，本脚本不清理。
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
      skipped=$((skipped+1))   # Armbian 自己也有打不上的（其构建日志里的 needs_rebase）
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
    # 纯净版 0002 与 Armbian 的 rockchip_emmc_data 架构不兼容，跳过 patch 部分应用，
    # 优先由重锚脚本按新上下文注入；若重锚脚本失败，则回退到已适配的 Armbian 补丁
    rebased=0
    if [ -f "$W/tools/rebase-mmc-onto-armbian.py" ]; then
      if python3 "$W/tools/rebase-mmc-onto-armbian.py" \
        "$TREE/drivers/mmc/host/sdhci-of-dwcmshc.c"; then
        git -C "$TREE" add -A
        commit_with_patch_message "$f"
        rebased=1
        printf '  ✅ %-12s %s（重锚到 Armbian 基线）\n' "${name:0:12}" "$(git -C "$TREE" log -1 --format=%s)"
      else
        echo "  ⚠️  $name 重锚脚本失败，尝试回退使用已适配的 Armbian 补丁..."
        git -C "$TREE" am --abort 2>/dev/null || true
        git -C "$TREE" checkout -- .
      fi
    fi
    if [ "$rebased" = 0 ]; then
      if [ -f "$ARMBIAN_DIR/w132d-$name.patch" ] && git -C "$TREE" am -q "$ARMBIAN_DIR/w132d-$name.patch"; then
        printf '  ✅ %-12s %s（使用已适配的 Armbian 源补丁）\n' "${name:0:12}" "$(git -C "$TREE" log -1 --format=%s)"
      else
        git -C "$TREE" am --abort 2>/dev/null || true
        die "$name 缺少可用的 Armbian 重锚方案或适配补丁应用失败"
      fi
    fi
  elif [ "$ON_ARMBIAN" = 1 ] && [[ "$name" == 0008-drm-rockchip-vop2-* ]]; then
    # 纯净版 0008 与 Armbian 的 RK3562 VOP2 上下文冲突，
    # 优先由重锚脚本按新上下文重做；若脚本执行失败，则回退到已适配的 Armbian 补丁
    rebased=0
    if [ -f "$W/tools/rebase-vop-onto-armbian.py" ]; then
      if python3 "$W/tools/rebase-vop-onto-armbian.py" "$TREE"; then
        git -C "$TREE" add -A
        commit_with_patch_message "$f"
        rebased=1
        printf '  ✅ %-12s %s（重锚到 Armbian 基线）\n' "${name:0:12}" "$(git -C "$TREE" log -1 --format=%s)"
      else
        echo "  ⚠️  $name 重锚脚本失败，尝试回退使用已适配的 Armbian 补丁..."
        git -C "$TREE" am --abort 2>/dev/null || true
        git -C "$TREE" checkout -- .
      fi
    fi
    if [ "$rebased" = 0 ]; then
      if [ -f "$ARMBIAN_DIR/w132d-$name.patch" ] && git -C "$TREE" am -q "$ARMBIAN_DIR/w132d-$name.patch"; then
        printf '  ✅ %-12s %s（使用已适配的 Armbian 源补丁）\n' "${name:0:12}" "$(git -C "$TREE" log -1 --format=%s)"
      else
        git -C "$TREE" am --abort 2>/dev/null || true
        die "$name 缺少可用的 Armbian 重锚方案或适配补丁应用失败"
      fi
    fi
  else
    # git am 不做 fuzz：上下文对不齐就是失败，这正是要的 —— 源补丁打不上就该重新锚定
    if ! out=$(git -C "$TREE" am -q "$f" 2>&1); then
      # 若在 --on-armbian 下且有对应的 w132d-*.patch 适配补丁，则尝试使用适配补丁
      if [ "$ON_ARMBIAN" = 1 ] && [ -f "$ARMBIAN_DIR/w132d-$name.patch" ]; then
        git -C "$TREE" am --abort 2>/dev/null || true
        if git -C "$TREE" am -q "$ARMBIAN_DIR/w132d-$name.patch" 2>/dev/null; then
          printf '  ✅ %-12s %s（使用已适配的 Armbian 源补丁）\n' "${name:0:12}" "$(git -C "$TREE" log -1 --format=%s)"
          n=$((n+1))
          continue
        fi
      fi
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
# 作者日期取上一个提交的：DTS 没有自己的 Date:，又不能每次生成都变
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
  # 只清由本脚本生成的编号补丁；w132d-armbian-* 是手工维护的，不动
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
