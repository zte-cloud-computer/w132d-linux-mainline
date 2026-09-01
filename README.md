# ZTE W132D 主线 Linux

在 ZTE Cloud Computer W132D（Rockchip RK3528，出厂 Android 9）上运行主线 Linux。

板级支持以 **Armbian 为上游**：内核跟随 Armbian 的 `edge` 分支（当前 7.2），板级
配置、内核补丁、rootfs 定制全部按 `armbian/build` 的目录规约摆放，目标是能作为 PR
提上去。放在 `userpatches/` 下，是因为官方代码里板级配置、family 与内核补丁目录都有
`${USERPATCHES_PATH}` 查找分支，这样能跟着 Armbian 主线走而不必 fork。

> [!WARNING]
> 本项目处于开发阶段，主要由少量实机验证，且大量实现由 AI 协助生成、未经完整人工
> 审查。请把它视为硬件移植项目，而不是面向普通用户的稳定发行版。

## 目录

| 路径 | 内容 |
|---|---|
| `userpatches/config/boards/w132d.csc` | 板级配置：family `rk35xx`、内核 `edge`、不编 u-boot、分区几何 |
| `userpatches/kernel/archive/rockchip64-7.2/` | 板级 DTS 与内核补丁（Armbian 的补丁目录名） |
| `tools/` | 生成与校验脚本 |
| `cache/` | 拉来的上游输入：内核源码、上游仓库克隆。**不入库**，`tools/fetch-inputs.sh` 可重来 |
| `out/` | 构建产物。**不入库** |
| `private/` | 逐机数据：BL31 原版、RF 校准、SN/MAC。**不可再生，永不提交** |

## 快速开始

```sh
# 拉输入：内核源码 + 上游板级仓库
tools/fetch-inputs.sh

# 在容器里编板级 DTB 并跑关键属性校验
docker run --rm -v w132d-72:/build -v "$PWD":/w -v "$PWD/cache/src":/src:ro \
  debian:13 bash /w/tools/build-dtb.sh
```

## 硬件支持

以下都在实机上验证过（在迁移前的自研构建链上）。第一版 Armbian 板级支持覆盖除
HDMI 外的全部：

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
| 面板双色指示灯 | 可用 | 启动、故障、温度状态 |
| 软件待机 | 可用 | 红外/BLE 电源键；Linux 与网络保持运行 |
| HDMI | **本版不含** | 主线 7.2 对 RK3528 显示链零支持；上游 25 个补丁按 7.1 锚定、12 个打不上。作为独立系列后补 |

暂不支持 suspend-to-RAM；4G 模组驱动不在项目范围内。

## 内核补丁

第一版只有 4 个，全部来自上游板级仓库
[`zte-cloud-computer/w132d-linux-mainline`](https://github.com/zte-cloud-computer/w132d-linux-mainline)
（钉在 `e07492b5`，PR #2 的合并点），且都是本项目此前上游过去的：

| 补丁 | 内容 |
|---|---|
| `rk3528-audio` | RK3528 acodec 与 ES7202 驱动（移植自 Rockchip BSP，6.1 → 7.x API 适配） |
| `rk3528-dwcmshc-hs400` | RK3528 的 eMMC DLL tap 6/6/3（主线写死 RK3588 的 10/8/4） |
| `rk3528-tsadc` | RK3528 TSADC 码表与初始化序列 |
| `rk3528-rkvdec` | RK3528 解码器 of_match 条目 |

**不钉在上游 main 的最新提交**：紧随合并点之后的 `1283062a` 把 eMMC 从 HS400 降回
52MHz，而 HS400 配合 DLL tap 补丁是实测可用的。`tools/verify-dtb.sh` 会把这类回退
当作硬失败拦下来。

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
