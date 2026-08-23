#!/bin/bash
# SPDX-License-Identifier: MIT
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
MAINLINE_DIR=${W132D_MAINLINE_DIR:-$REPO_ROOT}
BUILD_ROOT=${W132D_BUILD_ROOT:-/root/w132d-build}
PRIVATE_DIR=${W132D_PRIVATE_DIR:-/mnt/c/Users/a8ec29b/w132d-armbian}
HEAD_BIN=${W132D_MAINLINE_HEAD_BIN:-$PRIVATE_DIR/vendor-blobs/head.bin}
UBOOT_IMAGE=${W132D_MAINLINE_UBOOT_IMAGE:-$PRIVATE_DIR/vendor-blobs/p2_uboot-wdt.img}
OUT_DIR=${W132D_MAINLINE_IMAGE_OUT_DIR:-$MAINLINE_DIR/out/images}
OUT_WORK=${W132D_MAINLINE_WORK_DIR:-$BUILD_ROOT/mainline-image-work}
BASE_IMAGE=${W132D_MAINLINE_BASE_IMAGE:-$PRIVATE_DIR/w132d-armbian-20260820-200141-UTC+8.img}
VENDOR_ANDROID_IMAGE=${W132D_MAINLINE_VENDOR_IMAGE:-$PRIVATE_DIR/w132d-a9/15.vendor.img}
WIRELESS_OUT=${W132D_MAINLINE_WIRELESS_OUT:-$MAINLINE_DIR/out/wireless}
WIRELESS_STAGE=${W132D_MAINLINE_WIRELESS_STAGE:-$BUILD_ROOT/vendor-wireless-mainline}
WIRELESS_PORT_REPO=${W132D_MAINLINE_PORT_REPO:-$MAINLINE_DIR/../w132d-armbian-port-repo}
CHROOT_POLICY_BACKUP=$OUT_WORK/policy-rc.d.backup
CHROOT_RESOLV_BACKUP=$OUT_WORK/resolv.conf.backup
HAD_CHROOT_POLICY=0
HAD_CHROOT_RESOLV=0
ROOT_UUID=${W132D_MAINLINE_ROOT_UUID:-b9d1a0d9-6a3b-4db8-9d7a-2b1b6c11e721}
ROOT_PARTUUID=${W132D_MAINLINE_ROOT_PARTUUID:-3051FA2F-CBC1-40D3-9B27-2CDE013D09CE}
ROOT_DEVICE=${W132D_MAINLINE_ROOT_DEVICE:-/dev/mmcblk0p3}
if [ "${W132D_MAINLINE_VIDEO_ARGS+x}" = x ]; then
	VIDEO_ARGS=$W132D_MAINLINE_VIDEO_ARGS
else
	VIDEO_ARGS=
fi
IMAGE_VARIANT=${W132D_IMAGE_VARIANT:-}
ROOT_START=1073152
BOOT_START=24576
BOOT_END=1073151
UBOOT_START=16384
IMAGE_SIZE_MIB=${W132D_MAINLINE_IMAGE_SIZE_MIB:-2700}

SOURCE_IMAGE=${W132D_MAINLINE_SOURCE_IMAGE:-}
SOURCE_ROOT_PART=${W132D_MAINLINE_SOURCE_ROOT_PART:-}
if [ -z "$SOURCE_IMAGE" ]; then
	VENDOR_SOURCE="$BUILD_ROOT/armbian-build/output/images/Armbian-unofficial_26.08.0-trunk_W132d_trixie_vendor_6.1.115_minimal.img"
	if [ -s "$VENDOR_SOURCE" ]; then
		SOURCE_IMAGE=$VENDOR_SOURCE
		SOURCE_ROOT_PART=${SOURCE_ROOT_PART:-1}
	else
		for candidate in "$OUT_DIR"/w132d-mainline-armbian-*.img; do
			[ -s "$candidate" ] || continue
			if [ -z "$SOURCE_IMAGE" ] || [ "$candidate" -nt "$SOURCE_IMAGE" ]; then
				SOURCE_IMAGE=$candidate
			fi
		done
		SOURCE_ROOT_PART=${SOURCE_ROOT_PART:-3}
	fi
