#!/bin/bash
# SPDX-License-Identifier: MIT
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
PRIVATE_DIR=${W132D_PRIVATE_DIR:?Set W132D_PRIVATE_DIR to a directory containing vendor-blobs/}
PUBLISH_DIR=${W132D_PUBLISH_DIR:-$PRIVATE_DIR}
BUILD_ROOT=${W132D_BUILD_ROOT:-/root/w132d-build}
VENDOR_HEAD=${W132D_VENDOR_HEAD:-$PRIVATE_DIR/vendor-blobs/head.bin}
VENDOR_UBOOT=${W132D_VENDOR_UBOOT:-$PRIVATE_DIR/vendor-blobs/p2_uboot-wdt.img}
DTSDUMP=$BUILD_ROOT/verify-rk3528-w132d.dts
FITCOPY=$BUILD_ROOT/verify-p2-uboot-wdt.img
FITDIR=$BUILD_ROOT/verify-wdt-fit
LO=
ATF1_PATCHED_SHA256=5d5540795a7b72b92b7d77c6907bafd0c5f2de8ca1fd302352f833bf0882bc02
ATF1_PATCH_OFFSET=100564
ATF1_PATCH_HEX=f4ffff17004480d2

[ "$(id -u)" -eq 0 ] || { echo 'ERROR: image verification must run as root'; exit 1; }
mkdir -p "$BUILD_ROOT"

cleanup() {
	set +e
	mountpoint -q /mnt/vb && umount /mnt/vb
	mountpoint -q /mnt/vr && umount /mnt/vr
	[ -n "$LO" ] && losetup -d "$LO" 2>/dev/null
	rm -rf "$DTSDUMP" "$FITCOPY" "$FITDIR"
}
trap cleanup EXIT

if [ -n "${W132D_IMAGE:-}" ]; then
	IMG=$W132D_IMAGE
else
	mapfile -t IMAGES < <(find "$PUBLISH_DIR" -maxdepth 1 -type f \
		-name 'w132d-armbian-????????-??????-UTC+8.img' -printf '%T@ %p\n' | sort -nr | cut -d' ' -f2-)
	[ "${#IMAGES[@]}" -gt 0 ] || { echo 'ERROR: no timestamped raw image found'; exit 1; }
	IMG=${IMAGES[0]}
fi
SUM=${IMG}.sha256

echo "=== verify image: $IMG ==="
case "$(basename "$IMG")" in
	w132d-armbian-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]-UTC+8.img) ;;
	*) echo 'ERROR: timestamped image filename is invalid'; exit 1 ;;
esac
[ -f "$SUM" ] || { echo "ERROR: checksum missing: $SUM"; exit 1; }
if find "$(dirname "$IMG")" -maxdepth 1 -type f -name "$(basename "$IMG").xz*" | grep -q .; then
	echo 'ERROR: timestamped image was compressed with xz'
	exit 1
fi

echo '=== SHA256 ==='
(cd "$(dirname "$SUM")" && sha256sum -c "$(basename "$SUM")")

echo '=== partition table ==='
sgdisk -p "$IMG"
sgdisk -v "$IMG"

echo '=== verified vendor boot chain ==='
[ -f "$VENDOR_HEAD" ] || { echo "ERROR: vendor idbloader not found: $VENDOR_HEAD"; exit 1; }
[ -f "$VENDOR_UBOOT" ] || { echo "ERROR: vendor U-Boot not found: $VENDOR_UBOOT"; exit 1; }
[ "$(stat -c %s "$VENDOR_UBOOT")" -eq 4194304 ] || { echo 'ERROR: vendor U-Boot is not 4 MiB'; exit 1; }
cmp -n 8355840 \
	<(dd if="$VENDOR_HEAD" bs=512 skip=64 count=16320 status=none) \
	<(dd if="$IMG" bs=512 skip=64 count=16320 status=none)
cmp "$VENDOR_UBOOT" <(dd if="$IMG" bs=512 skip=16384 count=8192 status=none)
echo 'Vendor idbloader and U-Boot: OK'

echo '=== matched Android 9 secure firmware ==='
rm -rf "$FITDIR"
mkdir -p "$FITDIR"
cp "$VENDOR_UBOOT" "$FITCOPY"
for index in 1 2 3; do
	dumpimage -T flat_dt -p "$index" -o "$FITDIR/atf-$index" "$FITCOPY" >/dev/null
