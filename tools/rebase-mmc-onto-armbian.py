#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""把 RK3528 的 HS400 tap 覆盖（patches/0002）改到 Armbian 补丁栈之上。

用法: rebase-mmc-onto-armbian.py <sdhci-of-dwcmshc.c>

Armbian 补丁栈（rk3576-0014）引入了通用的 struct rockchip_emmc_data 结构。
RK3528 沿用该架构提供专属的 rk3528_emmc_data 与 rk3528_pdata，并注册 of_match 条目。
"""
import sys


def sub(text, old, new, what):
    n = text.count(old)
    if n != 1:
        sys.exit(f"❌ {what}：期望 1 处匹配，实际 {n} 处 —— Armbian 的补丁变了")
    return text.replace(old, new)


def main():
    if len(sys.argv) != 2:
        raise SystemExit(f"用法: {sys.argv[0]} <sdhci-of-dwcmshc.c>")
    path = sys.argv[1]
    with open(path, encoding="utf-8") as f:
        s = f.read()

    if "rk3528_emmc_data" in s:
        print("  ✅ mmc：rk3528_emmc_data 已在位（基于上游 rockchip_emmc_data 架构）")
        return

    # 若尚未落地，基于上游 rk3562_emmc_data 上下文注入
    s = sub(s, """/* RK3562 DLL settings from the Rockchip vendor driver. */""",
"""/* RK3528 DLL settings from the Rockchip vendor driver. */
static const struct rockchip_emmc_data rk3528_emmc_data = {
	.hs200_tx_tapnum = 12,
	.hs400_tx_tapnum = 6,
	.hs400_cmd_tapnum = 6,
	.hs400_strbin_tapnum = 3,
	.ddr50_strbin_delay_num = 10,
	.dll_cmd_out = true,
	.tap_value_sel = true,
	.allow_low_clock = true,
};

static const struct rockchip_pltfm_data sdhci_dwcmshc_rk3528_pdata = {
	.dwcmshc_pdata = {
		.pdata = {
			.ops = &sdhci_dwcmshc_rk35xx_ops,
			.quirks = SDHCI_QUIRK_CAP_CLOCK_BASE_BROKEN |
				  SDHCI_QUIRK_BROKEN_TIMEOUT_VAL,
			.quirks2 = SDHCI_QUIRK2_PRESET_VALUE_BROKEN |
				   SDHCI_QUIRK2_CLOCK_DIV_ZERO_BROKEN,
		},
		.cqhci_host_ops = &rk35xx_cqhci_ops,
		.init = dwcmshc_rk35xx_init,
		.postinit = dwcmshc_rk35xx_postinit,
	},
	.revision = 1,
	.emmc_data = &rk3528_emmc_data,
};

/* RK3562 DLL settings from the Rockchip vendor driver. */""", "注入 rk3528_emmc_data 与 pdata")

    s = sub(s, """	{
		.compatible = "rockchip,rk3562-dwcmshc",
		.data = &sdhci_dwcmshc_rk3562_pdata,
	},""",
"""	{
		.compatible = "rockchip,rk3528-dwcmshc",
		.data = &sdhci_dwcmshc_rk3528_pdata,
	},
	{
		.compatible = "rockchip,rk3562-dwcmshc",
		.data = &sdhci_dwcmshc_rk3562_pdata,
	},""", "注入 rockchip,rk3528-dwcmshc compatible 条目")

    with open(path, "w", encoding="utf-8") as f:
        f.write(s)
    print("  ✅ mmc：改动已叠到 Armbian 补丁栈之上")


if __name__ == "__main__":
    main()

