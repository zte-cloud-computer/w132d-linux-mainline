#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""把 RK3528 的 HS400 tap 覆盖（patches/0002）改到 Armbian 补丁栈之上。

用法: rebase-mmc-onto-armbian.py <sdhci-of-dwcmshc.c>

Armbian 的 rk3576-0013-mmc-sdhci-dwcmshc-rk3576-dll-tap-calibration 与 0002 改同一处：都在
`int revision;` 后往 struct 插字段、都重写 dwcmshc_rk3568_set_clock() 的 HS400 分支，纯净基线的
diff 打不上。Armbian 把 HS400 分支改成了二选一（needs_hs400_dll_calibration：rk3576 标定 tap；
else：rk3588 等固定 tap），RK3528 属于后者但要用自己的 tap 值（6/6/3，来自 GPL-2.0 的 Rockchip BSP），
所以只让 else 分支支持覆盖，rk3576 与 rk3588 的行为不动。
每处改动都断言锚点唯一命中：Armbian 那个补丁将来变了会立刻失败，而不是产出打了一半的树。
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
    s = open(path, encoding="utf-8").read()

    # 1) 三个 tap 覆盖字段，插在 Armbian 那个字段之后（而不是抢它的位置）
    s = sub(s, """	bool needs_hs400_dll_calibration;
};""",
"""	bool needs_hs400_dll_calibration;
	/*
	 * Optional HS400 DLL tap overrides for revision-1 SoCs that do not use
	 * the calibration above.  Ported from the GPL-2.0 Rockchip BSP.  Zero
	 * keeps the generic values, so existing SoCs are unaffected.
	 */
	u8 hs400_tx_tap;
	u8 hs400_cmd_tap;
	u8 hs400_strbin_tap;
};""", "struct 加三个 tap 覆盖字段")

    # 2) else 分支（rk3588 等）支持覆盖；rk3576 那一支不动
    s = sub(s, """			/* rk3588 and other revision-1 SoCs: original fixed taps */
			txclk_tapnum = DLL_TXCLK_TAPNUM_90_DEGREES;

			extra = DLL_CMDOUT_SRC_CLK_NEG |
				DLL_CMDOUT_EN_SRC_CLK_NEG |
				DWCMSHC_EMMC_DLL_DLYENA |
				DLL_CMDOUT_TAPNUM_90_DEGREES |
				DLL_CMDOUT_TAPNUM_FROM_SW;""",
"""			/*
			 * rk3588 and other revision-1 SoCs: fixed taps, with
			 * optional per-SoC overrides (rk3528 needs 6/6/3).
			 */
			txclk_tapnum = rockchip_pdata->hs400_tx_tap ?:
				       DLL_TXCLK_TAPNUM_90_DEGREES;

			extra = DLL_CMDOUT_SRC_CLK_NEG |
				DLL_CMDOUT_EN_SRC_CLK_NEG |
				DWCMSHC_EMMC_DLL_DLYENA |
				(rockchip_pdata->hs400_cmd_tap ?:
				 DLL_CMDOUT_TAPNUM_90_DEGREES) |
				DLL_CMDOUT_TAPNUM_FROM_SW;""",
        "HS400 else 分支支持 tap 覆盖")

    # 3) STRBIN 同理：只动非标定那一支
    s = sub(s, """	else
		extra |= DLL_STRBIN_TAPNUM_DEFAULT;""",
"""	else
		extra |= rockchip_pdata->hs400_strbin_tap ?:
			 DLL_STRBIN_TAPNUM_DEFAULT;""",
        "STRBIN 支持 tap 覆盖")

    open(path, "w", encoding="utf-8").write(s)
    print("  ✅ mmc：三处改动已叠到 Armbian 补丁栈之上")


if __name__ == "__main__":
    main()
