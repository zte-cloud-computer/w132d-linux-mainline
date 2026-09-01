thermal: rockchip: add RK3528 TSADC support

The RK3528 TSADC is close to the RK3568 one but needs its own code table,
an 11-bit data mask and a separate initialisation sequence that programs
the trim code.  All register values and the code-to-temperature table are
taken verbatim from the GPL-2.0 Rockchip BSP
(armbian/linux-rockchip, rk-6.1-rkr5, drivers/thermal/rockchip_thermal.c).

Use TSHUT_MODE_CRU, matching what the vendor device tree selects with
rockchip,hw-tshut-mode = <0>; the BSP's TSHUT_MODE_OTP path has no
mainline equivalent.

Tested on a ZTE Cloud Computer W132D (RK3528): the SoC thermal zone
reports plausible temperatures and CPU passive cooling engages.
