# 硬件支持

适用设备：ZTE Cloud Computer W132D，SoC 为 RK3528，无线模块为 UWE5621DS。其他外观相似的云终端或无线模块变体不在适配范围内。

## 功能范围

| 功能 | 当前适配范围 |
|---|---|
| 存储 | eMMC，包含 HS400 Enhanced Strobe 配置 |
| 网络 | 千兆有线网络、UWE5621DS Wi-Fi；有线 MAC 按 OTP 派生 |
| USB | USB 2.0 外设与 Rockchip USB 下载模式 |
| 蓝牙 | 原生 HCI、BlueZ、BLE 遥控按键 |
| 红外 | NEC 0x22 遥控键表 |
| 模拟音频 | RK3528 DAC 3.5 mm 输出、ES7202 麦克风输入 |
| HDMI | 1080p60、热插拔、音频、CEC；更高分辨率见下文 |
| 图形与视频 | Lima GPU 驱动、RKVDEC H.264 / HEVC；应用需支持相应加速接口 |
| 系统管理 | 温控、DVFS、watchdog、pstore、面板指示灯 |
| 待机 | 软件待机；系统与网络服务继续运行 |

## HDMI 分辨率

| 模式 | 支持状态 |
|---|---|
| 1920×1080@60Hz | 支持 |
| 2560×1440 | 驱动已配置，实机兼容性待确认 |
| 3840×2160@30Hz / 60Hz | 驱动已配置，实机兼容性待确认 |

实际可用模式取决于显示器 EDID 和连接链路。4K 尚未列入确认可用的模式范围，HDMI 输出分辨率也不代表视频解码或桌面渲染性能。

## 已知限制

- 不提供 HDCP、CVBS 和系统 suspend 支持。
- BLE 遥控器桥接针对支持的设备协议，不能覆盖所有蓝牙遥控器。
- 公开镜像接收原始语音帧，不包含私有解码器；语音识别需自行配置解码组件和应用。
- Linux amd64、Linux arm64、macOS arm64 提供随包刷写工具；Windows 需自行准备兼容工具，其 USB 刷写路径尚未确认实机兼容性。
- fnOS 为独立实验镜像，不适用本项目的 Armbian 内核 APT 升级流程。

## 无线驱动兼容名称

UWE5621DS 使用 Marlin3E 固件协议。驱动保留 `uwe5622_bsp_sdio`、`sprdwl_ng`、`sprdbt_tty` 模块名和 `uwe5622` 固件目录，以兼容现有接口；这些名称不表示板上芯片为 UWE5622 或 UWE5623。

驱动与固件来源见 [SOURCES.json](../userpatches/extensions/w132d/drivers/SOURCES.json) 和 [config/sources.json](../config/sources.json)。
