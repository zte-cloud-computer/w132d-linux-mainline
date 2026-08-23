# Mainline build notes

The default local source checkout used for the mainline build is:

```text
/root/w132d-build/linux-v7.1
```

It is pinned to Linux v7.1 commit `8cd9520d35a6c38db6567e97dd93b1f11f185dc6`.
The DTB helper copies only the W132D board file into that checkout and adds one
local Makefile target. It does not modify the vendor kernel worktree. Both
helpers derive the workspace path from their own location, so they do not
depend on the encoding of the Windows workspace path.

The image assembly helper uses an existing Armbian/Debian trixie minimal image
as a rootfs source, the mainline `out/Image` and DTB, and the already verified
vendor `head.bin` plus `p2_uboot-wdt.img` as private boot inputs. It writes only
to `out/images/` and never replaces vendor images.

From an elevated WSL Debian shell:

```bash
bash scripts/build_mainline_kernel_wsl.sh
bash scripts/assemble_mainline_image_wsl.sh
```

The result is an uncompressed `.img` with a timestamped name and adjacent
`.sha256` file. The script requires `sgdisk`, `mkfs.vfat`, `mkfs.ext4`,
`mkimage`, and `rsync`. The default private input directory is
`/mnt/c/Users/a8ec29b/w132d-armbian`; override it with `W132D_PRIVATE_DIR` if
the boot blobs are stored elsewhere. Raw partition-only export is intentionally
unsupported; the tested flashing workflow uses a complete image.

The known-good vendor SPL/U-Boot is deliberately reused only for this first
kernel bring-up. Mainline U-Boot is a separate project and is not assumed to
boot this board.

The ophub CD1000 layout is useful for the eventual Armbian boot filesystem:
`Image`, `uInitrd`, `dtb/rockchip/<board>.dtb`, and an `armbianEnv.txt` loaded
by `boot.cmd`. Its `bootloader.bin` and vendor 6.1 DTB must remain separate
from the mainline board definition.
