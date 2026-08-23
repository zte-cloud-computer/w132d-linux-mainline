#!/bin/bash
# SPDX-License-Identifier: MIT
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MAINLINE_DIR="${W132D_MAINLINE_DIR:-$(cd -- "$SCRIPT_DIR/.." && pwd)}"
BUILD_ROOT="${W132D_BUILD_ROOT:-/root/w132d-build}"
KERNEL_DIR="${W132D_MAINLINE_KERNEL_DIR:-$BUILD_ROOT/linux-v7.1}"
STAGE="${W132D_WIRELESS_STAGE:-$BUILD_ROOT/w132d-wireless-mainline}"
PORT_REPO="${W132D_PORT_REPO:-$MAINLINE_DIR}"
OUT="${W132D_WIRELESS_OUT:-$MAINLINE_DIR/out/wireless}"
ARCH=arm64
CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
WIFI_BUILD="$STAGE/src/uwe5621ds-aml"
BT_BUILD="$STAGE/src/uwe5631-aml/BT/tty-sdio"

[ -d "$KERNEL_DIR" ] || { echo "ERROR: kernel checkout not found: $KERNEL_DIR" >&2; exit 1; }
[ -d "$WIFI_BUILD/unisocwcn" ] || { echo "ERROR: run prepare_wireless_mainline_wsl.sh first" >&2; exit 1; }
[ -d "$BT_BUILD" ] || { echo "ERROR: Bluetooth source staging is missing" >&2; exit 1; }
[ -s "$PORT_REPO/patches/uwe5621ds-aml/0001-linux-6.1-w132d.patch" ] || {
	echo "ERROR: WiFi port patch not found under $PORT_REPO" >&2
	exit 1
}

echo '=== refresh clean wireless source staging ==='
"$MAINLINE_DIR/scripts/prepare_wireless_mainline_wsl.sh"

echo '=== prepare Linux 7.1 kernel configuration ==='
"$MAINLINE_DIR/scripts/prepare_mainline_kernel_wsl.sh"
"$KERNEL_DIR/scripts/config" --file "$KERNEL_DIR/.config" \
	--module CONFIG_CFG80211 \
	--module CONFIG_RFKILL \
	--module CONFIG_BT \
	--module CONFIG_BT_HCIUART \
	--enable CONFIG_BT_HCIUART_H4 \
	--disable CONFIG_BT_HCIUART_BCSP \
	--disable CONFIG_BT_HCIUART_3WIRE \
	--disable CONFIG_BT_HCIUART_LL \
	--disable CONFIG_BT_HCIUART_ATH3K \
	--disable CONFIG_BT_HCIUART_INTEL \
	--disable CONFIG_BT_HCIUART_BCM \
	--disable CONFIG_BT_HCIUART_QCA \
	--disable CONFIG_BT_HCIUART_AG6XX \
	--disable CONFIG_BT_HCIUART_MRVL \
	--module CONFIG_CRYPTO_KPP \
	--module CONFIG_CRYPTO_ECC \
	--module CONFIG_CRYPTO_ECDH \
	--module CONFIG_CRYPTO_CMAC
make -C "$KERNEL_DIR" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" LOCALVERSION= olddefconfig >/dev/null

echo '=== build Linux 7.1 wireless dependency modules ==='
make -C "$KERNEL_DIR" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" \
	LOCALVERSION= modules -j"$(nproc)"

echo '=== apply W132D WiFi and Bluetooth compatibility patches ==='
patch -d "$WIFI_BUILD" -p1 --forward --batch < \
	"$PORT_REPO/patches/uwe5621ds-aml/0001-linux-6.1-w132d.patch"
patch -d "$WIFI_BUILD" -p1 --forward --batch < \
	"$MAINLINE_DIR/patches/uwe5621ds-aml/0002-mainline-carddetect.patch"
install -m 0644 "$PORT_REPO/patches/uwe5621ds-aml/compat.h" \
	"$WIFI_BUILD/unisocwifi/compat.h"
patch -d "$STAGE/src/uwe5631-aml" -p1 --forward --batch < \
	"$PORT_REPO/patches/uwe5631-aml/0001-sdio-rx-bounds.patch"
