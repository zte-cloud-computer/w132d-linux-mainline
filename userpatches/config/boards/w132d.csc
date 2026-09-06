# SPDX-License-Identifier: MIT
# ZTE Cloud Computer W132D（Rockchip RK3528）：主线内核 + 主线 U-Boot（rkbin DDR/BL31 blob）。
# 只用 Armbian 现成机制（rk35xx 家族、edge 分支、OFFSET/BOOTSIZE），便于原样提交给 armbian/build；
# 引导链钩子暂在 userpatches/extensions/w132d-uboot.sh，提交时并入本文件。
BOARD_NAME="ZTE Cloud Computer W132D"
BOARD_VENDOR="zte"
BOARDFAMILY="rk35xx"
BOARD_MAINTAINER=""
INTRODUCED="2026"
BOOT_SOC="rk3528"
KERNEL_TARGET="edge"

FULL_DESKTOP="no"
BOOT_FDT_FILE="rockchip/rk3528-w132d.dtb"

# overlay 里的 unit/脚本直接调 bluetoothd/btmgmt、ir-keytable、dbus-python+GLib，minimal 镜像不带，
# 缺了服务起不来且构建不报错。不用 bluetooth 元包（会拖进 obexd 等）。
PACKAGE_LIST_BOARD="bluez rfkill ir-keytable python3-dbus python3-gi"

# 调试串口是 UART0；rockchip64_common 对非 rk3576 默认 ttyS2，getty 会在不存在的串口上等 90 s。
SERIALCON="ttyS0"

# 主线 U-Boot bootstd 直接读 extlinux.conf，不依赖 boot.scr 的一堆环境变量。
# loglevel=7：盒子没串口，硬挂现场只有 console-ramoops 抓得到，等级低了零现场。
SRC_EXTLINUX="yes"
SRC_CMDLINE="rootwait rootfstype=ext4 console=ttyS0,115200 console=tty1 consoleblank=0 loglevel=7"

# 主线 U-Boot generic-rk3528 + rkbin blob；源、blob 版本、defconfig 改动、分两段写入见 w132d-uboot 扩展。
BOOTCONFIG="generic-rk3528_defconfig"
BOOT_SCENARIO="spl-blobs"
enable_extension "w132d-uboot"

# 分区几何复现现有镜像：p2@24576 扇区（OFFSET=12）、p3@1073152（BOOTSIZE=512）。
# 必须在 post_family_config 里设：rockchip64_common.inc 无条件 OFFSET=16，写在顶层会被覆盖且不报错。
function post_family_config__w132d_partition_geometry() {
	declare -g OFFSET=12
	declare -g BOOTSIZE=512
	declare -g BOOTFS_TYPE=fat
	declare -g IMAGE_PARTITION_TABLE="gpt"
	display_alert "W132D" "分区几何 OFFSET=${OFFSET} BOOTSIZE=${BOOTSIZE}（p2@24576 扇区）" "info"
}

# GPT 身份固定（镜像可复现、fstab/文档/救砖流程对得上），bootfs 打 LegacyBIOSBootable 属性
# （U-Boot 优先扫带 bootable 属性的分区）。这些值是镜像格式的一部分，不是逐机数据。
declare -g W132D_GPT_LABEL_ID="9460D758-5782-409D-ACD6-FE1596D204B3"
declare -g W132D_UUID_P1="A67F44A9-997D-4AA6-A64C-14CED9E9CFD6"
declare -g W132D_UUID_P2="6EA179DE-730E-4C8D-A85C-AE1CC68EF1D7"
declare -g W132D_UUID_P3="EF7972D4-085A-44C6-B550-DB6494052869"

function post_create_partitions__w132d_gpt_identity() {
	# 此时分区表还在 ${SDCARD}.raw 上，loop 设备尚未建立；按 ${LOOP} 判断会静默跳过。
	declare img="${SDCARD}.raw"
	[[ -f "${img}" ]] || { display_alert "W132D" "找不到 ${img}" "err"; return 1; }

	display_alert "W132D" "固定 GPT 身份并给 bootfs 打 LegacyBIOSBootable" "info"
	# Armbian 镜像只有 bootfs/rootfs 两个分区（u-boot.itb 在空档里不占分区），1/2 对应设备上的 p2/p3；
	# 设备形状的三分区 GPT 由 make-release.sh 生成。
	run_host_command_logged sgdisk \
		--disk-guid="${W132D_GPT_LABEL_ID}" \
		--partition-guid=1:"${W132D_UUID_P2}" \
		--partition-guid=2:"${W132D_UUID_P3}" \
		--attributes=1:set:2 \
		"${img}"
}

