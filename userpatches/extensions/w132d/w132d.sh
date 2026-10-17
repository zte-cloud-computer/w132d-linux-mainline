# SPDX-License-Identifier: MIT
# shellcheck shell=bash disable=SC2034,SC2154,SC2317,SC1091
# All paths are relative to the staged userpatches, including Docker builds.
W132D_EXT="${USERPATCHES_PATH}/extensions/w132d"
[[ -f "${W132D_EXT}/locked.sh" ]] || exit_with_error "Use tools/w132d to lock build inputs first"
source "${W132D_EXT}/locked.sh"
export SOURCE_DATE_EPOCH
source "${W132D_EXT}/cache.sh"

function post_family_config__w132d() {
	declare -g KERNELSOURCE="https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git"
	declare -g KERNELBRANCH="commit:${W132D_LINUX_SHA}"
	declare -g KERNEL_MAJOR_MINOR="${W132D_KERNEL_SERIES}"
	declare -g KERNELPATCHDIR="w132d"
	declare -g LINUXFAMILY="rockchip64" EXTRAWIFI="no" KEEP_ORIGINAL_OS_RELEASE="yes"
	declare -g INSTALL_ARMBIAN_FIRMWARE="no"
	# Let Armbian generate cpufrequtils once during image customization.
	declare -g CPUMIN=408000 CPUMAX=2016000 GOVERNOR=schedutil CPUFREQUTILS_ENABLE=false
	declare -g OFFSET=16 BOOTSIZE=512 BOOTFS_TYPE=fat IMAGE_PARTITION_TABLE=gpt
	declare -g BOOTSOURCE="https://github.com/u-boot/u-boot.git"
	declare -g BOOTBRANCH="commit:${W132D_UBOOT_SHA}"
	declare -g BOOTPATCHDIR="w132d" BOOTDIR="u-boot-w132d" BOOTDELAY=1
	declare -g UBOOT_TARGET_MAP="BL31=${W132D_EXT}/inputs/bl31 ROCKCHIP_TPL=${W132D_EXT}/inputs/ddr;;idbloader.img u-boot.itb"
	# Only the manifest-verified blobs are used by this board.
	unset -f uboot_custom_postprocess write_uboot_platform_mtd
	function write_uboot_platform() {
		# Preserve vendor storage and RKSS between the two boot components.
		dd "if=$1/idbloader.img" "of=$2" bs=512 seek=64 conv=notrunc status=none
		dd "if=$1/u-boot.itb" "of=$2" bs=512 seek=16384 conv=notrunc status=none
	}
}