patch -d "$BT_BUILD" -p1 --forward --batch < \
	"$PORT_REPO/patches/uwe5631-aml/0002-w132d-board-integration.patch"

# Linux 7.1 removed the old <linux/of_gpio.h> number-based DT helpers. Keep
# the vendor driver's integer GPIO storage for this first port, but resolve
# each property through the supported descriptor API. The DTS uses the normal
# <name>-gpios spelling, while callers can keep their historical names.
cat > "$WIFI_BUILD/unisocwcn/include/w132d_of_gpio_compat.h" <<'EOF'
#ifndef __W132D_OF_GPIO_COMPAT_H
#define __W132D_OF_GPIO_COMPAT_H

#include <linux/errno.h>
#include <linux/gpio/consumer.h>
#include <linux/of.h>

static inline int w132d_of_get_named_gpio(const struct device_node *np,
						const char *name, int index)
{
	struct gpio_desc *desc;
	int gpio;

	desc = fwnode_gpiod_get_index((struct fwnode_handle *)of_fwnode_handle(np), name, index,
					     GPIOD_ASIS, "uwe5622");
	if (IS_ERR(desc))
		return PTR_ERR(desc);
	/* The vendor driver still calls gpio_request() on the returned number.
	 * Release the descriptor acquired by fwnode_gpiod_get_index() first, or
	 * every subsequent legacy request fails with -EBUSY. */
	gpio = desc_to_gpio(desc);
	gpiod_put(desc);
	return gpio;
}

#define of_get_named_gpio(np, name, index) \
	w132d_of_get_named_gpio((np), (name), (index))

#endif
EOF
mkdir -p "$WIFI_BUILD/unisocwcn/include/linux" "$BT_BUILD/include"
cat > "$WIFI_BUILD/unisocwcn/include/linux/wakelock.h" <<'EOF'
#ifndef _W132D_LINUX_WAKELOCK_H
#define _W132D_LINUX_WAKELOCK_H

#include <linux/device.h>
#include <linux/jiffies.h>
#include <linux/pm_wakeup.h>

enum { WAKE_LOCK_SUSPEND, WAKE_LOCK_TYPE_COUNT };

struct wake_lock { struct wakeup_source *ws; };

static inline void wake_lock_init(struct wake_lock *lock, int type,
				  const char *name)
{
	(void)type;
	lock->ws = wakeup_source_register(NULL, name);
}

static inline void wake_lock_destroy(struct wake_lock *lock)
{
	wakeup_source_unregister(lock->ws);
	lock->ws = NULL;
}

static inline void wake_lock(struct wake_lock *lock)
{
	if (lock->ws)
		__pm_stay_awake(lock->ws);
}

static inline void wake_lock_timeout(struct wake_lock *lock, long timeout)
{
	if (lock->ws)
		__pm_wakeup_event(lock->ws, jiffies_to_msecs(timeout));
}

static inline void wake_unlock(struct wake_lock *lock)
{
	if (lock->ws)
		__pm_relax(lock->ws);
}

static inline int wake_lock_active(struct wake_lock *lock)
{
	return lock->ws ? lock->ws->active : 0;
}

#endif
EOF
install -m 0644 "$WIFI_BUILD/unisocwcn/include/linux/wakelock.h" \
	"$BT_BUILD/include/wakelock.h"
# The 7.1 wakeup_source API is pointer-based. Convert the vendor's embedded
# source fields and calls before kbuild sees them.
for file in \
	"$WIFI_BUILD/unisocwcn/sdio/sdiohal.h" \
	"$WIFI_BUILD/unisocwcn/platform/wcn_txrx.h" \
	"$WIFI_BUILD/unisocwcn/sleep/sdio_int.h"; do
	sed -i \
		-e 's/struct wakeup_source tx_ws;/struct wakeup_source *tx_ws;/' \
		-e 's/struct wakeup_source rx_ws;/struct wakeup_source *rx_ws;/' \
		-e 's/struct wakeup_source scan_ws;/struct wakeup_source *scan_ws;/' \
		-e 's/struct wakeup_source[[:space:]]*rw_wake_lock;/struct wakeup_source *rw_wake_lock;/' \
		-e 's/struct wakeup_source pub_int_ws;/struct wakeup_source *pub_int_ws;/' \
		"$file"
