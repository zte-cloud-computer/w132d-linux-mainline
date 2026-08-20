#!/bin/bash
# SPDX-License-Identifier: MIT
# Run on the W132D after first boot (as root) to verify the hardware bring-up.
set -u
failures=0

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; failures=$((failures + 1)); }

echo '=== device tree ==='
cat /proc/device-tree/model 2>/dev/null; echo
echo "kernel: $(uname -r)"

echo '=== USB controllers ==='
for c in $(find /sys/bus/usb/devices -maxdepth 2 -name '*.usb' -o -name 'usb*' 2>/dev/null); do
  [ -f "$c/idVendor" ] && echo "$c: $(cat $c/product 2>/dev/null)"
done
lsusb 2>/dev/null | sed -n '1,12p'
external_hubs=0
for dev in /sys/bus/usb/devices/*-*; do
  [ -f "$dev/bDeviceClass" ] || continue
  [ "$(cat "$dev/bDeviceClass")" = 09 ] && external_hubs=$((external_hubs + 1))
done
if [ "$external_hubs" -gt 0 ]; then
  pass "external USB2 hub enumerated"
else
  fail "external USB2 hub did not enumerate"
fi

if find /proc/device-tree -path '*usb-hub-reset-hog/line-name' -exec grep -alq 'usb-hub-reset' {} \; 2>/dev/null; then
  pass "USB hub reset GPIO hog is present in the live device tree"
else
  fail "USB hub reset GPIO hog is missing from the live device tree"
fi

echo '=== watchdog and infrared cleanup ==='
if [ -L /sys/bus/platform/drivers/dw_wdt/ffac0000.watchdog ]; then
  pass "RK3528 non-secure DesignWare watchdog driver is bound"
else
  fail "RK3528 non-secure DesignWare watchdog driver did not bind"
fi
if find /proc/device-tree -path '*pwm@ffa90030/status' -exec grep -alq 'disabled' {} \; 2>/dev/null; then
  pass "unused PWM infrared receiver is disabled"
else
  fail "unused PWM infrared receiver is not disabled"
fi
if dmesg | grep -qE 'remotectl-pwm|rk_pwm_pwr_irq|nobody cared'; then
  fail "kernel log still contains PWM infrared IRQ errors"
else
  pass "no PWM infrared IRQ errors"
fi
dmesg | grep -iE 'watchdog|dw_wdt|remotectl|nobody cared' | tail -12

echo '=== DDR runtime scaling ==='
if find /proc/device-tree -maxdepth 2 -path '*/dmc/status' -exec grep -alq 'disabled' {} \; 2>/dev/null; then
  pass "runtime Rockchip DMC scaling is disabled"
else
  fail "runtime Rockchip DMC scaling is not disabled"
fi
if [ -L /sys/bus/platform/drivers/rockchip-dmc/dmc ]; then
  fail "rockchip-dmc unexpectedly bound despite the disabled DT node"
else
  pass "rockchip-dmc driver is not bound"
fi
dmesg | grep -iE 'rockchip-dmc|current ATF version|normal_rate' | tail -12

echo '=== USB3 (dwc3) + USB2 (ehci/ohci) drivers ==='
ls /sys/bus/usb/devices/ | sed -n '1,8p'
dmesg | grep -iE 'dwc3|ehci|ohci|usb2phy' | tail -6

echo '=== UWE5622 WiFi ==='
if lsmod | awk '{print $1}' | grep -qx uwe5622_bsp_sdio; then
  pass "UWE5622 WCN BSP module loaded"
else
  fail "UWE5622 WCN BSP module is not loaded"
fi
if lsmod | awk '{print $1}' | grep -qx sprdwl_ng; then
  pass "sprdwl_ng WiFi module loaded"
else
  fail "sprdwl_ng WiFi module is not loaded"
fi
if find /sys/bus/sdio/devices -mindepth 1 -maxdepth 1 -type l 2>/dev/null | grep -q .; then
  pass "UWE5622 enumerated on SDIO1"
  find /sys/bus/sdio/devices -mindepth 1 -maxdepth 1 -type l -printf '%f\n' 2>/dev/null
else
  fail "no SDIO function enumerated"
