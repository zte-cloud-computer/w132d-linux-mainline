# SPDX-License-Identifier: MIT
# ZTE Cloud Computer W132D（Rockchip RK3528）——主线内核 + 主线 U-Boot（rkbin DDR/BL31 blob）。
#
# 这个文件的目标形态就是最终提给 armbian/build 的 `config/boards/w132d.csc`，
# 所以除了必要的注释以外，尽量只用 Armbian 官方已有的机制，不自造概念：
#   * BOARDFAMILY 用官方的 rk35xx（RK3528 已有 9 块板在用）
#   * KERNEL_TARGET 用官方的 edge（rk35xx.conf 里 source 了 rockchip64_common.inc，
#     edge 分支给出 LINUXFAMILY=rockchip64 / KERNEL_MAJOR_MINOR=7.2 /
#     补丁目录 rockchip64-7.2），不自建 family、不自建分支
#   * 引导链与 radxa-e24c 同法：主线 U-Boot generic-rk3528 + rkbin blob（钩子在
#     userpatches/extensions/w132d-uboot.sh，毕业时并进这个文件）
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
# 主线 U-Boot 的 bootstd 直接读 extlinux/extlinux.conf（厂商 U-Boot 的 distro boot 也是），
# 里面全是写死的路径和参数，没有脚本逻辑；Armbian 默认的 boot.scr 依赖一堆环境变量，
# 在厂商 U-Boot 上两次刷写都没起来，所以一直用 extlinux。
#
# SRC_EXTLINUX 下 armbianEnv.txt 会被删掉，内核参数只有这一处：root= 由 Armbian 加。
# 控制台 ttyS0/115200（DTS 的 stdout-path）。loglevel 先开到 7：盒子没串口，崩溃现场
# 全靠 console-ramoops，它记的是打到 console 的东西，等级低了硬挂时零现场。
SRC_EXTLINUX="yes"
SRC_CMDLINE="rootwait rootfstype=ext4 console=ttyS0,115200 console=tty1 consoleblank=0 loglevel=7"

# ## 引导链：主线 U-Boot v2026.07 + rkbin DDR v1.13 / BL31 v1.21
#
# 2026-09-04 分两步实机验证：先只换 P1（厂商 SPL 能加载主线 FIT），再换 idbloader；
# 全主线链引导 14.3 s，设备上不再有任何厂商引导二进制。HDMI 旁的针孔是 SARADC ch1
# 下载键，由 U-Boot proper 读：命中写 BOOT_BROM_DOWNLOAD 复位，BootROM 进 MaskROM，
# rkdeveloptool db 一个 rkbin loader 后即可读写 eMMC（实测）。
# 具体钩子（源、分支、blob、defconfig 改动、分两段写入）在 w132d-uboot 扩展里。
BOOTCONFIG="generic-rk3528_defconfig"
BOOT_SCENARIO="spl-blobs"
enable_extension "w132d-uboot"

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
	# Armbian 的镜像只有两个分区（bootfs、rootfs），u-boot.itb 在 16384 的空档里不占分区；
	# 所以这里的 1/2 对应设备上的 p2/p3。设备形状的三分区 GPT 由 make-release.sh 生成。
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
	# 用 rsync 而不是 cp -a：宿主是 macOS，overlay 目录里随时会冒出 .DS_Store；本机跑过
	# 自测的脚本旁边会留 __pycache__ —— 这些都不该进包（实测 __pycache__ 真进去过一次）。
	display_alert "W132D" "铺 $(find "${src}" -type f -not -name .DS_Store -not -path '*/__pycache__/*' | wc -l) 个设备定制文件" "info"
	run_host_command_logged rsync -a --exclude=.DS_Store --exclude=__pycache__ "${src}/" "${destination}/"
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
	display_alert "W132D" "写入 $(find "${src}" -type f -not -name .DS_Store | wc -l) 个归属其他包的配置" "info"
	run_host_command_logged rsync -a --exclude=.DS_Store --exclude=__pycache__ "${src}/" "${SDCARD}/"
}