fi
SOURCE_ROOT_PART=${SOURCE_ROOT_PART:-1}

# This workflow intentionally emits complete RKDevTool-compatible images.
# Raw partition export was removed because copying multi-gigabyte ranges
# through /mnt/c is extremely slow and a partition image is unsafe to flash
# on this board without the surrounding GPT/container metadata.
if [ "${W132D_MAINLINE_PARTITION_ONLY:-0}" = 1 ]; then
	echo 'ERROR: partition-only output has been removed; build a complete image instead' >&2
	exit 1
fi

[ "$(id -u)" -eq 0 ] || { echo 'ERROR: run this script as root in WSL' >&2; exit 1; }
[ -s "$MAINLINE_DIR/out/Image" ] || { echo "ERROR: missing $MAINLINE_DIR/out/Image" >&2; exit 1; }
[ -s "$MAINLINE_DIR/out/rk3528-w132d.dtb" ] || { echo "ERROR: missing $MAINLINE_DIR/out/rk3528-w132d.dtb" >&2; exit 1; }
[ -s "$SOURCE_IMAGE" ] || { echo "ERROR: missing source Armbian image $SOURCE_IMAGE" >&2; exit 1; }
[ -s "$HEAD_BIN" ] || { echo "ERROR: missing vendor head.bin $HEAD_BIN" >&2; exit 1; }
[ -s "$UBOOT_IMAGE" ] || { echo "ERROR: missing vendor U-Boot image $UBOOT_IMAGE" >&2; exit 1; }
[ -s "$VENDOR_ANDROID_IMAGE" ] || { echo "ERROR: missing Android vendor image $VENDOR_ANDROID_IMAGE" >&2; exit 1; }
[ -s "$WIRELESS_OUT/uwe5622_bsp_sdio.ko" ] || { echo "ERROR: missing mainline WCN module; run build_wireless_mainline_wsl.sh" >&2; exit 1; }
[ -s "$WIRELESS_OUT/sprdwl_ng.ko" ] || { echo "ERROR: missing mainline WiFi module; run build_wireless_mainline_wsl.sh" >&2; exit 1; }
[ -s "$WIRELESS_OUT/sprdbt_tty.ko" ] || { echo "ERROR: missing mainline Bluetooth module; run build_wireless_mainline_wsl.sh" >&2; exit 1; }
[ -s "$WIRELESS_OUT/base/cfg80211.ko" ] || { echo "ERROR: missing cfg80211 module; run build_wireless_mainline_wsl.sh" >&2; exit 1; }
[ -s "$WIRELESS_OUT/base/rfkill.ko" ] || { echo "ERROR: missing rfkill module; run build_wireless_mainline_wsl.sh" >&2; exit 1; }
[ -s "$WIRELESS_OUT/base/bluetooth.ko" ] || { echo "ERROR: missing bluetooth module; run build_wireless_mainline_wsl.sh" >&2; exit 1; }
[ -s "$WIRELESS_OUT/base/hci_uart.ko" ] || { echo "ERROR: missing hci_uart module; run build_wireless_mainline_wsl.sh" >&2; exit 1; }
[ -s "$WIRELESS_OUT/base/kpp.ko" ] || { echo "ERROR: missing kpp module; run build_wireless_mainline_wsl.sh" >&2; exit 1; }
[ -s "$WIRELESS_OUT/base/ecc.ko" ] || { echo "ERROR: missing ecc module; run build_wireless_mainline_wsl.sh" >&2; exit 1; }
[ -s "$WIRELESS_OUT/base/ecdh_generic.ko" ] || { echo "ERROR: missing ecdh module; run build_wireless_mainline_wsl.sh" >&2; exit 1; }
[ -s "$WIRELESS_OUT/base/cmac.ko" ] || { echo "ERROR: missing cmac module; run build_wireless_mainline_wsl.sh" >&2; exit 1; }
[ -x "$WIRELESS_OUT/w132d-btattach" ] || { echo "ERROR: missing mainline Bluetooth helper; run build_wireless_mainline_wsl.sh" >&2; exit 1; }
[ -s "$WIRELESS_PORT_REPO/rootfs/w132d-bluetooth.service" ] || { echo "ERROR: missing Bluetooth service template $WIRELESS_PORT_REPO" >&2; exit 1; }
[ "$(stat -c %s "$UBOOT_IMAGE")" -eq 4194304 ] || { echo 'ERROR: vendor U-Boot must be exactly 4 MiB' >&2; exit 1; }
command -v sgdisk >/dev/null || { echo 'ERROR: sgdisk is required' >&2; exit 1; }
command -v mkimage >/dev/null || { echo 'ERROR: mkimage is required' >&2; exit 1; }
command -v rsync >/dev/null || { echo 'ERROR: rsync is required' >&2; exit 1; }

