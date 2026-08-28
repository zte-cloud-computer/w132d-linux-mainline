# SPDX-License-Identifier: MIT
# ZTE Cloud Computer W132D - experimental Linux v7.1.10 board metadata
BOARD_NAME="ZTE Cloud Computer W132D (mainline 7.1.10 experiment)"
BOARD_VENDOR="zte"
BOARDFAMILY="rk35xx-mainline"
BOARD_MAINTAINER="w132d"
INTRODUCED="2026"
KERNEL_TARGET="mainline"
FULL_DESKTOP="no"
BOOT_LOGO="desktop"
BOOT_FDT_FILE="rockchip/rk3528-w132d.dtb"
IMAGE_PARTITION_TABLE="gpt"
BOOT_FS_TYPE="fat"

function post_family_config__w132d_mainline_packages() {
	add_packages_to_image cloud-guest-utils
}
