# SPDX-License-Identifier: MIT
# @description 在 chroot 里从源码构建 W132D 的原生小工具并装进镜像，编完把工具链卸干净。
#
# ## 为什么要一个 extension
#
# extensions/src/*.c 的产物都是 aarch64 可执行文件，编译产物不进仓库，所以 bsp
# overlay 里只有对应的 systemd unit，二进制由这里从源码编，装到 /usr/local/sbin/：
#
#   w132d-btattach      UWE5622 的 HCI transport。一个顶三个：打开 /dev/ttyBT0、
#                       按 H4 挂上 HCI line discipline，并在此之前下发展锐 Marlin3
#                       的厂商初始化 —— 0xFCA0（pskey）、0xFCA2（RF 配置）、
#                       0xFCA1（core enable）。Linux 侧的 sprdbt_tty 驱动没有这一步
#                       （实测 hci0 up 全程 0 条厂商命令），控制器会跑在未标定状态：
#                       LE 建连 0x3e、监督超时掉线。pskey 与 RF 配置是代码内构造的，
#                       不读 /lib/firmware/uwe5622/bt_configure_*.ini —— 那是厂商逐板
#                       校准数据，再分发授权不明。BD 地址从网卡 MAC 派生。
#                       源码取自 zte-cloud-computer/w132d-linux-mainline（MIT）。
#
# ## 工具链必须卸掉
#
# gcc + libc6-dev 连依赖近百 MB，minimal 镜像里没有别的东西需要它。
# 不用 autoremove（它会把 Armbian 自己装的、恰好标成 auto 的包一起收走），
# 而是比对装前/装后的包清单，只 purge 这次新装进来的那一组。
# ${USERPATCHES_PATH}/extensions 是官方的 extension 查找路径之一（extensions.sh:478），
# 源码就放在它旁边的 src/ 里。

function post_family_tweaks__w132d_build_native_tools() {
	declare srcdir="${USERPATCHES_PATH}/extensions/src"
	declare -a sources=("${srcdir}"/*.c)
	[[ -f "${sources[0]}" ]] || { display_alert "W132D" "${srcdir} 里没有 .c 源文件" "err"; return 1; }

	chroot_sdcard "dpkg-query -W -f '\${Package}\n' | sort > /tmp/w132d-pkgs-before"
	chroot_sdcard_apt_get_install gcc libc6-dev
	chroot_sdcard "dpkg-query -W -f '\${Package}\n' | sort > /tmp/w132d-pkgs-after"
	declare -a added=()
	mapfile -t added < <(comm -13 "${SDCARD}/tmp/w132d-pkgs-before" "${SDCARD}/tmp/w132d-pkgs-after")

	declare src name machine
	for src in "${sources[@]}"; do
		name="$(basename "${src}" .c)"
		display_alert "W132D" "在 chroot 里编译 ${name}（目标架构 ${ARCH}）" "info"
		run_host_command_logged cp "${src}" "${SDCARD}/tmp/${name}.c"
		chroot_sdcard gcc -O2 -Wall -Wextra -o "/usr/local/sbin/${name}" "/tmp/${name}.c"
		chroot_sdcard rm -f "/tmp/${name}.c"
		# 编出来的必须是 aarch64 ELF（e_machine = 0xB7，文件偏移 18 处小端 2 字节）。
		# 宿主是 x86_64 而 binfmt 没注册时，chroot 里的 gcc 可能静默产出错误架构，
		# 镜像看着装好了、实际起不来。
		machine="$(od -An -tx1 -j18 -N2 "${SDCARD}/usr/local/sbin/${name}" | tr -d ' \n')"
		[[ "${machine}" == "b700" ]] || {
			display_alert "W132D" "${name} 不是 aarch64 ELF（e_machine=${machine}）" "err"
			return 1
		}
	done

	if [[ ${#added[@]} -gt 0 ]]; then
		display_alert "W132D" "卸掉为编译临时装进来的 ${#added[@]} 个包" "info"
		chroot_sdcard_apt_get purge "${added[@]}"
	fi
	run_host_command_logged rm -f "${SDCARD}/tmp/w132d-pkgs-before" "${SDCARD}/tmp/w132d-pkgs-after"
}