mkdir -p "$OUT_DIR" "$OUT_WORK" /mnt/w132d-mainline-src /mnt/w132d-mainline-boot /mnt/w132d-mainline-root
rm -rf "$WIRELESS_STAGE"
mkdir -p "$WIRELESS_STAGE"

echo '=== extract private UWE5622 firmware from Android vendor image ==='
for firmware in wcnmodem.bin wifi_board_config.ini; do
	debugfs -R "dump -p etc/firmware/${firmware} $WIRELESS_STAGE/${firmware}" \
		"$VENDOR_ANDROID_IMAGE" >/dev/null
done
for firmware in bt_configure_pskey.ini bt_configure_rf.ini; do
	debugfs -R "dump -p etc/${firmware} $WIRELESS_STAGE/${firmware}" \
		"$VENDOR_ANDROID_IMAGE" >/dev/null
done
for firmware in wcnmodem.bin wifi_board_config.ini bt_configure_pskey.ini bt_configure_rf.ini; do
	[ -s "$WIRELESS_STAGE/$firmware" ] || { echo "ERROR: firmware extraction failed: $firmware" >&2; exit 1; }
done
OUT_IMG="$OUT_WORK/w132d-mainline-armbian.img"
LOOP_SRC=
LOOP_OUT=

cleanup() {
	set +e
	restore_chroot_overrides
	mountpoint -q /mnt/w132d-mainline-root && umount /mnt/w132d-mainline-root
	mountpoint -q /mnt/w132d-mainline-boot && umount /mnt/w132d-mainline-boot
	mountpoint -q /mnt/w132d-mainline-src && umount /mnt/w132d-mainline-src
	[ -n "$LOOP_OUT" ] && losetup -d "$LOOP_OUT" 2>/dev/null
	[ -n "$LOOP_SRC" ] && losetup -d "$LOOP_SRC" 2>/dev/null
}

restore_chroot_overrides() {
	if mountpoint -q /mnt/w132d-mainline-root; then
		if [ "$HAD_CHROOT_POLICY" -eq 1 ]; then
			rm -f /mnt/w132d-mainline-root/usr/sbin/policy-rc.d
			cp -a "$CHROOT_POLICY_BACKUP" /mnt/w132d-mainline-root/usr/sbin/policy-rc.d
		else
			rm -f /mnt/w132d-mainline-root/usr/sbin/policy-rc.d
		fi
		if [ "$HAD_CHROOT_RESOLV" -eq 1 ]; then
			rm -f /mnt/w132d-mainline-root/etc/resolv.conf
			cp -a "$CHROOT_RESOLV_BACKUP" /mnt/w132d-mainline-root/etc/resolv.conf
		else
			rm -f /mnt/w132d-mainline-root/etc/resolv.conf
		fi
	fi
	rm -f "$CHROOT_POLICY_BACKUP" "$CHROOT_RESOLV_BACKUP"
	HAD_CHROOT_POLICY=0
	HAD_CHROOT_RESOLV=0
}
trap cleanup EXIT

