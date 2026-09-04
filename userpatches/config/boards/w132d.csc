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

# ## 板级服务的运行时依赖
#
# minimal 镜像里没有 bluez、ir-keytable、python3-dbus/gi。overlay 里的 unit 与脚本
# 直接调用 bluetoothd/btmgmt/hciconfig、ir-keytable、dbus-python + GLib，缺一个
# 对应的服务就起不来——而且构建时不会有任何报错（实测第一版镜像全缺）。
# 精确列出，不用 bluetooth 元包（它会拖进 bluez-obexd 等无关的东西）。
PACKAGE_LIST_BOARD="bluez rfkill ir-keytable python3-dbus python3-gi"

# ## 串口控制台：UART0 / ttyS0，不是 Armbian 默认的 ttyS2
#
# RK3528 的调试串口是 UART0（DTS 的 stdout-path 指向 serial0 = &uart0，115200），
# 本板也只使能了 uart0。rockchip64_common.inc 的晚期钩子对非 rk3576 的 SoC 一律
# 默认 SERIALCON=ttyS2，于是 getty 会挂在一个不存在的串口上（dev-ttyS2.device
# 等 90 秒超时才放弃）。板级配置先设好，那个钩子看到已设就不动（radxa-e24c 同法）。
SERIALCON="ttyS0"

# ## 引导：extlinux.conf，不用 boot.scr
#
# 厂商 U-Boot 走 distro boot，先找 extlinux/extlinux.conf 再找 boot.scr。迁移前的构建链
# 就是 extlinux（`kernel /Image`），实机验证过；Armbian 默认的 boot.scr 依赖 U-Boot 环境里
# 一堆变量（devtype/devnum/distro_bootpart/prefix/kernel_addr_r…）和 `test -e`、
# `env import`、`fdt` 等命令在厂商 2017.09 U-Boot 上的行为——两次刷写都没起来，
# 没有串口无从定位。extlinux 里全是写死的路径和参数，没有脚本逻辑，先用它。
# 先例：aml-s9xx-box.tvb（同样 BOOTCONFIG=none + 厂商 U-Boot + FAT bootfs）。
#
# SRC_EXTLINUX 下 armbianEnv.txt 会被删掉，内核参数只有这一处：root= 由 Armbian 加。
# 控制台 ttyS0/115200（DTS 的 stdout-path）。loglevel 先开到 7：盒子没串口，崩溃现场
# 全靠 console-ramoops，它记的是打到 console 的东西，等级低了硬挂时零现场。
SRC_EXTLINUX="yes"
SRC_CMDLINE="rootwait rootfstype=ext4 console=ttyS0,115200 console=tty1 consoleblank=0 loglevel=7"

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

# ## GPT 身份与 p2 的 LegacyBIOSBootable
#
# Armbian 的 prepare_partitions 会自己生成随机的 label-id 与分区 UUID，且不设任何
# 分区属性。两处都得改回来：
#
#   * **LegacyBIOSBootable 缺了设备起不来。** 厂商 U-Boot 走 distro boot，靠扫
#     带这个属性的分区去找 boot.scr。这是实测值 —— 从设备 `sfdisk -d` 读回来的
#     p2 就带着 `attrs="LegacyBIOSBootable"`。
#   * **固定 UUID** 让镜像可复现，也让 fstab / 文档 / 救砖流程始终对得上。
#
# 这些值不是逐机数据，是镜像格式的一部分（每台刷本镜像的设备都拿到同一组），
# 和 SN/MAC/HDCP 那类不可再生的东西是两回事。
declare -g W132D_GPT_LABEL_ID="9460D758-5782-409D-ACD6-FE1596D204B3"
declare -g W132D_UUID_P1="A67F44A9-997D-4AA6-A64C-14CED9E9CFD6"
declare -g W132D_UUID_P2="6EA179DE-730E-4C8D-A85C-AE1CC68EF1D7"
declare -g W132D_UUID_P3="EF7972D4-085A-44C6-B550-DB6494052869"

function post_create_partitions__w132d_gpt_identity() {
	# ⚠️ 这个钩子触发时**分区表还在 ${SDCARD}.raw 这个文件上，loop 设备尚未建立**
	# （partitioning.sh:268 紧跟 sfdisk 之后，loop setup 在其后）。
	# 早先这里写的是 `[[ -b "${LOOP}" ]] || return 0`，于是每次都静默返回、
	# 什么都没做 —— 镜像里 GPT 是随机 id、p2 没有 LegacyBIOSBootable，
	# 而构建日志里一句话都没有。
	declare img="${SDCARD}.raw"
	[[ -f "${img}" ]] || { display_alert "W132D" "找不到 ${img}" "err"; return 1; }

	display_alert "W132D" "固定 GPT 身份并给 bootfs 打 LegacyBIOSBootable" "info"
	# BOOTCONFIG=none 下 Armbian 只建两个分区（bootfs、rootfs），没有厂商 uboot 那个，
	# 所以这里的 1/2 对应设备上的 p2/p3。补 p1 的事见下面的 w132d_declare_uboot_part。
	run_host_command_logged sgdisk \
		--disk-guid="${W132D_GPT_LABEL_ID}" \
		--partition-guid=1:"${W132D_UUID_P2}" \
		--partition-guid=2:"${W132D_UUID_P3}" \
		--attributes=1:set:2 \
		"${img}"
}

