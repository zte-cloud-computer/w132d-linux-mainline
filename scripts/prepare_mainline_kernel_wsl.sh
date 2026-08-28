#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
WIN_DIR="${W132D_MAINLINE_DIR:-$(cd -- "$SCRIPT_DIR/.." && pwd)}"
KERNEL_DIR="${W132D_MAINLINE_KERNEL_DIR:-/root/w132d-build/linux-v7.1.10}"
EXPECTED_KERNEL_VERSION=7.1.10
ARCH=arm64
CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
ENABLE_HDMI="${W132D_ENABLE_HDMI:-1}"
[ -d "$KERNEL_DIR" ] || { echo "ERROR: kernel checkout not found: $KERNEL_DIR" >&2; exit 1; }
KERNEL_VERSION="$(make -s -C "$KERNEL_DIR" kernelversion)"
[ "$KERNEL_VERSION" = "$EXPECTED_KERNEL_VERSION" ] || {
	echo "ERROR: expected Linux $EXPECTED_KERNEL_VERSION, found $KERNEL_VERSION in $KERNEL_DIR" >&2
	exit 1
}
DRIVER_SRC="$WIN_DIR/drivers/phy-rockchip-rk3528-usb2.c"
USB2_PATCH="$WIN_DIR/patches/rk3528-inno-usb2-7.1.patch"
USB_DTSI_PATCH="$WIN_DIR/patches/rk3528-usb-dtsi-7.1.patch"
HS400_PATCH="$WIN_DIR/patches/rk3528-dwcmshc-hs400-7.1.patch"
TSADC_PATCH="$WIN_DIR/patches/rk3528-tsadc-7.1.patch"
RKVDEC_PATCH="$WIN_DIR/patches/rk3528-rkvdec-7.1.patch"
AUDIO_PATCH="$WIN_DIR/patches/rk3528-audio-7.1.patch"
HDMI_PHY_SRC="$WIN_DIR/drivers/phy-rockchip-inno-hdmi-phy.c"
HDMI_2415_PATCH="$WIN_DIR/patches/rk3528-hdmi-2415mhz-7.1.patch"
HDMI_FORCE_RESET_PATCH="$WIN_DIR/patches/rk3528-hdmi-force-phy-reset-7.1.patch"
HDMI_PIXEL_CLOCK_PATCH="$WIN_DIR/patches/rk3528-hdmi-pixel-clock-7.1.patch"
HDMI_SINGLE_CLOCK_PATCH="$WIN_DIR/patches/rk3528-hdmi-single-clock-7.1.patch"
HDMI_SINGLE_CLOCK_FIX_PATCH="$WIN_DIR/patches/rk3528-hdmi-single-clock-fix-7.1.patch"
HDMI_CLOCK_SYNC_PATCH="$WIN_DIR/patches/rk3528-hdmi-clock-sync-7.1.patch"
HDMI_MODE_STATUS_PATCH="$WIN_DIR/patches/rk3528-hdmi-mode-status-7.1.patch"
HDMI_GLUE_PATCH="$WIN_DIR/patches/rk3528-hdmi-glue-7.1.patch"
HDMI_GLUE_FIX_PATCH="$WIN_DIR/patches/rk3528-hdmi-glue-fix-7.1.patch"
HDMI_GRF_PATCH="$WIN_DIR/patches/rk3528-hdmi-grf-7.1.patch"
HDMI_GRF_OFFSET_PATCH="$WIN_DIR/patches/rk3528-hdmi-grf-offset-7.1.patch"
HDMI_HPD_PATCH="$WIN_DIR/patches/rk3528-hdmi-hpd-7.1.patch"
HDMI_EDID_DEBUG_PATCH="$WIN_DIR/patches/rk3528-hdmi-edid-debug-7.1.patch"
VOP_HDMI_POLARITY_PATCH="$WIN_DIR/patches/rk3528-vop2-hdmi-polarity-7.1.patch"
HDMI_MODE_VALID_PATCH="$WIN_DIR/patches/rk3528-hdmi-mode-valid-7.1.patch"
HDMI_MODE_PLACEMENT_FIX_PATCH="$WIN_DIR/patches/rk3528-hdmi-mode-placement-fix-7.1.patch"
VOP_PATCH="$WIN_DIR/patches/rk3528-vop2-minimal-7.1.patch"
VOP_VERSION_PATCH="$WIN_DIR/patches/rk3528-vop2-version-7.1.patch"
VOP_ESMART_PATCH="$WIN_DIR/patches/rk3528-vop2-esmart-primary-7.1.patch"
VOP_CLUSTER_PATCH="$WIN_DIR/patches/rk3528-vop2-cluster-primary-7.1.patch"
VOP_BG_DELAY_PATCH="$WIN_DIR/patches/rk3528-vop2-bg-delay-7.1.patch"
VOP_REG_PATCH="$WIN_DIR/patches/rk3528-vop2-registers-7.1.patch"
VOP_REG_FIX_PATCH="$WIN_DIR/patches/rk3528-vop2-registers-fix-7.1.patch"
HDMI_RGB888_PATCH="$WIN_DIR/patches/rk3528-hdmi-rgb888-7.1.patch"
VOP_VENDOR_DELAY_PATCH="$WIN_DIR/patches/rk3528-vop2-vendor-delay-7.1.patch"

