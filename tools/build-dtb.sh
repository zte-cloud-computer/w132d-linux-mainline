#!/bin/bash
# SPDX-License-Identifier: MIT
# 在 Linux 7.2.2 上应用本项目的内核补丁并编译板级 DTB。
#
# 用法（在容器里跑，/w 是仓库根、/build 是构建卷、/src 是内核 tarball 所在目录）：
#   bash /w/tools/build-dtb.sh
#
# ## 这一步在验什么
#
# 第一版 Armbian 板级支持只带 4 个内核补丁（audio / dwcmshc-hs400 / rkvdec /
# tsadc），全部来自上游板级仓库、且都是本项目此前上游过去的。显示路径（25 个
# HDMI/VOP2 补丁）已剔除，理由见 tools/make-board-dts.py 抬头。
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
PORT="$W/cache/upstream/w132d-port"
OUT="$B/out"

step(){ echo; echo "########## $* ##########"; }

step "0/4 依赖"
export DEBIAN_FRONTEND=noninteractive
apt-get -qq update >/dev/null
apt-get -qq install -y --no-install-recommends \
  build-essential bc bison flex libssl-dev libelf-dev python3 xz-utils \
  patch device-tree-compiler >/dev/null
echo "  gcc $(gcc -dumpversion) / $(nproc) 核"

step "1/4 展开内核 $KVER"
if [ ! -d "$TREE" ]; then
  [ -f "$SRC" ] || { echo "❌ 缺内核 tarball: $SRC"; exit 1; }
  mkdir -p "$TREE"; tar -xf "$SRC" -C "$TREE" --strip-components=1
fi
echo "  $(grep -m1 '^VERSION' "$TREE/Makefile" | tr -d ' \t')$(grep -m1 '^PATCHLEVEL' "$TREE/Makefile" | sed 's/.*=/./;s/ //g')$(grep -m1 '^SUBLEVEL' "$TREE/Makefile" | sed 's/.*=/./;s/ //g')"

step "2/4 内核补丁（4 个，全部来自上游板级仓库）"
for p in rk3528-audio rk3528-dwcmshc-hs400 rk3528-rkvdec rk3528-tsadc; do
  f="$PORT/patches/$p-7.1.patch"
  [ -f "$f" ] || { echo "  ❌ 缺 $f"; exit 1; }
  # 幂等：先用反向 dry-run 判断是不是已经打过了。
  # 不能靠解析 patch 的报错文本 —— GNU patch 说的是
  # "Reversed (or previously applied) patch detected!"，而且同一个补丁里
  # 「新建文件」的 hunk 报的又是另一句话，逐条匹配很脆。
  if patch -d "$TREE" -p1 -R --dry-run --batch -f < "$f" >/dev/null 2>&1; then
    printf '  ⏭  %-26s 已应用\n' "$p"; continue
  fi
  out=$(patch -d "$TREE" -p1 --forward --batch < "$f" 2>&1) || {
    printf '  ❌ %-26s\n' "$p"; sed 's/^/     /' <<<"$out"; exit 1
  }
  if grep -q 'with fuzz' <<<"$out"; then
    printf '  ⚠️  %-26s 带 fuzz 应用\n' "$p"
  else
    printf '  ✅ %-26s 干净\n' "$p"
  fi
done
if find "$TREE" -name '*.rej' -print -quit | grep -q .; then
  echo "  ❌ 存在 .rej"; find "$TREE" -name '*.rej'; exit 1
fi
echo "  ✅ 零 .rej"

step "3/4 装入板级 DTS"
cp -f "$W/userpatches/kernel/archive/rockchip64-7.2/rk3528-w132d.dts" \
      "$TREE/arch/arm64/boot/dts/rockchip/"
MK="$TREE/arch/arm64/boot/dts/rockchip/Makefile"
grep -qxF 'dtb-$(CONFIG_ARCH_ROCKCHIP) += rk3528-w132d.dtb' "$MK" \
  || printf '\ndtb-$(CONFIG_ARCH_ROCKCHIP) += rk3528-w132d.dtb\n' >> "$MK"
echo "  ✅ DTS 与 Makefile 条目就位"

step "4/4 编译 DTB"
make -C "$TREE" ARCH=arm64 CROSS_COMPILE= LOCALVERSION= defconfig >/dev/null 2>&1
make -C "$TREE" ARCH=arm64 CROSS_COMPILE= LOCALVERSION= \
  rockchip/rk3528-w132d.dtb -j"$(nproc)" 2>&1 | grep -vE '^ *(HOSTCC|LEX|YACC|HOSTLD|UPD|WRAP|GEN|SYNC|CALL)' | tail -8
DTB="$TREE/arch/arm64/boot/dts/rockchip/rk3528-w132d.dtb"
[ -f "$DTB" ] || { echo "❌ DTB 没编出来"; exit 1; }
mkdir -p "$OUT"; cp -f "$DTB" "$OUT/"
echo
bash "$W/tools/verify-dtb.sh" "$OUT/rk3528-w132d.dtb"
