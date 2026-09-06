#!/bin/bash
# SPDX-License-Identifier: MIT
# make-patch-series 与 check-drift 共用：把 patches/ 里的板级 DTS 放进内核树并登记 dtb 目标（幂等）。
w132d_place_dts() {   # $1 = 内核树，$2 = DTS 文件
	local tree="$1" dts="$2"
	local mk="$tree/arch/arm64/boot/dts/rockchip/Makefile"
	[ -f "$dts" ] || { echo "  ❌ 缺板级 DTS：$dts" >&2; return 1; }
	[ -f "$mk" ]  || { echo "  ❌ 不是内核树：$tree" >&2; return 1; }
	cp -f "$dts" "$tree/arch/arm64/boot/dts/rockchip/"
	grep -qxF 'dtb-$(CONFIG_ARCH_ROCKCHIP) += rk3528-w132d.dtb' "$mk" \
		|| printf '\ndtb-$(CONFIG_ARCH_ROCKCHIP) += rk3528-w132d.dtb\n' >> "$mk"
}