[ -s "$USB2_PATCH" ] || { echo "ERROR: missing RK3528 USB2 PHY patch: $USB2_PATCH" >&2; exit 1; }
[ -s "$USB_DTSI_PATCH" ] || { echo "ERROR: missing RK3528 USB DTS patch: $USB_DTSI_PATCH" >&2; exit 1; }
[ -s "$HS400_PATCH" ] || { echo "ERROR: missing RK3528 HS400 patch: $HS400_PATCH" >&2; exit 1; }
[ -s "$TSADC_PATCH" ] || { echo "ERROR: missing RK3528 TSADC patch: $TSADC_PATCH" >&2; exit 1; }
[ -s "$RKVDEC_PATCH" ] || { echo "ERROR: missing RK3528 VDEC patch: $RKVDEC_PATCH" >&2; exit 1; }
[ -s "$AUDIO_PATCH" ] || { echo "ERROR: missing RK3528 audio patch: $AUDIO_PATCH" >&2; exit 1; }
if [ "$ENABLE_HDMI" = 1 ]; then
[ -s "$HDMI_PHY_SRC" ] || { echo "ERROR: missing RK3528 HDMI PHY backport: $HDMI_PHY_SRC" >&2; exit 1; }
[ -s "$HDMI_2415_PATCH" ] || { echo "ERROR: missing RK3528 HDMI 241.5 MHz patch: $HDMI_2415_PATCH" >&2; exit 1; }
[ -s "$HDMI_FORCE_RESET_PATCH" ] || { echo "ERROR: missing RK3528 HDMI PHY reset patch: $HDMI_FORCE_RESET_PATCH" >&2; exit 1; }
[ -s "$HDMI_PIXEL_CLOCK_PATCH" ] || { echo "ERROR: missing RK3528 HDMI pixel clock patch: $HDMI_PIXEL_CLOCK_PATCH" >&2; exit 1; }
[ -s "$HDMI_SINGLE_CLOCK_PATCH" ] || { echo "ERROR: missing RK3528 HDMI single-clock patch: $HDMI_SINGLE_CLOCK_PATCH" >&2; exit 1; }
[ -s "$HDMI_SINGLE_CLOCK_FIX_PATCH" ] || { echo "ERROR: missing RK3528 HDMI single-clock fix patch: $HDMI_SINGLE_CLOCK_FIX_PATCH" >&2; exit 1; }
[ -s "$HDMI_CLOCK_SYNC_PATCH" ] || { echo "ERROR: missing RK3528 HDMI clock sync patch: $HDMI_CLOCK_SYNC_PATCH" >&2; exit 1; }
[ -s "$HDMI_MODE_STATUS_PATCH" ] || { echo "ERROR: missing RK3528 HDMI mode status patch: $HDMI_MODE_STATUS_PATCH" >&2; exit 1; }
[ -s "$HDMI_GLUE_PATCH" ] || { echo "ERROR: missing RK3528 HDMI glue patch: $HDMI_GLUE_PATCH" >&2; exit 1; }
[ -s "$HDMI_GLUE_FIX_PATCH" ] || { echo "ERROR: missing RK3528 HDMI glue fix patch: $HDMI_GLUE_FIX_PATCH" >&2; exit 1; }
[ -s "$HDMI_GRF_PATCH" ] || { echo "ERROR: missing RK3528 HDMI GRF patch: $HDMI_GRF_PATCH" >&2; exit 1; }
[ -s "$HDMI_GRF_OFFSET_PATCH" ] || { echo "ERROR: missing RK3528 HDMI GRF offset patch: $HDMI_GRF_OFFSET_PATCH" >&2; exit 1; }
[ -s "$HDMI_HPD_PATCH" ] || { echo "ERROR: missing RK3528 HDMI HPD patch: $HDMI_HPD_PATCH" >&2; exit 1; }
[ -s "$HDMI_EDID_DEBUG_PATCH" ] || { echo "ERROR: missing RK3528 HDMI EDID debug patch: $HDMI_EDID_DEBUG_PATCH" >&2; exit 1; }
[ -s "$VOP_HDMI_POLARITY_PATCH" ] || { echo "ERROR: missing RK3528 VOP HDMI polarity patch: $VOP_HDMI_POLARITY_PATCH" >&2; exit 1; }
[ -s "$HDMI_MODE_VALID_PATCH" ] || { echo "ERROR: missing RK3528 HDMI mode validation patch: $HDMI_MODE_VALID_PATCH" >&2; exit 1; }
[ -s "$HDMI_MODE_PLACEMENT_FIX_PATCH" ] || { echo "ERROR: missing RK3528 HDMI mode placement fix patch: $HDMI_MODE_PLACEMENT_FIX_PATCH" >&2; exit 1; }
[ -s "$VOP_PATCH" ] || { echo "ERROR: missing RK3528 VOP patch: $VOP_PATCH" >&2; exit 1; }
[ -s "$VOP_VERSION_PATCH" ] || { echo "ERROR: missing RK3528 VOP version patch: $VOP_VERSION_PATCH" >&2; exit 1; }
[ -s "$VOP_CLUSTER_PATCH" ] || { echo "ERROR: missing RK3528 Cluster primary patch: $VOP_CLUSTER_PATCH" >&2; exit 1; }
[ -s "$VOP_BG_DELAY_PATCH" ] || { echo "ERROR: missing RK3528 VOP background delay patch: $VOP_BG_DELAY_PATCH" >&2; exit 1; }
[ -s "$VOP_REG_PATCH" ] || { echo "ERROR: missing RK3528 VOP register patch: $VOP_REG_PATCH" >&2; exit 1; }
[ -s "$VOP_REG_FIX_PATCH" ] || { echo "ERROR: missing RK3528 VOP register fix patch: $VOP_REG_FIX_PATCH" >&2; exit 1; }
[ -s "$HDMI_RGB888_PATCH" ] || { echo "ERROR: missing RK3528 RGB888 HDMI patch: $HDMI_RGB888_PATCH" >&2; exit 1; }
[ -s "$VOP_VENDOR_DELAY_PATCH" ] || { echo "ERROR: missing RK3528 vendor VOP delay patch: $VOP_VENDOR_DELAY_PATCH" >&2; exit 1; }

