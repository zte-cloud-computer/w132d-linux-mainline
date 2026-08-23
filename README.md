# ZTE W132D 主线 Linux 移植

本仓库包含 ZTE Cloud Computer W132D（Rockchip RK3528）的公开板级描述、补丁、构建辅助脚本和测试记录。当前 `main` 分支以主线 Linux v7.1 为目标，长期目标是逐步替代 vendor 内核。

历史 vendor Linux 6.1 快照保存在本地和远端的 `vendor-6.1` 分支中。它仅用于参考，不是 `main` 分支的运行时目标。

## 当前硬件状态

最新主线镜像已在真实 W132D 硬件上测试，结果如下：

| 功能 | 状态 |
| --- | --- |
| eMMC 根文件系统 | 正常 |
| USB2 主机 | 正常 |
| USB3 主机 | 正常 |
| 有线网口（RMII） | 正常 |
| UWE5622 Wi-Fi | 正常 |
| UWE5622 蓝牙 | 正常 |
| 3.5mm 音频 | 放弃适配 |
| 红外 | 放弃适配 |
| HDMI 显示输出 | 本快照中主动禁用，移植暂缓 |

W132D 设备树中已移除显示路径，主线内核配置也禁用了显示相关选项。本快照不包含显示驱动、显示 endpoint、显示补丁或显示启动参数。

## 仓库结构

- `board/`：W132D Linux v7.1 DTS 和 Armbian 板级元数据草稿。
- `boot/`：已验证 vendor 启动链使用的串口/eMMC 启动模板。
- `patches/`：USB 主机修改和无线驱动兼容补丁。
- `drivers/`：保留的 USB2 研究源码；构建时使用 `patches/` 中的对应补丁。
- `rootfs/`：无线服务、蓝牙 HCI 服务和根文件系统扩容辅助脚本。
- `scripts/`：DTB/内核、无线模块和完整镜像构建辅助脚本。
- `tools/`：W132D 蓝牙 HCI 初始化工具。
- `docs/`：构建、参考、无线移植和状态文档。

生成的镜像、内核模块、启动 blob、Android 备份、校准文件和固件均由 `.gitignore` 排除。

## 主线构建

默认要求 WSL2 中存在 Linux v7.1 源码检出：`/root/w132d-build/linux-v7.1`。如有需要，可通过环境变量覆盖路径。

```bash
export W132D_MAINLINE_DIR=/path/to/w132d-armbian-port-repo
export W132D_MAINLINE_KERNEL_DIR=/root/w132d-build/linux-v7.1

bash scripts/build_mainline_kernel_wsl.sh
bash scripts/prepare_wireless_mainline_wsl.sh
bash scripts/build_wireless_mainline_wsl.sh
```

完整镜像组装还需要合法取得的 Armbian rootfs/镜像、已验证的 W132D 启动 blob 和原始 WCN 固件。脚本会在本地提取这些输入，绝不会加入 Git。详见 [docs/BUILDING.md](docs/BUILDING.md) 和 [docs/WIRELESS_PORTING.md](docs/WIRELESS_PORTING.md)。

vendor SPL/U-Boot 仅作为临时启动链复用。主线 U-Boot 支持属于后续独立工作。

## 许可证与再分发

本仓库包含多种许可证。原创辅助代码采用 MIT；W132D DTS 采用 `(GPL-2.0+ OR MIT)`；源自 Linux 的兼容补丁采用 GPL-2.0-only。源代码发布时必须同时保留 [LICENSE](LICENSE)、[LICENSES/](LICENSES/) 和 [THIRD_PARTY.md](THIRD_PARTY.md) 中的声明。

第三方源码树、vendor 启动固件、WCN 固件、校准数据和生成的镜像继续受其各自许可证约束，本仓库不对其重新授权或再分发。

---

# ZTE W132D Mainline Linux Port

This repository contains the public board description, patches, build helpers, and test notes for the ZTE Cloud Computer W132D (Rockchip RK3528). The active `main` branch targets an upstream Linux v7.1 based kernel and is intended to replace the vendor kernel over time.

The historical vendor Linux 6.1 snapshot is preserved locally and on the remote as branch `vendor-6.1`. It is reference material, not the runtime target of the mainline branch.

## Current Hardware Status

The latest mainline image was tested on real W132D hardware with the following results:

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

The display path is omitted from the W132D device tree and disabled in the mainline kernel configuration. No display driver, display endpoint, display patch, or display boot argument is part of this snapshot.

## Repository Layout

- `board/`: W132D Linux v7.1 DTS and draft Armbian board metadata.
- `boot/`: serial/eMMC boot templates for the verified vendor boot chain.
- `patches/`: USB host changes and wireless driver compatibility patches.
- `drivers/`: retained USB2 research source; the build uses the corresponding patch in `patches/`.
- `rootfs/`: wireless service, Bluetooth HCI service, and rootfs growth helper.
- `scripts/`: DTB/kernel, wireless module, and complete-image build helpers.
- `tools/`: the W132D Bluetooth HCI initialization helper.
- `docs/`: build, reference, wireless-porting, and status notes.

Generated images, kernel modules, boot blobs, Android backups, calibration files, and firmware are intentionally excluded by `.gitignore`.

## Mainline Build

The helpers expect a Linux v7.1 checkout at `/root/w132d-build/linux-v7.1` inside WSL2 by default. Override paths with environment variables when needed.

```bash
export W132D_MAINLINE_DIR=/path/to/w132d-armbian-port-repo
export W132D_MAINLINE_KERNEL_DIR=/root/w132d-build/linux-v7.1

bash scripts/build_mainline_kernel_wsl.sh
bash scripts/prepare_wireless_mainline_wsl.sh
bash scripts/build_wireless_mainline_wsl.sh
```

Complete image assembly additionally needs a private, legally obtained Armbian rootfs/image, the verified W132D boot blobs, and the original WCN firmware. The scripts extract those inputs locally and never add them to Git. See [docs/BUILDING.md](docs/BUILDING.md) and [docs/WIRELESS_PORTING.md](docs/WIRELESS_PORTING.md).

The vendor SPL/U-Boot is reused only as a temporary boot chain. Mainline U-Boot support is a separate future task.

## Licensing and Redistribution

This is a mixed-license repository. Original helper code is MIT; the W132D DTS is `(GPL-2.0+ OR MIT)`; Linux-derived compatibility patches are GPL-2.0-only. The notices in [LICENSE](LICENSE), [LICENSES/](LICENSES/), and [THIRD_PARTY.md](THIRD_PARTY.md) are part of the source distribution.

Third-party source trees, vendor boot firmware, WCN firmware, calibration data, and generated images retain their own licenses and are not relicensed or redistributed by this repository.