rm -f "$OUT_IMG"
if [ -s "$BASE_IMAGE" ]; then
	# Preserve the disk GUID and GPT metadata from a known RKDevTool-compatible
	# image. Only the filesystem payloads are replaced below.
	echo "=== clone compatible image container: $BASE_IMAGE ==="
	cp -f "$BASE_IMAGE" "$OUT_IMG"
	[ "$(stat -c %s "$OUT_IMG")" -eq $((IMAGE_SIZE_MIB * 1024 * 1024)) ] || {
		echo 'ERROR: compatible base image has unexpected size' >&2
		exit 1
	}
else
	truncate -s "${IMAGE_SIZE_MIB}M" "$OUT_IMG"
	sgdisk --zap-all "$OUT_IMG" >/dev/null
	sgdisk -n 1:${UBOOT_START}:$((UBOOT_START + 8191)) -c 1:uboot -t 1:8300 "$OUT_IMG" >/dev/null
	sgdisk -n 2:${BOOT_START}:${BOOT_END} -c 2:bootfs -t 2:0700 "$OUT_IMG" >/dev/null
	sgdisk -A 2:set:2 "$OUT_IMG" >/dev/null
	sgdisk -n 3:${ROOT_START}:0 -c 3:rootfs -t 3:8300 "$OUT_IMG" >/dev/null
fi

dd if="$HEAD_BIN" of="$OUT_IMG" bs=512 skip=64 seek=64 count=16320 conv=notrunc status=none
dd if="$UBOOT_IMAGE" of="$OUT_IMG" bs=512 seek="$UBOOT_START" count=8192 conv=notrunc status=none
LOOP_SRC=$(losetup -fP --show "$SOURCE_IMAGE")
LOOP_OUT=$(losetup -fP --show "$OUT_IMG")
for n in 1 2 3; do
	udevadm settle || true
	[ -b "${LOOP_SRC}p1" ] && [ -b "${LOOP_OUT}p2" ] && [ -b "${LOOP_OUT}p3" ] && break
	sleep 1
done
[ -b "${LOOP_SRC}p${SOURCE_ROOT_PART}" ] || { echo "ERROR: source rootfs partition did not appear: p${SOURCE_ROOT_PART}" >&2; exit 1; }
[ -b "${LOOP_OUT}p2" ] || { echo 'ERROR: output boot partition did not appear' >&2; exit 1; }
[ -b "${LOOP_OUT}p3" ] || { echo 'ERROR: output rootfs partition did not appear' >&2; exit 1; }

mkfs.vfat -F 32 -n BOOTFS "${LOOP_OUT}p2" >/dev/null
mkfs.ext4 -F -L ROOTFS "${LOOP_OUT}p3" >/dev/null
tune2fs -U "$ROOT_UUID" "${LOOP_OUT}p3" >/dev/null
mount -o ro "${LOOP_SRC}p${SOURCE_ROOT_PART}" /mnt/w132d-mainline-src
mount "${LOOP_OUT}p2" /mnt/w132d-mainline-boot
mount "${LOOP_OUT}p3" /mnt/w132d-mainline-root

echo '=== copy Armbian/Debian rootfs ==='
rsync -aHAX --numeric-ids --exclude=/boot/ /mnt/w132d-mainline-src/ /mnt/w132d-mainline-root/
mkdir -p /mnt/w132d-mainline-root/boot

echo '=== install mainline boot files ==='
install -m 0644 "$MAINLINE_DIR/out/Image" /mnt/w132d-mainline-boot/Image
install -d /mnt/w132d-mainline-boot/rockchip /mnt/w132d-mainline-boot/extlinux
install -m 0644 "$MAINLINE_DIR/out/rk3528-w132d.dtb" /mnt/w132d-mainline-boot/rockchip/rk3528-w132d.dtb
install -m 0644 "$REPO_ROOT/boot/extlinux.mainline.conf" /mnt/w132d-mainline-boot/extlinux/extlinux.conf
install -m 0644 "$REPO_ROOT/boot/armbianEnv.mainline.txt" /mnt/w132d-mainline-boot/armbianEnv.txt
sed -e "s|@ROOT_DEVICE@|${ROOT_DEVICE}|g" -e "s|@VIDEO_ARGS@|${VIDEO_ARGS}|g" \
	"$REPO_ROOT/boot/boot.mainline.cmd" > "$OUT_WORK/boot.mainline.cmd"