# The upstream 7.1.10 tree has the generic INNO HDMI PHY driver but no RK3528
# register programming.  Keep the vendor-derived RK3528 implementation as a
# project-local backport until the equivalent code is accepted upstream.
cp -f "$HDMI_PHY_SRC" "$KERNEL_DIR/drivers/phy/rockchip/phy-rockchip-inno-hdmi.c"
if ! grep -q '241500000, 241500000' "$KERNEL_DIR/drivers/phy/rockchip/phy-rockchip-inno-hdmi.c"; then
	patch -d "$KERNEL_DIR" -p1 --forward --batch --fuzz=0 < "$HDMI_2415_PATCH"
fi
if ! grep -q 'forcing reset of U-Boot-powered PHY' "$KERNEL_DIR/drivers/phy/rockchip/phy-rockchip-inno-hdmi.c"; then
	patch -d "$KERNEL_DIR" -p1 --forward --batch --fuzz=0 < "$HDMI_FORCE_RESET_PATCH"
fi
if ! grep -q 'RK3528 HDMI mode 2560x1440@60 accepted' "$KERNEL_DIR/drivers/gpu/drm/rockchip/dw_hdmi-rockchip.c"; then
	patch -d "$KERNEL_DIR" -p1 --forward --batch --fuzz=0 < "$HDMI_PIXEL_CLOCK_PATCH"
