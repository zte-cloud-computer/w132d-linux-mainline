#!/bin/bash
# SPDX-License-Identifier: MIT
set -euo pipefail

PRIVATE_DIR=${W132D_PRIVATE_DIR:?Set W132D_PRIVATE_DIR to a directory containing vendor-blobs/ and w132d-a9/}
BUILD_ROOT=${W132D_BUILD_ROOT:-/root/w132d-build}
CURRENT=${W132D_BASE_UBOOT:-$PRIVATE_DIR/vendor-blobs/p2_uboot.img}
ANDROID=${W132D_ANDROID_UBOOT:-$PRIVATE_DIR/w132d-a9/2.uboot.img}
OUTPUT=${W132D_REPACKED_UBOOT:-$PRIVATE_DIR/vendor-blobs/p2_uboot-wdt.img}
UBOOT=${W132D_UBOOT_SOURCE_DIR:-$BUILD_ROOT/armbian-build/cache/sources/u-boot-worktree/u-boot-rockchip64/next-dev-v2024.10}
TMP=${W132D_REPACK_TMP:-$BUILD_ROOT/wdt-fit-repack}

[ "$(id -u)" -eq 0 ] || { echo 'ERROR: FIT repack must run as root'; exit 1; }

# Android 9 BL31 contains a secure timer callback which probes UART0 every
# minute. After 30 probes it emits the fixed '#/8/--/]' training frame and
# writes CRU registers, which matches the ~30 minute lockup observed on W132D.
# Keep the callback's completion/ack path intact, but force its post-counter
# branch to the existing cleanup path before the frame-output code. The
# callback is loaded at 0x80000; the branch at 0x988d4 is file offset 100564.
ATF1_ORIGINAL_SHA256=4f8d9fc2e2a27a6e553bc5e213b13124b2108fddb93e8a484fee3bc5c46d74b1
ATF1_PATCHED_SHA256=5d5540795a7b72b92b7d77c6907bafd0c5f2de8ca1fd302352f833bf0882bc02
ATF1_PATCH_OFFSET=100564
ATF1_PATCH_BYTES='f4 ff ff 17 00 44 80 d2'

cleanup() {
	rm -rf "$TMP"
}
trap cleanup EXIT

for file in "$CURRENT" "$ANDROID"; do
	[ -f "$file" ] || { echo "ERROR: missing FIT image: $file"; exit 1; }
done
[ -x "$UBOOT/scripts/fit-unpack.sh" ] || { echo 'ERROR: fit-unpack.sh not found'; exit 1; }
[ -x "$UBOOT/scripts/fit-repack.sh" ] || { echo 'ERROR: fit-repack.sh not found'; exit 1; }

rm -rf "$TMP"
mkdir -p "$TMP/current" "$TMP/android"
cp "$CURRENT" "$TMP/p2_uboot-wdt.img"

"$UBOOT/scripts/fit-unpack.sh" -f "$TMP/p2_uboot-wdt.img" -o "$TMP/current"

# The current FIT stores payloads externally and is handled by fit-unpack.sh,
# while the Android 9 FIT embeds its payloads and has no data-position fields.
# Extract BL31 and OP-TEE by their verified FIT image indexes.
for index in 1 2 3; do
	dumpimage -T flat_dt -p "$index" -o "$TMP/android/atf-$index" "$ANDROID" >/dev/null
done
dumpimage -T flat_dt -p 4 -o "$TMP/android/optee" "$ANDROID" >/dev/null
echo "4f8d9fc2e2a27a6e553bc5e213b13124b2108fddb93e8a484fee3bc5c46d74b1  $TMP/android/atf-1" | sha256sum -c -
echo "2ead5967c1e23dbb9381df9fbc55ff762815ba6be532669b553966b5aba81879  $TMP/android/atf-2" | sha256sum -c -
echo "9e4547a3b33f0fd56d71455958faa8c1d25c04a528632da7fb4a3949e1733910  $TMP/android/atf-3" | sha256sum -c -
echo "82da4e7f8b0e15906f172aa4897192be66e8d45e8898f01f7d2be3f7abfae023  $TMP/android/optee" | sha256sum -c -

# atf-1/2/3 are the three loadable segments of one BL31 ELF. Replace them
# as a set so code in DRAM, SRAM and PMU SRAM always comes from one build.
# Keep OP-TEE paired with the Android 9 BL31 instead of mixing the older
# 2023-04 OP-TEE from the legacy FIT with the newer secure monitor.
for segment in atf-1 atf-2 atf-3; do
	cp "$TMP/android/$segment" "$TMP/current/$segment"
done
cp "$TMP/android/optee" "$TMP/current/optee"

echo '=== bypass BL31 periodic UART frame output, preserve callback completion ==='
echo "$ATF1_ORIGINAL_SHA256  $TMP/current/atf-1" | sha256sum -c -
printf '\xf4\xff\xff\x17' |
	dd of="$TMP/current/atf-1" bs=1 seek="$ATF1_PATCH_OFFSET" conv=notrunc status=none
echo "$ATF1_PATCHED_SHA256  $TMP/current/atf-1" | sha256sum -c -
EXPECTED_PATCH_HEX=$(echo "$ATF1_PATCH_BYTES" | tr -d ' ')
ACTUAL_PATCH_HEX=$(od -An -tx1 -j "$ATF1_PATCH_OFFSET" -N 8 "$TMP/current/atf-1" | tr -d ' \n')
[ "$ACTUAL_PATCH_HEX" = "$EXPECTED_PATCH_HEX" ] || {
	echo "ERROR: BL31 UART callback patch bytes mismatch: $ACTUAL_PATCH_HEX"
	exit 1
}

(
	cd "$UBOOT"
	./scripts/fit-repack.sh -f "$TMP/p2_uboot-wdt.img" -d "$TMP/current"
)

[ "$(stat -c %s "$TMP/p2_uboot-wdt.img")" -eq 4194304 ] || {
	echo 'ERROR: repacked U-Boot FIT is not exactly 4 MiB'
	exit 1
}

mkdir -p "$(dirname "$OUTPUT")"
install -m 0644 "$TMP/p2_uboot-wdt.img" "$OUTPUT"

VERIFY="$TMP/verify"
mkdir -p "$VERIFY"
for index in 1 2 3; do
	dumpimage -T flat_dt -p "$index" -o "$VERIFY/atf-$index" "$OUTPUT" >/dev/null
done
dumpimage -T flat_dt -p 4 -o "$VERIFY/optee" "$OUTPUT" >/dev/null
cmp "$TMP/current/atf-1" "$VERIFY/atf-1"
cmp "$TMP/android/atf-2" "$VERIFY/atf-2"
cmp "$TMP/android/atf-3" "$VERIFY/atf-3"
cmp "$TMP/android/optee" "$VERIFY/optee"
echo "$ATF1_PATCHED_SHA256  $VERIFY/atf-1" | sha256sum -c -
ACTUAL_PATCH_HEX=$(od -An -tx1 -j "$ATF1_PATCH_OFFSET" -N 8 "$VERIFY/atf-1" | tr -d ' \n')
[ "$ACTUAL_PATCH_HEX" = "$EXPECTED_PATCH_HEX" ] || {
	echo "ERROR: repacked FIT lost BL31 UART callback patch"
	exit 1
}
dumpimage -l "$OUTPUT" | sed -n '1,70p'
sha256sum "$OUTPUT"
echo 'WDT_BOOTCHAIN_DONE'
