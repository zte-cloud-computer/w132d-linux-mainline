# SPDX-License-Identifier: MIT
# 引导链：主线 U-Boot v2026.07 generic-rk3528 + 本板 DT（userpatches/u-boot/v2026.07/）+ rkbin DDR/BL31 blob，
# 做法照 radxa-e24c.conf。板级配置 enable_extension 启用；提交 armbian/build 时并入 config/boards/w132d.csc。
function extension_prepare_config__w132d_uboot() {
	declare -g BOOTCONFIG="generic-rk3528_defconfig"
	declare -g BOOT_SCENARIO="spl-blobs"
}

function post_family_config__w132d_use_mainline_uboot() {
	display_alert "W132D" "主线 U-Boot v2026.07（实验：替代厂商引导链）" "info"
	declare -g BOOTDELAY=1
	# blob 版本必须在 post_family_config 里设：家族配置写的是 ${DDR_BLOB:-默认}，而 extension_prepare_config
	# 跑得更晚，放那里只会得到默认的 v1.09 / v1.17。与 radxa-e24c 同版。
	declare -g DDR_BLOB="rk35/rk3528_ddr_1056MHz_v1.13.bin"
	declare -g BL31_BLOB="rk35/rk3528_bl31_v1.21.elf"
	declare -g BOOTSOURCE="https://github.com/u-boot/u-boot.git"
	declare -g BOOTBRANCH="tag:v2026.07"
	declare -g BOOTPATCHDIR="v2026.07"
	declare -g BOOTDIR="u-boot-w132d"
	declare -g UBOOT_TARGET_MAP="BL31=${RKBIN_DIR}/${BL31_BLOB} ROCKCHIP_TPL=${RKBIN_DIR}/${DDR_BLOB};;u-boot-rockchip.bin idbloader.img u-boot.itb"
	# binman 已产出 idbloader / u-boot.itb，rockchip64_common 的后处理不要。
	unset uboot_custom_postprocess write_uboot_platform write_uboot_platform_mtd
	# 不能拿整块 u-boot-rockchip.bin 从扇区 64 一路 dd：它中间的 0xff 填充会抹掉扇区 7168 的
	# vendor storage（MAC/SN）和 8192 的 RKSS 安全存储。两段分开写，中间永远不碰。
	function write_uboot_platform() {
		dd "if=$1/idbloader.img" "of=$2" bs=512 seek=64 conv=notrunc status=none
		dd "if=$1/u-boot.itb" "of=$2" bs=512 seek=16384 conv=notrunc status=none
	}
}

function post_config_uboot_target__w132d_uboot_configs() {
	display_alert "W132D" "u-boot: 本板 DT + SARADC 下载键（针孔）" "info"
	run_host_command_logged scripts/config --set-str CONFIG_DEFAULT_DEVICE_TREE "rk3528-w132d"
	# OF_LIST 在 defconfig 展开时已定死为 generic，不跟着 DEFAULT_DEVICE_TREE 变，binman 组 FIT 用的是它。
	run_host_command_logged scripts/config --set-str CONFIG_OF_LIST "rk3528-w132d"
	run_host_command_logged scripts/config --set-str CONFIG_DEFAULT_FDT_FILE "rockchip/rk3528-w132d.dtb"
	# HDMI 旁的针孔是 SARADC ch1 下载键，rockchip_dnl_key_pressed() 只在 ADC 开着时编进去；
	# saradc 驱动要 vref-supply，本板 DT 给的是固定 1.8 V 稳压器节点。
	run_host_command_logged scripts/config --enable CONFIG_ADC
	run_host_command_logged scripts/config --enable CONFIG_SARADC_ROCKCHIP
	run_host_command_logged scripts/config --enable CONFIG_DM_REGULATOR
	run_host_command_logged scripts/config --enable CONFIG_DM_REGULATOR_FIXED
	# MAC 由 misc_init_r 按 OTP cpuid 派生（每台固定、不等于机身标签），起内核时按 ethernet0 别名注入 DT，
	# 不开 NET 也能注入。不要开 ENV_IS_IN_MMC / CONFIG_NET：eMMC 里一份 CRC 正确但只含 ethaddr 的 env
	# 会顶掉编进二进制的默认环境（没有 bootcmd/boot_targets），设备停在 U-Boot 提示符。
	#
	# PREBOOT 写 GRF 0xff370220 = 0x2b4d1f7a：rkbin BL31 的 uartdbg 从定时器第 30 次 tick 起检查这个握手
	# cookie（厂商内核的 fiq_debugger 负责写，主线没有），没有就往 console 喷训练帧并改 UART 分频，整机挂死。
	# BL31 定时器每次复位从头计、U-Boot 每次复位都重跑 preboot，所以写一次覆盖冷启动和重启。
	run_host_command_logged scripts/config --enable CONFIG_USE_PREBOOT
	# run_host_command_logged 会把命令串重新求值，带空格的值要"双引号套单引号"。
	run_host_command_logged scripts/config --set-str CONFIG_PREBOOT "'mw.l 0xff370220 0x2b4d1f7a'"
}