fi
if find /sys/class/net -maxdepth 1 -type l -name 'wlan*' | grep -q .; then
  pass "WiFi network interface created"
  ip -brief link show | grep -E 'wlan|p2p' || true
else
  fail "WiFi network interface was not created"
fi
dmesg | grep -iE 'uwe|unisoc|sprdwl|sdiohal|wcnmodem' | tail -30

echo '=== UWE5622 Bluetooth ==='
if lsmod | awk '{print $1}' | grep -qx sprdbt_tty; then
  pass "sprdbt_tty module loaded"
else
  fail "sprdbt_tty module is not loaded"
fi
if [ -c /dev/ttyBT0 ]; then
  pass "ttyBT0 transport device created"
else
  fail "ttyBT0 transport device is missing"
fi
if systemctl is-active --quiet w132d-bluetooth.service; then
  pass "Marlin3 initialization/HCI attach service active"
else
  fail "w132d-bluetooth.service is not active"
  systemctl --no-pager --full status w132d-bluetooth.service || true
fi
if find /sys/class/bluetooth -mindepth 1 -maxdepth 1 -name 'hci*' 2>/dev/null | grep -q .; then
  pass "Bluetooth HCI controller registered"
  find /sys/class/bluetooth -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null
else
  fail "Bluetooth HCI controller was not registered"
fi
if timeout 10 bluetoothctl list 2>/dev/null | grep -q '^Controller '; then
  pass "BlueZ sees the Bluetooth controller"
  timeout 10 bluetoothctl list || true
else
  fail "BlueZ does not list a Bluetooth controller"
fi
rfkill list bluetooth 2>/dev/null || true
dmesg | grep -iE 'mtty|sprdbt|MARLIN_BLUETOOTH|Bluetooth|hci_uart' | tail -40

echo '=== Rockchip VPU / MPP ==='
if [ -c /dev/mpp_service ]; then
  pass "Rockchip MPP service device created"
else
  fail "/dev/mpp_service is missing"
fi
if [ -c /dev/rga ]; then
  pass "Rockchip RGA device created"
else
  fail "/dev/rga is missing"
fi
if [ -x /usr/local/bin/mpi_dec_test ] && [ -x /usr/local/bin/mpi_enc_test ]; then
  pass "Rockchip MPP decode/encode test tools installed"
else
  fail "Rockchip MPP test tools are missing"
fi
ldconfig -p 2>/dev/null | grep -E 'librockchip_(mpp|vpu)' || true
dmesg | grep -iE 'mpp_service|rkvdec|rkvenc|vdpu|vepu|rga' | tail -30

echo '=== Ethernet (GMAC0 internal phy, expect end0/eth0 up with DHCP) ==='
ip -brief link
ip -brief addr show
dmesg | grep -iE 'stmmac|rk_gmac|gmac|phy' | tail -8

echo '=== HDMI / display ==='
ls /sys/class/drm/ | sed -n '1,10p'
cat /sys/class/drm/card0-*/status 2>/dev/null | sort -u
dmesg | grep -iE 'drm|vop|hdmi' | tail -8

echo '=== eMMC ==='
lsblk | grep -E 'mmcblk|sda'

echo '=== storage / root ==='
df -h /
if [ -e /etc/.grow-rootfs-done ]; then
  pass "first-boot root filesystem expansion completed"
else
  fail "first-boot root filesystem expansion did not complete"
fi

root_bytes=$(df --output=size -B1 / | tail -1 | tr -d '[:space:]')
if [ "$root_bytes" -gt 10000000000 ]; then
  pass "root filesystem is larger than 10 GB"
else
  fail "root filesystem is still smaller than 10 GB"
fi

echo '=== kernel health ==='
if dmesg | grep -qE 'Internal error: Oops|Kernel panic|Undefined instruction'; then
  fail "kernel log contains an Oops, panic, or undefined instruction"
else
  pass "no Oops, panic, or undefined instruction in the kernel log"
fi

echo '=== result ==='
if [ "$failures" -eq 0 ]; then
  echo 'VERIFY_PASS'
else
  echo "VERIFY_FAIL ($failures checks failed)"
fi
exit "$failures"