sed -e "s|@ROOT_DEVICE@|${ROOT_DEVICE}|g" -e "s|@VIDEO_ARGS@|${VIDEO_ARGS}|g" \
	"$REPO_ROOT/boot/extlinux.mainline.conf" > "$OUT_WORK/extlinux.mainline.conf"
sed -e "s|@ROOT_DEVICE@|${ROOT_DEVICE}|g" -e "s|@VIDEO_ARGS@|${VIDEO_ARGS}|g" \
	"$REPO_ROOT/boot/armbianEnv.mainline.txt" > "$OUT_WORK/armbianEnv.mainline.txt"
install -m 0644 "$OUT_WORK/extlinux.mainline.conf" /mnt/w132d-mainline-boot/extlinux/extlinux.conf
install -m 0644 "$OUT_WORK/armbianEnv.mainline.txt" /mnt/w132d-mainline-boot/armbianEnv.txt
mkimage -C none -A arm64 -T script -d "$OUT_WORK/boot.mainline.cmd" /mnt/w132d-mainline-boot/boot.scr >/dev/null

echo '=== configure rootfs for mainline serial bring-up ==='
cat > /mnt/w132d-mainline-root/etc/fstab <<EOF
UUID=${ROOT_UUID} / ext4 defaults,noatime,errors=remount-ro 0 1
tmpfs /tmp tmpfs defaults,nosuid 0 0
EOF
mkdir -p /mnt/w132d-mainline-root/etc/systemd/system/getty.target.wants
ln -sf /lib/systemd/system/serial-getty@.service \
	/mnt/w132d-mainline-root/etc/systemd/system/getty.target.wants/serial-getty@ttyS0.service
ln -sf /lib/systemd/system/getty@.service \
	/mnt/w132d-mainline-root/etc/systemd/system/getty.target.wants/getty@tty1.service
printf 'mainline-v7.1-w132d\n' > /mnt/w132d-mainline-root/etc/w132d-mainline-release

echo '=== install mainline UWE5622 WiFi/Bluetooth support ==='
KERNEL_RELEASE=$(make -s -C "$BUILD_ROOT/linux-v7.1" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- LOCALVERSION= kernelrelease)
MODULE_DIR="/mnt/w132d-mainline-root/lib/modules/${KERNEL_RELEASE}/updates/uwe5622"
rm -rf "/mnt/w132d-mainline-root/lib/modules/${KERNEL_RELEASE}"
install -d "$MODULE_DIR" \
	/mnt/w132d-mainline-root/lib/firmware/uwe5622 \
	/mnt/w132d-mainline-root/etc/w132d/bluetooth \
	/mnt/w132d-mainline-root/etc/modules-load.d \
	/mnt/w132d-mainline-root/usr/local/sbin \
	/mnt/w132d-mainline-root/etc/systemd/system/multi-user.target.wants
