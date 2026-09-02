#!/bin/bash
# SPDX-License-Identifier: MIT
# 三个内核侧脚本（make-patch-series / build-dtb / check-drift）共用的一小段。
#
# 板级 DTS 在 patches/ 里是源文件，不是补丁：往内核树里放要做两件事 —— 拷进
# arch/arm64/boot/dts/rockchip/ 并在 Makefile 里登记 dtb 目标。三处各写一遍
# 迟早对不齐，所以收在这里。幂等：重复调用不会重复登记。
w132d_place_dts() {   # $1 = 内核树，$2 = DTS 文件
	local tree="$1" dts="$2"
	local mk="$tree/arch/arm64/boot/dts/rockchip/Makefile"
	[ -f "$dts" ] || { echo "  ❌ 缺板级 DTS：$dts" >&2; return 1; }
	[ -f "$mk" ]  || { echo "  ❌ 不是内核树：$tree" >&2; return 1; }
	cp -f "$dts" "$tree/arch/arm64/boot/dts/rockchip/"
	grep -qxF 'dtb-$(CONFIG_ARCH_ROCKCHIP) += rk3528-w132d.dtb' "$mk" \
		|| printf '\ndtb-$(CONFIG_ARCH_ROCKCHIP) += rk3528-w132d.dtb\n' >> "$mk"
}