done
dumpimage -T flat_dt -p 4 -o "$FITDIR/optee" "$FITCOPY" >/dev/null
echo "$ATF1_PATCHED_SHA256  $FITDIR/atf-1" | sha256sum -c -
echo "2ead5967c1e23dbb9381df9fbc55ff762815ba6be532669b553966b5aba81879  $FITDIR/atf-2" | sha256sum -c -
echo "9e4547a3b33f0fd56d71455958faa8c1d25c04a528632da7fb4a3949e1733910  $FITDIR/atf-3" | sha256sum -c -
echo "82da4e7f8b0e15906f172aa4897192be66e8d45e8898f01f7d2be3f7abfae023  $FITDIR/optee" | sha256sum -c -
grep -aFq 'Built : 17:46:19, Sep 30 2024' "$FITDIR/atf-1"
grep -aFq 'U3.13.0-743-gb5340fd65' "$FITDIR/optee"
ACTUAL_PATCH_HEX=$(od -An -tx1 -j "$ATF1_PATCH_OFFSET" -N 8 "$FITDIR/atf-1" | tr -d ' \n')
[ "$ACTUAL_PATCH_HEX" = "$ATF1_PATCH_HEX" ] || {
	echo "ERROR: BL31 periodic UART callback patch missing: $ACTUAL_PATCH_HEX"
	exit 1
}
echo 'Android 9 BL31 segments, paired OP-TEE, and UART-output bypass: OK'

echo '=== mount partitions ==='
LO=$(losetup -fP --show "$IMG")
partprobe "$LO" || true
udevadm settle || true
mkdir -p /mnt/vb /mnt/vr
mount -o ro "${LO}p2" /mnt/vb
mount -o ro "${LO}p3" /mnt/vr

echo '=== bootfs and device tree ==='
test -s /mnt/vb/Image
test -s /mnt/vb/uInitrd
test -s /mnt/vb/rockchip/rk3528-w132d.dtb
test -s /mnt/vb/extlinux/extlinux.conf
dtc -q -I dtb -O dts /mnt/vb/rockchip/rk3528-w132d.dtb > "$DTSDUMP"
grep -q 'usb-hub-reset-hog' "$DTSDUMP"
grep -q 'gpio-hog;' "$DTSDUMP"
grep -q 'output-high;' "$DTSDUMP"
grep -q 'line-name = "usb-hub-reset";' "$DTSDUMP"
grep -q 'watchdog@ffac0000' "$DTSDUMP"
WDT_NODE=$(grep -A12 -m1 'watchdog@ffac0000' "$DTSDUMP")
grep -q 'status = "okay";' <<<"$WDT_NODE"
grep -q 'resets = <.*0x9f>;' <<<"$WDT_NODE"
if grep -q 'interrupts =' <<<"$WDT_NODE"; then
	echo 'ERROR: non-secure watchdog still has a pretimeout interrupt'
	exit 1
fi
PWM3_NODE=$(grep -A12 -m1 'pwm@ffa90030' "$DTSDUMP")
grep -q 'status = "disabled";' <<<"$PWM3_NODE"
DMC_NODE=$(grep -A18 -m1 '^[[:space:]]*dmc[[:space:]]*{' "$DTSDUMP")
grep -q 'status = "disabled";' <<<"$DMC_NODE"
grep -q 'esmart_lb_mode = \[03\];' "$DTSDUMP"
grep -q 'support-multi-area;' "$DTSDUMP"
grep -q 'rockchip,plane-mask = <0x05>;' "$DTSDUMP"
grep -q 'rockchip,primary-plane = <0x00>;' "$DTSDUMP"
SDIO_NODE=$(grep -A35 -m1 'mmc@ffc20000' "$DTSDUMP")
grep -q 'status = "okay";' <<<"$SDIO_NODE"
grep -q 'non-removable;' <<<"$SDIO_NODE"
grep -q 'cap-sdio-irq;' <<<"$SDIO_NODE"
grep -q 'mmc-pwrseq = ' <<<"$SDIO_NODE"
grep -q 'compatible = "mmc-pwrseq-simple";' "$DTSDUMP"
grep -q 'reset-gpios = <.*0x0a 0x01>;' "$DTSDUMP"
grep -q 'rockchip,pins = <0x03 0x0a 0x00 ' "$DTSDUMP"
grep -q 'rockchip,pins = <0x03 0x14 0x00 ' "$DTSDUMP"
grep -q 'status = "okay";' "$DTSDUMP"
SPRD_NODE=$(grep -A5 -m1 '^[[:space:]]*sprd-wlan[[:space:]]*{' "$DTSDUMP")
grep -q 'compatible = "sprd,unisoc-wifi";' <<<"$SPRD_NODE"
grep -q 'status = "okay";' <<<"$SPRD_NODE"
UWE_NODE=$(grep -A15 -m1 '^[[:space:]]*uwe-bsp[[:space:]]*{' "$DTSDUMP")
grep -q 'compatible = "unisoc,uwe_bsp";' <<<"$UWE_NODE"
grep -q 'bt-reg-on = <.*0x12 0x00>;' <<<"$UWE_NODE"
grep -q 'sdio-ext-int-gpio = <.*0x13 0x00>;' <<<"$UWE_NODE"
grep -q 'bt-wake-host;' <<<"$UWE_NODE"
grep -q 'bt-wake-host-gpio = <.*0x11 0x00>;' <<<"$UWE_NODE"
grep -q 'unisoc,btwf-file-name = "/lib/firmware/uwe5622/wcnmodem.bin";' <<<"$UWE_NODE"
grep -q 'data-irq;' <<<"$UWE_NODE"
grep -q 'blksz-512;' <<<"$UWE_NODE"
grep -q 'keep-power-on;' <<<"$UWE_NODE"
grep -q 'status = "okay";' <<<"$UWE_NODE"
MTTY_NODE=$(grep -A5 -m1 '^[[:space:]]*mtty[[:space:]]*{' "$DTSDUMP")
grep -q 'compatible = "sprd,mtty";' <<<"$MTTY_NODE"
grep -q 'sprd,name = "ttyBT";' <<<"$MTTY_NODE"
grep -q 'status = "okay";' <<<"$MTTY_NODE"
UART2_NODE=$(grep -A16 -m1 '^[[:space:]]*serial@ffa00000[[:space:]]*{' "$DTSDUMP")
grep -q 'status = "disabled";' <<<"$UART2_NODE"
echo 'USB reset, watchdog cleanup, DMC/infrared disable, HDMI VOP, and UWE5622 WiFi/BT DT properties: OK'

