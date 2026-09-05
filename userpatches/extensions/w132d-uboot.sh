# SPDX-License-Identifier: MIT
# ## 引导链：主线 U-Boot（板级配置 enable_extension 默认启用）
#
# U-Boot v2026.07 的 generic-rk3528 + 本板 DT（userpatches/u-boot/v2026.07/），照抄
# radxa-e24c.conf 的做法（rk35xx 家族里唯一走主线 U-Boot 的板子）。
# 2026-09-04 分两步实机验证通过：先只换 P1（厂商 SPL 能加载主线 FIT），再换 idbloader。
# 针孔由 U-Boot proper 读 SARADC ch1：命中写 BOOT_BROM_DOWNLOAD 复位，BootROM 进 MaskROM。
# 「毕业」成 armbian/build 的 PR 时，这里的钩子并进 config/boards/w132d.csc。
#
# rkbin 的 DDR / BL31 blob 按原样使用（其 LICENSE 允许分发未修改的 blob，Armbian 所有
# RK 板子都这么做）。BL31 的 uartdbg 32 分钟问题由本扩展的 PREBOOT 写 cookie 绕过，对任何版本有效。
function extension_prepare_config__w132d_uboot() {
	declare -g BOOTCONFIG="generic-rk3528_defconfig"
	declare -g BOOT_SCENARIO="spl-blobs"
}

function post_family_config__w132d_use_mainline_uboot() {
	display_alert "W132D" "主线 U-Boot v2026.07（实验：替代厂商引导链）" "info"
	declare -g BOOTDELAY=1
	# blob 版本要在这里设：家族配置里是 ${DDR_BLOB:-默认}，而 extension_prepare_config
	# 跑在 post_family_config 之后，放那里就只剩默认的 v1.09 / v1.17（实测）。
	# 与 radxa-e24c 同版：DDR v1.13、BL31 v1.21（uartdbg 由 cookie 服务绕过，版本无关）。
	declare -g DDR_BLOB="rk35/rk3528_ddr_1056MHz_v1.13.bin"
	declare -g BL31_BLOB="rk35/rk3528_bl31_v1.21.elf"
	declare -g BOOTSOURCE="https://github.com/u-boot/u-boot.git"
	declare -g BOOTBRANCH="tag:v2026.07"
	declare -g BOOTPATCHDIR="v2026.07"
	declare -g BOOTDIR="u-boot-w132d"
	declare -g UBOOT_TARGET_MAP="BL31=${RKBIN_DIR}/${BL31_BLOB} ROCKCHIP_TPL=${RKBIN_DIR}/${DDR_BLOB};;u-boot-rockchip.bin idbloader.img u-boot.itb"
	# binman 已经把 idbloader / u-boot.itb 都做好了，rockchip64_common 那套后处理不要
	unset uboot_custom_postprocess write_uboot_platform write_uboot_platform_mtd
	# ⚠️ 绝不能拿整块 u-boot-rockchip.bin 从扇区 64 一路 dd（Armbian 对 e24c 就是这么写的）：
	# 它中间是 0xff 填充直到扇区 16384，会把 7168 的 vendor storage（MAC/SN）和 8192 的
	# RKSS 安全存储抹掉。两段分开写，中间那段永远不碰。
	function write_uboot_platform() {
		dd "if=$1/idbloader.img" "of=$2" bs=512 seek=64 conv=notrunc status=none
		dd "if=$1/u-boot.itb" "of=$2" bs=512 seek=16384 conv=notrunc status=none
	}
}

function post_config_uboot_target__w132d_uboot_configs() {
	display_alert "W132D" "u-boot: 本板 DT + SARADC 下载键（针孔）" "info"
	run_host_command_logged scripts/config --set-str CONFIG_DEFAULT_DEVICE_TREE "rk3528-w132d"
	# OF_LIST 在 defconfig 展开时已按 generic 定死，不跟着 DEFAULT_DEVICE_TREE 变；binman 组 FIT
	# 用的是它（"default-dt entry argument 'rk3528-w132d' not found in fdt list"，实测）
	run_host_command_logged scripts/config --set-str CONFIG_OF_LIST "rk3528-w132d"
	run_host_command_logged scripts/config --set-str CONFIG_DEFAULT_FDT_FILE "rockchip/rk3528-w132d.dtb"
	# generic-rk3528 默认没开 ADC；针孔是 SARADC ch1，rockchip_dnl_key_pressed() 只在 ADC 开着时编进去。
	# saradc 驱动要 vref-supply，本板 DT 给的是固定 1.8 V 稳压器节点。
	run_host_command_logged scripts/config --enable CONFIG_ADC
	run_host_command_logged scripts/config --enable CONFIG_SARADC_ROCKCHIP
	run_host_command_logged scripts/config --enable CONFIG_DM_REGULATOR
	run_host_command_logged scripts/config --enable CONFIG_DM_REGULATOR_FIXED
	# MAC：不写 env、不抢救出厂 MAC。misc_init_r 按 OTP cpuid 派生一个固定地址（主线 Rockchip
	# 板的标准做法），起内核时按 ethernet0 别名注入 DT 的 local-mac-address —— 不开 NET 也能注入。
	# 每台机器固定、不同机器不同，只是不等于机身标签上的出厂值（2026-09-05 用户拍板：不值得抢救）。
	#
	# ⛔ 别把 env 放进 eMMC（ENV_IS_IN_MMC），也别开 CONFIG_NET。2026-09-05 实测：往 env 扇区写一份
	# 只有 ethaddr 的 env，设备就停在 U-Boot 提示符 —— env/common.c 的 env_relocate() 只在存储的
	# env 无效时才载入编进二进制的默认环境，读到一份 CRC 正确的就直接用它，于是没有
	# bootcmd/boot_targets/bootdelay（CONFIG_ENV_APPEND 也救不了，它只是 H_NOCLEAR）。真要预置 env
	# 得用 u-boot-initial-env + mkenvimage 写完整的一份（OE 的做法），且每次刷 U-Boot 都得重写。
	#
	# BL31（rkbin 任何版本）的安全侧串口调试器 uartdbg：定时器第 30 次 tick 起检查 GRF 0xff370220
	# 里有没有握手 cookie 0x2b4d1f7a（厂商内核的 fiq_debugger 负责写，主线内核没有），没有就往
	# console 喷训练帧并改 UART 分频，整机挂死。BL31 的定时器每次复位从头计、U-Boot 每次复位都
	# 重跑 preboot，所以在这里写一次就覆盖冷启动和重启；OS_REG 便签寄存器进 Linux 后不会被动。
	# 2026-09-04 用 Linux 侧服务写同一个值实测 42 分钟无事，这里只是把写的位置前移到 U-Boot。
	# 先例：radxa-e24c 用 PREBOOT 点 LED。
	run_host_command_logged scripts/config --enable CONFIG_USE_PREBOOT
	# run_host_command_logged 会把命令串重新求值，带空格的值要"双引号套单引号"（e24c 同款写法）
	run_host_command_logged scripts/config --set-str CONFIG_PREBOOT "'mw.l 0xff370220 0x2b4d1f7a'"
}