done
for file in "$WIFI_BUILD/unisocwcn/sdio/sdiohal_common.c" \
	"$WIFI_BUILD/unisocwcn/sleep/sdio_int.c" \
	"$WIFI_BUILD/unisocwcn/platform/wcn_txrx.c"; do
	sed -i \
		-e 's/wakeup_source_init(\&p_data->tx_ws, /p_data->tx_ws = wakeup_source_register(NULL, /' \
		-e 's/wakeup_source_init(\&p_data->rx_ws, /p_data->rx_ws = wakeup_source_register(NULL, /' \
		-e 's/wakeup_source_init(\&p_data->scan_ws, /p_data->scan_ws = wakeup_source_register(NULL, /' \
		-e 's/wakeup_source_trash(\&p_data->tx_ws)/wakeup_source_unregister(p_data->tx_ws)/' \
		-e 's/wakeup_source_trash(\&p_data->rx_ws)/wakeup_source_unregister(p_data->rx_ws)/' \
		-e 's/wakeup_source_trash(\&p_data->scan_ws)/wakeup_source_unregister(p_data->scan_ws)/' \
		-e 's/wakeup_source_init(\&(sdio_int\.pub_int_ws), /sdio_int.pub_int_ws = wakeup_source_register(NULL, /' \
		-e 's/wakeup_source_trash(\&(sdio_int\.pub_int_ws))/wakeup_source_unregister(sdio_int.pub_int_ws)/' \
		-e 's/wakeup_source_init(\&ring_dev->rw_wake_lock, /ring_dev->rw_wake_lock = wakeup_source_register(NULL, /' \
		-e 's/wakeup_source_trash(\&ring_dev->rw_wake_lock)/wakeup_source_unregister(ring_dev->rw_wake_lock)/' \
		-e 's/\&p_data->\(tx_ws\|rx_ws\|scan_ws\)/p_data->\1/g' \
		-e 's/\&p_data->\(tx_wl\|rx_wl\|scan_wl\)\.ws/p_data->\1.ws/g' \
		-e 's/\&sdio_int\.pub_int_wakelock\.ws/sdio_int.pub_int_wakelock.ws/g' \
		-e 's/\&ring_dev->rw_wake_lock\.ws/ring_dev->rw_wake_lock.ws/g' \
		-e 's/\&sdio_int\.pub_int_ws/sdio_int.pub_int_ws/g' \
		"$file"
done
sed -i \
	-e 's/static int[[:space:]]\+marlin_remove(struct platform_device \*pdev)/static void marlin_remove(struct platform_device *pdev)/' \
	-e '/static int marlin_remove/,/^}/ s/return 0;/return;/' \
	-e '/static void marlin_remove/,/^}/ s/return 0;/return;/' \
	"$WIFI_BUILD/unisocwcn/platform/wcn_boot.c"
find "$WIFI_BUILD/unisocwcn" -type f \( -name '*.c' -o -name '*.h' \) \
	-exec sed -i 's@#include <linux/of_gpio.h>@#include <linux/of.h>\n#include <linux/gpio.h>\n#include <linux/gpio/consumer.h>@' {} +
# The Bluetooth tty-over-SDIO source carries the same obsolete include, but
# does not use its number-based helpers.  Keep the source buildable against
# Linux 7.1 without introducing a second GPIO compatibility layer.
find "$BT_BUILD" -type f \( -name '*.c' -o -name '*.h' \) \
	-exec sed -i 's@#include <linux/of_gpio.h>@#include <linux/of.h>\n#include <linux/gpio.h>\n#include <linux/gpio/consumer.h>@' {} +
# Linux 7.1 keeps of_find_device_by_node() in the platform OF API header.
# The vendor BSP used to receive this declaration indirectly from headers
# that no longer include it, so add it only to the files that call the API.
while IFS= read -r file; do
	grep -q '^#include <linux/of_platform.h>$' "$file" || \
		sed -i '1i#include <linux/of_platform.h>' "$file"
