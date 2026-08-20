#!/bin/bash
# SPDX-License-Identifier: MIT
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
BUILD_ROOT=${W132D_BUILD_ROOT:-/root/w132d-build}
WIFI_SRC=${W132D_WIFI_SRC:?Set W132D_WIFI_SRC to a clone of KryptonLee/uwe5621ds-aml}
BT_SRC=${W132D_BT_SRC:?Set W132D_BT_SRC to a clone of CoreELEC/uwe5631-aml}
MPP_SRC=${W132D_MPP_SRC:?Set W132D_MPP_SRC to a clone of rockchip-linux/mpp}
WIFI_COMMIT=0c12c46df48da9592abc7848335482e68d23e28a
BT_COMMIT=08165b5d56f46b569ee6461d7082ff795efafb2e
MPP_COMMIT=c08762ebfadeb4e986d2fed993bc7a54862d3ebe
WIFI_BUILD=${W132D_WIFI_BUILD_DIR:-$BUILD_ROOT/uwe5622-linux61}
BT_ARCHIVE=${W132D_BT_BUILD_DIR:-$BUILD_ROOT/sprdbt-tty-linux61}
BT_BUILD=$BT_ARCHIVE/BT/tty-sdio
MPP_SOURCE_BUILD=${W132D_MPP_SOURCE_BUILD_DIR:-$BUILD_ROOT/mpp-source}
MPP_BUILD=${W132D_MPP_BUILD_DIR:-$BUILD_ROOT/mpp-linux-arm64}
MPP_OUT=${W132D_MPP_OUT_DIR:-$BUILD_ROOT/mpp-out}
KERNEL=${W132D_KERNEL_DIR:-$BUILD_ROOT/armbian-build/cache/sources/linux-kernel-worktree/6.1__rk35xx__arm64}
OUT=${W132D_COMPONENT_OUT_DIR:-$BUILD_ROOT/uwe5622-out}
CROSS_COMPILE=${CROSS_COMPILE:-aarch64-linux-gnu-}

check_source() {
	local path=$1
	local expected=$2
	local name=$3
	local actual

	git -C "$path" rev-parse --git-dir >/dev/null 2>&1 || {
		echo "ERROR: $name is not a Git worktree: $path"
		exit 1
	}
	actual=$(git -C "$path" rev-parse HEAD)
	[ "$actual" = "$expected" ] || {
		echo "ERROR: $name must be checked out at $expected (found $actual)"
		exit 1
	}
}

check_source "$WIFI_SRC" "$WIFI_COMMIT" uwe5621ds-aml
check_source "$BT_SRC" "$BT_COMMIT" uwe5631-aml
check_source "$MPP_SRC" "$MPP_COMMIT" rockchip-mpp
[ -d "$KERNEL" ] || { echo "ERROR: kernel build tree not found: $KERNEL"; exit 1; }

rm -rf "$WIFI_BUILD" "$BT_ARCHIVE" "$MPP_SOURCE_BUILD" "$MPP_BUILD" "$MPP_OUT" "$OUT"
mkdir -p "$WIFI_BUILD" "$BT_ARCHIVE" "$MPP_SOURCE_BUILD" "$MPP_OUT" "$OUT"

# Archive exact commits so uncommitted research-tree changes cannot leak into a build.
git -C "$WIFI_SRC" archive "$WIFI_COMMIT" | tar -x -C "$WIFI_BUILD"
git -C "$BT_SRC" archive "$BT_COMMIT" BT/tty-sdio | tar -x -C "$BT_ARCHIVE"
git -C "$MPP_SRC" archive "$MPP_COMMIT" | tar -x -C "$MPP_SOURCE_BUILD"

echo '=== apply W132D WiFi and Bluetooth patches ==='
patch -d "$WIFI_BUILD" -p1 < "$REPO_ROOT/patches/uwe5621ds-aml/0001-linux-6.1-w132d.patch"
install -m 0644 "$REPO_ROOT/patches/uwe5621ds-aml/compat.h" \
	"$WIFI_BUILD/unisocwifi/compat.h"
sed -i 's/\r$//' "$BT_BUILD/Makefile" "$BT_BUILD/rfkill.c" "$BT_BUILD/tty.c" \
	"$BT_BUILD/sdio.c" "$BT_BUILD/sitm.c"
patch -d "$BT_ARCHIVE" -p1 < "$REPO_ROOT/patches/uwe5631-aml/0001-sdio-rx-bounds.patch"
patch -d "$BT_BUILD" -p1 < "$REPO_ROOT/patches/uwe5631-aml/0002-w132d-board-integration.patch"

