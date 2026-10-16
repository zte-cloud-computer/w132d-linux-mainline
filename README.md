# ZTE W132D Linux

面向 ZTE Cloud Computer W132D（RK3528）的自行维护发行版：原生 Linux 稳定内核、W132D 本地驱动和补丁、正式 Armbian 构建框架、Debian trixie minimal。

Wi-Fi / BLE 芯片为 **UWE5621DS**。源码集中在 `userpatches/extensions/w132d/drivers/uwe5621ds/`；保留已验证的 Marlin3E 固件协议、芯片 ID，以及 `uwe5622_bsp_sdio`、`sprdwl_ng`、`sprdbt_tty` 模块名。这些兼容名称不表示板上芯片为 UWE5622 或 UWE5623。

正式版本使用 GitHub Releases 的 **Latest**，新安装设备默认使用签名的 **stable APT** 源。main 构建属于 experimental；实验镜像同样默认 stable，持续跟进 main 内核需主动切换通道。正式版本必须通过自动门禁，实机覆盖另行记录，见[硬件验证](docs/hardware.md)。

本次发布体系面向新安装设备，不提供旧实验系统的原地迁移或旧 Release `apt` 源过渡包。已有设备需要使用新发布包重新安装，并自行恢复数据。

## 使用文档

- [安装与首次启动](docs/install.md)
- [正常升级与 stable / experimental 通道](docs/upgrades.md)
- [恢复与刷写故障排查](docs/recovery.md)
- [源码构建与本地验证](docs/build.md)
- [维护、自动发版与故障重试](docs/maintenance.md)
- [硬件验证记录与限制](docs/hardware.md)

## 构建与发布

| 触发 | 内容 | 发布 |
|---|---|---|
| PR | 静态、行为、严格补丁、DTB/schema、原生 ARM64 内核包 | 不发布，不使用签名密钥 |
| main 推送 | 内核、DTB、headers、libc-dev | experimental APT 与预发布产物 |
| 每六小时 / 每日北京时间 10:43 | 同时检查 Linux stable、Armbian 正式版和维护输入变化；无变化跳过 | 完整候选通过后发布 stable |
| 手动 kernel / image | 默认 experimental；stable 强制完整镜像 | 同一套自动门禁 |
| 手动 fnOS | 显式提供基础镜像及 SHA256 | 独立实验产物，不进入 stable |

Linux 可以跨内核系列更新，RC 不自动构建；Armbian 排除 trunk、预览版和草稿。更新遇到补丁冲突、编译、验证、签名或部署失败时，保留已发布稳定版本。所有本地和 CI 入口统一为 `tools/w132d`：

```sh
tools/w132d fetch
tools/w132d build
# Optional full image build
tools/w132d build image
```

完整刷写包附带 Linux amd64、Linux arm64、macOS arm64 的本项目 rkdeveloptool 二进制、许可证和对应源码；完整 Release 也分别提供三个平台的工具压缩包。Windows PowerShell 共用同一验证引擎，需自行提供兼容工具；Windows USB 实机验证状态见硬件文档。

## 源码组织

| 目录 | 职责 |
|---|---|
| `config/` | 固定来源、摘要、构建配置与布局参数 |
| `userpatches/kernel/w132d/` | 唯一 Linux 补丁栈，按媒体、MMC、温控、显示、蓝牙与 binding 分组 |
| `userpatches/extensions/w132d/` | 本地驱动、唯一 Linux DTS/DTSI、binding、构建与 BSP 钩子 |
| `userpatches/u-boot/` | 引导器最小板级适配 |
| `userpatches/overlay/bsp-cli/` | 包管理的配置、服务、运行脚本、APT 信任与通道设置 |
| `vendor/rkdeveloptool/` | 直接维护的刷写工具源码 |
| `tools/w132dlib/` | 锁定、构建、验证、发布、APT 仓库实现 |
| `tests/` | 版本、包、隔离 APT、发布故障与刷写行为测试 |

只使用 Armbian 的 userpatches 和扩展接口；不修改构建框架本体，不维护 LKML 导出或第二份内核补丁。代码文本和发布说明使用英文，操作与维护文档使用中文。

## 许可与来源

项目工具和脚本采用 [MIT](LICENSE)；驱动、内核、U-Boot、rkdeveloptool 及 libusb 分别遵循其源文件和附带许可证。驱动导入来源及修改记录见 [SOURCES.json](userpatches/extensions/w132d/drivers/SOURCES.json)，刷写工具来源见 [SOURCE.json](vendor/rkdeveloptool/SOURCE.json)。固件和 rkbin 使用固定来源并校验 SHA256；发布清单与源码归档随版本保存。
