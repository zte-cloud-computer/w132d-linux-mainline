# 硬件验证与限制

板卡：ZTE Cloud Computer W132D，RK3528，UWE5621DS Wi-Fi / BLE。无线固件使用已验证的 Marlin3E 识别路径；历史驱动和固件目录名不用于判断芯片型号。

下表来自改造前仓库的既有实机记录，不能作为本次新内核、新驱动目录和新镜像的完整复测结论。完整 Armbian 镜像集成和真实 USB 刷写尚未完成本轮验证；自动化检查只能覆盖内核、驱动、U-Boot、BSP 和发布脚本。每个正式版本的自动验证证据保存在 Release 清单与报告中；实机测试需要另行填写具体版本。

| 功能 | 既有记录 | 本次发布体系改造后的实机复测 |
|---|---|---|
| eMMC HS400 Enhanced Strobe | 可用 | 未完成 |
| USB 2.0 / 千兆有线网络 | 可用；MAC 按 OTP 派生 | 未完成 |
| UWE5621DS Wi-Fi / Bluetooth / BLE 遥控按键 | 可用；内核注册 HCI，无用户态 attach | 未完成 |
| 红外 | 29 键 NEC 0x22 映射可用 | 未完成 |
| RK3528 DAC / ES7202 PDM | 3.5 mm 输出和麦克风输入可用 | 未完成 |
| Lima GPU / RKVDEC H.264、HEVC | 既有记录可用 | 未完成 |
| 温控、DVFS、watchdog、pstore | 既有记录可用 | 未完成 |
| 面板 LED / 软件待机 | 既有记录可用；设备本身不进入系统 suspend | 未完成 |
| HDMI 1080p60、热插拔、音频、CEC | 已有实测记录 | 未完成 |
| HDMI 2560×1440 | 有 PLL 表项，未实测 | 未验证 |
| HDCP / CVBS | 不提供支持 | 不适用 |
| Windows USB 刷写 | 未实测 | 未验证 |
| macOS arm64 / Linux arm64 新维护版工具 | 已配置 CI 原生编译与自动检查，尚未执行 | USB 实机未验证 |
| fnOS | 保留独立实验构建入口 | 新版本未复测 |

BLE 语音桥可保存原始音频帧。可选的私有语音解码器不包含在公开镜像中，不能把遥控按键或原始数据接收成功表述为公开镜像已完成语音解码验证。

## 本地自动验证记录

2026-10-15，在 Linux 容器中使用 Linux v7.2.10、Armbian v26.5.1、U-Boot v2026.07 和 GCC 14 完成以下检查。记录针对本次工作区改造，不代表已发布版本或实机测试。

| 检查 | 结果 |
|---|---|
| 原生 ARM64 内核 Image 和完整模块编译 | 通过 |
| Linux / U-Boot 严格补丁应用、W132D DTB 编译、维护的 binding 与整个 DTB schema 检查 | 通过 |
| U-Boot 编译、下载键、BL31 cookie 和引导组件边界 | 通过 |
| Armbian 实际 BSP 包生成、conffile 与运行依赖检查 | 通过 |
| Debian 服务工具在隔离根目录中首次启用服务、升级保留管理员禁用状态 | 通过 |
| 28 项隔离 APT、包、发布与刷写行为测试 | 通过；补充的旧任务跨日期重跑场景也通过 |
| Linux amd64 rkdeveloptool 静态构建、帮助与版本命令 | 通过 |
| 固定 rkbin 输入生成 USB loader | 通过 |
| 从锁定提交生成源码归档并包含构建清单 | 通过 |
| 英文文本、Python/Bash 语法、Actions 语法与 diff 空白检查 | 通过 |

GitHub Actions 尚未在远端执行，macOS arm64 / Linux arm64 二进制的原生构建与 USB 实机写入尚未验证。fnOS 未提供基础镜像，因此没有执行完整构建。完整 Armbian 镜像的本地集成验证单独记录，不能从内核或 BSP 编译通过推断镜像已经通过。

记录模板：

```text
Release:
Project commit:
Kernel version:
Board revision:
Display and mode:
Host OS and flash-tool version:
Test procedure:
Expected result:
Observed result:
Logs and checksums:
```

复测至少覆盖冷启动/热重启/断电恢复、首次扩容、持续网络传输、Wi-Fi 重连、BLE 配对与重连、显示热插拔、音频、负载温度、watchdog/pstore、stable 升级与通道退出。刷写测试覆盖单设备、双设备拒绝、错误校验和和回读中断；模拟测试和真实 USB 测试应分别记录。
