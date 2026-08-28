# 主线构建说明

主线构建默认使用的本地源码检出路径是：

```text
/root/w132d-build/linux-v7.1.10
```

源码固定在 Linux stable v7.1.10 提交 `8d4e6356173a7b2e4a6a8ee1669060c33528fdb9`。kernel.org 官方 `linux-7.1.10.tar.xz` 的 SHA-256 是 `67d2f4697a02f3bec98e744b1bdc307e920c24bb4e88b5ee97dc9a34e9aa9999`。准备脚本会拒绝其他内核版本。DTB 辅助脚本只把 W132D 板级文件复制到该检出，并增加一个本地 Makefile 目标，不会修改 vendor 内核工作树。两个辅助脚本都根据自身位置推导工作区路径，因此不依赖 Windows 工作区路径的编码。

镜像组装辅助脚本使用已有的 Armbian/Debian trixie 最小镜像作为 rootfs 来源，使用主线 `out/Image` 和 DTB，以及已验证的 vendor `head.bin` 和 `p2_uboot-wdt.img` 作为私有启动输入。它只写入 `out/images/`，不会替换 vendor 镜像。

在提升权限的 WSL Debian shell 中执行：

```bash
bash scripts/build_mainline_kernel_wsl.sh
bash scripts/assemble_mainline_image_wsl.sh
```

脚本生成带时间戳名称的未压缩 `.img`，并在旁边生成 `.sha256` 文件。脚本需要 `sgdisk`、`mkfs.vfat`、`mkfs.ext4`、`mkimage` 和 `rsync`。默认私有输入目录是 `/mnt/c/Users/a8ec29b/w132d-armbian`；如果启动 blob 存放在其他位置，可用 `W132D_PRIVATE_DIR` 覆盖。当前明确不支持只导出分区；经过测试的刷写流程使用完整镜像。

已知可用的 vendor SPL/U-Boot 只在首次内核 bring-up 阶段作为启动链复用。主线 U-Boot 是独立项目，本仓库不假设它已经能启动本板。

ophub CD1000 的布局可作为未来 Armbian 启动文件系统的参考：`Image`、`uInitrd`、`dtb/rockchip/<board>.dtb` 和由 `boot.cmd` 加载的 `armbianEnv.txt`。其中 `bootloader.bin` 和 vendor 6.1 DTB 必须与主线板级定义分开。

---

# Mainline Build Notes

The default local source checkout used for the mainline build is:

```text
/root/w132d-build/linux-v7.1.10
```

It is pinned to Linux stable v7.1.10 commit `8d4e6356173a7b2e4a6a8ee1669060c33528fdb9`. The SHA-256 of kernel.org's official `linux-7.1.10.tar.xz` is `67d2f4697a02f3bec98e744b1bdc307e920c24bb4e88b5ee97dc9a34e9aa9999`. The preparation helper rejects other kernel versions. The DTB helper copies only the W132D board file into that checkout and adds one local Makefile target. It does not modify the vendor kernel worktree. Both helpers derive the workspace path from their own location, so they do not depend on the encoding of the Windows workspace path.

The image assembly helper uses an existing Armbian/Debian trixie minimal image as a rootfs source, the mainline `out/Image` and DTB, and the already verified vendor `head.bin` plus `p2_uboot-wdt.img` as private boot inputs. It writes only to `out/images/` and never replaces vendor images.

From an elevated WSL Debian shell:

```bash
bash scripts/build_mainline_kernel_wsl.sh
bash scripts/assemble_mainline_image_wsl.sh
```

The result is an uncompressed `.img` with a timestamped name and adjacent `.sha256` file. The script requires `sgdisk`, `mkfs.vfat`, `mkfs.ext4`, `mkimage`, and `rsync`. The default private input directory is `/mnt/c/Users/a8ec29b/w132d-armbian`; override it with `W132D_PRIVATE_DIR` if the boot blobs are stored elsewhere. Raw partition-only export is intentionally unsupported; the tested flashing workflow uses a complete image.

The known-good vendor SPL/U-Boot is deliberately reused only for this first kernel bring-up. Mainline U-Boot is a separate project and is not assumed to boot this board.

The ophub CD1000 layout is useful for the eventual Armbian boot filesystem: `Image`, `uInitrd`, `dtb/rockchip/<board>.dtb`, and an `armbianEnv.txt` loaded by `boot.cmd`. Its `bootloader.bin` and vendor 6.1 DTB must remain separate from the mainline board definition.