# Armbian 的按板 overlay（config/optional/boards/<board>/_packages/bsp-cli/）只在 ${SRC} 下找，
# 不认 ${USERPATCHES_PATH}，所以用钩子自己拷。提交 armbian/build 时把文件搬过去、删掉本钩子。
function post_family_tweaks_bsp__w132d_rootfs_overlay() {
	declare src="${USERPATCHES_PATH}/overlay/bsp-cli"
	[[ -d "${src}" ]] || { display_alert "W132D" "没有 overlay 目录，跳过" "wrn"; return 0; }
	# 排除 macOS 的 .DS_Store 与本机自测留下的 __pycache__，它们不该进包。
	display_alert "W132D" "铺 $(find "${src}" -type f -not -name .DS_Store -not -path '*/__pycache__/*' | wc -l) 个设备定制文件" "info"
	run_host_command_logged rsync -a --exclude=.DS_Store --exclude=__pycache__ "${src}/" "${destination}/"
}

# 归其他包所有的文件（bluez main.conf、cpufrequtils、asound.conf）不能进 bsp 包：dpkg 不允许两个包
# 拥有同一文件，整个镜像会装不上。能用 drop-in 的都改成了 drop-in，剩下的由本钩子直接写进 rootfs。
function post_family_tweaks__w132d_rootfs_edits() {
	declare src="${USERPATCHES_PATH}/overlay/rootfs-edits"
	[[ -d "${src}" ]] || return 0
	display_alert "W132D" "写入 $(find "${src}" -type f -not -name .DS_Store | wc -l) 个归属其他包的配置" "info"
	run_host_command_logged rsync -a --exclude=.DS_Store --exclude=__pycache__ "${src}/" "${SDCARD}/"
}

# WCN 固件（UWE5623 / Marlin3E）：armbian-firmware 自带的 wcnmodem-38222.bin 一关联就 CP2 断言，
# wcnmodem.bin 是 Marlin3 Lite 的；CoreELEC 公开仓库的 MARLIN3E_20A_W23.03.2 可用。
# 仓库不放二进制：构建时按钉住的提交下载、校 sha256（钉提交是因为上游 master 后来又换回了旧版）。
# 装到 wcnmodem-marlin3e.bin，DTS 的 unisoc,btwf-file-name 指它，与 armbian-firmware 的文件无归属冲突。
declare -g W132D_WCN_FW_COMMIT="82f0b4a1b842c3f41f49ec870b7ec8f5899a8895" # "wcnmodem.bin: update firmware from W22.47.2 to W23.03.2"
declare -g W132D_WCN_FW_SHA256="d84724b2e442a79d3999c630e5a13a418ef3f1b0a5ecafcf1ce031b3ede758cb"
declare -g W132D_WCN_FW_URL="https://raw.githubusercontent.com/CoreELEC/uwe5631-aml/${W132D_WCN_FW_COMMIT}/BSP/fw/wcnmodem.bin"
declare -g W132D_WCN_FW_DEST="lib/firmware/uwe5622/wcnmodem-marlin3e.bin"

function post_family_tweaks_bsp__w132d_wcn_firmware() {
	declare cache="${SRC}/cache/w132d"
	declare fw="${cache}/wcnmodem-marlin3e-${W132D_WCN_FW_COMMIT:0:12}.bin"
	mkdir -p "${cache}"
	if [[ ! -f "${fw}" ]] || ! echo "${W132D_WCN_FW_SHA256}  ${fw}" | sha256sum -c --status; then
		display_alert "W132D" "下载 WCN 固件（CoreELEC/uwe5631-aml @ ${W132D_WCN_FW_COMMIT:0:12}）" "info"
		run_host_command_logged curl -fsSL --retry 3 -o "${fw}.part" "${W132D_WCN_FW_URL}"
		echo "${W132D_WCN_FW_SHA256}  ${fw}.part" | sha256sum -c --status \
			|| exit_with_error "WCN 固件 sha256 不符（$(sha256sum "${fw}.part" | cut -c1-16)…）—— 下载坏了，或上游改写了历史"
		mv "${fw}.part" "${fw}"
	fi
	grep -qa "MARLIN3E_" "${fw}" || exit_with_error "${fw} 里没有 Marlin3E 版本串"
	mkdir -p "${destination}/$(dirname "${W132D_WCN_FW_DEST}")"
	install -m 0644 "${fw}" "${destination}/${W132D_WCN_FW_DEST}"
	display_alert "W132D" "WCN 固件：$(grep -ao 'MARLIN3E_[^[:cntrl:]]*' "${fw}" | head -1 | cut -c1-30)（CoreELEC，sha256 已校）+ 三天线 RF 配置" "info"
}

