#!/bin/bash
# SPDX-License-Identifier: MIT
# 校验编出来的 rk3528-w132d.dtb 带着设备起得来所必需的那些属性。
#
# 用法: verify-dtb.sh <dtb>
#
# ## 为什么需要
#
# 板级 DTS 在本仓库自己手里（userpatches/board/rk3528-w132d.dts）。但改它的人不
# 一定意识到某个属性掉了会怎样 —— DTB 照样编得出来、照样是合法的树，只是设备起不来，
# 或者起来了缺一半功能。上游那份 DTS 就有现成的例子：我们导入的那个提交之后紧接着
# 的一次改动把 eMMC 从 HS400 降回了 52MHz，纯 DTS 属性变更，编译毫无异常。
#
# 每一条都对应一个真实后果：
#   - HS400/CQE 掉了            → eMMC 掉到 52MHz，整机 I/O 慢一个数量级
#   - pwm-dutycycle-range 掉了  → 「请求高电压得到低电压」，2016MHz 直接挂死
#   - tsadc 掉了                → 没有温控，也没有热降频
#   - ir wakeup-source 冒出来   → 与软件待机冲突（本项目不做 s2ram）
#   - 冒出 vop/hdmi 节点        → 显示路径漏进来了，而主线 7.2 没有对应驱动
set -euo pipefail

D="${1:?用法: $0 <dtb>}"
[ -f "$D" ] || { echo "  ❌ DTB 不存在: $D"; exit 1; }
for t in fdtget dtc; do
  command -v "$t" >/dev/null || { echo "  ❌ 缺 $t（apt-get install device-tree-compiler）"; exit 1; }
done

FAIL=0

chk() {  # chk <节点> <属性> <说明>
  if fdtget "$D" "$1" "$2" >/dev/null 2>&1; then
    printf '  ✅ %-30s %s\n' "$3" "$(fdtget -t s "$D" "$1" "$2" 2>/dev/null | head -c 32)"
  else
    printf '  ❌ %-30s 缺失（%s %s）\n' "$3" "$1" "$2"; FAIL=1
  fi
}

nochk() {  # nochk <节点> <属性> <说明> —— 断言不存在
  if fdtget "$D" "$1" "$2" >/dev/null 2>&1; then
    printf '  ❌ %-30s 不应存在（%s %s）\n' "$3" "$1" "$2"; FAIL=1
  else
    printf '  ✅ %-30s 不存在，符合预期\n' "$3"
  fi
}

dtc -I dtb -O dts "$D" > /tmp/verify-dtb.dts 2>/dev/null \
  || { echo "  ❌ DTB 结构无效"; exit 1; }

chk /soc/mmc@ffbf0000         mmc-hs400-1_8v            "eMMC HS400"
chk /soc/mmc@ffbf0000         mmc-hs400-enhanced-strobe "eMMC Enhanced Strobe"
chk /soc/mmc@ffbf0000         supports-cqe              "eMMC 命令队列"
chk /soc/watchdog@ffac0000    compatible                "看门狗"
chk /soc/tsadc@ffad0000       status                    "温度传感器"
chk /regulator-vdd-cpu        pwm-dutycycle-range       "vdd_cpu 占空比映射"
chk /cpus/cpu@0               cpu-supply                "cpu-supply"
chk /regulator-vdd-logic      pwm-dutycycle-range       "vdd_logic"
chk /soc/gpu@ff700000         mali-supply               "GPU 供电"
chk /soc/video-codec@ff740000 compatible                "VDEC"
chk /ir-receiver              compatible                "红外接收"
chk /leds                     compatible                "面板指示灯"
chk /reserved-memory/ramoops@110000 reg                 "ramoops 崩溃留存"
chk /firmware/optee           compatible                "OP-TEE"
nochk /ir-receiver            wakeup-source             "红外唤醒策略"

# 显示路径必须确实不在树里：主线 7.2 对 RK3528 的 VOP2/HDMI 零支持，
# 漏进来会得到一个引用不存在驱动的节点。
if grep -qiE '^\s*(vop|hdmi|hdmiphy)@|display-subsystem' /tmp/verify-dtb.dts; then
  echo "  ❌ 树里出现了显示节点，但本版不带显示驱动"
  grep -niE '^\s*(vop|hdmi|hdmiphy)@|display-subsystem' /tmp/verify-dtb.dts | head -5 | sed 's/^/     /'
  FAIL=1
else
  printf '  ✅ %-30s 不存在，符合预期\n' "显示节点（本版不带）"
fi

[ "$FAIL" = 0 ] || { echo "  ❌ 关键属性缺失，不要用这份 DTB"; exit 1; }
echo "DTB_VERIFY_OK $D ($(wc -c < "$D" | tr -d ' ') B)"