HID_APPLE=$(find /mnt/vr/lib/modules -type f -name 'hid-apple.ko*' | head -1)
[ -n "$HID_APPLE" ] || { echo 'ERROR: hid-apple module not found'; exit 1; }
modinfo -F alias "$HID_APPLE" | grep -i 'v000005ACp0000024F' || true
if modinfo -F alias "$HID_APPLE" | grep -qi 'hid:b0003.*v000005ACp0000024F'; then
	echo 'ERROR: hid-apple still claims HFD 05ac:024f'
	exit 1
fi
echo 'HFD 05ac:024f is not claimed by hid-apple: OK'

echo '=== UWE5622 WiFi/Bluetooth modules and firmware ==='
KREL=6.1.115-vendor-rk35xx
UWE_DIR=/mnt/vr/lib/modules/${KREL}/updates/uwe5622
test -s "$UWE_DIR/uwe5622_bsp_sdio.ko"
test -s "$UWE_DIR/sprdwl_ng.ko"
test -s "$UWE_DIR/sprdbt_tty.ko"
[ "$(modinfo -F vermagic "$UWE_DIR/uwe5622_bsp_sdio.ko" | awk '{print $1}')" = "$KREL" ]
[ "$(modinfo -F vermagic "$UWE_DIR/sprdwl_ng.ko" | awk '{print $1}')" = "$KREL" ]
[ "$(modinfo -F vermagic "$UWE_DIR/sprdbt_tty.ko" | awk '{print $1}')" = "$KREL" ]
modinfo -F depends "$UWE_DIR/sprdwl_ng.ko" | grep -q 'uwe5622_bsp_sdio'
modinfo -F depends "$UWE_DIR/sprdbt_tty.ko" | grep -q 'uwe5622_bsp_sdio'
modinfo -F softdep "$UWE_DIR/sprdbt_tty.ko" | grep -q 'uwe5622_bsp_sdio'
grep -aFq 'sprdwl: cfg80211 vendor raw-data policies initialized' "$UWE_DIR/sprdwl_ng.ko"
grep -aFq 'RX_BOUNDS sdma trailer reject' "$UWE_DIR/uwe5622_bsp_sdio.ko"
grep -aFq 'BT_RX_BOUNDS reject block=' "$UWE_DIR/sprdbt_tty.ko"
grep -aFq 'SITM_BOUNDS drop HCI type=' "$UWE_DIR/sprdbt_tty.ko"
grep -q 'updates/uwe5622/uwe5622_bsp_sdio.ko' "/mnt/vr/lib/modules/${KREL}/modules.dep"
grep -q 'updates/uwe5622/sprdwl_ng.ko.*uwe5622_bsp_sdio.ko' "/mnt/vr/lib/modules/${KREL}/modules.dep"
grep -q 'updates/uwe5622/sprdbt_tty.ko.*uwe5622_bsp_sdio.ko' "/mnt/vr/lib/modules/${KREL}/modules.dep"
echo 'ee9cb2cec5b680f4a91f13d737b30593f1216e05ac69c048a2877e51f8902b0e  /mnt/vr/lib/firmware/uwe5622/wcnmodem.bin' | sha256sum -c -
echo 'e63e257fea222f54f1e94960ac299b242358d48bfc6048a418aa2c36bb372932  /mnt/vr/lib/firmware/uwe5622/wifi_board_config.ini' | sha256sum -c -
echo 'f7f17f1c4eef85053dc57fd5b52d4bc02d4bf54a69e6867f6fdf9a0146db5140  /mnt/vr/etc/w132d/bluetooth/bt_configure_pskey.ini' | sha256sum -c -
echo '41c1eab6f4777b730a057d437e5b940fa45c0aceac973044a88afbc738a08da7  /mnt/vr/etc/w132d/bluetooth/bt_configure_rf.ini' | sha256sum -c -
cmp -s /mnt/vr/lib/firmware/uwe5622/wifi_board_config.ini /mnt/vr/lib/firmware/uwe5622/wifi_56630001_3ant.ini
printf 'uwe5622_bsp_sdio\nsprdwl_ng\nsprdbt_tty\nhci_uart\n' | cmp -s - /mnt/vr/etc/modules-load.d/w132d-uwe5622.conf
echo 'UWE5622 modules, dependencies, firmware, board data, and module load order: OK'

