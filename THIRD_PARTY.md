# Third-party sources and redistribution notes

This file records the upstream projects used as build inputs or porting
references. It does not imply endorsement by, or a contribution to, those
projects.

| Component | Upstream and pinned reference | Repository contents | License handling |
| --- | --- | --- | --- |
| Armbian build | `https://github.com/armbian/build` (pinned by the image build notes) | Board metadata and build instructions only | Follow the upstream GPL-2.0 terms |
| Linux | Upstream Linux v7.1, commit `8cd9520d35a6c38db6567e97dd93b1f11f185dc6` | Board DTS and small compatibility patches | Linux-derived patches are GPL-2.0-only; see `LICENSES/GPL-2.0-only` |
| U-Boot tools | `https://github.com/u-boot/u-boot` | Invocation of FIT/image tools only | No U-Boot source is copied here; follow the upstream license |
| UWE5621/WCN/Wi-Fi | `https://github.com/KryptonLee/uwe5621ds-aml`, commit `0c12c46df48da9592abc7848335482e68d23e28a` | Compatibility patches and build instructions | Preserve the upstream GPL notices; patches are GPL-2.0-only |
| UWE5631 Bluetooth tty-over-SDIO | `https://github.com/CoreELEC/uwe5631-aml`, commit `08165b5d56f46b569ee6461d7082ff795efafb2e` | Compatibility patches and build instructions | Preserve the upstream GPL notices; patches are GPL-2.0-only |
| Rockchip MPP | `https://github.com/rockchip-linux/mpp`, commit `c08762ebfadeb4e986d2fed993bc7a54862d3ebe` | Optional build reference only | No MPP source or binary is stored here |

The repository does not redistribute the following private inputs:

- Android disk images or partitions;
- Rockchip SPL, loader, BL31/ATF, OP-TEE, or vendor U-Boot FIT data;
- `wcnmodem.bin`, Wi-Fi/BT calibration files, PSKEY/RF configuration, or MAC data;
- compiled kernel modules, DTBs, complete disk images, or image hash files;
- logs or configuration containing passwords, tokens, private keys, or serial data.

Image assembly scripts may extract required firmware from a user-owned Android
vendor image in a private WSL staging directory. That extraction is a local
build operation and does not grant redistribution rights.

## Compatibility patch application

The wireless build helper archives the exact upstream commits above, then
applies the compatibility patches in this repository to temporary build trees.
The Linux 6.1 compatibility patches are migration inputs for the out-of-tree
wireless port; they are not applied to the upstream Linux tree as a generic
kernel patch set.

No generated image or proprietary component is required to review the public
board DTS, USB changes, wireless compatibility work, or build logic.