fi
if ! grep -q 'phy_dclk_before=' "$KERNEL_DIR/drivers/gpu/drm/rockchip/dw_hdmi-rockchip.c"; then
	patch -d "$KERNEL_DIR" -p1 --forward --batch --fuzz=0 < "$HDMI_SINGLE_CLOCK_PATCH"
fi
if grep -q 'RK3528 vp%d dclk requested' "$KERNEL_DIR/drivers/gpu/drm/rockchip/rockchip_drm_vop2.c" && \
	! grep -q 'clk_get_rate(vp->dclk));' "$KERNEL_DIR/drivers/gpu/drm/rockchip/rockchip_drm_vop2.c"; then
	patch -d "$KERNEL_DIR" -p1 --forward --batch --fuzz=0 < "$HDMI_SINGLE_CLOCK_FIX_PATCH"
fi
if ! grep -q 'phy_dclk requested=' "$KERNEL_DIR/drivers/gpu/drm/rockchip/dw_hdmi-rockchip.c"; then
	patch -d "$KERNEL_DIR" -p1 --forward --batch --fuzz=0 < "$HDMI_CLOCK_SYNC_PATCH"
fi
if ! sed -n '/User-defined mode not supported:/,+3p' \
	"$KERNEL_DIR/drivers/gpu/drm/drm_modes.c" | grep -q 'drm_get_mode_status_name'; then
	patch -d "$KERNEL_DIR" -p1 --forward --batch --fuzz=0 < "$HDMI_MODE_STATUS_PATCH"
fi
if ! grep -q 'rk3528_hdmi_drv_data' "$KERNEL_DIR/drivers/gpu/drm/rockchip/dw_hdmi-rockchip.c"; then
	patch -d "$KERNEL_DIR" -p1 --forward --batch --fuzz=0 < "$HDMI_GLUE_PATCH"
fi
if ! grep -q 'FIELD_PREP_WM16(RK3528_HDMI_SNKDET, 1)' "$KERNEL_DIR/drivers/gpu/drm/rockchip/dw_hdmi-rockchip.c"; then
	patch -d "$KERNEL_DIR" -p1 --forward --batch --fuzz=0 < "$HDMI_GLUE_FIX_PATCH"
fi
if ! grep -q 'RK3528_HDMI_SDAIN_MSK, 1' "$KERNEL_DIR/drivers/gpu/drm/rockchip/dw_hdmi-rockchip.c"; then
	patch -d "$KERNEL_DIR" -p1 --forward --batch --fuzz=0 < "$HDMI_GRF_PATCH"
fi
if ! grep -q 'rk3528_gpio_hpd_sync' "$KERNEL_DIR/drivers/gpu/drm/rockchip/dw_hdmi-rockchip.c"; then
	patch -d "$KERNEL_DIR" -p1 --forward --batch --fuzz=0 < "$HDMI_HPD_PATCH"
