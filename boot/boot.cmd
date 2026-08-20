# SPDX-License-Identifier: MIT
# U-Boot script for ZTE Cloud Computer W132D (RK3528)
# Works with the vendor U-Boot distro-boot flow (extlinux/boot.scr scan).

setenv bootargs "root=UUID=b921b045-1df0-41c3-af44-4c6f280d3fae rw rootwait console=ttyS0,115200n8 earlycon=uart8250,mmio32,0xff9f0000"

load ${devtype} ${devnum}:${distro_bootpart} ${kernel_addr_r} /Image
load ${devtype} ${devnum}:${distro_bootpart} ${fdt_addr_r} /rockchip/rk3528-w132d.dtb
load ${devtype} ${devnum}:${distro_bootpart} ${ramdisk_addr_r} /uInitrd

booti ${kernel_addr_r} ${ramdisk_addr_r}:${filesize} ${fdt_addr_r}