done < <(grep -rl --include='*.c' 'of_find_device_by_node' "$WIFI_BUILD/unisocwcn" || true)
find "$WIFI_BUILD/unisocwcn" -type f -name '*.c' \
	-exec sed -i 's/class_create(THIS_MODULE, /class_create(/g' {} +
# cfg80211 moved a few callback arguments in newer kernels.  Keep the
# vendor callbacks source-compatible for this first STA bring-up; callbacks
# that are not exercised by normal scan/connect are linked as warnings.  The
# two notification helpers below do require the current wireless_dev object.
sed -i \
	-e 's/cfg80211_new_sta(vif->ndev,/cfg80211_new_sta(\&vif->wdev,/' \
	-e 's/cfg80211_del_sta(vif->ndev,/cfg80211_del_sta(\&vif->wdev,/' \
	"$WIFI_BUILD/unisocwifi/cfg80211.c"
# Linux 7.1 passes struct wireless_dev to add_key/del_key. The vendor
# callbacks still use the old net_device type; letting that mismatch compile
# makes WPA key installation treat wireless_dev as net_device and crash.
perl -0pi -e 's/static int sprdwl_cfg80211_add_key\(struct wiphy \*wiphy, struct net_device \*ndev,/static int sprdwl_cfg80211_add_key(struct wiphy *wiphy, struct wireless_dev *wdev,/' \
	"$WIFI_BUILD/unisocwifi/cfg80211.c"
perl -0pi -e 's/(static int sprdwl_cfg80211_add_key.*?\n\{\n)\tstruct sprdwl_vif \*vif = netdev_priv\(ndev\);/$1\tstruct net_device *ndev = wdev ? wdev->netdev : NULL;\n\tstruct sprdwl_vif *vif;\n\n\tif (!ndev || !params)\n\t\treturn -ENODEV;\n\tvif = netdev_priv(ndev);\n\tif (!vif || key_index > SPRDWL_MAX_KEY_INDEX)\n\t\treturn -EINVAL;/s' \
	"$WIFI_BUILD/unisocwifi/cfg80211.c"
perl -0pi -e 's/static int sprdwl_cfg80211_del_key\(struct wiphy \*wiphy, struct net_device \*ndev,/static int sprdwl_cfg80211_del_key(struct wiphy *wiphy, struct wireless_dev *wdev,/' \
	"$WIFI_BUILD/unisocwifi/cfg80211.c"
perl -0pi -e 's/(static int sprdwl_cfg80211_del_key.*?\n\{\n)\tstruct sprdwl_vif \*vif = netdev_priv\(ndev\);/$1\tstruct net_device *ndev = wdev ? wdev->netdev : NULL;\n\tstruct sprdwl_vif *vif;\n\n\tif (!ndev)\n\t\treturn -ENODEV;\n\tvif = netdev_priv(ndev);\n\tif (!vif)\n\t\treturn -ENODEV;/s' \
	"$WIFI_BUILD/unisocwifi/cfg80211.c"
# Apply the same wireless_dev conversion to station callbacks. These are
# queried immediately after association by common userspace tools.
for callback in add_station del_station change_station get_station; do
	perl -0pi -e "s/(static int sprdwl_cfg80211_${callback}\\(.*?struct )net_device \\*ndev/\${1}wireless_dev *wdev/sg" \
		"$WIFI_BUILD/unisocwifi/cfg80211.c"
done
sed -i '/sprdwl_cfg80211_change_station/,/^}/ s/struct net_device \*ndev/struct wireless_dev *wdev/' \
	"$WIFI_BUILD/unisocwifi/cfg80211.c"
perl -0pi -e 's/(static int sprdwl_cfg80211_del_station.*?\n\{\n)\tstruct sprdwl_vif \*vif = netdev_priv\(ndev\);/$1\tstruct net_device *ndev = wdev ? wdev->netdev : NULL;\n\tstruct sprdwl_vif *vif;\n\n\tif (!ndev)\n\t\treturn -ENODEV;\n\tvif = netdev_priv(ndev);\n\tif (!vif)\n\t\treturn -ENODEV;/s' \
	"$WIFI_BUILD/unisocwifi/cfg80211.c"