fi
if grep -q 'RK3528_VO_GRF_HDMI_MASK.*0x60014' "$KERNEL_DIR/drivers/gpu/drm/rockchip/dw_hdmi-rockchip.c"; then
	patch -d "$KERNEL_DIR" -p1 --forward --batch --fuzz=0 < "$HDMI_GRF_OFFSET_PATCH"
fi
if ! grep -q 'failed to get EDID over DDC' "$KERNEL_DIR/drivers/gpu/drm/bridge/synopsys/dw-hdmi.c"; then
	patch -d "$KERNEL_DIR" -p1 --forward --batch --fuzz=0 < "$HDMI_EDID_DEBUG_PATCH"
fi
if ! grep -q 'RK3528 bring-up descriptor' "$KERNEL_DIR/drivers/gpu/drm/rockchip/rockchip_vop2_reg.c"; then
	patch -d "$KERNEL_DIR" -p1 --forward --batch --fuzz=0 < "$VOP_PATCH"
fi
if ! grep -q 'The RK3528 vendor VOP descriptor sets hdmi_dclk_pol=1' \
	"$KERNEL_DIR/drivers/gpu/drm/rockchip/rockchip_vop2_reg.c"; then
	patch -d "$KERNEL_DIR" -p1 --forward --batch --fuzz=0 < "$VOP_HDMI_POLARITY_PATCH"
fi
if sed -n '/if (hdmi->ref_clk)/,/PHY table explicitly supports the 241.5 MHz CVT-RB mode/p' \
	"$KERNEL_DIR/drivers/gpu/drm/rockchip/dw_hdmi-rockchip.c" | \
	grep -q 'PHY table explicitly supports the 241.5 MHz CVT-RB mode'; then
	patch -d "$KERNEL_DIR" -p1 --forward --batch --fuzz=0 < "$HDMI_MODE_PLACEMENT_FIX_PATCH"
fi
if ! grep -q 'PHY table explicitly supports the 241.5 MHz CVT-RB mode' \
	"$KERNEL_DIR/drivers/gpu/drm/rockchip/dw_hdmi-rockchip.c"; then
	patch -d "$KERNEL_DIR" -p1 --forward --batch --fuzz=0 < "$HDMI_MODE_VALID_PATCH"
fi
# The explanatory comment is wrapped across source lines; use its stable
# single-line prefix so repeated preparation remains idempotent.
if ! grep -q 'revision-specific' "$KERNEL_DIR/drivers/gpu/drm/rockchip/rockchip_drm_vop2.c"; then
	patch -d "$KERNEL_DIR" -p1 --forward --batch --fuzz=0 < "$VOP_VERSION_PATCH"
fi
# A previous experiment used Esmart0 as primary. It does not produce a valid
# TMDS stream on the W132D; unwind that experiment in an incremental tree.
if sed -n '/static const struct vop2_win_data rk3528_vop_win_data/,/};/p' \
	"$KERNEL_DIR/drivers/gpu/drm/rockchip/rockchip_vop2_reg.c" | \
	grep -q 'Esmart0-win0'; then
	patch -d "$KERNEL_DIR" -p1 -R --forward --batch --fuzz=0 < "$VOP_ESMART_PATCH"
fi
if ! sed -n '/static const struct vop2_win_data rk3528_vop_win_data/,/};/p' \
	"$KERNEL_DIR/drivers/gpu/drm/rockchip/rockchip_vop2_reg.c" | \
	grep -q 'Cluster0-win0'; then
	patch -d "$KERNEL_DIR" -p1 --forward --batch --fuzz=0 < "$VOP_CLUSTER_PATCH"
fi

# Apply the RK3528-specific background mix delay after the primary window.
if ! grep -q 'high byte of PORT0_BG_MIX_CTRL' "$KERNEL_DIR/drivers/gpu/drm/rockchip/rockchip_vop2_reg.c"; then
	patch -d "$KERNEL_DIR" -p1 --forward --batch --fuzz=0 < "$VOP_BG_DELAY_PATCH"