# bsp 包装进 rootfs 之后再确认一遍：固件是钉住的那份、RF 配置也在。
function post_family_tweaks__w132d_wcn_firmware() {
	echo "${W132D_WCN_FW_SHA256}  ${SDCARD}/${W132D_WCN_FW_DEST}" | sha256sum -c --status \
		|| exit_with_error "rootfs 里的 /${W132D_WCN_FW_DEST} 缺失或不是钉住的那份 —— DTS 的 btwf-file-name 指着它"
	[[ -f "${SDCARD}/lib/firmware/wifi_56630001_3ant.ini" ]] \
		|| exit_with_error "缺 /lib/firmware/wifi_56630001_3ant.ini（overlay 里的软链没铺进去？）"
}

# overlay 只放 unit 文件，不会自动 enable。蓝牙不需要用户态 attach：uwe5622 驱动直接注册 hci0。
function post_family_tweaks__w132d_enable_services() {
	display_alert "W132D" "使能板级服务" "info"
	chroot_sdcard systemctl enable \
		w132d-wireless.service \
		w132d-ble-remote.service w132d-ir-keymap.service w132d-led-status.service \
		w132d-soft-standby.service
	# ttyFIQ0 是 Rockchip vendor 内核的 FIQ debugger 串口，主线没有；Armbian 基底使能的 getty 会白等 90 s。
	chroot_sdcard systemctl mask serial-getty@ttyFIQ0.service "||" true
}

# 内核 config 只维护与 Armbian rockchip64-edge 的差异：
#   * SND_SOC_RK3528 / ES7202 由本仓库的 rk3528-audio 补丁引入，Armbian 的 config 里不可能有
#   * PSTORE_CONSOLE：盒子没串口，看门狗复位时 kmsg_dump 跑不到，只有 console-ramoops 抓得到现场；
#     PSTORE_RAM 内建是为了不漏开机头几秒（模块要等 udev）
#   * TTY_OVERY_SDIO_HCI：uwe5622 蓝牙直接注册 hci0（w132d 补丁 0005 加的选项）
#   * HDMI PHY 与 SAI 编成模块：出问题时不把开机挂死
# 钩子会被调两次（算产物哈希时没有 .config）：hashes 必须在 .config 存在性检查之前追加，
# 否则 Armbian 认为 config 没变、复用缓存的旧内核 deb。
function custom_kernel_config__w132d() {
	kernel_config_modifying_hashes+=("CONFIG_SND_SOC_RK3528=m" "CONFIG_SND_SOC_ES7202=m"
		"CONFIG_PSTORE_RAM=y" "CONFIG_PSTORE_CONSOLE=y" "CONFIG_PSTORE_PMSG=y"
		"CONFIG_TTY_OVERY_SDIO_HCI=y"
		"CONFIG_PHY_ROCKCHIP_INNO_HDMI=m" "CONFIG_SND_SOC_ROCKCHIP_SAI=m")
	[[ -f .config ]] || return 0
	display_alert "W132D" "打开 RK3528 acodec 与 ES7202（由 rk3528-audio 补丁引入）；pstore console 通路；uwe5622 蓝牙走 HCI 设备；HDMI PHY 与 SAI 编成模块" "info"
	run_kernel_make olddefconfig
	scripts/config --module CONFIG_SND_SOC_RK3528
	scripts/config --module CONFIG_SND_SOC_ES7202
	scripts/config --enable CONFIG_PSTORE_RAM
	scripts/config --enable CONFIG_PSTORE_CONSOLE
	scripts/config --enable CONFIG_PSTORE_PMSG
	scripts/config --enable CONFIG_TTY_OVERY_SDIO_HCI
	scripts/config --module CONFIG_PHY_ROCKCHIP_INNO_HDMI
	scripts/config --module CONFIG_SND_SOC_ROCKCHIP_SAI
}
