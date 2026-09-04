#!/bin/bash
# SPDX-License-Identifier: MIT
# 用 armbian/build 真正构建本板的内核。
#
# 用法（容器里）：
#   bash /w/tools/armbian-kernel.sh [命令]
#     kernel-patch   只拉源码并应用补丁（快，用来先验补丁栈）
#                    ⚠️ 它本身是**交互式的补丁重写工具**，补丁阶段跑完会因为
#                    "stdin is not a terminal" 退出 43。补丁栈的结论看
#                    "Summary: kernel patching: N total; N applied" 那一行即可，
#                    退出码在这个模式下没有意义。
#     kernel         构建内核，产出 linux-image/dtb/headers/libc-dev 四个 deb
#     build          完整镜像（需要 --privileged：要 losetup/mount）
#     uboot          只编 U-Boot（板级默认 BOOTCONFIG=none 什么都不编；加
#                    ENABLE_EXTENSIONS=w132d-uboot 才走主线 U-Boot 实验）
#   命令之后的参数原样传给 compile.sh（例如 ENABLE_EXTENSIONS=w132d-uboot）
#   默认 kernel-patch
#
# ## 这一步在验什么
#
# 到此为止的验证都是我们自己的脚本做的：拿 tarball、手工 patch、手工编 DTB。
# 而 Armbian 走的是另一条路 —— 它从 git 拉 `linux-7.2.y` 的 **HEAD**（不是我们钉的
# 7.2.2），用它自己的补丁机制应用 `userpatches/kernel/archive/rockchip64-7.2/`，
# 再套 linux-rockchip64-edge.config。这三处都可能和我们的假设不一致。
#
# 先跑 kernel-patch：补丁栈过不了，编译再久也是白费。
#
# ## 日志过滤
#
# 部分 Debian 镜像上 apt 会把 "Tried to start delayed item" 刷成上百万行 stderr，
# 经 Armbian 的 logger 一转就是几百 MB 日志，真正的报错全被淹掉（实测一次 371 MB、
# 其中 239 万行是这一句）。这里在入 tee 之前先滤掉它和 update-alternatives 的噪音。
#
# ## 非交互所需的参数
#
# 少给一个 Armbian 就会弹 dialog，而容器里没有终端，直接 `stdin is not a terminal`
# 退出 43。实测 `build` 会问 KERNEL_CONFIGURE（"Select the kernel configuration"），
# 所以 BUILD_MINIMAL / BUILD_DESKTOP / KERNEL_CONFIGURE 三个都得显式给。
#
# ## build 还需要 CONTAINER_COMPAT=yes 和 -v /dev:/tmp/dev
#
# 容器里没有 udev，`losetup -P` 之后 /dev/loop0p2 这类分区节点不会自动出现，
# Armbian 会重试 5 次然后 "Device node /dev/loop0p2 does not exist"。
# 官方给了 CONTAINER_COMPAT 开关（loop.sh:25）：它从 /tmp/<device> 读设备号、
# 用 mknod 手工建节点 —— 所以宿主 /dev 必须挂到容器的 /tmp/dev：
#
#   docker run --privileged -v /dev:/tmp/dev ...
#
# ## USE_TMPFS=no 是必须的
#
# Armbian 默认给日志挂 tmpfs，容器里没 CAP_SYS_ADMIN 会直接失败。官方留了这个
# 开关（lib/functions/host/tmpfs-utils.sh），比开 --privileged 干净得多。
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

# Armbian 只认 $SRC/userpatches，硬编码且只读（entrypoint.sh:127），所以软链
rm -rf "$ARMBIAN/userpatches"
ln -sfn "$W/userpatches" "$ARMBIAN/userpatches"
echo "  userpatches -> $W/userpatches"
echo "    板级配置  $(ls "$W/userpatches/config/boards/")"
echo "    内核补丁  $(ls "$W/userpatches/kernel/archive/rockchip64-7.2/" | wc -l) 个"

step "2/3 ./compile.sh $CMD"
cd "$ARMBIAN"
# ⚠️ bsp 包必须每次重打。
#
# Armbian 的包哈希只按**它自己认得的输入**算，而我们的 overlay 是通过
# post_family_tweaks_bsp 钩子塞进去的 —— 改了 userpatches/overlay/ 它一无所知，
# 于是直接复用缓存的 deb。实测：删掉 pstore.conf 之后重建三次，装的还是那个
# 带着 pstore.conf 的旧包，报同一个 dpkg 冲突。
# 通配要用 `w132d*` 而不是 `w132d-*`：产物有两种命名（armbian-bsp-cli-w132d_… 与
# armbian-bsp-cli-w132d-edge_…），只匹配带横杠的会漏掉一半，于是照样装到旧包。
# 而且不能只删 .deb：Armbian 的产物缓存是 output/packages-hashed/ 里的 **.tar**
# （"deb-tar" artifact），deb 是从它解出来再改版本号的。只删 deb 时它照样从 tar
# 里解出旧包 —— 实测加了新 unit 后"Failed to enable unit: does not exist"。
find "$ARMBIAN/output" -name 'armbian-bsp-cli-w132d*' -type f -delete 2>/dev/null || true
rm -rf "$ARMBIAN/cache/memoize" 2>/dev/null || true
# W132D_PUBLIC=yes：本机有 userpatches/customize-image.sh（私有内容）时也能出公开镜像 ——
# 构建期间把它挪开，结束后放回。make-release.sh 也看这个变量决定包名要不要加 -private。
CI_SH="$W/userpatches/customize-image.sh"
if [ "${W132D_PUBLIC:-}" = yes ] && [ -f "$CI_SH" ]; then
  mv "$CI_SH" "$CI_SH.off"; trap 'mv -f "$CI_SH.off" "$CI_SH" 2>/dev/null' EXIT
  echo "  W132D_PUBLIC=yes：已暂时挪开 customize-image.sh，出的是公开镜像"
fi
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

# 补丁阶段的判据：**我们的**补丁一个 hunk 都不能失败。
# 不能拿 "rej" 这个子串当判据：Armbian 的补丁摘要表会把每个补丁的 Subject 打出来，
# 我们有个补丁标题里就有 "rejects"（Bluetooth link policy 那个），实测把一次成功的
# 构建误判成失败。Armbian 自己的补丁栈本来就有 5 个 needs_rebase，也不该算我们的。
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