install -m 0644 "$WIRELESS_OUT/uwe5622_bsp_sdio.ko" "$MODULE_DIR/"
install -m 0644 "$WIRELESS_OUT/sprdwl_ng.ko" "$MODULE_DIR/"
install -m 0644 "$WIRELESS_OUT/sprdbt_tty.ko" "$MODULE_DIR/"
install -m 0644 "$WIRELESS_OUT/base/"*.ko "$MODULE_DIR/"
install -m 0755 "$WIRELESS_OUT/w132d-btattach" /mnt/w132d-mainline-root/usr/local/sbin/w132d-btattach
install -m 0644 "$WIRELESS_STAGE/wcnmodem.bin" /mnt/w132d-mainline-root/lib/firmware/uwe5622/wcnmodem.bin
install -m 0644 "$WIRELESS_STAGE/wifi_board_config.ini" /mnt/w132d-mainline-root/lib/firmware/uwe5622/wifi_board_config.ini
install -m 0644 "$WIRELESS_STAGE/wifi_board_config.ini" /mnt/w132d-mainline-root/lib/firmware/uwe5622/wifi_56630001_3ant.ini
install -m 0644 "$WIRELESS_STAGE/bt_configure_pskey.ini" /mnt/w132d-mainline-root/etc/w132d/bluetooth/bt_configure_pskey.ini
install -m 0644 "$WIRELESS_STAGE/bt_configure_rf.ini" /mnt/w132d-mainline-root/etc/w132d/bluetooth/bt_configure_rf.ini
install -m 0644 "$WIRELESS_PORT_REPO/rootfs/w132d-bluetooth.service" /mnt/w132d-mainline-root/etc/systemd/system/w132d-bluetooth.service
install -m 0644 "$REPO_ROOT/rootfs/w132d-wireless.service" /mnt/w132d-mainline-root/etc/systemd/system/w132d-wireless.service
cat > /mnt/w132d-mainline-root/etc/modules-load.d/w132d-uwe5622.conf <<'EOF'
# The ordered systemd unit below performs dependency-aware loading and logs
# each failure. Keep this file as a fallback for systems without that unit.
kpp
ecc
ecdh_generic
cmac
rfkill
bluetooth
hci_uart
cfg80211
EOF
if command -v depmod >/dev/null 2>&1; then
	depmod -b /mnt/w132d-mainline-root "$KERNEL_RELEASE" || true
fi
ln -sf /etc/systemd/system/w132d-bluetooth.service \
	/mnt/w132d-mainline-root/etc/systemd/system/multi-user.target.wants/w132d-bluetooth.service
ln -sf /etc/systemd/system/w132d-wireless.service \
	/mnt/w132d-mainline-root/etc/systemd/system/multi-user.target.wants/w132d-wireless.service
sync

mountpoint -q /mnt/w132d-mainline-boot && umount /mnt/w132d-mainline-boot
mountpoint -q /mnt/w132d-mainline-src && umount /mnt/w132d-mainline-src
mountpoint -q /mnt/w132d-mainline-root && umount /mnt/w132d-mainline-root
losetup -d "$LOOP_OUT"; LOOP_OUT=
if [ -n "$LOOP_SRC" ]; then
	losetup -d "$LOOP_SRC"
	LOOP_SRC=
fi

STAMP=$(TZ=Asia/Shanghai date +%Y%m%d-%H%M%S)
if [ -n "$IMAGE_VARIANT" ]; then
	case "$IMAGE_VARIANT" in
		*[!a-zA-Z0-9._-]*) echo 'ERROR: invalid W132D_IMAGE_VARIANT' >&2; exit 1 ;;
	esac
	PUBLISH_IMG="$OUT_DIR/w132d-mainline-armbian-${IMAGE_VARIANT}-${STAMP}-UTC+8.img"
else
	PUBLISH_IMG="$OUT_DIR/w132d-mainline-armbian-${STAMP}-UTC+8.img"
fi
cp -f "$OUT_IMG" "$PUBLISH_IMG"
(cd "$OUT_DIR" && sha256sum "$(basename "$PUBLISH_IMG")" > "$(basename "$PUBLISH_IMG").sha256")
if [ "${W132D_KEEP_ALL_IMAGES:-1}" != 1 ]; then
	mapfile -t PUBLISHED_IMAGES < <(ls -1t "$OUT_DIR"/w132d-mainline-armbian-*.img 2>/dev/null || true)
	for old_image in "${PUBLISHED_IMAGES[@]:2}"; do
		rm -f "$old_image" "${old_image}.sha256"
	done
	# Remove hash sidecars left behind when an image was manually removed.
	for hash_file in "$OUT_DIR"/w132d-mainline-armbian-*.img.sha256; do
		[ -e "$hash_file" ] || continue
		[ -e "${hash_file%.sha256}" ] || rm -f "$hash_file"
	done
fi
echo "MAINLINE_IMAGE_DONE $PUBLISH_IMG"
