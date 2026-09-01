# SPDX-License-Identifier: MIT
# ZTE Cloud Computer W132D（Rockchip RK3528）——主线内核 + 保留厂商引导链。
#
# 这个文件的目标形态就是最终提给 armbian/build 的 `config/boards/w132d.csc`，
# 所以除了必要的注释以外，尽量只用 Armbian 官方已有的机制，不自造概念：
#   * BOARDFAMILY 用官方的 rk35xx（RK3528 已有 9 块板在用）
#   * KERNEL_TARGET 用官方的 edge（rk35xx.conf 里 source 了 rockchip64_common.inc，
#     edge 分支给出 LINUXFAMILY=rockchip64 / KERNEL_MAJOR_MINOR=7.2 /
#     补丁目录 rockchip64-7.2），不自建 family、不自建分支
#   * BOOTCONFIG=none 用官方机制跳过 u-boot（先例：aml-s9xx-box.tvb 等 8 块板）
#   * 分区几何用官方的 OFFSET / BOOTSIZE，不自造分区代码
#
# 放在 userpatches/ 下而不是 fork armbian/build：板级配置、内核补丁目录在官方代码
# 里都有 ${USERPATCHES_PATH} 查找分支（config-interactive.sh:69、
# main-config.sh:578、patching.sh:36-39），所以能跟着 Armbian 主线走。
# 「毕业」成 PR 时基本是把这些文件移进 armbian/build 的对应目录。
BOARD_NAME="ZTE Cloud Computer W132D"
BOARD_VENDOR="zte"
BOARDFAMILY="rk35xx"
BOARD_MAINTAINER=""
INTRODUCED="2026"
BOOT_SOC="rk3528"
KERNEL_TARGET="edge"

FULL_DESKTOP="no"
BOOT_FDT_FILE="rockchip/rk3528-w132d.dtb"

# ## 不编、不发 u-boot
#
# 设备出厂的 idbloader 与 U-Boot 就能引导本项目的 Linux（2026-08-28 实测），
# 而 sector 64–16383 里是逐机数据（DDR/SPL、vendor storage 的 SN/MAC/HDCP/IMEI）
# 和 RKSS —— 不可再生，碰了就变砖或丢身份。所以镜像里不放引导链，刷写也不写那段。
#
# 附带的好处：HDMI 旁那个针孔（实测是 SARADC ch1 下载键，不是硬复位）由厂商
# miniloader 读，按住上电进 Loader 模式 —— 这段我们永不覆盖，行为与原厂一致。
BOOTCONFIG="none"

# ## 分区布局：逐扇区复现现有镜像
#
# Armbian 的 prepare_partitions 用 `bootstart=$((OFFSET * 2048))`、
# `rootstart=$((bootstart + BOOTSIZE*2048))`。现有布局是
#   p2 起点 24576 扇区 = 12 MiB              -> OFFSET=12
#   p3 起点 1073152 扇区 = 524 MiB = 12+512  -> BOOTSIZE=512
#
# ⚠️ **必须在 post_family_config 钩子里设，不能写在文件顶层**：家族配置在板级配置
# 之后加载，而 rockchip64_common.inc 第 11 行无条件 `OFFSET=16`，写在顶层会被它
# 覆盖掉。实测 config-dump：顶层写 OFFSET=12，解析结果是 16 —— p2 会落到 32768
# 扇区而不是 24576，整个布局错位，而且**不会有任何报错**。
function post_family_config__w132d_partition_geometry() {
	declare -g OFFSET=12
	declare -g BOOTSIZE=512
	declare -g BOOTFS_TYPE=fat
	declare -g IMAGE_PARTITION_TABLE="gpt"
	display_alert "W132D" "分区几何 OFFSET=${OFFSET} BOOTSIZE=${BOOTSIZE}（p2@24576 扇区）" "info"
}

# ⚠️ 还差两样必须靠 hook 补：固定的 GPT label-id / 三个分区 UUID，以及 p2 的
# LegacyBIOSBootable 属性 —— 厂商 U-Boot 的 distro boot 靠它扫到 boot.scr，
# **缺了不启动**。等实际出镜像那一步再填 pre_prepare_partitions。

# ## 内核 config：只补两个符号
#
# Armbian 的 linux-rockchip64-edge.config 已经带了本板需要的绝大部分 —— IR 解码器
# 与 LIRC/RC_CORE、UHID（BLE 遥控走 uhid 桥）、NETFILTER_XTABLES_LEGACY/NF_TABLES、
# DRM_LIMA、ROCKCHIP_IOMMU、VIDEO_ROCKCHIP_VDEC、PSTORE_RAM、ROCKCHIP_THERMAL、
# MMC_SDHCI_OF_DWCMSHC、ROCKCHIP_PDM/SAI 全都在。
#
# 缺的只有音频那两个，**因为这两个 Kconfig 符号本来就是我们的 rk3528-audio 补丁
# 引入的** —— 补丁没打进去时它们根本不存在，所以不可能出现在 Armbian 的 config 里。
#
# 用 custom_kernel_config 而不是自带一整份 .config：那样就不用跟着 Armbian 每次
# 更新 config 去同步一万多行，只维护这两行差异。
function custom_kernel_config__w132d_audio() {
	[[ -f .config ]] || return 0
	display_alert "W132D" "打开 RK3528 acodec 与 ES7202（由 rk3528-audio 补丁引入）" "info"
	kernel_config_modifying_hashes+=("CONFIG_SND_SOC_RK3528=m" "CONFIG_SND_SOC_ES7202=m")
	run_kernel_make olddefconfig
	scripts/config --module CONFIG_SND_SOC_RK3528
	scripts/config --module CONFIG_SND_SOC_ES7202
}
