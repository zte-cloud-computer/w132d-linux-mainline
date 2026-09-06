# ZTE W132D 主线 Linux

在 ZTE Cloud Computer W132D（Rockchip RK3528 电视盒，出厂 Android 9）上运行主线 Linux：
Armbian（Debian trixie，minimal）+ 主线内核 7.2 + 主线 U-Boot，整盘镜像一条命令刷入。

板级支持以 [Armbian](https://github.com/armbian/build) 为上游：板级配置、内核补丁、U-Boot 补丁都按
`armbian/build` 的目录规约放在 `userpatches/` 下，可以直接作为 PR 提交；内核补丁同时维护成可投 LKML 的形态。

> [!WARNING]
> 开发阶段项目，只在少量实机上验证，且大量实现由 AI 协助生成、未经完整人工审查。
> 请把它当作硬件移植项目，而不是面向普通用户的稳定发行版。

## 硬件支持

| 功能 | 状态 | 说明 |
|---|---|---|
| eMMC | 可用 | HS400 Enhanced Strobe |
| USB 2.0 / 千兆有线 | 可用 | MAC 由 U-Boot 按 SoC OTP 派生（固定，但不等于机身标签上的出厂值） |
| Wi-Fi / 蓝牙 / BLE 语音遥控 | 可用 | UWE5623（Marlin3E）。固件取自 CoreELEC 公开仓库 [uwe5631-aml](https://github.com/CoreELEC/uwe5631-aml)，构建时按钉住的提交下载并校验。蓝牙由驱动直接注册为 hci0（内核内完成厂商初始化），无需用户态 attach |
| 红外遥控 | 可用 | rc-core，NEC |
| 3.5 mm 音频 | 可用 | 输出 acodec，输入 ES7202/PDM |
| Mali-450 GPU | 可用 | Lima，含热降频 |
| H.264 / HEVC 硬解 | 可用 | 主线 RKVDEC |
| 温控 / DVFS / 看门狗 / pstore | 可用 | |
| 面板指示灯 · 软件待机 | 可用 | 红外/BLE 电源键 |
| HDMI | 可用 | VOP2 + DesignWare HDMI + Innosilicon PHY，三个主线形态补丁；1080p60 出图（显示器与电视）、热插拔、音频（SAI3→HDMI，电视出声）、CEC 适配器已实测，2560x1440 有 PLL 表项但未实测。热插拔走 GPIO0_A2 镜像到 VO-GRF（SoC 设计如此）；VOP 不挂 IOMMU（见 docs/maintenance.md）。不做 HDCP、CVBS |

## 下载与刷写

发布包（GitHub Release）内含整盘镜像 `w132d.img`、macOS/Linux 与 Windows 的刷写脚本、Rockchip USB loader
和一份刷写说明（[flash/README.md](flash/README.md)）。

1. 设备断电，用顶针按住 HDMI 旁的 Reset 针孔，保持按住的同时接通电源，USB-A 口直连电脑。
2. `./flash.sh`（Windows：`flash.ps1`）。脚本写完整盘后回读比对再重启。
3. 首次开机需要几分钟（扩容 rootfs、生成 SSH 密钥）。

刷写会抹掉整张 eMMC，包括出厂系统。救砖不依赖任何厂商内容：按住针孔上电即可回到 MaskROM 重刷。

## 从源码构建

需要 Docker。

```sh
tools/fetch-inputs.sh      # 内核源码 + rkbin loader

docker run --rm --privileged -v /dev:/tmp/dev -v w132d-armbian:/build -v "$PWD":/w \
  debian:13 bash -c 'bash /w/tools/armbian-kernel.sh build \
    && bash /w/tools/verify-image.sh && bash /w/tools/make-release.sh'
# 产物：out/release/w132d-armbian-<日期>.zip
```

`armbian-kernel.sh` 还接受 `kernel-patch`（只验补丁栈）、`kernel`、`uboot`；`tools/check-drift.sh` 可对下一个内核版本干跑补丁。
本地放了 `userpatches/customize-image.sh`（不入库，用于加入私有内容）时构建的是私有镜像，包名自动带 `-private`；
加 `-e W132D_PUBLIC=yes` 可在同一台机器上出公开镜像。

CI（[build-packages.yml](.github/workflows/build-packages.yml)）构建 deb 包（内核、U-Boot、bsp）并发 Release，
设备上 `dpkg -i` 更新；细节见 [docs/maintenance.md](docs/maintenance.md)。

## 仓库结构

只列入库的路径；Armbian 运行时会在 `userpatches/` 下生成大量空目录，不在 git 里。

```
.
├── patches/                            内核补丁源头（可 git am 到主线）与板级 DTS
│   ├── 000N-*.patch
│   ├── 000N-*.msg                      板级 DTS 补丁的提交信息（编号最大）
│   └── rk3528-w132d.dts                板级 DTS，tools/make-patch-series.sh 拼成最后一个补丁
├── userpatches/                        Armbian 构建框架的输入
│   ├── config/boards/w132d.csc         板级配置（Armbian 板文件）
│   ├── extensions/w132d-uboot.sh       构建钩子：U-Boot 源/补丁/blob/配置
│   ├── kernel/archive/rockchip64-7.2/  内核补丁（Armbian 形态，由 patches/ 生成）
│   ├── u-boot/v2026.07/                U-Boot 补丁
│   └── overlay/
│       ├── bsp-cli/                    进 bsp 包：systemd unit、脚本、keymap、RF 配置、apt pin
│       └── rootfs-edits/               归属其他包、直接写进 rootfs 的整文件配置
├── flash/                              刷写脚本与说明，整目录进发布包
├── tools/                              构建、校验、出包脚本
├── docs/                               引导链、上游化与维护备忘
├── .github/workflows/                  CI：构建 deb 并发 Release
├── cache/                              上游源码与 rkbin（不入库，tools/fetch-inputs.sh 生成）
└── out/                                构建产物（不入库）
```

## 上游状态

| 补丁 | 目标 | 状态 |
|---|---|---|
| `media: rkvdec: add RK3528 support` | Linux | 待投 |
| `mmc: sdhci-of-dwcmshc: RK3528 HS400 DLL taps` | Linux | 待投 |
| `thermal: rockchip: add RK3528 TSADC support` | Linux | 待投 |
| `Bluetooth: hci_sync: don't fail init when the controller rejects the default link policy` | Linux | 待投 |
| `phy: rockchip: inno-hdmi: add RK3528 support` | Linux | 待投 |
| `drm/rockchip: dw_hdmi: add RK3528 support` | Linux | 待投 |
| `drm/rockchip: vop2: add RK3528 support` | Linux | 待投 |
| `arm64: dts: rockchip: add ZTE W132D` | Linux | 待投 |
| `ASoC: rockchip: RK3528 codec + ES7202` | Linux | 待整理 |
| uwe5622 驱动：四处修复（含 PMF 密钥槽越界）+ 直接注册 HCI 设备（免用户态 attach） | armbian/uwe5622 | 待投 |
| pmdomain: rockchip: 整个 provider 延迟而不是丢掉延迟的域 | armbian/build | 待投 |
| `rockchip_dnl_key_pressed()` 按 compatible 匹配 ADC | U-Boot | 待投 |
| Marlin3E 三天线 RF 配置 | armbian/firmware | 待投 |

更多：[docs/boot-chain.md](docs/boot-chain.md)（引导链、针孔、MAC、BL31 缺陷的绕过）、
[docs/maintenance.md](docs/maintenance.md)（补丁维护、防漂、CI、已知坑）。

## 许可

代码与脚本 [MIT](LICENSE)；内核补丁 GPL-2.0，U-Boot 补丁 GPL-2.0+。rkbin blob 与 Unisoc 固件是第三方闭源组件，
仓库不含二进制，构建时按钉住的来源下载并按各自条款原样分发。
