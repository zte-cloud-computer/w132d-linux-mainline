#!/bin/bash
# SPDX-License-Identifier: MIT
set -euo pipefail

root_mount=${GROW_ROOTFS_MOUNT:-/}
marker=${GROW_ROOTFS_MARKER:-/etc/.grow-rootfs-done}
rootpart=$(readlink -f "$(findmnt -n -o SOURCE "$root_mount")")
fstype=$(findmnt -n -o FSTYPE "$root_mount")
disk_name=$(lsblk -ndo PKNAME "$rootpart" | tr -d '[:space:]')
partnum=$(lsblk -ndo PARTN "$rootpart" | tr -d '[:space:]')

[ "$fstype" = ext4 ] || { echo "ERROR: root filesystem is $fstype, expected ext4"; exit 1; }
[ -b "$rootpart" ] || { echo "ERROR: root partition is not a block device: $rootpart"; exit 1; }
[ -n "$disk_name" ] && [ -n "$partnum" ] || {
  echo "ERROR: cannot resolve parent disk or partition number for $rootpart"
  exit 1
}
disk="/dev/$disk_name"
[ -b "$disk" ] || { echo "ERROR: parent disk is not a block device: $disk"; exit 1; }

echo "Growing $rootpart (partition $partnum on $disk)"
growpart "$disk" "$partnum"

# The mounted root partition is resized online. Wait until the kernel has
# accepted the new partition end before growing the ext4 filesystem.
disk_sectors=$(blockdev --getsz "$disk")
partition_start=$(cat "/sys/class/block/${rootpart##*/}/start")
partition_ready=false
for attempt in 1 2 3 4 5; do
  partprobe "$disk" || true
  udevadm settle || true
  partition_sectors=$(blockdev --getsz "$rootpart")
  trailing_sectors=$((disk_sectors - partition_start - partition_sectors))
  if [ "$trailing_sectors" -ge 0 ] && [ "$trailing_sectors" -lt 32768 ]; then
    partition_ready=true
    break
  fi
  echo "Waiting for updated partition size (attempt $attempt/5)"
  sleep 2
done
[ "$partition_ready" = true ] || {
  echo "ERROR: kernel did not accept the expanded partition table"
  exit 1
}

resize2fs "$rootpart"
touch "$marker"
echo "Root filesystem expansion complete"
