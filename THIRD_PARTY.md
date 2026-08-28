# 第三方来源与再分发说明

本文记录构建输入或移植参考所使用的上游项目。不表示本仓库获得这些项目的背书，也不表示本仓库向这些项目贡献了代码。

| 组件 | 上游项目与固定参考 | 本仓库内容 | 许可证处理 |
| --- | --- | --- | --- |
| Armbian 构建系统 | `https://github.com/armbian/build`（由镜像构建文档固定） | 仅包含板级元数据和构建说明 | 遵循上游 GPL-2.0 条款 |
| Linux | 上游 Linux v7.1.10，提交 `8d4e6356173a7b2e4a6a8ee1669060c33528fdb9` | 板级 DTS 和少量兼容补丁 | 源自 Linux 的补丁采用 GPL-2.0-only，见 `LICENSES/GPL-2.0-only` |
| U-Boot 工具 | `https://github.com/u-boot/u-boot` | 仅调用 FIT/镜像工具 | 未复制 U-Boot 源码；遵循上游许可证 |
| UWE5621/WCN/Wi-Fi | `https://github.com/KryptonLee/uwe5621ds-aml`，提交 `0c12c46df48da9592abc7848335482e68d23e28a` | 兼容补丁和构建说明 | 保留上游 GPL 声明；补丁采用 GPL-2.0-only |
| UWE5631 蓝牙 SDIO 串口 | `https://github.com/CoreELEC/uwe5631-aml`，提交 `08165b5d56f46b569ee6461d7082ff795efafb2e` | 兼容补丁和构建说明 | 保留上游 GPL 声明；补丁采用 GPL-2.0-only |
| Rockchip MPP | `https://github.com/rockchip-linux/mpp`，提交 `c08762ebfadeb4e986d2fed993bc7a54862d3ebe` | 仅作为可选构建参考 | 本仓库不保存 MPP 源码或二进制 |

本仓库不再分发以下私有输入：

- Android 磁盘镜像或分区；
- Rockchip SPL、loader、BL31/ATF、OP-TEE 或 vendor U-Boot FIT 数据；
- `wcnmodem.bin`、Wi-Fi/蓝牙校准文件、PSKEY/RF 配置或 MAC 数据；
- 已编译的内核模块、DTB、完整磁盘镜像或镜像哈希文件；
- 含密码、令牌、私钥或串口数据的日志和配置。

镜像组装脚本可能从用户拥有的 Android vendor 镜像中提取所需固件，写入私有 WSL staging 目录。这是本地构建操作，不代表获得再分发权。

## 兼容补丁应用范围

无线构建辅助脚本会归档上面列出的精确上游提交，然后将本仓库中的兼容补丁应用到临时构建树。Linux 6.1 兼容补丁只是迁移外置无线端口所需的输入，不会作为通用内核补丁集应用到上游 Linux 源码树。

审阅公开板级 DTS、USB 修改、无线兼容工作或构建逻辑不需要任何生成的镜像或专有组件。

---

# Third-Party Sources and Redistribution Notes

This file records the upstream projects used as build inputs or porting references. It does not imply endorsement by, or a contribution to, those projects.

| Component | Upstream and pinned reference | Repository contents | License handling |
| --- | --- | --- | --- |
| Armbian build | `https://github.com/armbian/build` (pinned by the image build notes) | Board metadata and build instructions only | Follow the upstream GPL-2.0 terms |
| Linux | Upstream Linux v7.1.10, commit `8d4e6356173a7b2e4a6a8ee1669060c33528fdb9` | Board DTS and small compatibility patches | Linux-derived patches are GPL-2.0-only; see `LICENSES/GPL-2.0-only` |
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

Image assembly scripts may extract required firmware from a user-owned Android vendor image in a private WSL staging directory. That extraction is a local build operation and does not grant redistribution rights.

## Compatibility Patch Application

The wireless build helper archives the exact upstream commits above, then applies the compatibility patches in this repository to temporary build trees. The Linux 6.1 compatibility patches are migration inputs for the out-of-tree wireless port; they are not applied to the upstream Linux tree as a generic kernel patch set.

No generated image or proprietary component is required to review the public board DTS, USB changes, wireless compatibility work, or build logic.
