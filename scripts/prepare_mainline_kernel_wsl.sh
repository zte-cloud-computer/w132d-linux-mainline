#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
WIN_DIR="${W132D_MAINLINE_DIR:-$(cd -- "$SCRIPT_DIR/.." && pwd)}"
KERNEL_DIR="${W132D_MAINLINE_KERNEL_DIR:-/root/w132d-build/linux-v7.1}"
ARCH=arm64
CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
USB2_PATCH="$WIN_DIR/patches/rk3528-inno-usb2-7.1.patch"
USB_DTSI_PATCH="$WIN_DIR/patches/rk3528-usb-dtsi-7.1.patch"

[ -d "$KERNEL_DIR" ] || { echo "ERROR: kernel checkout not found: $KERNEL_DIR" >&2; exit 1; }
[ -s "$USB2_PATCH" ] || { echo "ERROR: missing RK3528 USB2 PHY patch: $USB2_PATCH" >&2; exit 1; }
[ -s "$USB_DTSI_PATCH" ] || { echo "ERROR: missing RK3528 USB DTS patch: $USB_DTSI_PATCH" >&2; exit 1; }

if ! grep -q 'rk3528_phy_cfgs' "$KERNEL_DIR/drivers/phy/rockchip/phy-rockchip-inno-usb2.c"; then
	patch -d "$KERNEL_DIR" -p1 --forward --batch < "$USB2_PATCH"
fi
if ! grep -q 'usb_host0_xhci:' "$KERNEL_DIR/arch/arm64/boot/dts/rockchip/rk3528.dtsi"; then
	patch -d "$KERNEL_DIR" -p1 --forward --batch < "$USB_DTSI_PATCH"
fi

# The WCN Bluetooth controller advertises this command but returns Invalid
# Parameters. Treat that response as a successful optional setup step.
if ! grep -q 'ignoring invalid default link policy response' "$KERNEL_DIR/net/bluetooth/hci_sync.c"; then
	perl -0pi -e 's/(\tu16 link_policy = 0;\n)/$1\tint err;\n/; s/\treturn __hci_cmd_sync_status\(hdev, HCI_OP_WRITE_DEF_LINK_POLICY,\n\s+sizeof\(cp\), &cp, HCI_CMD_TIMEOUT\);/\terr = __hci_cmd_sync_status(hdev, HCI_OP_WRITE_DEF_LINK_POLICY,\n\t\t\t\t    sizeof(cp), \&cp, HCI_CMD_TIMEOUT);\n\t\/\* UWE5622 advertises this command but returns Invalid Parameters. \*\/\n\tif (err == -EINVAL) {\n\t\tbt_dev_warn(hdev, "ignoring invalid default link policy response");\n\t\treturn 0;\n\t}\n\n\treturn err;/s' \
		"$KERNEL_DIR/net/bluetooth/hci_sync.c"
fi

# Do not inject the obsolete project-local USB2 object into the kernel tree.
sed -i '/^obj-y += phy-rockchip-rk3528-usb2\.o$/d' \
	"$KERNEL_DIR/drivers/phy/rockchip/Makefile"

echo '=== prepare Linux v7.1 configuration ==='
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
	--enable CONFIG_PHY_ROCKCHIP_INNO_USB2 \
	--enable CONFIG_PHY_ROCKCHIP_NANENG_COMBO_PHY \
	--disable CONFIG_DRM \
	--disable CONFIG_DRM_ROCKCHIP \
	--disable CONFIG_DRM_DW_HDMI \
	--disable CONFIG_DRM_DW_HDMI_I2S_AUDIO \
	--disable CONFIG_DRM_DW_HDMI_CEC \
	--disable CONFIG_DRM_SIMPLEDRM \
	--disable CONFIG_SYSFB_SIMPLEFB \
	--disable CONFIG_PHY_ROCKCHIP_INNO_HDMI \
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
rm -f "$KERNEL_DIR/include/config/kernel.release"

echo '=== effective bring-up configuration ==='
grep -E '^(CONFIG_LOCALVERSION|CONFIG_LOCALVERSION_AUTO|CONFIG_STMMAC_ETH|CONFIG_STMMAC_PLATFORM|CONFIG_DWMAC_ROCKCHIP|CONFIG_PHY_ROCKCHIP_INNO_USB2|CONFIG_PHY_ROCKCHIP_NANENG_COMBO_PHY|CONFIG_USB_EHCI_HCD_PLATFORM|CONFIG_USB_OHCI_HCD_PLATFORM|CONFIG_USB_XHCI_HCD|CONFIG_USB_XHCI_PLATFORM|CONFIG_USB_DWC3|CONFIG_USB_DWC3_HOST|CONFIG_USB_DWC3_OF_SIMPLE|CONFIG_DRM|CONFIG_PHY_ROCKCHIP_INNO_HDMI)=' "$KERNEL_DIR/.config" || true