fi
if ! grep -q 'rk3528_vop_cluster_regs' "$KERNEL_DIR/drivers/gpu/drm/rockchip/rockchip_vop2_reg.c"; then
	patch -d "$KERNEL_DIR" -p1 --forward --batch --fuzz=0 < "$VOP_REG_PATCH"
fi
if grep -q 'to_vop2_win(vp->primary_plane)' "$KERNEL_DIR/drivers/gpu/drm/rockchip/rockchip_vop2_reg.c"; then
	patch -d "$KERNEL_DIR" -p1 --forward --batch --fuzz=0 < "$VOP_REG_FIX_PATCH"
fi
if ! grep -q 'RK3528 HDMI is wired for the standard 8-bit RGB888 path' \
	"$KERNEL_DIR/drivers/gpu/drm/rockchip/dw_hdmi-rockchip.c"; then
	patch -d "$KERNEL_DIR" -p1 --forward --batch --fuzz=0 < "$HDMI_RGB888_PATCH"
fi
if ! grep -q 'RK3528 vendor values: window, layer mix, HDR mix, total' \
	"$KERNEL_DIR/drivers/gpu/drm/rockchip/rockchip_vop2_reg.c"; then
	patch -d "$KERNEL_DIR" -p1 --forward --batch --fuzz=0 < "$VOP_VENDOR_DELAY_PATCH"
fi
fi

# Use the Armbian/mainline RK3528 PHY implementation. The older project-local
# driver is intentionally left in the repository as historical reference but
# is no longer injected into the kernel build.
if ! grep -q 'rk3528_phy_cfgs' "$KERNEL_DIR/drivers/phy/rockchip/phy-rockchip-inno-usb2.c"; then
	patch -d "$KERNEL_DIR" -p1 --forward --batch --fuzz=0 < "$USB2_PATCH"
fi
if ! grep -q 'usb_host0_xhci:' "$KERNEL_DIR/arch/arm64/boot/dts/rockchip/rk3528.dtsi"; then
	patch -d "$KERNEL_DIR" -p1 --forward --batch --fuzz=0 < "$USB_DTSI_PATCH"
fi
if ! grep -q 'hs400_tx_tap' "$KERNEL_DIR/drivers/mmc/host/sdhci-of-dwcmshc.c"; then
	patch -d "$KERNEL_DIR" -p1 --forward --batch --fuzz=0 < "$HS400_PATCH"
fi
if ! grep -q 'rockchip,rk3528-tsadc' "$KERNEL_DIR/drivers/thermal/rockchip_thermal.c"; then
	patch -d "$KERNEL_DIR" -p1 --forward --batch --fuzz=0 < "$TSADC_PATCH"
fi
if ! grep -q 'rockchip,rk3528-vdec' \
	"$KERNEL_DIR/drivers/media/platform/rockchip/rkvdec/rkvdec.c"; then
	patch -d "$KERNEL_DIR" -p1 --forward --batch --fuzz=0 < "$RKVDEC_PATCH"
fi
if ! grep -q 'config SND_SOC_RK3528' "$KERNEL_DIR/sound/soc/codecs/Kconfig"; then
	patch -d "$KERNEL_DIR" -p1 --forward --batch --fuzz=0 < "$AUDIO_PATCH"
fi
if ! grep -q 'ignoring invalid default link policy response' "$KERNEL_DIR/net/bluetooth/hci_sync.c"; then
	perl -0pi -e 's/(\tu16 link_policy = 0;\n)/$1\tint err;\n/; s/\treturn __hci_cmd_sync_status\(hdev, HCI_OP_WRITE_DEF_LINK_POLICY,\n\t\s+sizeof\(cp\), &cp, HCI_CMD_TIMEOUT\);/\terr = __hci_cmd_sync_status(hdev, HCI_OP_WRITE_DEF_LINK_POLICY,\n\t\t\t\t    sizeof(cp), \&cp, HCI_CMD_TIMEOUT);\n\t\/\* UWE5622 advertises this command but returns Invalid Parameters. \*\/\n\tif (err == -EINVAL) {\n\t\tbt_dev_warn(hdev, "ignoring invalid default link policy response");\n\t\treturn 0;\n\t}\n\n\treturn err;/s' \
		"$KERNEL_DIR/net/bluetooth/hci_sync.c"
