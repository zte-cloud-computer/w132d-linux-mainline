#!/bin/bash
# SPDX-License-Identifier: MIT
# 校验编出来的 rk3528-w132d.dtb 带着设备起得来、功能齐全所必需的属性：DTS 掉一个属性，DTB 照样合法地编出来。
# 用法: verify-dtb.sh <dtb>
#
# 每条都对应一个真实后果：HS400 掉了 eMMC 降到 52MHz；pwm-dutycycle-range 掉了「请求高电压得到低电压」、
# 2016MHz 直接挂死；tsadc 掉了没有热降频；VOP 挂上 IOMMU 会被自动门控卡总线；ir wakeup-source 冒出来
# 与软件待机冲突（本项目不做 s2ram）。
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

chkval() {  # chkval <节点> <属性> <期望值> <说明> —— 字符串属性必须等于期望值
  local v; v=$(fdtget -t s "$D" "$1" "$2" 2>/dev/null)
  if [ "$v" = "$3" ]; then
    printf '  ✅ %-30s %s\n' "$4" "$(head -c 40 <<<"$v")"
  else
    printf '  ❌ %-30s 是 "%s"，应为 "%s"\n' "$4" "${v:-<缺失>}" "$3"; FAIL=1
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
chk /soc/watchdog@ffac0000    compatible                "看门狗"
chkval /soc/vop@ff840000      compatible "rockchip,rk3528-vop"      "VOP2"
nochk  /soc/vop@ff840000      iommus                    "VOP 不挂 IOMMU（自动门控会卡总线）"
chkval /soc/hdmi@ff8d0000     compatible "rockchip,rk3528-dw-hdmi"  "HDMI 控制器"
chk    /soc/hdmi@ff8d0000     hpd-gpios                 "HDMI 热插拔走 GPIO"
chkval /soc/phy@ffe00000      compatible "rockchip,rk3528-hdmi-phy" "HDMI PHY"
chk    /soc/sai@ffb70000      compatible                "SAI3（HDMI 音频）"
chk /soc/tsadc@ffad0000       status                    "温度传感器"
chk /regulator-vdd-cpu        pwm-dutycycle-range       "vdd_cpu 占空比映射"
chk /cpus/cpu@0               cpu-supply                "cpu-supply"
chk /regulator-vdd-logic      pwm-dutycycle-range       "vdd_logic"
chk /soc/gpu@ff700000         mali-supply               "GPU 供电"
chk /soc/video-codec@ff740000 compatible                "VDEC"
# WCN 固件必须指向 bsp 包装的 CoreELEC W23.03.2：指回 wcnmodem.bin 是 SC2355 的（起不来），
# 指回 wcnmodem-38222.bin 是 W21.03.3（一关联就断言）
chkval /uwe-bsp unisoc,btwf-file-name /lib/firmware/uwe5622/wcnmodem-marlin3e.bin "WCN 固件文件名"
chk /ir-receiver              compatible                "红外接收"
chk /leds                     compatible                "面板指示灯"
chk /reserved-memory/ramoops@110000 reg                 "ramoops 崩溃留存"
chk /firmware/optee           compatible                "OP-TEE"
nochk /ir-receiver            wakeup-source             "红外唤醒策略"

[ "$FAIL" = 0 ] || { echo "  ❌ 关键属性缺失，不要用这份 DTB"; exit 1; }
echo "DTB_VERIFY_OK $D ($(wc -c < "$D" | tr -d ' ') B)"
