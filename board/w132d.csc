# SPDX-License-Identifier: MIT
# ZTE Cloud Computer W132D - Rockchip RK3528 quad core, 2GB DDR4, 32GB eMMC
BOARD_NAME="ZTE Cloud Computer W132D"
BOARD_VENDOR="zte"
BOARDFAMILY="rk35xx"
BOOTCONFIG="hinlink_rk3528_defconfig"
BOARD_MAINTAINER="w132d"
INTRODUCED="2026"
KERNEL_TARGET="vendor"
FULL_DESKTOP="no"
BOOT_LOGO="desktop"
BOOT_FDT_FILE="rockchip/rk3528-w132d.dtb"
BOOT_SCENARIO="spl-blobs"
IMAGE_PARTITION_TABLE="gpt"
BOOT_FS_TYPE="fat"

function post_family_config__w132d_add_growpart() {
	add_packages_to_image cloud-guest-utils
}
