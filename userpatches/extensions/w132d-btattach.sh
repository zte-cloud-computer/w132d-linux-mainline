# SPDX-License-Identifier: MIT
# @description 为 W132D 构建并安装 w132d-btattach —— UWE5622 的 HCI transport。
#
# ## 为什么要一个 extension
#
# `/usr/local/sbin/w132d-btattach` 是 aarch64 可执行文件。编译产物不进仓库，
# 所以 bsp overlay 里只有那个 systemd unit，二进制由这里从源码编。
#
# ## 这个工具做什么
#
# 它一个顶三个：打开 /dev/ttyBT0、按 H4 挂上 HCI line discipline，并在此之前
# 下发展锐 Marlin3 的厂商初始化——0xFCA0（176 字节 pskey）、0xFCA2（252 字节 RF
# 配置）、0xFCA1（core enable）。Linux 侧的 sprdbt_tty / uwe5622_bsp_sdio 驱动
# **没有实现这一步**（实测 hci0 up 全程 0 条厂商命令），控制器会跑在未标定状态：
# 射频功率表用芯片默认值，链路余量不足，表现为 LE 建连 0x3e、监督超时掉线。
#
# pskey 与 RF 配置是**代码内构造**的，不读 /lib/firmware/uwe5622/*.ini ——
# 那些是厂商逐板校准数据、再分发授权不明。代价是用通用射频值而非本机标定值。
#
# BD 地址从网卡 MAC 派生（置本地管理位），落在
# /var/lib/bluetooth/w132d-bdaddr，保证每次开机一致。
#
# 源码取自 zte-cloud-computer/w132d-linux-mainline 的 tools/w132d-btattach.c（MIT）。

function post_family_tweaks__w132d_build_btattach() {
	# ${USERPATCHES_PATH}/extensions 是官方的 extension 查找路径之一
	# （extensions.sh:478），源码就放在它旁边。
	declare src="${USERPATCHES_PATH}/extensions/src/w132d-btattach.c"
	[[ -f "${src}" ]] || { display_alert "W132D" "找不到 ${src}" "err"; return 1; }

	display_alert "W132D" "在 chroot 里编译 w132d-btattach（目标架构 ${ARCH}）" "info"
	run_host_command_logged cp "${src}" "${SDCARD}/tmp/w132d-btattach.c"
	chroot_sdcard_apt_get_install gcc libc6-dev
	chroot_sdcard gcc -O2 -Wall -Wextra -o /usr/local/sbin/w132d-btattach \
		/tmp/w132d-btattach.c
	chroot_sdcard rm -f /tmp/w132d-btattach.c
	# 编出来的必须是目标架构：宿主是 x86_64 而 binfmt 没注册时，chroot 里的 gcc
	# 会静默失败或产出错误架构，镜像看着装好了、实际起不来蓝牙。
	chroot_sdcard test -x /usr/local/sbin/w132d-btattach
}