perl -0pi -e 's/(static int sprdwl_cfg80211_get_station.*?\n\{\n)\tstruct sprdwl_vif \*vif = netdev_priv\(ndev\);/$1\tstruct net_device *ndev = wdev ? wdev->netdev : NULL;\n\tstruct sprdwl_vif *vif;\n\n\tif (!ndev)\n\t\treturn -ENODEV;\n\tvif = netdev_priv(ndev);\n\tif (!vif)\n\t\treturn -ENODEV;/sg' \
	"$WIFI_BUILD/unisocwifi/cfg80211.c"
# Linux 7.1 wraps beacon updates in cfg80211_ap_update and adds a radio index
# to set_wiphy_params. The underlying vendor helpers keep their old payload.
perl -0pi -e 's/(static int sprdwl_cfg80211_change_beacon\(struct wiphy \*wiphy,\n\s*struct net_device \*ndev,\n)\s*struct cfg80211_beacon_data \*beacon\)/$1\t\t\t\t\t struct cfg80211_ap_update *info)/; s/(static int sprdwl_cfg80211_change_beacon.*?\n\{\n)\tstruct sprdwl_vif \*vif = netdev_priv\(ndev\);/$1\tstruct cfg80211_beacon_data *beacon = \&info->beacon;\n\tstruct sprdwl_vif *vif = netdev_priv(ndev);/s' \
	"$WIFI_BUILD/unisocwifi/cfg80211.c"
perl -0pi -e 's/static int sprdwl_cfg80211_set_wiphy_params\(struct wiphy \*wiphy, u32 changed\)/static int sprdwl_cfg80211_set_wiphy_params(struct wiphy *wiphy, int radio_idx, u32 changed)/' \
	"$WIFI_BUILD/unisocwifi/cfg80211.c"
perl -0pi -e 's/(static int sprdwl_cfg80211_tdls_mgmt\(struct wiphy \*wiphy,\n\s*struct net_device \*ndev, const u8 \*peer,\n)/$1#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 1, 0)\n\t\t\t\t     int link_id,\n#endif\n/' \
	"$WIFI_BUILD/unisocwifi/cfg80211.c"
sed -i '1i#include <linux/timer.h>' "$WIFI_BUILD/unisocwifi/cfg80211.c"
sed -i \
	-e 's/del_timer_sync(/timer_delete_sync(/g' \
	-e 's/from_timer(priv, t, scan_timer)/container_of(t, struct sprdwl_priv, scan_timer)/g' \
	"$WIFI_BUILD/unisocwifi/cfg80211.c"
find "$WIFI_BUILD/unisocwifi" -type f -name '*.c' -exec sed -i \
	-e 's/del_timer_sync(/timer_delete_sync(/g' \
	-e 's/del_timer(/timer_delete(/g' {} +
sed -i 's/from_timer(ack_info, t, timer)/container_of(t, struct sprdwl_tcp_ack_info, timer)/g' \
	"$WIFI_BUILD/unisocwifi/tcp_ack.c"
sed -i 's/from_timer(priv, t, wmmac\.wmmac_edcaf_timer)/container_of(t, struct sprdwl_priv, wmmac.wmmac_edcaf_timer)/g' \
	"$WIFI_BUILD/unisocwifi/qos.c"
sed -i 's/from_timer(ba_node, t, reorder_timer)/container_of(t, struct rx_ba_node, reorder_timer)/g' \
	"$WIFI_BUILD/unisocwifi/reorder.c"
find "$WIFI_BUILD/unisocwifi" -type f -name '*.c' -exec sed -i '1i#include <linux/timer.h>' {} +
printf 'ccflags-y += -include linux/timer.h\n' >> "$WIFI_BUILD/unisocwifi/Makefile"
printf 'ccflags-y += -Wno-error=incompatible-pointer-types\n' >> "$WIFI_BUILD/unisocwifi/Makefile"
printf '\nccflags-y += -include $(src)/include/w132d_of_gpio_compat.h\n' >> \
	"$WIFI_BUILD/unisocwcn/Makefile"
# Keep the Rockchip vendor ordering: the WCN module obtains the host from its
# SDIO function probe, after the mainline MMC host has actually enumerated.

rm -rf "$OUT"
mkdir -p "$OUT"