fi
# Remove the previous experimental object injection if this build tree was
# used by an earlier iteration.
sed -i '/^obj-y += phy-rockchip-rk3528-usb2\.o$/d' \
	"$KERNEL_DIR/drivers/phy/rockchip/Makefile"

echo '=== prepare Linux v7.1.10 configuration ==='
make -C "$KERNEL_DIR" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" LOCALVERSION= defconfig >/dev/null
"$KERNEL_DIR/scripts/config" --file "$KERNEL_DIR/.config" \
	--disable CONFIG_LOCALVERSION_AUTO \
	--set-str CONFIG_LOCALVERSION '' \
	--enable CONFIG_STMMAC_ETH \
	--enable CONFIG_STMMAC_PLATFORM \
	--enable CONFIG_DWMAC_ROCKCHIP \
	--enable CONFIG_USB_EHCI_HCD_PLATFORM \
	--enable CONFIG_USB_OHCI_HCD_PLATFORM \
	--enable CONFIG_USB_XHCI_HCD \
	--enable CONFIG_USB_XHCI_PLATFORM \
	--enable CONFIG_USB_DWC3 \
	--enable CONFIG_USB_DWC3_HOST \
	--enable CONFIG_USB_DWC3_OF_SIMPLE \
	--enable CONFIG_PHY_ROCKCHIP_NANENG_COMBO_PHY \
	--enable CONFIG_PHY_ROCKCHIP_INNO_HDMI \
	--enable CONFIG_DRM \
	--enable CONFIG_DRM_KMS_HELPER \
	--enable CONFIG_DRM_ROCKCHIP \
	--enable CONFIG_DRM_DW_HDMI \
	--enable CONFIG_DRM_DW_HDMI_I2S_AUDIO \
	--enable CONFIG_DRM_DW_HDMI_CEC \
	--enable CONFIG_DRM_SIMPLEDRM \
	--enable CONFIG_SYSFB_SIMPLEFB \
	--enable CONFIG_MMC_CQHCI \
	--enable CONFIG_MMC_SDHCI_OF_DWCMSHC \
	--enable CONFIG_THERMAL \
	--module CONFIG_ROCKCHIP_THERMAL \
	--enable CONFIG_MEDIA_SUPPORT \
	--enable CONFIG_MEDIA_PLATFORM_SUPPORT \
	--module CONFIG_VIDEO_ROCKCHIP_VDEC \
	--module CONFIG_DRM_LIMA \
	--enable CONFIG_WATCHDOG \
	--enable CONFIG_DW_WATCHDOG \
	--enable CONFIG_PWM_ROCKCHIP \
	--enable CONFIG_REGULATOR_PWM \
	--enable CONFIG_OPTEE \
	--enable CONFIG_PSTORE \
	--enable CONFIG_PSTORE_RAM \
	--enable CONFIG_PSTORE_CONSOLE \
	--enable CONFIG_NEW_LEDS \
	--enable CONFIG_LEDS_CLASS \
	--enable CONFIG_LEDS_GPIO \
	--module CONFIG_RC_CORE \
	--enable CONFIG_RC_MAP \
	--enable CONFIG_LIRC \
	--module CONFIG_IR_GPIO_CIR \
	--module CONFIG_IR_NEC_DECODER \
	--module CONFIG_IR_RC5_DECODER \
	--module CONFIG_IR_RC6_DECODER \
	--module CONFIG_IR_SONY_DECODER \
	--module CONFIG_IR_JVC_DECODER \
	--module CONFIG_IR_SHARP_DECODER \
	--module CONFIG_SND \
	--module CONFIG_SND_SOC \
	--module CONFIG_SND_SOC_ROCKCHIP_SAI \
	--module CONFIG_SND_SOC_ROCKCHIP_PDM \
	--module CONFIG_SND_SOC_RK3528 \
	--module CONFIG_SND_SOC_ES7202 \
	--set-val CONFIG_SND_SOC_ES7202_MIC_MAX_CHANNELS 2 \
	--module CONFIG_SND_SIMPLE_CARD \
	--module CONFIG_ROCKCHIP_SARADC \
	--module CONFIG_RFKILL \
	--module CONFIG_CFG80211 \
	--module CONFIG_BT \
	--module CONFIG_BT_HCIUART \
	--enable CONFIG_BT_HCIUART_H4 \
	--disable CONFIG_BT_HCIUART_BCSP \
	--disable CONFIG_BT_HCIUART_3WIRE \
	--disable CONFIG_BT_HCIUART_LL \
	--disable CONFIG_BT_HCIUART_ATH3K \
	--disable CONFIG_BT_HCIUART_INTEL \
	--disable CONFIG_BT_HCIUART_BCM \
	--disable CONFIG_BT_HCIUART_QCA \
	--disable CONFIG_BT_HCIUART_AG6XX \
	--disable CONFIG_BT_HCIUART_MRVL \
	--module CONFIG_CRYPTO_KPP \
	--module CONFIG_CRYPTO_ECC \
	--module CONFIG_CRYPTO_ECDH \
	--module CONFIG_CRYPTO_CMAC