# ## WCN 固件：从 CoreELEC 的公开仓库按钉住的提交取，构建时校 sha256
#
# 板上是 UWE5623 / Marlin3E（芯片 id 0x56630001）。2026-09-04 用同一脚本、各干净重启
# 一次做的对照（关联同一台 5 GHz AP，两个方向各传 100 MB，--interface wlan0 绑接口，
# 用 wlan0/eth0 的字节计数证明流量确实走无线）：
#   * armbian-firmware 的 uwe5622/wcnmodem-38222.bin（WCNM 合并镜像，3EAB 段是
#     MARLIN3E_20A_W21.03.3）—— 扫描 100/100，但**一关联就 CP2 断言**
#     （cmd_tx_rom.c:3212 → marlin_cp2_reset，蓝牙跟着下电），拿不到 IP
#   * armbian-firmware 的 uwe5622/wcnmodem.bin —— SC2355 / Marlin3 Lite 的，装错零件
#   * 出厂 W25.45.3 —— 第一次扫描就崩；作者版 W24.48.5 —— 能用，但是私有文件
#   * CoreELEC/uwe5631-aml 的 BSP/fw/wcnmodem.bin，MARLIN3E_20A_W23.03.2 ——
#     关联 OK（VHT80 MCS9 NSS2）、下行 17–19 MB/s、上行 14 MB/s、0 断言、蓝牙/遥控器
#     不受影响。公开仓库、按提交可定位、可校验。**用这份。**
#
# 仓库里不放二进制：bsp 包构建时从钉住的提交下载到 Armbian 的 cache/ 里，sha256 不对
# 就构建失败。钉提交而不是分支：CoreELEC master 后来又换成了更旧的 W22.47.2。
# 装到 /lib/firmware/uwe5622/wcnmodem-marlin3e.bin，DTS 的 unisoc,btwf-file-name 指它；
# armbian-firmware 自己那两份留在原地不碰、不改道 —— 两个包各管各的文件，没有归属冲突。
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

# bsp 包装进 rootfs 之后再确认一遍：文件在、就是钉住的那份、RF 配置也在
function post_family_tweaks__w132d_wcn_firmware() {
	echo "${W132D_WCN_FW_SHA256}  ${SDCARD}/${W132D_WCN_FW_DEST}" | sha256sum -c --status \
		|| exit_with_error "rootfs 里的 /${W132D_WCN_FW_DEST} 缺失或不是钉住的那份 —— DTS 的 btwf-file-name 指着它"
	[[ -f "${SDCARD}/lib/firmware/wifi_56630001_3ant.ini" ]] \
		|| exit_with_error "缺 /lib/firmware/wifi_56630001_3ant.ini（overlay 里的软链没铺进去？）"
}

# 服务使能：overlay 只是把 unit 文件放进去，不会自动 enable。
# HDMI 相关的 unit 本版不带，所以不在列表里。
function post_family_tweaks__w132d_enable_services() {
	display_alert "W132D" "使能板级服务" "info"
	# BL31 uartdbg 32 分钟挂死的绕过（往 GRF 写握手 cookie）已改由 U-Boot 的 PREBOOT 做
	#（见 extensions/w132d-uboot.sh），Linux 侧不再有对应服务。
	# 蓝牙不需要任何用户态 attach：uwe5622 驱动（w132d-armbian-0005 补丁 + CONFIG_TTY_OVERY_SDIO_HCI）
	# 直接注册 hci0，pskey/RF/enable 在内核里下发，bluetoothd 走 mgmt 上电即可。
	chroot_sdcard systemctl enable \
		w132d-wireless.service \
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
		"CONFIG_PSTORE_RAM=y" "CONFIG_PSTORE_CONSOLE=y" "CONFIG_PSTORE_PMSG=y"
		"CONFIG_TTY_OVERY_SDIO_HCI=y")
	[[ -f .config ]] || return 0
	display_alert "W132D" "打开 RK3528 acodec 与 ES7202（由 rk3528-audio 补丁引入）；pstore console 通路；uwe5622 蓝牙走 HCI 设备" "info"
	run_kernel_make olddefconfig
	scripts/config --module CONFIG_SND_SOC_RK3528
	scripts/config --module CONFIG_SND_SOC_ES7202
	scripts/config --enable CONFIG_PSTORE_RAM
	scripts/config --enable CONFIG_PSTORE_CONSOLE
	scripts/config --enable CONFIG_PSTORE_PMSG
	# uwe5622 的蓝牙通道直接注册成 hci0（w132d-armbian-0005 补丁加的选项），不再经 /dev/ttyBT0 + 用户态 attach
	scripts/config --enable CONFIG_TTY_OVERY_SDIO_HCI
}