function kernel_copy_extra_sources__w132d() {
	[[ "$(git -C "${kernel_work_dir}" rev-parse HEAD)" == "${W132D_LINUX_SHA}" ]] || exit_with_error "Kernel tag no longer matches its locked commit"
	python3 "${W132D_EXT}/install-sources.py" "${kernel_work_dir}"
	# Armbian resets to kernel_git_revision during patching. Commit only this
	# temporary source overlay so the supported source hook survives that reset.
	git -C "${kernel_work_dir}" add drivers/net/wireless sound/soc/codecs arch/arm64/boot/dts/rockchip Documentation/devicetree/bindings
	GIT_AUTHOR_DATE="@${SOURCE_DATE_EPOCH} +0000" GIT_COMMITTER_DATE="@${SOURCE_DATE_EPOCH} +0000" \
		git -C "${kernel_work_dir}" -c user.name=W132D -c user.email=build@w132d.invalid -c commit.gpgsign=false commit -qm "build(w132d): Install maintained sources"
	kernel_git_revision="$(git -C "${kernel_work_dir}" rev-parse HEAD)"
	git -C "${kernel_work_dir}" apply --check "${USERPATCHES_PATH}"/kernel/w132d/*.patch
}

function custom_kernel_config__w132d() {
	kernel_config_modifying_hashes+=("${W132D_CONTENT_HASH}")
	[[ -f .config ]] || return 0
	git apply --reverse --check "${USERPATCHES_PATH}"/kernel/w132d/*.patch
	scripts/kconfig/merge_config.sh -m .config "${W132D_EXT}/kernel.config"
	run_kernel_make olddefconfig
}

function pre_config_uboot_target__w132d() {
	git apply --reverse --check "${USERPATCHES_PATH}"/u-boot/w132d/*.patch
}

function post_config_uboot_target__w132d() {
	run_host_command_logged scripts/config --set-str CONFIG_DEFAULT_DEVICE_TREE rk3528-w132d
	run_host_command_logged scripts/config --set-str CONFIG_OF_LIST rk3528-w132d
	run_host_command_logged scripts/config --set-str CONFIG_DEFAULT_FDT_FILE rockchip/rk3528-w132d.dtb
	run_host_command_logged scripts/config --enable CONFIG_ADC --enable CONFIG_SARADC_ROCKCHIP
	run_host_command_logged scripts/config --enable CONFIG_DM_REGULATOR --enable CONFIG_DM_REGULATOR_FIXED
	# BL31 expects this handshake on every boot, including warm resets.
	run_host_command_logged scripts/config --enable CONFIG_USE_PREBOOT
	run_host_command_logged scripts/config --set-str CONFIG_PREBOOT "'mw.l 0xff370220 0x2b4d1f7a'"
}

function post_create_partitions__w132d() {
	# Keep Armbian's native GPT and resize service; mark the FAT boot partition.
	run_host_command_logged sgdisk --attributes=1:set:2 "${SDCARD}.raw"
}

function post_family_tweaks_bsp__w132d() {
	rsync -a --exclude=__pycache__ --exclude=.DS_Store "${USERPATCHES_PATH}/overlay/bsp-cli/" "${destination}/"
	install -Dm644 "${W132D_EXT}/inputs/wcn" "${destination}/usr/lib/firmware/uwe5622/wcnmodem-marlin3e.bin"
	# Preserve board configuration without taking ownership of framework state
	# such as armbian-release, which is rewritten during artifact reversioning.
	find "${USERPATCHES_PATH}/overlay/bsp-cli/etc" -type f -printf '/etc/%P\n' >> "${destination}/DEBIAN/conffiles"
	LC_ALL=C sort -u -o "${destination}/DEBIAN/conffiles" "${destination}/DEBIAN/conffiles"
	postinst_functions+=(w132d_board_postinst)
	postrm_functions+=(w132d_board_postrm)
	artifact_package_hook_helper_board_side_functions "prerm" w132d_board_prerm
}

function w132d_board_postinst() {
	if [[ "$1" == configure ]]; then
		for unit in w132d-wireless w132d-ble-remote w132d-ir-keymap w132d-led-status w132d-soft-standby; do
			# Follow debhelper semantics and preserve administrator disablement.
			deb-systemd-helper unmask "${unit}.service" >/dev/null || exit 1
			if deb-systemd-helper --quiet was-enabled "${unit}.service"; then
				deb-systemd-helper enable "${unit}.service" >/dev/null || exit 1
			else
				deb-systemd-helper update-state "${unit}.service" >/dev/null || exit 1
			fi
		done
		if [[ -d /run/systemd/system ]]; then
			systemctl daemon-reload || exit 1
			action=start
			[[ -z "${2:-}" ]] || action=try-restart
			deb-systemd-invoke "$action" w132d-wireless.service w132d-ble-remote.service w132d-ir-keymap.service w132d-led-status.service w132d-soft-standby.service || exit 1
		fi
	fi
}

function w132d_board_prerm() {
	if [[ "$1" == remove && -d /run/systemd/system ]]; then
		deb-systemd-invoke stop w132d-wireless.service w132d-ble-remote.service w132d-ir-keymap.service w132d-led-status.service w132d-soft-standby.service || exit 1
	fi
}

function w132d_board_postrm() {
	if [[ "$1" == purge ]]; then
		deb-systemd-helper purge w132d-wireless.service w132d-ble-remote.service w132d-ir-keymap.service w132d-led-status.service w132d-soft-standby.service || exit 1
	fi
	if [[ "$1" == remove && -d /run/systemd/system ]]; then
		systemctl daemon-reload || exit 1
	fi
}

function pre_install_kernel_debs__w132d() {
	# Finalize the local output before image installation. Kernel-only builds
	# use this same helper; the hashed Armbian artifact cache is never changed.
	PYTHONPATH="${W132D_EXT}" python3 - "${DEB_STORAGE}" "${REVISION}" <<'PY'
from pathlib import Path
import sys
from w132dlib.packages import finalize, metadata
for path in Path(sys.argv[1]).rglob('*.deb'):
    if metadata(path).get('Version') == sys.argv[2]:
        finalize(path)
PY
	install_artifact_deb_chroot "linux-dtb"
}

function post_family_tweaks__w132d() {
	chroot_sdcard systemctl enable w132d-wireless w132d-ble-remote w132d-ir-keymap w132d-led-status w132d-soft-standby
	chroot_sdcard systemctl mask serial-getty@ttyFIQ0.service
}
