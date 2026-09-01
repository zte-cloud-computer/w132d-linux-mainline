# ZTE W132D 主线 Linux

在 ZTE Cloud Computer W132D（Rockchip RK3528，出厂 Android 9）上运行主线 Linux。

板级支持以 **Armbian 为上游**：内核跟随 Armbian 的 `edge` 分支（当前 7.2），板级
配置与内核补丁按 `armbian/build` 的目录规约摆放，目标是能作为 PR 提上去。放在
`userpatches/` 下，是因为官方代码里板级配置与内核补丁目录都有 `${USERPATCHES_PATH}`
查找分支，这样能跟着 Armbian 主线走而不必 fork。

内核补丁同时维护成**能投 LKML 的形态**——见下面「防漂与上游化」。

> [!WARNING]
> 本项目处于开发阶段，主要由少量实机验证，且大量实现由 AI 协助生成、未经完整人工
> 审查。请把它视为硬件移植项目，而不是面向普通用户的稳定发行版。

## 目录

| 路径 | 内容 |
|---|---|
| `userpatches/config/boards/w132d.csc` | 板级配置：family `rk35xx`、内核 `edge`、不编 u-boot、分区几何 |
| `userpatches/kernel/archive/rockchip64-7.2/` | 内核补丁（5 个，由 `make-patch-series.sh` 生成，勿手改） |
| `userpatches/board/rk3528-w132d.dts` | 板级 DTS 源文件 |
| `patches-src/import/` · `patches-src/messages/` | 补丁的原始导入件与提交信息 |
| `tools/` | 构建与校验脚本 |
| `cache/` | 拉来的内核源码。**不入库**，`tools/fetch-inputs.sh` 可重来 |
| `out/` · `private/` | 构建产物 · 逐机数据（BL31 原版、RF 校准、SN/MAC）。均不入库；后者从自己的整盘备份里取 |

## 快速开始

```sh
tools/fetch-inputs.sh                              # 拉内核源码

# 编板级 DTB 并跑关键属性校验（快，几分钟）
docker run --rm -v w132d-72:/build -v "$PWD":/w -v "$PWD/cache/src":/src:ro \
  debian:13 bash /w/tools/build-dtb.sh

# 让 Armbian 自己拉源码、打补丁（真实构建路径）
docker run --rm -v w132d-armbian:/build -v "$PWD":/w \
  debian:13 bash /w/tools/armbian-kernel.sh kernel-patch
```

## 防漂与上游化

自己带补丁就会漂。这里有三层机制，第三层是唯一能真正终结漂移的：

**1 · 补丁维护成 git 提交** — [`tools/make-patch-series.sh`](tools/make-patch-series.sh)

在内核树上建一串提交，由 `git format-patch` 同时产出两样东西：可以 `git send-email`
投 LKML 的补丁，和 Armbian 补丁目录的内容。将来 rebase 到新内核时，git 会直接指出
哪个提交、哪个 hunk 冲突——这就是防漂本身，不必再看 `.rej` 猜。

**2 · 提前对下一个内核干跑** — [`tools/check-drift.sh`](tools/check-drift.sh)

```sh
docker run --rm -v w132d-drift:/build -v "$PWD":/w \
  debian:13 bash /w/tools/check-drift.sh 7.2.2 7.3-rc1
```

Armbian 的 edge 跟的是 `linux-7.2.y` 的 HEAD、且迟早 bump 到 7.3，两件事都会在我们
不知情时把补丁打崩。两个设计决定：**fuzz 当预警不当通过**（今天的 fuzz 就是明天的
fail）；**必须真编一次 DTB**——光测补丁会漏掉「上游 dtsi 自己变了」这一类漂移，实测
例子就是主线 7.2 自带了 `usb2phy` 节点、与上游 DTS 用的 `u2phy` 对不上，补丁全绿但
dtc 直接报 label not found。

**3 · 逐个投主线，投进一个少一个**

| 补丁 | 可上游性 |
|---|---|
| `media: rkvdec: add RK3528 support` | 高——一条 of_match 指向已有 variant |
| `mmc: sdhci-of-dwcmshc: RK3528 HS400 DLL taps` | 高——小且自洽 |
| `thermal: rockchip: add RK3528 TSADC support` | 中——标准 SoC 使能，需配 DT binding 文档 |
| `arm64: dts: rockchip: add the W132D` | 中——需在 binding 里登记 compatible |
| `ASoC: rockchip: RK3528 codec + ES7202` | 低——2359 行两个新驱动，需正经 binding 与 review |

## 硬件支持

以下都在实机上验证过（在迁移前的自研构建链上）：

| 功能 | 状态 | 说明 |
|---|---|---|
| eMMC | 可用 | HS400 Enhanced Strobe，RK3528 DLL tap 6/6/3 |
| USB 2.0 / 有线网络 | 可用 | **7.2 起 USB2 PHY 驱动与 DT 节点由主线自带** |
| Wi-Fi / 蓝牙 / BLE 遥控 | 可用 | UWE5622，含 PSKEY/RF 校准 |
| 红外遥控 | 可用 | GPIO4_C6，rc-core + NEC |
| 3.5 mm 音频 | 可用 | acodec 输出，ES7202/PDM 输入 |
| Mali-450 GPU | 可用 | Lima，300–800 MHz，含热降频 |
| H.264 / HEVC 解码 | 可用 | 主线 RKVDEC |
| 温控 / DVFS / 看门狗 / pstore | 可用 | — |
| 面板双色指示灯 · 软件待机 | 可用 | 红外/BLE 电源键；Linux 与网络保持运行 |
| HDMI | **本版不含** | 主线 7.2 对 RK3528 显示链零支持（VOP2/dw-hdmi/inno-hdmi 里 rk3528 命中数全为 0）。作为独立系列后补 |

暂不支持 suspend-to-RAM；4G 模组驱动不在项目范围内。

## 引导链：保留设备自己的

镜像不含引导链，刷写**只写 GPT（扇区 0–63）和扇区 24576 起**，完全不碰 64–24575。
那一段是设备自己的 idbloader、vendor storage（SN/MAC/HDCP/IMEI）、RKSS 和 U-Boot ——
用它自己的就能启动，所以不需要备份 L0，逐机数据也不会被覆盖。板级配置里对应
`BOOTCONFIG="none"`（先例：`aml-s9xx-box.tvb` 等 8 块板）。

这也意味着 HDMI 旁那个针孔行为与原厂一致：实测它是 **SARADC 通道 1 的下载键**（按下
读数 10，静息 1019），不是硬复位；读它的是我们永不覆盖的厂商 miniloader。

> [!CAUTION]
> 出厂 BL31 有一个每约 32 分钟打死整机的缺陷：Rockchip 的安全侧串口调试器
> （uartdbg）在宽限期后开始扫波特率，往 console 喷训练帧并改写 UART 时钟分频。
> 需要给设备自己那份 BL31 打一个 4 字节补丁（偏移 `0x188d4`，`89 fe ff 54` →
> `f4 ff ff 17`）。rkbin 的 v1.21 同样没有修复这个问题。
