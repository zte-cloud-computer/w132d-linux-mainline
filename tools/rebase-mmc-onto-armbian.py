#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""把 RK3528 的 HS400 tap 覆盖（patches/0002）改到 Armbian 补丁栈之上。

用法: rebase-mmc-onto-armbian.py <sdhci-of-dwcmshc.c>

Armbian 补丁栈（rk3576-0014）引入了通用的 struct rockchip_emmc_data 结构。
RK3528 沿用该架构提供专属的 rk3528_emmc_data 与 rk3528_pdata，并注册 of_match 条目。
"""
import re
import sys


def sub(text, old, new, what):
    n = text.count(old)
    if n != 1:
        sys.exit(f"❌ {what}：期望 1 处匹配，实际 {n} 处 —— Armbian 的补丁变了")
    return text.replace(old, new)


RK3528_DATA = "static const struct rockchip_emmc_data rk3528_emmc_data = {"
RK3528_PDATA = "static const struct rockchip_pltfm_data sdhci_dwcmshc_rk3528_pdata = {"
RK3528_MATCH = """\t\t.compatible = "rockchip,rk3528-dwcmshc",
\t\t.data = &sdhci_dwcmshc_rk3528_pdata,"""


def main():
    if len(sys.argv) != 2:
        raise SystemExit(f"用法: {sys.argv[0]} <sdhci-of-dwcmshc.c>")
    path = sys.argv[1]
    with open(path, encoding="utf-8") as f:
        s = f.read()

    # 若检测到旧版 mainline pdata（包含 .hs400_tx_tap = ），先清理旧定义以便重新按 Armbian 架构注入
    if ".hs400_tx_tap =" in s:
        s = re.sub(
            r"static const struct rockchip_pltfm_data sdhci_dwcmshc_rk3528_pdata = \{.*?^};\n+",
            "",
            s,
            flags=re.MULTILINE | re.DOTALL,
        )
        s = re.sub(
            r"\t\{\n\t\t\.compatible = \"rockchip,rk3528-dwcmshc\",\n\t\t\.data = &sdhci_dwcmshc_rk3528_pdata,\n\t\},\n?",
            "",
            s,
        )

    data_present = RK3528_DATA in s
    pdata_present = RK3528_PDATA in s
    match_present = RK3528_MATCH in s

    if data_present or pdata_present or match_present:
        if not (data_present and pdata_present):
            sys.exit("❌ mmc：检测到 RK3528 改动不完整，拒绝继续生成补丁")
        if match_present:
            print("  ✅ mmc：RK3528 数据与 compatible 条目均已在位")
            return

        # patch 可能已经成功落下数据 hunk，但 compatible hunk 发生漂移。
        s = sub(s, """\t{
\t\t.compatible = "rockchip,rk3562-dwcmshc",
\t\t.data = &sdhci_dwcmshc_rk3562_pdata,
\t},""",
        """\t{
\t\t.compatible = "rockchip,rk3528-dwcmshc",
\t\t.data = &sdhci_dwcmshc_rk3528_pdata,
\t},
\t{
\t\t.compatible = "rockchip,rk3562-dwcmshc",
\t\t.data = &sdhci_dwcmshc_rk3562_pdata,
\t},""", "补齐 rockchip,rk3528-dwcmshc compatible 条目")
        with open(path, "w", encoding="utf-8") as f:
            f.write(s)
        print("  ✅ mmc：已补齐 RK3528 compatible 条目")
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
