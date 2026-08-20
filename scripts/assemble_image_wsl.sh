#!/bin/bash
# SPDX-License-Identifier: MIT
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
PRIVATE_DIR=${W132D_PRIVATE_DIR:?Set W132D_PRIVATE_DIR to a directory containing vendor-blobs/ and w132d-a9/}
PUBLISH_DIR=${W132D_PUBLISH_DIR:-$PRIVATE_DIR}
BUILD_ROOT=${W132D_BUILD_ROOT:-/root/w132d-build}
OUTBASE=${W132D_IMAGE_OUT_DIR:-$BUILD_ROOT/out}
OUTIMG=${OUTBASE}/w132d-armbian.img
ROOT_UUID=b921b045-1df0-41c3-af44-4c6f280d3fae
AB=${ARMBIAN_BUILD_DIR:-$BUILD_ROOT/armbian-build}
VBL=${W132D_VENDOR_BLOBS_DIR:-$PRIVATE_DIR/vendor-blobs}
ANDROID_BACKUP=${W132D_ANDROID_BACKUP_DIR:-$PRIVATE_DIR/w132d-a9}
VENDOR_UBOOT=${W132D_VENDOR_UBOOT:-$VBL/p2_uboot-wdt.img}
VENDOR_IMG=${W132D_VENDOR_IMAGE:-$ANDROID_BACKUP/15.vendor.img}
UWE_BUILD=$SCRIPT_DIR/build_uwe5622_wsl.sh
UWE_OUT=${W132D_COMPONENT_OUT_DIR:-$BUILD_ROOT/uwe5622-out}
VENDOR_STAGE=${W132D_VENDOR_STAGE_DIR:-$BUILD_ROOT/vendor-wireless}
MPP_STAGE=${W132D_MPP_OUT_DIR:-$BUILD_ROOT/mpp-out}
ALOOP=
OLOOP=
CHROOT_POLICY_BACKUP=$BUILD_ROOT/policy-rc.d.backup
CHROOT_RESOLV_BACKUP=$BUILD_ROOT/resolv.conf.backup
HAD_CHROOT_POLICY=0
HAD_CHROOT_RESOLV=0

[ "$(id -u)" -eq 0 ] || { echo 'ERROR: image assembly must run as root'; exit 1; }
mkdir -p "$PUBLISH_DIR"

restore_chroot_overrides() {
  if mountpoint -q /mnt/oroot; then
    if [ "$HAD_CHROOT_POLICY" -eq 1 ]; then
      rm -f /mnt/oroot/usr/sbin/policy-rc.d
      cp -a "$CHROOT_POLICY_BACKUP" /mnt/oroot/usr/sbin/policy-rc.d
    else
      rm -f /mnt/oroot/usr/sbin/policy-rc.d
    fi
    if [ "$HAD_CHROOT_RESOLV" -eq 1 ]; then
      rm -f /mnt/oroot/etc/resolv.conf
      cp -a "$CHROOT_RESOLV_BACKUP" /mnt/oroot/etc/resolv.conf
    else
      rm -f /mnt/oroot/etc/resolv.conf
    fi
  fi
  rm -f "$CHROOT_POLICY_BACKUP" "$CHROOT_RESOLV_BACKUP"
  HAD_CHROOT_POLICY=0
  HAD_CHROOT_RESOLV=0
}

cleanup() {
  set +e
  restore_chroot_overrides
  sync
  mountpoint -q /mnt/oboot && umount /mnt/oboot
  mountpoint -q /mnt/oroot && umount /mnt/oroot
  [ -n "$OLOOP" ] && losetup -d "$OLOOP" 2>/dev/null
  mountpoint -q /mnt/aroot && umount /mnt/aroot
  [ -n "$ALOOP" ] && losetup -d "$ALOOP" 2>/dev/null
}
trap cleanup EXIT

wait_for_block_devices() {
  local attempt
  local device
  local missing
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    udevadm settle || true
    missing=0
    for device in "$@"; do
      [ -b "$device" ] || missing=1
    done
    if [ "$missing" -eq 0 ]; then
      sleep 1
      udevadm settle || true
      missing=0
      for device in "$@"; do
        [ -b "$device" ] || missing=1
      done
      [ "$missing" -eq 0 ] && return 0
    fi
    sleep 1
  done
  echo "ERROR: block devices did not become stable: $*"
  return 1
}

