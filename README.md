# ZTE W132D Armbian port

这是中兴云电脑 W132D（Rockchip RK3528、2 GiB DDR4、32 GiB eMMC）的实验性
Armbian 适配资料库。仓库保存可审查的设备树、补丁、辅助程序、构建方法和验证方法；不保存
原机 Android 备份、专有启动固件、无线固件、板级校准数据或可刷写镜像。

当前稳定候选基于 Linux `6.1.115-vendor-rk35xx` 和 Debian 13 (trixie)。USB2、
2560x1440 HDMI、有线网络、UWE5622 Wi-Fi、蓝牙、Mali-450 GPU 基本功能已经过实机测试。
VPU 仅集成 Rockchip MPP 用户态，尚未完成系统性验收。
红外和3.5mm音频不可用。

## 重要说明

本项目的大部分分析与实现由 AI agent 辅助完成，尚未经过全面人工代码审查。它不代表
ZTE、Rockchip、Unisoc、Armbian、KryptonLee、CoreELEC 或其他上游项目的认可。仓库中记录
上游 URL 和精确 commit 仅用于在本仓库内重建补丁基线。

镜像组装依赖你合法持有的 W132D 原机备份。脚本会从本地备份中提取并校验专有组件，但不会
下载或提供它们。

## 稳定性状态

当前参考镜像（仓库中没有）：

```text
w132d-armbian-20260820-200141-UTC+8.img
SHA256 852927a4226ad4940213e1a3ac63dfce900770e3742f03c5a497bf374f0684d9
```

该镜像已连续运行超过 2 小时，越过此前约 30 分钟的固定串口帧/整机失联窗口；随后连接
Wi-Fi 并保持正常，未观察到 Oops、panic、WCN 超时或网络 watchdog。它是当前稳定候选，
不等于完成了长期压力、休眠唤醒、全部外设组合或断电一致性认证。`20260820-185142` 是已知
无法启动的坏版本，不应使用；原因见 [启动链说明](docs/BOOTCHAIN.md)。

## 仓库内容

| 路径 | 内容 | 是否建议提交 |
| --- | --- | --- |
| `board/` | W132D DTS 与 Armbian 板卡配置 | 是 |
| `boot/` | extlinux 与 U-Boot 文本启动配置 | 是 |
| `patches/linux/` | Linux HID 板级修正 | 是 |
| `patches/uwe5621ds-aml/` | Wi-Fi/WCN 的 Linux 6.1 适配补丁 | 是 |
| `patches/uwe5631-aml/` | 蓝牙 SDIO 边界检查与板级集成补丁 | 是 |
| `tools/` | W132D 蓝牙 HCI 初始化/附加程序 | 是 |
| `rootfs/` | 首次扩容脚本与 systemd 服务 | 是 |
| `scripts/` | 构建、启动链重打包、镜像组装和验证脚本 | 是 |
| `docs/` | 构建、启动链、测试和 Git 操作说明 | 是 |
| `w132d-a9/`、`vendor-blobs/`、`*.img`、`*.bin`、`*.ko` | 备份、专有输入和生成物 | 否 |


## 构建入口

先阅读 [构建说明](docs/BUILDING.md)。核心脚本均从环境变量读取本机路径，不包含用户名或
固定 Windows 目录：

```bash
export W132D_PRIVATE_DIR=/mnt/c/path/to/w132d-private
export W132D_WIFI_SRC=/path/to/uwe5621ds-aml
export W132D_BT_SRC=/path/to/uwe5631-aml
export W132D_MPP_SRC=/path/to/mpp

bash scripts/build_uwe5622_wsl.sh
bash scripts/repack_wdt_bootchain_wsl.sh
W132D_REUSE_COMPONENTS=1 bash scripts/assemble_image_wsl.sh
bash scripts/verify_image.sh
```

这些镜像操作需要 loop device、mount、chroot 和文件系统工具，必须在 WSL2 Linux 环境以
root 执行。默认输出未经 XZ 压缩的带 UTC+8 时间戳 `.img`，并写入
`W132D_PUBLISH_DIR`（未设置时为 `W132D_PRIVATE_DIR`）。

## 许可证

这是混合许可证仓库：

- 原创脚本、服务和辅助程序：MIT；
- W132D DTS：`GPL-2.0+ OR MIT`；
- Linux、UWE5621/UWE5631 衍生补丁：GPL-2.0-only；
- 第三方源码和二进制：保持各自条款，本仓库的许可证不覆盖它们。

完整说明见 [LICENSE](LICENSE) 和 [THIRD_PARTY.md](THIRD_PARTY.md)。
