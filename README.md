# ZTE W132D mainline Linux port

This repository contains the public board description, patches, build helpers,
and test notes for the ZTE Cloud Computer W132D (Rockchip RK3528). The active
`main` branch targets an upstream Linux v7.1 based kernel and is intended to
replace the vendor kernel over time.

The historical vendor Linux 6.1 snapshot is preserved locally and on the
remote as branch `vendor-6.1`. It is reference material, not the runtime target
of the mainline branch.

## Current hardware status

The latest mainline image was tested on real W132D hardware with the following
results:

| Function | Status |
| --- | --- |
| eMMC root filesystem | Working |
| USB2 host | Working |
| USB3 host | Working |
| Wired Ethernet (RMII) | Working |
| UWE5622 Wi-Fi | Working |
| UWE5622 Bluetooth | Working |
| 3.5 mm audio | Not being adapted |
| Infrared | Not being adapted |
| HDMI display output | Intentionally disabled in this snapshot; porting is deferred |

The display path is omitted from the W132D device tree and disabled in the
mainline kernel configuration. No display driver, display endpoint, display
patch, or display boot argument is part of this snapshot.

## Repository layout

- `board/`: W132D Linux v7.1 DTS and draft Armbian board metadata.
- `boot/`: serial/eMMC boot templates for the verified vendor boot chain.
- `patches/`: USB2/USB host changes and wireless driver compatibility patches.
- `drivers/`: retained USB2 research source; the build uses the corresponding
  patch in `patches/`.
- `rootfs/`: wireless service, Bluetooth HCI service, and rootfs growth helper.
- `scripts/`: DTB/kernel, wireless module, and complete-image build helpers.
- `tools/`: the W132D Bluetooth HCI initialization helper.
- `docs/`: build, reference, wireless-porting, and status notes.

Generated images, kernel modules, boot blobs, Android backups, calibration
files, and firmware are intentionally excluded by `.gitignore`.

## Mainline build

The helpers expect a Linux v7.1 checkout at `/root/w132d-build/linux-v7.1`
inside WSL2 by default. Override paths with environment variables when needed.

```bash
export W132D_MAINLINE_DIR=/path/to/w132d-armbian-port-repo
export W132D_MAINLINE_KERNEL_DIR=/root/w132d-build/linux-v7.1

bash scripts/build_mainline_kernel_wsl.sh
bash scripts/prepare_wireless_mainline_wsl.sh
bash scripts/build_wireless_mainline_wsl.sh
```

Complete image assembly additionally needs a private, legally obtained
Armbian rootfs/image, the verified W132D boot blobs, and the original WCN
firmware. The scripts extract those inputs locally and never add them to Git.
See [docs/BUILDING.md](docs/BUILDING.md) and [docs/WIRELESS_PORTING.md](docs/WIRELESS_PORTING.md).

The vendor SPL/U-Boot is reused only as a temporary boot chain. Mainline
U-Boot support is a separate future task.

## Licensing and redistribution

This is a mixed-license repository. Original helper code is MIT; the W132D DTS
is `(GPL-2.0+ OR MIT)`; Linux-derived compatibility patches are GPL-2.0-only.
The notices in [LICENSE](LICENSE), [LICENSES/](LICENSES/), and
[THIRD_PARTY.md](THIRD_PARTY.md) are part of the source distribution.

Third-party source trees, vendor boot firmware, WCN firmware, calibration data,
and generated images retain their own licenses and are not relicensed or
redistributed by this repository.
