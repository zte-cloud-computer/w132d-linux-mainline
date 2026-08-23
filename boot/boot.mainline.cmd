# SPDX-License-Identifier: MIT
# Minimal W132D mainline boot script for the already verified vendor U-Boot.
setenv bootargs "root=@ROOT_DEVICE@ rootfstype=ext4 rw rootwait console=tty0 console=ttyS0,115200n8 earlycon=uart8250,mmio32,0xff9f0000 clk_ignore_unused pd_ignore_unused"
load ${devtype} ${devnum}:${distro_bootpart} ${kernel_addr_r} /Image
load ${devtype} ${devnum}:${distro_bootpart} ${fdt_addr_r} /rockchip/rk3528-w132d.dtb
booti ${kernel_addr_r} - ${fdt_addr_r}