# ## rootfs 定制文件
#
# Armbian 的按板 overlay 目录（config/optional/boards/<board>/_packages/bsp-cli/）
# 查找用的是 `${SRC}` 而**不是** `${USERPATCHES_PATH}`（utils-bsp.sh:22），所以
# userpatches 里放了也不会被收。用钩子自己拷 —— radxa-e20c.csc 写 armbian-leds.conf
# 用的也是这一类钩子。
#
# 「毕业」成 armbian/build 的 PR 时，这些文件直接搬进
# config/optional/boards/w132d/_packages/bsp-cli/，这个钩子随之删掉。
function post_family_tweaks_bsp__w132d_rootfs_overlay() {
	declare src="${USERPATCHES_PATH}/overlay/bsp-cli"
	[[ -d "${src}" ]] || { display_alert "W132D" "没有 overlay 目录，跳过" "wrn"; return 0; }
	display_alert "W132D" "铺 $(find "${src}" -type f | wc -l) 个设备定制文件" "info"
	run_host_command_logged cp -a "${src}/." "${destination}/"
}

# ## 归别的包所有的配置文件不能进 bsp 包
#
# dpkg 不允许两个包拥有同一个文件。实测：/etc/systemd/pstore.conf 归 systemd 包，
# 放进 bsp 包会让整个镜像装不上 ——
#   "trying to overwrite '/etc/systemd/pstore.conf', which is also in package systemd"
#
# 三种处理方式，按优先级：
#   1. 能用 drop-in 的就用 —— pstore.conf 已改成 pstore.conf.d/10-w132d-ramoops.conf
#   2. 本来就不需要的就删 —— rc_maps.cfg 归 ir-keytable 包，而我们的
#      w132d-ir-keymap.service 直接 `ir-keytable -w /etc/rc_keymaps/w132d.toml`，
#      根本不读它，那一行是冗余的
#   3. 必须整文件改、又没有 drop-in 机制的（bluez 的 main.conf、cpufrequtils 的
#      default 文件、asound.conf），改由本钩子直接写进 rootfs —— 不作为包内容，
#      dpkg 就不会有归属冲突
function post_family_tweaks__w132d_rootfs_edits() {
	declare src="${USERPATCHES_PATH}/overlay/rootfs-edits"
	[[ -d "${src}" ]] || return 0
	display_alert "W132D" "写入 $(find "${src}" -type f | wc -l) 个归属其他包的配置" "info"
	run_host_command_logged cp -a "${src}/." "${SDCARD}/"
}

# ## WCN 固件：用 Armbian 包自带的，不带私有输入
#
# 板上是 UWE5623 / Marlin3E。armbian-firmware 的 uwe5622/ 目录里有两份：
#   * wcnmodem.bin        —— SC2355 / Marlin3 Lite 的，**装错零件**，WiFi 起不来
#   * wcnmodem-38222.bin  —— WCNM 合并镜像，含 3EAB（Marlin3E AB，本板芯片 id 0x56630001）
#                            与 3LAB 两段，驱动按芯片 tag 选段。与 Allwinner Tina SDK 里的
#                            逐字节相同。2026-09-02 本板实测：100 次背靠背扫描 100/100、
#                            0 个 WCN 错误、BLE 遥控器重启自动重连、压力后不掉
# 所以 DTS 里 unisoc,btwf-file-name 指向 38222 —— 一行 DT，固件来自 Armbian 自己的包，
# 没有再分发问题，板级 PR 不受阻。这里只断言那份文件还在、还是 Marlin3E 的。
#
# 三天线 RF 配置 wifi_56630001_3ant.ini 是板级参数（收发链掩码、逐信道功率表、
# ant_cfg 与 Allwinner 通用版不同），随 overlay 装。驱动到 /lib/firmware 根目录找它
# （UNISOC_WIFI_CUS_CONFIG 没设），所以 overlay 里除了 uwe5622/ 下的文件还有根目录的
# 软链 —— 与 armbian-firmware 摆 wifi_2355b001_1ant.ini 的方式一致。
function post_family_tweaks__w132d_wcn_firmware() {
	declare fw="${SDCARD}/lib/firmware/uwe5622/wcnmodem-38222.bin"
	[[ -f "${fw}" ]] || exit_with_error "armbian-firmware 不再带 uwe5622/wcnmodem-38222.bin —— 本板 WiFi/蓝牙固件没了，DTS 的 btwf-file-name 指着它"
	grep -qa "MARLIN3E_" "${fw}" || exit_with_error "${fw} 里没有 Marlin3E 段 —— 文件变了？"
	[[ -f "${SDCARD}/lib/firmware/wifi_56630001_3ant.ini" ]] \
		|| exit_with_error "缺 /lib/firmware/wifi_56630001_3ant.ini（overlay 里的软链没铺进去？）"
	display_alert "W132D" "WCN 固件：Armbian 包自带的 wcnmodem-38222.bin（$(grep -ao 'MARLIN3E_[^[:cntrl:]]*' "${fw}" | head -1 | cut -c1-30)）+ 三天线 RF 配置" "info"
}