echo '=== Bluetooth userspace ==='
test -x /mnt/vr/usr/local/sbin/w132d-btattach
file /mnt/vr/usr/local/sbin/w132d-btattach | grep -q 'ARM aarch64'
grep -aFq 'opcode 0x%04x complete' /mnt/vr/usr/local/sbin/w132d-btattach
cmp -s "$REPO_ROOT/rootfs/w132d-bluetooth.service" /mnt/vr/etc/systemd/system/w132d-bluetooth.service
test -L /mnt/vr/etc/systemd/system/multi-user.target.wants/w132d-bluetooth.service
test -L /mnt/vr/etc/systemd/system/bluetooth.target.wants/bluetooth.service
test -x /mnt/vr/usr/bin/btattach
test -x /mnt/vr/usr/bin/bluetoothctl
find /mnt/vr/usr -type f -name bluetoothd -perm /111 | grep -q .
echo 'BlueZ, Marlin3 initializer, and enabled systemd services: OK'

echo '=== NetworkManager ==='
dpkg-query --admindir=/mnt/vr/var/lib/dpkg -W -f='${db:Status-Status}\n' network-manager | grep -qx installed
test -x /mnt/vr/usr/bin/nmcli
test -s /mnt/vr/lib/systemd/system/NetworkManager.service
test -L /mnt/vr/etc/systemd/system/multi-user.target.wants/NetworkManager.service
grep -qx 'unmanaged-devices=interface-name:e\*;interface-name:lan\*;interface-name:wan\*' \
  /mnt/vr/etc/NetworkManager/conf.d/10-w132d-network-ownership.conf
echo 'NetworkManager package, nmcli, enabled service, and wired/WiFi ownership split: OK'

echo '=== Rockchip MPP userspace ==='
test -L /mnt/vr/usr/local/lib/librockchip_mpp.so
test -s /mnt/vr/usr/local/lib/librockchip_mpp.so.1
test -x /mnt/vr/usr/local/bin/mpi_dec_test
test -x /mnt/vr/usr/local/bin/mpi_enc_test
file /mnt/vr/usr/local/bin/mpi_dec_test | grep -q 'ARM aarch64'
file /mnt/vr/usr/local/bin/mpi_enc_test | grep -q 'ARM aarch64'
echo 'Rockchip MPP libraries and decode/encode tests: OK'

echo '=== rootfs ==='
cat /mnt/vr/etc/os-release | sed -n '1,3p'
test -s /mnt/vr/usr/local/sbin/grow-rootfs.sh
test -s /mnt/vr/etc/systemd/system/grow-rootfs.service
for tool in partprobe resize2fs; do
	test -x "/mnt/vr/usr/sbin/$tool"
done
test -x /mnt/vr/usr/bin/growpart
cmp -s "$REPO_ROOT/rootfs/grow-rootfs.sh" /mnt/vr/usr/local/sbin/grow-rootfs.sh
echo 'Root filesystem grow service: OK'

echo '=== cleanup ==='
umount /mnt/vb /mnt/vr
losetup -d "$LO"
LO=
rm -f "$DTSDUMP"
echo 'VERIFY_DONE'
