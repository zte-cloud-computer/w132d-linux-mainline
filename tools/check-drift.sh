#!/bin/bash
# SPDX-License-Identifier: MIT
# 对一批内核版本干跑我们的补丁与板级 DTS，提前发现漂移。
#
# 用法（容器里）：
#   bash /w/tools/check-drift.sh [版本...]
#   默认测：钉住的 7.2.2 + 同系列较新的 + 下一个系列
#
# ## 为什么需要
#
# Armbian 的 edge 跟的是 `branch:linux-7.2.y` 的 **HEAD**，不是我们测过的 7.2.2；
# 而且它迟早会 bump 到 7.3。两件事都会在我们不知情的时候把补丁打崩。
#
# 这个脚本的价值在于**提前**：在 Armbian 动之前就知道会不会炸，以及炸在哪个 hunk。
#
# ## fuzz 当预警，不当通过
#
# `patch` 打出 fuzz 意味着上下文已经对不齐、只是还能猜出位置。今天的 fuzz 就是
# 明天的 fail —— 所以这里单独统计，出现即提示重新锚定，而不是当成成功。
#
# ## 为什么还要编 DTS
#
# 光测补丁会漏掉一整类漂移：**上游 dtsi 自己变了**。实测例子 —— 主线 7.2 自带了
# RK3528 的 usb2phy 节点，标签叫 `usb2phy_*`，而上游板级 DTS 用的是 `u2phy_*`，
# 补丁全绿但 dtc 直接报 "Label or path not found"。所以每个版本都真编一次 DTB。
set -uo pipefail

W="${W132D_ROOT:-/w}"
B=/build
# 测主线形态（patches/），不是 userpatches/kernel/ 里的 Armbian 形态：这里的树是纯净
# 内核，Armbian 形态的 0002 重锚在 Armbian 补丁栈之上，纯净树上必然打不上。
# Armbian 那一侧的漂移由真实构建验：tools/armbian-kernel.sh kernel-patch。
PATCHDIR="$W/patches"
DTS="$W/patches/rk3528-w132d.dts"
# shellcheck source=tools/lib.sh
. "$(dirname "$0")/lib.sh"

VERSIONS=("$@")
if [ "${#VERSIONS[@]}" -eq 0 ]; then
  VERSIONS=(7.2.2)
fi

export DEBIAN_FRONTEND=noninteractive
apt-get -qq update >/dev/null 2>&1
apt-get -qq install -y --no-install-recommends \
  build-essential bc bison flex libssl-dev libelf-dev python3 xz-utils \
  patch device-tree-compiler curl ca-certificates >/dev/null 2>&1

shopt -s nullglob
PATCHES=("$PATCHDIR"/[0-9][0-9][0-9][0-9]-*.patch)
[ "${#PATCHES[@]}" -gt 0 ] || { echo "❌ $PATCHDIR 里没有补丁"; exit 1; }
[ -f "$DTS" ] || { echo "❌ 缺板级 DTS：$DTS"; exit 1; }

TOTAL_FAIL=0
TOTAL_FUZZ=0