make -C "$KERNEL_DIR" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" LOCALVERSION= olddefconfig >/dev/null
if [ "$ENABLE_HDMI" != 1 ]; then
	"$KERNEL_DIR/scripts/config" --file "$KERNEL_DIR/.config" \
		--disable CONFIG_DRM \
		--disable CONFIG_DRM_ROCKCHIP \
		--disable CONFIG_DRM_DW_HDMI \
		--disable CONFIG_DRM_DW_HDMI_I2S_AUDIO \
		--disable CONFIG_DRM_DW_HDMI_CEC \
		--disable CONFIG_PHY_ROCKCHIP_INNO_HDMI \
		--disable CONFIG_DRM_SIMPLEDRM \
		--disable CONFIG_SYSFB_SIMPLEFB
	make -C "$KERNEL_DIR" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" LOCALVERSION= olddefconfig >/dev/null
fi
# A stale generated release file can retain an earlier -dirty suffix across
# incremental builds even after CONFIG_LOCALVERSION_AUTO is disabled.
rm -f "$KERNEL_DIR/include/config/kernel.release"

echo '=== effective bring-up configuration ==='
grep -E '^(CONFIG_LOCALVERSION|CONFIG_LOCALVERSION_AUTO|CONFIG_STMMAC_ETH|CONFIG_STMMAC_PLATFORM|CONFIG_DWMAC_ROCKCHIP|CONFIG_PHY_ROCKCHIP_INNO_USB2|CONFIG_PHY_ROCKCHIP_NANENG_COMBO_PHY|CONFIG_PHY_ROCKCHIP_INNO_HDMI|CONFIG_USB_EHCI_HCD_PLATFORM|CONFIG_USB_OHCI_HCD_PLATFORM|CONFIG_USB_XHCI_HCD|CONFIG_USB_XHCI_PLATFORM|CONFIG_USB_DWC3|CONFIG_USB_DWC3_HOST|CONFIG_USB_DWC3_OF_SIMPLE|CONFIG_DRM|CONFIG_DRM_KMS_HELPER|CONFIG_DRM_ROCKCHIP|CONFIG_DRM_DW_HDMI|CONFIG_DRM_DW_HDMI_I2S_AUDIO|CONFIG_DRM_DW_HDMI_CEC|CONFIG_DRM_SIMPLEDRM|CONFIG_SYSFB_SIMPLEFB)=' "$KERNEL_DIR/.config"
