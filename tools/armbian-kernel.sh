#!/bin/bash
# SPDX-License-Identifier: MIT
# 在容器里用 armbian/build 构建本板：验补丁栈、出内核 deb、出整盘镜像或 U-Boot。
#
# 用法（容器里，/w 是仓库根、/build 是构建卷）：
#   bash /w/tools/armbian-kernel.sh [命令] [传给 compile.sh 的参数...]
#     kernel-patch   只拉源码并应用补丁（默认；快，先验补丁栈）。它是交互式补丁重写工具，没有终端时
#                    会以 43 退出，结论只看 "Summary: kernel patching: N total; N applied" 那一行
#     kernel         构建内核，产出 linux-image/dtb/headers/libc-dev 四个 deb
#     build          完整镜像；需要 --privileged -v /dev:/tmp/dev（losetup/mount，见下）
#     uboot          只编 U-Boot（钩子在 userpatches/extensions/w132d-uboot.sh）
set -euo pipefail

W="${W132D_ROOT:-/w}"
B=/build
CMD="${1:-kernel-patch}"
ARMBIAN="$B/armbian-build"
ARMBIAN_REF="${ARMBIAN_REF:-main}"

step(){ echo; echo "########## $* ##########"; }

step "0/3 依赖"
export DEBIAN_FRONTEND=noninteractive
apt-get -qq update >/dev/null 2>&1
apt-get -qq install -y --no-install-recommends \
  git ca-certificates python3 jq bc sudo >/dev/null 2>&1
echo "  bash $BASH_VERSION / $(nproc) 核"

step "1/3 取 armbian/build"
if [ ! -d "$ARMBIAN/.git" ]; then
  git clone -q --depth 1 --branch "$ARMBIAN_REF" \
    https://github.com/armbian/build "$ARMBIAN"
fi
echo "  armbian/build @ $(git -C "$ARMBIAN" rev-parse --short HEAD)"

# Armbian 把 USERPATCHES_PATH 硬编码成 $SRC/userpatches 且只读（entrypoint.sh），只能软链进去
rm -rf "$ARMBIAN/userpatches"
ln -sfn "$W/userpatches" "$ARMBIAN/userpatches"
echo "  userpatches -> $W/userpatches"
echo "    板级配置  $(ls "$W/userpatches/config/boards/")"
echo "    内核补丁  $(ls "$W/userpatches/kernel/archive/rockchip64-7.2/" | wc -l) 个"

step "2/3 ./compile.sh $CMD"
cd "$ARMBIAN"
# bsp 包必须每次重打：Armbian 的包哈希不含 post_family_tweaks_bsp 钩子塞进去的 overlay，改了
# userpatches/overlay/ 它照样复用缓存的 deb。通配要用 w132d*（产物有 armbian-bsp-cli-w132d_… 与
# …-w132d-edge_… 两种名字），且缓存源头是 output/packages-hashed/ 里的 .tar（deb 从它解出），只删 .deb 没用。
find "$ARMBIAN/output" -name 'armbian-bsp-cli-w132d*' -type f -delete 2>/dev/null || true
rm -rf "$ARMBIAN/cache/memoize" 2>/dev/null || true
# W132D_PUBLIC=yes：本机有 userpatches/customize-image.sh（私有内容）时也能出公开镜像 ——
# 构建期间把它挪开，结束后放回。make-release.sh 也看这个变量决定包名要不要加 -private。
CI_SH="$W/userpatches/customize-image.sh"
if [ "${W132D_PUBLIC:-}" = yes ] && [ -f "$CI_SH" ]; then
  mv "$CI_SH" "$CI_SH.off"; trap 'mv -f "$CI_SH.off" "$CI_SH" 2>/dev/null' EXIT
  echo "  W132D_PUBLIC=yes：已暂时挪开 customize-image.sh，出的是公开镜像"
fi
# 少给一个参数 Armbian 就弹 dialog，容器里没终端会以 43 退出：BUILD_MINIMAL/BUILD_DESKTOP/KERNEL_CONFIGURE 都要显式给。
# USE_TMPFS=no：默认给日志挂 tmpfs，容器里没 CAP_SYS_ADMIN 会失败。
# CONTAINER_COMPAT=yes：容器里没 udev，losetup -P 后 /dev/loopNpM 不会出现；Armbian 会从 /tmp/dev（挂进来的
# 宿主 /dev）读设备号自己 mknod（loop.sh），所以 build 要 -v /dev:/tmp/dev。
# 过滤 "Tried to start delayed item"：部分 Debian 镜像上 apt 会把它刷成上百万行，日志几百 MB、真正的报错被淹掉。
set +e
./compile.sh "$CMD" \
  BOARD=w132d BRANCH=edge RELEASE=trixie \
  BUILD_MINIMAL=yes BUILD_DESKTOP=no KERNEL_CONFIGURE=no \
  SHOW_LOG=yes USE_TMPFS=no ARMBIAN_RUNNING_IN_CONTAINER=yes CONTAINER_COMPAT=yes \
  "${@:2}" \
  2>&1 \
  | grep -vE "Tried to start delayed item|update-alternatives:|^\s*$" \
  | tee "$B/armbian-$CMD.log"
RC=${PIPESTATUS[0]}
set -e

step "3/3 结果"
if [ "$RC" -ne 0 ]; then
  echo "  ❌ 退出码 $RC"
  echo "  --- 日志里的错误 ---"
  grep -niE "error|failed|rejects|\.rej" "$B/armbian-$CMD.log" | tail -25 | sed 's/^/     /'
  exit 1
fi

# 判据：我们的补丁一个 hunk 都不能失败。不能拿 "rej" 子串判：Armbian 的补丁摘要会打印每个 Subject，
# 我们 0005 的标题里就有 "rejects"；Armbian 自己的补丁栈本来就有几个 needs_rebase，不算我们的。
if grep -E "Hunk #[0-9]+ FAILED|saving rejects to|-> [0-9]+/[0-9]+: w132d-.*\(problems\)" "$B/armbian-$CMD.log" | grep -qi "w132d-"; then
  echo "  ❌ 我们的补丁有 hunk 没打上"
  grep -E "Hunk #[0-9]+ FAILED|saving rejects to|w132d-.*problems" "$B/armbian-$CMD.log" | head -10 | sed 's/^/     /'
  exit 1
fi
echo "  ✅ w132d-* 补丁全部干净应用（Armbian 自己的 needs_rebase 不算）"

if [ "$CMD" = "kernel" ] || [ "$CMD" = "uboot" ]; then
  echo "  --- 产出的 deb ---"
  find "$ARMBIAN/output" -name 'linux-*.deb' -printf '     %f  %s B\n' 2>/dev/null \
    || find "$ARMBIAN/output" -name 'linux-*.deb' -exec ls -la {} \; 2>/dev/null
fi
echo
echo "ARMBIAN_${CMD//-/_}_OK"
