# Third-party sources and redistribution notes

本文件记录补丁基线和构建依赖，不表示向这些项目提交过 PR，也不表示上游认可本项目。

| 组件 | 上游与精确基线 | 本仓库保存内容 | 许可判断 |
| --- | --- | --- | --- |
| Armbian build | `https://github.com/armbian/build.git` @ `48cb69f26b1a29f015f327191eebcdd6144d0038` | 板卡配置及构建说明，不复制完整源码 | 上游 GPL-2.0；依其仓库文件为准 |
| Rockchip BSP Linux | Armbian 缓存基线 `c6157104418d012823413c02f9222f3fe123dd25`，分支标识 `kernel-rk35xx-6.1` | DTS 和一项 HID 补丁 | Linux 衍生补丁按 GPL-2.0-only；DTS 文件自身为 GPL-2.0+ OR MIT |
| U-Boot 工具树 | `https://github.com/u-boot/u-boot` @ `39cd993e5d6296635438e84f4576b3a9bf76f86e` | 仅调用其 FIT 工具的脚本 | 不复制源码；上游许可证依其仓库为准 |
| UWE5621/WCN/Wi-Fi | `https://github.com/KryptonLee/uwe5621ds-aml.git` @ `0c12c46df48da9592abc7848335482e68d23e28a` | `patches/uwe5621ds-aml/` | 上游无清晰顶层 LICENSE，但相关源码文件声明 GPL v2；补丁保守按 GPL-2.0-only |
| UWE5631 蓝牙 tty-over-SDIO | `https://github.com/CoreELEC/uwe5631-aml.git` @ `08165b5d56f46b569ee6461d7082ff795efafb2e` | `patches/uwe5631-aml/` | 相关源码文件声明 GPL v2；补丁按 GPL-2.0-only |
| Rockchip MPP | `https://github.com/rockchip-linux/mpp.git` @ `c08762ebfadeb4e986d2fed993bc7a54862d3ebe` | 仅有构建引用，不保存源码或二进制 | 上游包含 Apache-2.0/MIT 许可文件；最终分发按对应文件及构建产物条款复核 |

## 补丁应用顺序

Wi-Fi/WCN：

1. 检出 `KryptonLee/uwe5621ds-aml` 的精确 commit `0c12c46...`。
2. 应用 `patches/uwe5621ds-aml/0001-linux-6.1-w132d.patch`。
3. 将 `patches/uwe5621ds-aml/compat.h` 安装为 `unisocwifi/compat.h`。

蓝牙：

1. 检出 `CoreELEC/uwe5631-aml` 的精确 commit `08165b5d...`。
2. 对 `BT/tty-sdio` 应用 `0001-sdio-rx-bounds.patch`。
3. 再应用 `0002-w132d-board-integration.patch`。

`scripts/build_uwe5622_wsl.sh` 会从精确 commit 创建干净归档后按上述顺序操作，因此本地研究
目录中的未提交改动不会悄悄进入构建。

## 不进入 Git 的材料

以下文件的来源或再分发权利不够清晰，不提交：

- 原机 Android 全盘或分区备份；
- Rockchip SPL/loader、原厂 U-Boot FIT、BL31/ATF、OP-TEE、`head.bin`；
- `wcnmodem.bin`、Wi-Fi/蓝牙 RF/PSKEY/校准 INI；
- 编译出的 `.ko`、DTB、MPP 库/工具和完整 `.img`；
- 含 Wi-Fi 密码、私钥、token、账号或未脱敏 MAC/序列号的日志和配置。

本仓库只记录必要的 SHA256、版本字符串、文件偏移和从用户自有备份中提取的方法。公开发布
可刷写镜像是另一项独立的合规决策，不能仅凭本源码仓库的 MIT/GPL 文件就推导出授权。