make_module() {
	local module_dir=$1
	shift
	make -C "$KERNEL_DIR" \
		ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" \
		M="$module_dir" "$@" modules
}

echo '=== build UWE5622 WCN BSP ==='
make_module "$WIFI_BUILD/unisocwcn" \
	CONFIG_RK_WIFI_DEVICE_UWE5622=y \
	CONFIG_WCN_SDIO=y \
	CONFIG_WCN_SLP=y \
	CONFIG_WCN_SWD=y \
	CONFIG_CHECK_DRIVER_BY_CHIPID=y \
	CONFIG_WCN_BOOT=y \
	CONFIG_WCN_UTILS=y \
	CONFIG_CP2_ASSERT=y \
	CONFIG_WCN_RESET_PIN_CONNECTED=y \
	CONFIG_WCN_POWER_UP_DOWN=y \
	CONFIG_BT_WAKE_HOST_EN=y \
	CONFIG_CUSTOMIZE_SDIO_IRQ_TYPE=3 \
	CONFIG_SDIO_BLKSIZE_512=y \
	UNISOC_FW_PATH_CONFIG=/lib/firmware/uwe5622/ \
	TARGET_BUILD_VARIANT=user

echo '=== build UWE5622 WiFi ==='
make_module "$WIFI_BUILD/unisocwifi" \
	CONFIG_WLAN_UWE5622=m \
	UNISOC_WIFI_USE_DTS=y \
	KBUILD_EXTRA_SYMBOLS="$WIFI_BUILD/unisocwcn/Module.symvers" \
	UNISOC_BSP_INCLUDE="$WIFI_BUILD/unisocwcn/include" \
	UNISOC_WIFI_CUS_CONFIG=/lib/firmware/uwe5622/ \
	UNISOC_WIFI_MAC_FILE=/lib/firmware/uwe5622/wifimac.txt

echo '=== build UWE5622 Bluetooth tty-over-SDIO ==='
make -C "$KERNEL_DIR" \
	ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" \
	M="$BT_BUILD" \
	CURFOLDER="$WIFI_BUILD/unisocwcn" \
	UNISOC_BSP_INCLUDE="$WIFI_BUILD/unisocwcn/include" \
	KBUILD_EXTRA_SYMBOLS="$WIFI_BUILD/unisocwcn/Module.symvers" \
	modules

echo '=== build W132D Bluetooth HCI helper ==='
"${CROSS_COMPILE}gcc" -O2 -Wall -Wextra -Werror -std=c11 -static \
	-o "$OUT/w132d-btattach" "$PORT_REPO/tools/w132d-btattach.c"

install -m 0644 "$WIFI_BUILD/unisocwcn/uwe5622_bsp_sdio.ko" "$OUT/"
install -m 0644 "$WIFI_BUILD/unisocwifi/sprdwl_ng.ko" "$OUT/"
install -m 0644 "$BT_BUILD/sprdbt_tty.ko" "$OUT/"
mkdir -p "$OUT/base"
for module in \
	"$KERNEL_DIR/net/wireless/cfg80211.ko" \
	"$KERNEL_DIR/net/rfkill/rfkill.ko" \
	"$KERNEL_DIR/net/bluetooth/bluetooth.ko" \
	"$KERNEL_DIR/drivers/bluetooth/hci_uart.ko" \
	"$KERNEL_DIR/crypto/kpp.ko" \
	"$KERNEL_DIR/crypto/ecc.ko" \
	"$KERNEL_DIR/crypto/ecdh_generic.ko" \
	"$KERNEL_DIR/crypto/cmac.ko"; do
	[ -s "$module" ] || { echo "ERROR: missing base wireless module $module" >&2; exit 1; }
	install -m 0644 "$module" "$OUT/base/"
done
install -m 0644 "$PORT_REPO/rootfs/w132d-bluetooth.service" "$OUT/"

for module in "$OUT"/*.ko; do
	echo "=== $module ==="
	modinfo "$module" | grep -E '^(filename|license|description|depends|name|vermagic):' || true
done

file "$OUT"/*.ko "$OUT/base"/*.ko "$OUT/w132d-btattach"
printf 'WIRELESS_MAINLINE_BUILD_DONE %s\n' "$OUT"