mkdir -p "$OUTBASE"

echo '=== build UWE5622 WiFi/Bluetooth and Rockchip MPP ==='
[ -f "$UWE_BUILD" ] || { echo "ERROR: missing UWE5622 build script: $UWE_BUILD"; exit 1; }
if [ "${W132D_REUSE_COMPONENTS:-0}" = 1 ]; then
  echo 'reusing previously verified component build outputs'
else
  bash "$UWE_BUILD"
fi
test -s "$UWE_OUT/uwe5622_bsp_sdio.ko"
test -s "$UWE_OUT/sprdwl_ng.ko"
test -s "$UWE_OUT/sprdbt_tty.ko"
test -x "$UWE_OUT/w132d-btattach"
test -x "$MPP_STAGE/usr/local/bin/mpi_dec_test"
test -x "$MPP_STAGE/usr/local/bin/mpi_enc_test"
KREL=$(modinfo -F vermagic "$UWE_OUT/uwe5622_bsp_sdio.ko" | awk '{print $1}')
[ "$KREL" = "6.1.115-vendor-rk35xx" ] || {
  echo "ERROR: unexpected UWE5622 module kernel release: $KREL"
  exit 1
}

echo '=== extract verified vendor wireless firmware and board data ==='
[ -f "$VENDOR_IMG" ] || { echo "ERROR: Android vendor image not found: $VENDOR_IMG"; exit 1; }
rm -rf "$VENDOR_STAGE"
mkdir -p "$VENDOR_STAGE"
debugfs -R "dump -p etc/firmware/wcnmodem.bin $VENDOR_STAGE/wcnmodem.bin" "$VENDOR_IMG"
debugfs -R "dump -p etc/firmware/wifi_board_config.ini $VENDOR_STAGE/wifi_board_config.ini" "$VENDOR_IMG"
debugfs -R "dump -p etc/bt_configure_pskey.ini $VENDOR_STAGE/bt_configure_pskey.ini" "$VENDOR_IMG"
debugfs -R "dump -p etc/bt_configure_rf.ini $VENDOR_STAGE/bt_configure_rf.ini" "$VENDOR_IMG"
echo "ee9cb2cec5b680f4a91f13d737b30593f1216e05ac69c048a2877e51f8902b0e  $VENDOR_STAGE/wcnmodem.bin" | sha256sum -c -
echo "e63e257fea222f54f1e94960ac299b242358d48bfc6048a418aa2c36bb372932  $VENDOR_STAGE/wifi_board_config.ini" | sha256sum -c -
echo "f7f17f1c4eef85053dc57fd5b52d4bc02d4bf54a69e6867f6fdf9a0146db5140  $VENDOR_STAGE/bt_configure_pskey.ini" | sha256sum -c -
echo "41c1eab6f4777b730a057d437e5b940fa45c0aceac973044a88afbc738a08da7  $VENDOR_STAGE/bt_configure_rf.ini" | sha256sum -c -

