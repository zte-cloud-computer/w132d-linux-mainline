#!/bin/bash
# SPDX-License-Identifier: MIT
# 在 Linux 7.2.2 上应用本项目的内核补丁并编译板级 DTB。
#
# 用法（在容器里跑，/w 是仓库根、/build 是构建卷、/src 是内核 tarball 所在目录）：
#   bash /w/tools/build-dtb.sh
#
# ## 这一步在验什么
#
# 第一版 Armbian 板级支持只带 4 个驱动补丁（rkvdec / dwcmshc-hs400 / tsadc / audio）
# 加板级 DTS，源头在 patches/。显示路径（上游那 25 个 HDMI/VOP2 补丁）已剔除：
# 主线 7.2 对 RK3528 显示链零支持，那批补丁只能整体带、无法逐个上游。
#
# 主线 7.2 相比 7.1 的两处变化直接影响这里：
#   * USB2 PHY 驱动与 rk3528.dtsi 里的 usb 节点**上游已自带** —— 所以上游那两个
#     USB 补丁（inno-usb2 / usb-dtsi）不再应用，用了反而会造出重复节点；
#   * 显示链仍然零支持，所以只能剔除，不能指望上游。
set -euo pipefail

W="${W132D_ROOT:-/w}"
B=/build
KVER="${KVER:-7.2.2}"
SRC="/src/linux-$KVER.tar.xz"
TREE="$B/linux-$KVER"
PATCHDIR="$W/patches"
DTS="$W/patches/rk3528-w132d.dts"
OUT="$B/out"

step(){ echo; echo "########## $* ##########"; }
# shellcheck source=tools/lib.sh
. "$(dirname "$0")/lib.sh"

step "0/3 依赖"
export DEBIAN_FRONTEND=noninteractive
apt-get -qq update >/dev/null 2>&1
apt-get -qq install -y --no-install-recommends \
  build-essential bc bison flex libssl-dev libelf-dev python3 xz-utils \
  patch device-tree-compiler >/dev/null 2>&1
echo "  gcc $(gcc -dumpversion) / $(nproc) 核"

step "1/3 展开内核 $KVER"
if [ ! -d "$TREE" ]; then
  [ -f "$SRC" ] || { echo "❌ 缺内核 tarball: $SRC"; exit 1; }
  mkdir -p "$TREE"; tar -xf "$SRC" -C "$TREE" --strip-components=1
fi
echo "  $(grep -m1 '^VERSION' "$TREE/Makefile" | tr -d ' \t')$(grep -m1 '^PATCHLEVEL' "$TREE/Makefile" | sed 's/.*=/./;s/ //g')$(grep -m1 '^SUBLEVEL' "$TREE/Makefile" | sed 's/.*=/./;s/ //g')"

step "2/3 应用 patches/ 里的主线形态补丁"
# 这里的树是**纯净**内核，所以只能打主线形态（patches/0001–0004，能 git am 到干净
# 主线的那份）。userpatches/kernel/ 里的 Armbian 形态是重锚到 Armbian 补丁栈之上的
# —— 0002 在纯净树上必然打不上，拿它来测是错位的（早先就是这么错的）。
# Armbian 形态由真实构建验：tools/armbian-kernel.sh kernel-patch。
# GNU patch 会跳过 git 补丁的邮件头，直接 -p1 即可。
shopt -s nullglob
PATCHES=("$PATCHDIR"/[0-9][0-9][0-9][0-9]-*.patch)
[ "${#PATCHES[@]}" -gt 0 ] || { echo "  ❌ $PATCHDIR 里没有补丁"; exit 1; }
for f in "${PATCHES[@]}"; do
  name=$(basename "$f" .patch)
  # 幂等：先用反向 dry-run 判断是不是已经打过了。
  # 不能靠解析 patch 的报错文本 —— GNU patch 对"已应用"和"文件已存在"说的是
  # 两句不同的话，逐条匹配很脆。
  if patch -d "$TREE" -p1 -R --dry-run --batch -f < "$f" >/dev/null 2>&1; then
    printf '  ⏭  %-46s 已应用\n' "${name:0:46}"; continue
  fi
  out=$(patch -d "$TREE" -p1 --forward --batch < "$f" 2>&1) || {
    printf '  ❌ %-46s\n' "${name:0:46}"; sed 's/^/     /' <<<"$out"; exit 1
  }
  if grep -q 'with fuzz' <<<"$out"; then
    printf '  ⚠️  %-46s 带 fuzz\n' "${name:0:46}"
  else
    printf '  ✅ %-46s 干净\n' "${name:0:46}"
  fi
done
if find "$TREE" -name '*.rej' -print -quit | grep -q .; then
  echo "  ❌ 存在 .rej"; find "$TREE" -name '*.rej'; exit 1
fi
echo "  ✅ 零 .rej"
w132d_place_dts "$TREE" "$DTS" || exit 1
echo "  ✅ 板级 DTS 已放入树中（含 Makefile 条目）"

step "3/3 编译 DTB"
make -C "$TREE" ARCH=arm64 CROSS_COMPILE= LOCALVERSION= defconfig >/dev/null 2>&1
make -C "$TREE" ARCH=arm64 CROSS_COMPILE= LOCALVERSION= \
  rockchip/rk3528-w132d.dtb -j"$(nproc)" 2>&1 | grep -vE '^ *(HOSTCC|LEX|YACC|HOSTLD|UPD|WRAP|GEN|SYNC|CALL)' | tail -8
DTB="$TREE/arch/arm64/boot/dts/rockchip/rk3528-w132d.dtb"
[ -f "$DTB" ] || { echo "❌ DTB 没编出来"; exit 1; }
mkdir -p "$OUT"; cp -f "$DTB" "$OUT/"
echo
bash "$W/tools/verify-dtb.sh" "$OUT/rk3528-w132d.dtb"
