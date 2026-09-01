#!/bin/bash
# SPDX-License-Identifier: MIT
# 用 Armbian 自己的 config-dump 解析我们的板级配置，检查它到底被解析成了什么。
#
# 用法（在容器里跑，/w 是仓库根、/build 是构建卷）：
#   bash /w/tools/armbian-configdump.sh
#
# ## 为什么先做这一步
#
# 在这之前所有验证都是我们自己的脚本跑的 —— DTS 能编、补丁能打，但**板级配置有没有
# 被 Armbian 接受、被解析成什么样，完全没验过**。config-dump 只解析配置不编译，
# 几十秒就能回答这个问题，而一次内核构建要半小时。
#
# 重点看这几个解析结果：
#   LINUXFAMILY / KERNEL_MAJOR_MINOR   BOARDFAMILY=rk35xx + KERNEL_TARGET=edge
#                                      是否真的落到 rockchip64 / 7.2
#   KERNELPATCHDIR                     决定我们的补丁该放哪个目录名
#   LINUXCONFIG                        决定内核 config 文件该叫什么
#   BOOTCONFIG                         是否真的是 none（不编 u-boot）
#   OFFSET / BOOTSIZE / BOOTFS_TYPE    分区几何有没有被家族配置覆盖掉
#
# ## USERPATCHES_PATH 为什么用软链
#
# Armbian 把它硬编码成 `${SRC}/userpatches` 且声明为只读（entrypoint.sh:127），
# 没法用环境变量指过来。所以把仓库里的 userpatches/ 软链进 armbian/build 的克隆。
set -euo pipefail

W="${W132D_ROOT:-/w}"
B=/build
ARMBIAN="$B/armbian-build"
ARMBIAN_REF="${ARMBIAN_REF:-main}"

step(){ echo; echo "########## $* ##########"; }

step "0/3 依赖"
export DEBIAN_FRONTEND=noninteractive
apt-get -qq update >/dev/null 2>&1
apt-get -qq install -y --no-install-recommends \
  git ca-certificates python3 jq bc >/dev/null 2>&1
echo "  bash $BASH_VERSION"

step "1/3 取 armbian/build"
if [ ! -d "$ARMBIAN/.git" ]; then
  git clone -q --depth 1 --branch "$ARMBIAN_REF" \
    https://github.com/armbian/build "$ARMBIAN"
fi
echo "  armbian/build @ $(git -C "$ARMBIAN" rev-parse --short HEAD)"

# 我们的 userpatches 软链进去（Armbian 只认 $SRC/userpatches）
rm -rf "$ARMBIAN/userpatches"
ln -sfn "$W/userpatches" "$ARMBIAN/userpatches"
echo "  userpatches -> $W/userpatches"
echo "    板级配置: $(ls "$W/userpatches/config/boards/")"

step "2/3 config-dump"
cd "$ARMBIAN"
# OFFLINE_WORK=yes  config-dump 只解析配置，不必联网拉源码
# USE_TMPFS=no      Armbian 默认给日志挂 tmpfs，容器里没 CAP_SYS_ADMIN 会失败；
#                   官方留了这个开关（tmpfs-utils.sh:43），比开 --privileged 干净得多
set +e
CONFIG_DEFS_ONLY=yes ./compile.sh config-dump \
  BOARD=w132d BRANCH=edge RELEASE=trixie BUILD_MINIMAL=yes \
  SHOW_LOG=yes OFFLINE_WORK=yes USE_TMPFS=no > "$B/configdump.json" 2>"$B/configdump.err"
RC=$?
set -e
if [ "$RC" -ne 0 ]; then
  echo "  ❌ config-dump 退出码 $RC"
  tail -40 "$B/configdump.err" | sed 's/^/     /'
  exit 1
fi

step "3/3 关键变量"
python3 - "$B/configdump.json" <<'PY'
import json, sys
raw = open(sys.argv[1]).read()
start = raw.find("{")
if start < 0:
    sys.exit("❌ 输出里没有 JSON:\n" + raw[:800])
d = json.loads(raw[start:])
want = ["BOARD", "BOARDFAMILY", "BRANCH", "LINUXFAMILY", "KERNEL_MAJOR_MINOR",
        "KERNELSOURCE", "KERNELBRANCH", "KERNELPATCHDIR", "LINUXCONFIG",
        "BOOTCONFIG", "BOOT_SOC", "OFFSET", "BOOTSIZE", "BOOTFS_TYPE",
        "IMAGE_PARTITION_TABLE", "BOOT_FDT_FILE", "BOOT_SCENARIO"]
for k in want:
    v = d.get(k, "⟨未设置⟩")
    print(f"  {k:24} {v}")
PY
echo
echo "CONFIGDUMP_OK"