make_module() {
	local module_dir=$1
	shift
	make -C "$KERNEL" \
		ARCH=arm64 \
		CROSS_COMPILE="$CROSS_COMPILE" \
		M="$WIFI_BUILD/$module_dir" \
		"$@" \
		modules
}

make_module unisocwcn \
	CONFIG_RK_WIFI_DEVICE_UWE5622=y \
	UNISOC_FW_PATH_CONFIG=/lib/firmware/uwe5622/ \
	TARGET_BUILD_VARIANT=user

make_module unisocwifi \
	CONFIG_WLAN_UWE5622=m \
	UNISOC_WIFI_USE_DTS=y \
	KBUILD_EXTRA_SYMBOLS="$WIFI_BUILD/unisocwcn/Module.symvers" \
	UNISOC_BSP_INCLUDE="$WIFI_BUILD/unisocwcn/include" \
	UNISOC_WIFI_CUS_CONFIG=/lib/firmware/uwe5622/ \
	UNISOC_WIFI_MAC_FILE=/lib/firmware/uwe5622/wifimac.txt

echo '=== build UWE5622 Bluetooth tty-over-SDIO module ==='
make -C "$KERNEL" \
	ARCH=arm64 \
	CROSS_COMPILE="$CROSS_COMPILE" \
	M="$BT_BUILD" \
	CURFOLDER="$WIFI_BUILD/unisocwcn" \
	UNISOC_BSP_INCLUDE="$WIFI_BUILD/unisocwcn/include" \
	KBUILD_EXTRA_SYMBOLS="$WIFI_BUILD/unisocwcn/Module.symvers" \
	modules

echo '=== build W132D Marlin3 HCI initialization daemon ==='
"${CROSS_COMPILE}gcc" -O2 -Wall -Wextra -Werror -std=c11 -static \
	-o "$OUT/w132d-btattach" "$REPO_ROOT/tools/w132d-btattach.c"

echo '=== rebuild W132D device tree ==='
install -m 0644 "$REPO_ROOT/board/rk3528-w132d.dts" \
	"$KERNEL/arch/arm64/boot/dts/rockchip/rk3528-w132d.dts"
make -C "$KERNEL" \
	ARCH=arm64 \
	CROSS_COMPILE="$CROSS_COMPILE" \
	rockchip/rk3528-w132d.dtb

echo '=== build Rockchip MPP userspace for arm64 ==='
cmake -S "$MPP_SOURCE_BUILD" -B "$MPP_BUILD" \
	-DCMAKE_BUILD_TYPE=Release \
	-DCMAKE_SYSTEM_NAME=Linux \
	-DCMAKE_SYSTEM_PROCESSOR=aarch64 \
	-DCMAKE_C_COMPILER="${CROSS_COMPILE}gcc" \
	-DCMAKE_CXX_COMPILER="${CROSS_COMPILE}g++" \
	-DCMAKE_INSTALL_PREFIX=/usr/local \
	-DCMAKE_INSTALL_LIBDIR=lib \
	-DBUILD_TEST=ON
cmake --build "$MPP_BUILD" -j"$(nproc)"
DESTDIR="$MPP_OUT" cmake --install "$MPP_BUILD"
"${CROSS_COMPILE}strip" --strip-unneeded "$MPP_OUT"/usr/local/bin/*
"${CROSS_COMPILE}strip" --strip-unneeded "$MPP_OUT"/usr/local/lib/librockchip_mpp.so.1
"${CROSS_COMPILE}strip" --strip-unneeded "$MPP_OUT"/usr/local/lib/librockchip_vpu.so.1

install -m 0644 "$WIFI_BUILD/unisocwcn/uwe5622_bsp_sdio.ko" "$OUT/"
install -m 0644 "$WIFI_BUILD/unisocwifi/sprdwl_ng.ko" "$OUT/"
install -m 0644 "$BT_BUILD/sprdbt_tty.ko" "$OUT/"

for module in "$OUT"/*.ko; do
	modinfo "$module" | grep -E '^(filename|license|description|depends|name|vermagic):'
done
file "$OUT/w132d-btattach" \
	"$MPP_OUT/usr/local/bin/mpi_dec_test" \
	"$MPP_OUT/usr/local/bin/mpi_enc_test"

echo UWE5622_BT_MPP_BUILD_DONE
