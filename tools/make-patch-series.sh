#!/bin/bash
# SPDX-License-Identifier: MIT
# 把本项目对内核的改动维护成"内核树上的一串 git 提交"，并由它产出两样东西：
#   1. Armbian 的补丁目录内容（userpatches/kernel/archive/rockchip64-<ver>/）
#   2. 可以直接 git send-email 投给 LKML 的补丁
#
# 用法（容器里）：
#   bash /w/tools/make-patch-series.sh [内核版本] [--on-armbian]
#     不带 --on-armbian：基线是纯净内核，产物用于投 LKML
#     带  --on-armbian：基线是"纯净内核 + Armbian 的 rockchip64-7.2 补丁栈"，
#                       产物用于放进 Armbian 的补丁目录
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
# ## 为什么要两个基线
#
# 主线和 Armbian 是**不同的基线**，同一份 diff 不可能同时打进两边：
#
#   * 投 LKML 的补丁必须打在纯净 mainline 上；
#   * 进 Armbian 的必须打在它那 224 个补丁之后。
#
# 实测踩到过：我们的 mmc 补丁在 `int revision;` 后面插字段，而 Armbian 自己的
# rk3576-0013-mmc-sdhci-dwcmshc-rk3576-dll-tap-calibration 在**同一个位置**插
# `bool needs_hs400_dll_calibration;`。按文件名排序我们的排在前面、先应用，于是把
# 人家的挤失败了 —— 225 个补丁里唯一失败的那个是 Armbian 自己的。
#
# 只把我们 5 个补丁打到纯净树上是测不出这个的，必须跑真实构建。
#
# ## 文件名前缀
#
# Armbian 的补丁目录里大家都带前缀（rk3576-*、board-nanopi-r3s-*、general-*），
# 一是分类，二是决定应用顺序。我们用 `w132d-`，字典序排在 `rk3576-` 之后，
# 保证在人家的补丁之后应用。
#
# ## 产物在哪
#
#   $B/series/            投 LKML 用（纯净基线，带 From/Subject/S-o-b）
#   userpatches/kernel/archive/rockchip64-<ver>/   Armbian 用（其补丁栈之上，w132d- 前缀）
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
if [ "$ON_ARMBIAN" = 1 ]; then
  [ -d "$ARMBIAN/patch/kernel/archive/rockchip64-$KSERIES" ] \
    || { echo "  ❌ 缺 armbian/build 克隆：先跑一次 tools/armbian-kernel.sh"; exit 1; }
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

step "2/4 逐个应用并提交"
n=0
for f in "$SRCPATCH"/*.patch; do
  name=$(basename "$f" .patch)          # 例如 0001-rkvdec
  msg="$MSGS/$name.msg"
  [ -f "$msg" ] || { echo "  ❌ 缺提交信息 $msg"; exit 1; }
  # mmc 那个补丁与 Armbian 自带的 rk3576 DLL 标定补丁改同一处，纯净基线的 diff
  # 打不到它之后。--on-armbian 模式下改用专门的重锚脚本（见其抬头的分析）。
  if [ "$ON_ARMBIAN" = 1 ] && [ "$name" = "0002-dwcmshc" ]; then
    # `patch --forward` 本来就是「能打的打上、打不上的留 .rej」：6 个 hunk 里加
    # rk3528 pdata 与 of_match 条目那两个在两种基线上都能打，先让它们落地；
    # 剩下改 struct 与 HS400 分支的四个由重锚脚本按新上下文重做。
    patch -d "$TREE" -p1 --forward --batch < "$f" >/dev/null 2>&1 || true
    find "$TREE" -name '*.rej' -delete; find "$TREE" -name '*.orig' -delete
    python3 "$W/tools/rebase-mmc-onto-armbian.py" \
      "$TREE/drivers/mmc/host/sdhci-of-dwcmshc.c" || exit 1
  else
    out=$(patch -d "$TREE" -p1 --forward --batch < "$f" 2>&1) || {
      echo "  ❌ $name 打不上（内核 $KVER 已漂）"; sed 's/^/     /' <<<"$out"; exit 1
    }
  fi
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

step "4/4 落盘"
if [ "$ON_ARMBIAN" = 1 ]; then
  mkdir -p "$ARMBIAN_DIR"
  rm -f "$ARMBIAN_DIR"/*.patch
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
