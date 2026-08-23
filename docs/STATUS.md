# W132D mainline status

## Scope of this snapshot

This branch records the Linux v7.1 mainline bring-up after the hardware
validation pass. The goal is to replace the vendor kernel while retaining the
verified vendor SPL/U-Boot temporarily as the boot chain.

The display path is deliberately disabled in this snapshot. Display porting is
paused and its experimental code, patches, device-tree nodes, and boot
arguments are not part of `main`.

## Hardware matrix

| Device | Result | Notes |
| --- | --- | --- |
| eMMC | Pass | 3.3 V MMC High-Speed mode, capped at 52 MHz |
| USB2 | Pass | GM8220S hub reset held deasserted |
| USB3 | Pass | Host-only DWC3 path with RK3528 combo PHY |
| Wired Ethernet | Pass | RK3528 integrated RMII MACPHY |
| Wi-Fi | Pass | UWE5622 over SDIO1; scan and connection tested |
| Bluetooth | Pass | UWE5622 tty-over-SDIO plus userspace HCI setup |
| 3.5 mm audio | Dropped | No further adaptation planned |
| Infrared | Dropped | No further adaptation planned |
| Display output | Deferred | Disabled until a reviewed RK3528 mainline path exists |

## Mainline files

- `board/rk3528-w132d.dts` describes only the validated storage, network, USB,
  console, and wireless paths.
- `scripts/prepare_mainline_kernel_wsl.sh` applies the USB fixes, updates the
  Bluetooth command compatibility, and disables display-related kernel options.
- `scripts/build_wireless_mainline_wsl.sh` builds the WCN, Wi-Fi, Bluetooth,
  and HCI helper components against Linux v7.1.
- `scripts/assemble_mainline_image_wsl.sh` creates a complete image from
  private boot/rootfs/firmware inputs; it does not export raw partitions.

## Known boundaries

- Mainline U-Boot support is not included; verified vendor boot blobs remain
  private build inputs.
- UWE5622 firmware and calibration data are not redistributed.
- 3.5 mm audio and infrared are intentionally outside the project scope.
- No image is committed to Git. Hardware testing must use a locally assembled
  image and the normal RKDevTool workflow.

## Revalidation checklist

After a kernel or DTS change, test in this order:

1. serial console and eMMC rootfs;
2. USB2 and USB3 enumeration;
3. wired Ethernet link and DHCP;
4. Wi-Fi scan and connection;
5. Bluetooth controller creation and discovery.

Do not add display nodes or boot modes to this branch while the display port is
paused. Continue the display work from a separate experimental branch or from
the local research history.
