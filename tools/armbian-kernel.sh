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
#     kernel         完整构建，产出 linux-image-*.deb（慢）
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
set +e
./compile.sh "$CMD" \
  BOARD=w132d BRANCH=edge RELEASE=trixie BUILD_MINIMAL=yes \
  SHOW_LOG=yes USE_TMPFS=no ARMBIAN_RUNNING_IN_CONTAINER=yes \
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

# 补丁阶段的判据：一个 .rej 都不能有
if grep -qiE "rejects|\.rej\b" "$B/armbian-$CMD.log"; then
  echo "  ❌ 日志里出现 .rej —— 补丁没干净应用"
  grep -iE "rejects|\.rej\b" "$B/armbian-$CMD.log" | head -10 | sed 's/^/     /'
  exit 1
fi
echo "  ✅ 补丁阶段无 .rej"

if [ "$CMD" = "kernel" ]; then
  echo "  --- 产出的 deb ---"
  find "$ARMBIAN/output" -name 'linux-*.deb' -printf '     %f  %s B\n' 2>/dev/null \
    || find "$ARMBIAN/output" -name 'linux-*.deb' -exec ls -la {} \; 2>/dev/null
fi
echo
echo "ARMBIAN_${CMD//-/_}_OK"