for KVER in "${VERSIONS[@]}"; do
  echo
  echo "══════════════ linux-$KVER ══════════════"
  MAJOR="${KVER%%.*}"
  mkdir -p "$B/tarballs"
  # 正式版在 cdn 的 v<major>.x/ 下是 .tar.xz；-rc 只有 git.kernel.org 的快照 .tar.gz。
  # 要提前对下一个系列预警就绕不开 rc，所以两种都支持。
  case "$KVER" in
    *-rc*) TB="$B/tarballs/linux-$KVER.tar.gz"
           URL="https://git.kernel.org/torvalds/t/linux-$KVER.tar.gz" ;;
    *)     TB="$B/tarballs/linux-$KVER.tar.xz"
           URL="https://cdn.kernel.org/pub/linux/kernel/v${MAJOR}.x/linux-$KVER.tar.xz" ;;
  esac
  if [ ! -f "$TB" ]; then
    echo "  下载 $KVER ..."
    if ! curl -sfL -o "$TB.part" "$URL"; then
      echo "  ⚠️  取不到 $KVER（可能尚未发布），跳过"
      rm -f "$TB.part"; continue
    fi
    mv "$TB.part" "$TB"
  fi

  T="$B/drift-$KVER"
  rm -rf "$T"; mkdir -p "$T"
  tar -xf "$TB" -C "$T" --strip-components=1

  fail=0; fuzz=0
  for f in "${PATCHES[@]}"; do
    p=$(basename "$f" .patch); p="${p:0:44}"
    out=$(patch -d "$T" -p1 --forward --batch < "$f" 2>&1)
    if [ $? -ne 0 ]; then
      n=$(grep -c 'FAILED at' <<<"$out" || true)
      printf '  ❌ %-46s %s 个 hunk 失败\n' "$p" "$n"
      grep 'FAILED at' <<<"$out" | head -3 | sed 's/^/       /'
      fail=$((fail+1))
    elif grep -q 'with fuzz' <<<"$out"; then
      printf '  ⚠️  %-46s 带 fuzz —— 上下文已对不齐，建议重新锚定\n' "$p"
      grep 'with fuzz' <<<"$out" | head -2 | sed 's/^/       /'
      fuzz=$((fuzz+1))
    else
      printf '  ✅ %-46s 干净\n' "$p"
    fi
  done

  # 板级 DTS：补丁全绿也可能因为上游 dtsi 变了而编不过
  if [ "$fail" -eq 0 ]; then
    w132d_place_dts "$T" "$DTS" || exit 1
    make -C "$T" ARCH=arm64 CROSS_COMPILE= LOCALVERSION= defconfig >/dev/null 2>&1
    if dtb_out=$(make -C "$T" ARCH=arm64 CROSS_COMPILE= LOCALVERSION= \
                   rockchip/rk3528-w132d.dtb -j"$(nproc)" 2>&1); then
      echo "  ✅ 板级 DTS 编译通过"
      if ! bash "$W/tools/verify-dtb.sh" \
             "$T/arch/arm64/boot/dts/rockchip/rk3528-w132d.dtb" >/dev/null 2>&1; then
        echo "  ❌ DTB 关键属性校验未通过"
        bash "$W/tools/verify-dtb.sh" \
          "$T/arch/arm64/boot/dts/rockchip/rk3528-w132d.dtb" 2>&1 \
          | grep "❌" | head -5 | sed 's/^/     /'
        fail=$((fail+1))
      else
        echo "  ✅ DTB 关键属性 16 条全绿"
      fi
    else
      echo "  ❌ 板级 DTS 编译失败"
      grep -E "^Error|error:" <<<"$dtb_out" | head -5 | sed 's/^/     /'
      fail=$((fail+1))
    fi
  else
    echo "  ⏭  补丁已失败，跳过 DTS 编译"
  fi

  printf '  ── linux-%s 小结：失败 %d，fuzz %d\n' "$KVER" "$fail" "$fuzz"
  TOTAL_FAIL=$((TOTAL_FAIL+fail)); TOTAL_FUZZ=$((TOTAL_FUZZ+fuzz))
  rm -rf "$T"   # 每个版本用完即删，别把构建卷撑爆
done

echo
echo "DRIFT_RESULT fail=$TOTAL_FAIL fuzz=$TOTAL_FUZZ"
if [ "$TOTAL_FAIL" -gt 0 ]; then
  echo "❌ 有补丁打不上了 —— 在出问题的那个版本上重新锚定 patches/ 里的源补丁（README「防漂与上游化」）"
  exit 1
fi
if [ "$TOTAL_FUZZ" -gt 0 ]; then
  echo "⚠️  有补丁带 fuzz —— 还能用，但上下文已经在漂，建议尽快重新锚定"
fi
echo "✅ 无漂移"
