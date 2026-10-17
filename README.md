# ZTE W132D Linux

面向 ZTE Cloud Computer W132D 的 Debian trixie minimal 系统，基于 Linux 稳定内核和 Armbian 构建框架，提供板级驱动、USB 刷写包及签名 APT 更新源。

适用硬件为 **RK3528 + UWE5621DS** 的 W132D。硬件功能与限制见[硬件支持](docs/hardware.md)。

## 下载与安装

从 [Releases 的 Latest](https://github.com/zte-cloud-computer/w132d-linux-mainline/releases/latest) 下载 `w132d-flash.zip` 和 `SHA256SUMS`。核对摘要、解压后，按[安装指南](docs/install.md)进入 USB 下载模式并刷写。

刷写包附带 Linux amd64、Linux arm64 和 macOS arm64 的 rkdeveloptool，需要 Python 3.9+。刷写会替换系统和分区表，请先备份数据。

## 更新

新安装系统默认使用签名的 **stable** APT 源：

```sh
sudo apt update
sudo apt upgrade
sudo reboot
```

stable 提供完整镜像及配套软件包。experimental 跟随 main，需主动启用；切换和回退方法见[升级与通道](docs/upgrades.md)。

Linux、Armbian 和 U-Boot 自动跟踪上游正式版，排除 RC 和预览版。每次构建锁定具体提交；上游更新经过发布检查后进入 stable。

## 文档

| 文档 | 内容 |
|---|---|
| [安装与首次启动](docs/install.md) | 下载、刷写、首次登录 |
| [日常使用](docs/usage.md) | 音频、遥控器、软件待机、服务管理 |
| [升级与通道](docs/upgrades.md) | APT 更新、experimental、版本回退 |
| [恢复与故障排查](docs/recovery.md) | USB 刷写故障、启动日志、系统恢复 |
| [硬件支持](docs/hardware.md) | 适用设备、功能范围、已知限制 |
| [源码构建](docs/build.md) | 构建环境、锁定输入、产物 |
| [维护与发布](docs/maintenance.md) | 仓库配置、自动更新、发布与重试 |

## 源码结构

| 目录 | 内容 |
|---|---|
| `config/` | 上游快照、来源摘要、构建与布局参数 |
| `userpatches/kernel/w132d/` | Linux 板级补丁 |
| `userpatches/extensions/w132d/` | 本地驱动、设备树、binding 和 Armbian 扩展 |
| `userpatches/u-boot/w132d/` | U-Boot 板级补丁 |
| `userpatches/overlay/bsp-cli/` | 板级配置、服务、运行工具及 APT 配置 |
| `vendor/rkdeveloptool/` | 刷写工具源码 |
| `tools/` | 统一构建与发布入口 `tools/w132d` |
| `tests/` | 自动化测试 |

## 许可与来源

项目工具和脚本采用 [MIT](LICENSE)。内核、驱动、U-Boot、rkdeveloptool、libusb 和外部二进制分别遵循各自许可；项目许可证不覆盖这些组件。

驱动来源见 [SOURCES.json](userpatches/extensions/w132d/drivers/SOURCES.json)，刷写工具来源见 [SOURCE.json](vendor/rkdeveloptool/SOURCE.json)，固件和 rkbin 来源及摘要见 [config/sources.json](config/sources.json)。发布附带构建清单和对应源码。
