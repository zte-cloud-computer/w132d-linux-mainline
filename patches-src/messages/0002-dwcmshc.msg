mmc: sdhci-of-dwcmshc: use the RK3528 HS400 DLL taps

The revision==1 HS400 path hardcodes the RK3588 DLL taps (10/8/4).  The
RK3528 needs 6/6/3; with the RK3588 values the eMMC does not enumerate
at HS400 at all.  The correct values come from the GPL-2.0 Rockchip BSP
(drivers/mmc/host/sdhci-of-dwcmshc.c, rk3528_drvdata).

Add three optional tap overrides to struct rockchip_pltfm_data, keeping
the existing defaults when they are zero, and a RK3528 pdata that fills
them in.

Tested on a ZTE Cloud Computer W132D (RK3528): eMMC enumerates and runs
at HS400 with enhanced strobe and command queueing enabled.
