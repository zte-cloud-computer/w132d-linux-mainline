#!/bin/bash
# SPDX-License-Identifier: MIT
set -euo pipefail

# Stage exact upstream source snapshots for a Linux 7.1 out-of-tree port.
# This script deliberately does not modify the board DTS, kernel .config, or
# any image. It also does not copy proprietary firmware.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MAINLINE_DIR="${W132D_MAINLINE_DIR:-$(cd -- "$SCRIPT_DIR/.." && pwd)}"
BUILD_ROOT="${W132D_BUILD_ROOT:-/root/w132d-build}"
KERNEL_DIR="${W132D_MAINLINE_KERNEL_DIR:-$BUILD_ROOT/linux-v7.1}"
WIFI_SRC="${W132D_WIFI_SRC:-$MAINLINE_DIR/../.research-uwe5621ds-aml}"
BT_SRC="${W132D_BT_SRC:-$MAINLINE_DIR/../.research-uwe5631-aml}"
STAGE="${W132D_WIRELESS_STAGE:-$BUILD_ROOT/w132d-wireless-mainline}"
ARCH=arm64
CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
WIFI_COMMIT=0c12c46df48da9592abc7848335482e68d23e28a
BT_COMMIT=08165b5d56f46b569ee6461d7082ff795efafb2e

check_repo() {
	local path=$1 expected=$2 name=$3 actual
	[ -d "$path/.git" ] || { echo "ERROR: $name is not a Git worktree: $path" >&2; exit 1; }
	actual=$(git -c "safe.directory=$path" -C "$path" rev-parse HEAD)
	[ "$actual" = "$expected" ] || {
		echo "ERROR: $name must be at $expected (found $actual)" >&2
		exit 1
	}
}

[ -d "$KERNEL_DIR" ] || { echo "ERROR: kernel checkout not found: $KERNEL_DIR" >&2; exit 1; }
check_repo "$WIFI_SRC" "$WIFI_COMMIT" uwe5621ds-aml
check_repo "$BT_SRC" "$BT_COMMIT" uwe5631-aml
command -v git >/dev/null || { echo 'ERROR: git is required' >&2; exit 1; }
command -v tar >/dev/null || { echo 'ERROR: tar is required' >&2; exit 1; }

case "$STAGE" in
	"$BUILD_ROOT"/*) ;;
	*) echo "ERROR: staging path must remain under BUILD_ROOT: $STAGE" >&2; exit 1 ;;
esac

rm -rf "$STAGE"
mkdir -p "$STAGE/src/uwe5621ds-aml" "$STAGE/src/uwe5631-aml" "$STAGE/manifest"

echo '=== archive exact WiFi/WCN source commit ==='
git -c "safe.directory=$WIFI_SRC" -C "$WIFI_SRC" archive "$WIFI_COMMIT" | tar -x -C "$STAGE/src/uwe5621ds-aml"
echo '=== archive exact Bluetooth source commit ==='
git -c "safe.directory=$BT_SRC" -C "$BT_SRC" archive "$BT_COMMIT" BT/tty-sdio | tar -x -C "$STAGE/src/uwe5631-aml"

cat > "$STAGE/manifest/source.txt" <<EOF
uwe5621ds-aml=$WIFI_COMMIT
uwe5631-aml=$BT_COMMIT
kernel_dir=$KERNEL_DIR
arch=$ARCH
cross_compile=$CROSS_COMPILE
EOF

cat > "$STAGE/manifest/porting-checklist.txt" <<'EOF'
1. Build uwe5622_bsp_sdio.ko against Linux 7.1 and resolve all API/modpost errors.
2. Build sprdwl_ng.ko with the BSP Module.symvers as KBUILD_EXTRA_SYMBOLS.
3. Build sprdbt_tty.ko with the same BSP symbols and verify tty core APIs.
4. Check module vermagic, depends, softdep, and exported symbols.
5. Only after steps 1-4, enable SDIO1 and add the W132D pwrseq/IRQ GPIOs to DTS.
6. Test SDIO enumeration and WiFi before starting the Bluetooth HCI service.
EOF

echo '=== Linux 7.1 wireless config baseline (read-only check) ==='
if [ -s "$KERNEL_DIR/.config" ]; then
	grep -E '^(CONFIG_(CFG80211|MAC80211|BT|BT_HCIUART|BT_HCIUART_H4|MMC|MMC_SDHCI|MMC_SDHCI_OF_DWCMSHC))=' \
		"$KERNEL_DIR/.config" || true
else
	echo 'kernel .config is not present; run the normal mainline preparation first'
fi

echo "WIRELESS_MAINLINE_STAGE_READY $STAGE"