# 服务使能：overlay 只是把 unit 文件放进去，不会自动 enable。
# HDMI 相关的 unit 本版不带，所以不在列表里。
function post_family_tweaks__w132d_enable_services() {
	display_alert "W132D" "使能板级服务" "info"
	# ⚠️ 实验性：出厂 BL31 每约 32 分钟打死整机的绕过（往 GRF 写握手 cookie），
	# 尚未在未打补丁的 BL31 上实机验证。挂在 sysinit.target 下尽早跑。
	chroot_sdcard systemctl enable w132d-bl31-cookie.service
	# 出厂 MAC：厂商 U-Boot 没把 vendor storage 的 MAC 修进主线 DTB（首刷实测），
	# 由这个服务在 networkd 之前从 eMMC 读出来设上，否则每次重刷 MAC/IP 都变
	chroot_sdcard systemctl enable w132d-vendor-mac.service
	# 没有 w132d-bt-calib：它与 w132d-btattach 重复（两者都下发
	# 0xFCA0/0xFCA2/0xFCA1），而且它要读 /lib/firmware/uwe5622/bt_configure_*.ini
	# ——那是厂商逐板校准数据，再分发授权不明，不进可公开的镜像。
	# btattach 自己在代码里构造 pskey 与 RF 配置，不依赖那些文件。
	chroot_sdcard systemctl enable \
		w132d-wireless.service w132d-bluetooth.service \
		w132d-ble-remote.service w132d-ir-keymap.service w132d-led-status.service \
		w132d-soft-standby.service
	# 主线内核没有 ttyFIQ0（那是 Rockchip vendor 内核的 FIQ debugger 串口），
	# 而 Armbian 基底使能着对应的 getty —— 不 mask 每次开机白等 90 秒
	chroot_sdcard systemctl mask serial-getty@ttyFIQ0.service "||" true
}

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
# 更新 config 去同步一万多行，只维护这几行差异。
#
# 另一处差异是 pstore：Armbian 的 config 里 PSTORE_RAM=m 而 **PSTORE_CONSOLE 没开**。
# 本板没有 JTAG、盒子平时也不接串口，崩溃现场全靠 DTS 里那块 ramoops；而看门狗
# 复位（硬挂）时 kmsg_dump 根本没机会跑，dmesg-ramoops 一个字节都拿不到，
# **只有 console-ramoops 抓得到**（2026-08-27 看门狗真咬实测）。没有它，一次硬挂
# 留下零现场——32 分钟那个 BL31 缺陷当初就是靠它抓到训练帧的。
# PSTORE_RAM 顺带改成内建：作为模块要等 udev 起来才挂上，开机头几秒的 console 会漏。
#
# ⚠️ 这个钩子会被调用两次：一次在**算内核产物哈希**时（那时没有 .config），一次在
# 真正改 config 时。`kernel_config_modifying_hashes` 必须在 `.config` 存在性检查
# **之前**追加 —— 早先把它放在检查之后，哈希阶段直接 return，Armbian 认为 config
# 没变，改了这里也照样复用缓存的旧内核 deb（实测 pstore 那三行加了等于没加）。
function custom_kernel_config__w132d() {
	kernel_config_modifying_hashes+=("CONFIG_SND_SOC_RK3528=m" "CONFIG_SND_SOC_ES7202=m"
		"CONFIG_PSTORE_RAM=y" "CONFIG_PSTORE_CONSOLE=y" "CONFIG_PSTORE_PMSG=y")
	[[ -f .config ]] || return 0
	display_alert "W132D" "打开 RK3528 acodec 与 ES7202（由 rk3528-audio 补丁引入）；pstore console 通路" "info"
	run_kernel_make olddefconfig
	scripts/config --module CONFIG_SND_SOC_RK3528
	scripts/config --module CONFIG_SND_SOC_ES7202
	scripts/config --enable CONFIG_PSTORE_RAM
	scripts/config --enable CONFIG_PSTORE_CONSOLE
	scripts/config --enable CONFIG_PSTORE_PMSG
}

# w132d-btattach / w132d-bl31-cookie 是 aarch64 可执行文件，编译产物不进仓库，
# 由 extension 从 extensions/src/*.c 在 chroot 里编。overlay 里只有对应的 unit。
enable_extension "w132d-tools"