echo '=== locate armbian artifacts ==='
AIMG=$(ls ${AB}/output/images/*W132d*.img 2>/dev/null | grep -v '\.xz$' | head -1)
if [ -z "$AIMG" ]; then
  XZIMG=$(ls ${AB}/output/images/*W132d*.img.xz 2>/dev/null | head -1)
  if [ -n "$XZIMG" ]; then
    echo "uncompressing $XZIMG"
    xz -dk "$XZIMG"
    AIMG=$(ls ${AB}/output/images/*W132d*.img 2>/dev/null | grep -v '\.xz$' | head -1)
  fi
fi
[ -n "$AIMG" ] || { echo 'ERROR: armbian image not found'; exit 1; }
echo "armbian image: $AIMG"

echo '=== mount armbian image (single rootfs partition) ==='
for mount_dir in /mnt/aroot /mnt/oboot /mnt/oroot; do
  if mountpoint -q "$mount_dir"; then
    echo "ERROR: $mount_dir is already mounted"
    exit 1
  fi
  mkdir -p "$mount_dir"
done
ALOOP=$(losetup -fP --show "$AIMG")
wait_for_block_devices "${ALOOP}p1"
mount "${ALOOP}p1" /mnt/aroot
ls -l /mnt/aroot/boot/ | sed -n '1,8p'

echo '=== locate kernel dtb ==='
DTB=$(find ${AB}/cache/sources/linux-kernel-worktree -path '*/arch/arm64/boot/dts/rockchip/rk3528-w132d.dtb' 2>/dev/null | head -1)
[ -n "$DTB" ] || DTB=$(ls /mnt/aroot/boot/dtb-*/rockchip/rk3528-w132d.dtb 2>/dev/null | head -1)
[ -n "$DTB" ] || { echo 'ERROR: w132d dtb not found'; exit 1; }
echo "dtb: $DTB"

echo '=== build custom image (vendor boot chain + bootfs + rootfs) ==='
rm -f "$OUTIMG" "${OUTIMG}.xz" "${OUTIMG}.xz.sha256"
truncate -s 2700M "$OUTIMG"
sgdisk --zap-all "$OUTIMG"
sgdisk -n 1:16384:24575 -c 1:uboot -t 1:8300 "$OUTIMG"
sgdisk -n 2:24576:1073151 -c 2:bootfs -t 2:0700 "$OUTIMG"
sgdisk -A 2:set:2 "$OUTIMG"
sgdisk -n 3:1073152:0 -c 3:rootfs -t 3:8300 "$OUTIMG"

echo '=== flash verified vendor boot chain ==='
[ -f "${VBL}/head.bin" ] || { echo "ERROR: vendor idbloader not found: ${VBL}/head.bin"; exit 1; }
[ -f "$VENDOR_UBOOT" ] || { echo "ERROR: watchdog-fixed U-Boot image not found: $VENDOR_UBOOT"; exit 1; }
[ "$(stat -c %s "$VENDOR_UBOOT")" -eq 4194304 ] || {
  echo 'ERROR: watchdog-fixed U-Boot image must be exactly 4 MiB'
  exit 1
}
dd if=${VBL}/head.bin of="$OUTIMG" bs=512 skip=64 seek=64 count=16320 conv=notrunc status=none
dd if="$VENDOR_UBOOT" of="$OUTIMG" bs=512 seek=16384 count=8192 conv=notrunc status=none

echo '=== create filesystems ==='
OLOOP=$(losetup -fP --show "$OUTIMG")
wait_for_block_devices "${OLOOP}p2" "${OLOOP}p3"
mkfs.vfat -F 32 -n BOOTFS "${OLOOP}p2"
mkfs.ext4 -F -L rootfs "${OLOOP}p3"
tune2fs -U "$ROOT_UUID" "${OLOOP}p3"
mount "${OLOOP}p2" /mnt/oboot
mount "${OLOOP}p3" /mnt/oroot

echo '=== populate bootfs ==='
cp -f /mnt/aroot/boot/Image /mnt/oboot/Image
cp -f /mnt/aroot/boot/uInitrd /mnt/oboot/uInitrd
mkdir -p /mnt/oboot/rockchip /mnt/oboot/extlinux
cp -f "$DTB" /mnt/oboot/rockchip/rk3528-w132d.dtb
cp -f "$REPO_ROOT/boot/extlinux.conf" /mnt/oboot/extlinux/extlinux.conf
cp -f "$REPO_ROOT/boot/boot.cmd" /mnt/oboot/boot.cmd
mkimage -C none -A arm64 -T script -d "$REPO_ROOT/boot/boot.cmd" /mnt/oboot/boot.scr

echo '=== populate rootfs ==='
mkdir -p /mnt/oroot/boot
rsync -aHAX --numeric-ids --exclude=/boot/ /mnt/aroot/ /mnt/oroot/

echo '=== install UWE5622 WiFi/Bluetooth modules and board data ==='
MODULE_DIR=/mnt/oroot/lib/modules/${KREL}/updates/uwe5622
[ -d "/mnt/oroot/lib/modules/${KREL}" ] || {
  echo "ERROR: target rootfs has no module tree for $KREL"
  exit 1
}
install -d "$MODULE_DIR" /mnt/oroot/lib/firmware/uwe5622 \
  /mnt/oroot/etc/w132d/bluetooth /mnt/oroot/etc/modules-load.d \
  /mnt/oroot/usr/local/sbin /mnt/oroot/etc/systemd/system/multi-user.target.wants
install -m 0644 "$UWE_OUT/uwe5622_bsp_sdio.ko" "$MODULE_DIR/"
install -m 0644 "$UWE_OUT/sprdwl_ng.ko" "$MODULE_DIR/"
install -m 0644 "$UWE_OUT/sprdbt_tty.ko" "$MODULE_DIR/"
install -m 0755 "$UWE_OUT/w132d-btattach" /mnt/oroot/usr/local/sbin/w132d-btattach
install -m 0644 "$VENDOR_STAGE/wcnmodem.bin" /mnt/oroot/lib/firmware/uwe5622/wcnmodem.bin
install -m 0644 "$VENDOR_STAGE/wifi_board_config.ini" /mnt/oroot/lib/firmware/uwe5622/wifi_board_config.ini
install -m 0644 "$VENDOR_STAGE/wifi_board_config.ini" /mnt/oroot/lib/firmware/uwe5622/wifi_56630001_3ant.ini
install -m 0644 "$VENDOR_STAGE/bt_configure_pskey.ini" /mnt/oroot/etc/w132d/bluetooth/bt_configure_pskey.ini
install -m 0644 "$VENDOR_STAGE/bt_configure_rf.ini" /mnt/oroot/etc/w132d/bluetooth/bt_configure_rf.ini
install -m 0644 "$REPO_ROOT/rootfs/w132d-bluetooth.service" /mnt/oroot/etc/systemd/system/w132d-bluetooth.service
cat > /mnt/oroot/etc/modules-load.d/w132d-uwe5622.conf <<'EOF'
uwe5622_bsp_sdio
sprdwl_ng
sprdbt_tty
hci_uart
EOF
depmod -b /mnt/oroot "$KREL"
ln -sf /etc/systemd/system/w132d-bluetooth.service \
  /mnt/oroot/etc/systemd/system/multi-user.target.wants/w132d-bluetooth.service

echo '=== install BlueZ and NetworkManager ==='
POLICY=/mnt/oroot/usr/sbin/policy-rc.d
RESOLV=/mnt/oroot/etc/resolv.conf
rm -f "$CHROOT_POLICY_BACKUP" "$CHROOT_RESOLV_BACKUP"
if [ -e "$POLICY" ] || [ -L "$POLICY" ]; then
  cp -a "$POLICY" "$CHROOT_POLICY_BACKUP"
  HAD_CHROOT_POLICY=1
fi
if [ -e "$RESOLV" ] || [ -L "$RESOLV" ]; then
  cp -a "$RESOLV" "$CHROOT_RESOLV_BACKUP"
  HAD_CHROOT_RESOLV=1
fi
cat > "$POLICY" <<'EOF'
#!/bin/sh
exit 101
EOF
chmod 0755 "$POLICY"
rm -f "$RESOLV"
cp -L /etc/resolv.conf "$RESOLV"
chroot /mnt/oroot /usr/bin/apt-get update
chroot /mnt/oroot /usr/bin/env DEBIAN_FRONTEND=noninteractive \
  /usr/bin/apt-get install -y --no-install-recommends bluez network-manager
chroot /mnt/oroot /usr/bin/apt-get clean
rm -rf /mnt/oroot/var/lib/apt/lists/*
restore_chroot_overrides
install -d /mnt/oroot/etc/systemd/system/bluetooth.target.wants
ln -sf /lib/systemd/system/bluetooth.service \
  /mnt/oroot/etc/systemd/system/bluetooth.target.wants/bluetooth.service
install -d /mnt/oroot/etc/systemd/system/multi-user.target.wants
ln -sf /lib/systemd/system/NetworkManager.service \
  /mnt/oroot/etc/systemd/system/multi-user.target.wants/NetworkManager.service
install -d /mnt/oroot/etc/NetworkManager/conf.d
cat > /mnt/oroot/etc/NetworkManager/conf.d/10-w132d-network-ownership.conf <<'EOF'
[keyfile]
# Netplan/systemd-networkd keeps the proven DHCP path for wired interfaces.
unmanaged-devices=interface-name:e*;interface-name:lan*;interface-name:wan*
EOF

echo '=== install Rockchip MPP userspace ==='
rsync -a "$MPP_STAGE/usr/local/" /mnt/oroot/usr/local/
ldconfig -r /mnt/oroot

echo '=== fix fstab ==='
BOOT_UUID=$(blkid -s UUID -o value ${OLOOP}p2)
cat > /mnt/oroot/etc/fstab <<EOF
UUID=${ROOT_UUID} / ext4 defaults,noatime,commit=600,errors=remount-ro 0 1
UUID=${BOOT_UUID} /boot vfat defaults 0 2
tmpfs /tmp tmpfs defaults,nosuid 0 0
EOF

echo '=== first-boot grow service ==='
if [ -e /mnt/oroot/lib/systemd/system/armbian-resize-filesystem.service ]; then
  mv /mnt/oroot/lib/systemd/system/armbian-resize-filesystem.service /mnt/oroot/lib/systemd/system/armbian-resize-filesystem.service.disabled
  rm -f /mnt/oroot/etc/systemd/system/multi-user.target.wants/armbian-resize-filesystem.service
fi
for tool in partprobe resize2fs; do
  command -v "$tool" >/dev/null
  [ -x "/mnt/oroot/usr/sbin/$tool" ] || {
    echo "ERROR: target rootfs is missing /usr/sbin/$tool"
    exit 1
  }
done
[ -x /mnt/oroot/usr/bin/growpart ] || {
  echo 'ERROR: target rootfs is missing /usr/bin/growpart (cloud-guest-utils)'
  exit 1
}
mkdir -p /mnt/oroot/etc/systemd/system/multi-user.target.wants
cat > /mnt/oroot/etc/systemd/system/grow-rootfs.service <<'EOF'
[Unit]
Description=Grow root partition to fill the disk
ConditionPathExists=!/etc/.grow-rootfs-done
ConditionPathIsReadWrite=/
After=local-fs.target systemd-remount-fs.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/grow-rootfs.sh
TimeoutStartSec=120
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
EOF
mkdir -p /mnt/oroot/usr/local/sbin
install -m 0755 "$REPO_ROOT/rootfs/grow-rootfs.sh" /mnt/oroot/usr/local/sbin/grow-rootfs.sh
ln -sf /etc/systemd/system/grow-rootfs.service /mnt/oroot/etc/systemd/system/multi-user.target.wants/grow-rootfs.service

echo '=== unmount + finalize ==='
umount /mnt/oboot /mnt/oroot
losetup -d "$OLOOP" || true
OLOOP=
umount /mnt/aroot || true
losetup -d "$ALOOP" || true
ALOOP=

echo '=== publish raw image with UTC+8 build timestamp ==='
STAMP=$(TZ=Asia/Shanghai date +%Y%m%d-%H%M%S)
PUBLISH_IMG=${PUBLISH_DIR}/w132d-armbian-${STAMP}-UTC+8.img
PUBLISH_SUM=${PUBLISH_IMG}.sha256
cp -f "$OUTIMG" "$PUBLISH_IMG"
(cd "$PUBLISH_DIR" && sha256sum "$(basename "$PUBLISH_IMG")" > "$(basename "$PUBLISH_SUM")")
RKUSB=$(find ${AB}/cache/sources/rkbin-tools -name 'rk3528_spl_loader*.bin' 2>/dev/null | head -1)
if [ -n "$RKUSB" ]; then cp -f "$RKUSB" "${PUBLISH_DIR}/rk3528_spl_loader_v1.07.104.bin"; fi
ls -l "$PUBLISH_IMG" "$PUBLISH_SUM" "${PUBLISH_DIR}"/rk3528_spl_loader* 2>/dev/null
echo 'ASSEMBLY_DONE'
