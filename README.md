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
| `userpatches/kernel/archive/rockchip64-7.2/` | 内核补丁的 **Armbian 形态**（其补丁栈之上、`w132d-` 前缀），由 `make-patch-series.sh --on-armbian` 生成，勿手改 |
| `patches/` | 内核补丁的**源头**：`NNNN-*.patch` 是完整 git 补丁（能直接 `git am` 到干净主线，即投 LKML 的形态）；`rk3528-w132d.dts` 是最后一个补丁的源，配编号最大的 `NNNN-*.msg` 提交信息 |
| `userpatches/overlay/` · `userpatches/extensions/` | rootfs 定制文件（unit、keymap、脚本；运行时依赖包由板级配置的 `PACKAGE_LIST_BOARD` 装）· 在 chroot 里从源码编的原生工具（btattach、BL31 cookie） |
| `tools/` | 构建与校验脚本 |
| `cache/` | 拉来的内核源码。**不入库**，`tools/fetch-inputs.sh` 可重来 |
| `out/` | 构建产物，不入库 |

## 快速开始

```sh
tools/fetch-inputs.sh                              # 拉内核源码

# 编板级 DTB 并跑关键属性校验（快，几分钟）
docker run --rm -v w132d-72:/build -v "$PWD":/w -v "$PWD/cache/src":/src:ro \
  debian:13 bash /w/tools/build-dtb.sh

# 让 Armbian 自己拉源码、打补丁（真实构建路径）
docker run --rm -v w132d-armbian:/build -v "$PWD":/w \
  debian:13 bash /w/tools/armbian-kernel.sh kernel-patch

# 完整镜像 → 离线校验 → 两段式发布物 → 刷写（需要 --privileged：losetup/mount）
docker run --rm --privileged -v /dev:/tmp/dev -v w132d-armbian:/build -v "$PWD":/w \
  debian:13 bash -c 'bash /w/tools/armbian-kernel.sh build \
    && bash /w/tools/verify-image.sh && bash /w/tools/make-release.sh'
tools/flash.sh out/release                          # 设备按住 Reset 针孔上电，USB 直连
```

## 防漂与上游化

自己带补丁就会漂。这里有三层机制，第三层是唯一能真正终结漂移的：

**1 · 补丁维护成 git 提交** — [`tools/make-patch-series.sh`](tools/make-patch-series.sh)

把 `patches/` 里的源补丁 `git am` 到内核树上（DTS 做成最后一个提交），由
`git format-patch` 同时产出两样东西：可以 `git send-email` 投 LKML 的补丁，和 Armbian
补丁目录的内容。将来 rebase 到新内核时，git 会直接指出
哪个提交、哪个 hunk 冲突——这就是防漂本身，不必再看 `.rej` 猜。

**2 · 提前对下一个内核干跑** — [`tools/check-drift.sh`](tools/check-drift.sh)

```sh
docker run --rm -v w132d-drift:/build -v "$PWD":/w \
  debian:13 bash /w/tools/check-drift.sh 7.2.2 7.3-rc1
```

Armbian 的 edge 跟的是 `linux-7.2.y` 的 HEAD、且迟早 bump 到 7.3，两件事都会在我们
不知情时把补丁打崩。它测的是 `patches/` 里的**主线形态**打在纯净内核上（Armbian 形态
重锚在 Armbian 补丁栈之上，纯净树上打不上；那一侧由 `armbian-kernel.sh kernel-patch`
真实构建来验）。两个设计决定：**fuzz 当预警不当通过**（今天的 fuzz 就是明天的
fail）；**必须真编一次 DTB**——光测补丁会漏掉「上游 dtsi 自己变了」这一类漂移，实测
例子就是主线 7.2 自带了 `usb2phy` 节点、与上游 DTS 用的 `u2phy` 对不上，补丁全绿但
dtc 直接报 label not found。

**3 · 逐个投主线，投进一个少一个**

| 补丁 | 可上游性 |
|---|---|
| `media: rkvdec: add RK3528 support` | 高——一条 of_match 指向已有 variant |
| `mmc: sdhci-of-dwcmshc: RK3528 HS400 DLL taps` | 高——小且自洽 |
| `thermal: rockchip: add RK3528 TSADC support` | 中——标准 SoC 使能，需配 DT binding 文档 |
| `Bluetooth: hci_sync: 控制器拒绝默认 link policy 时不让初始化失败` | 高——通用修复，UWE5623 上报 Park 却拒绝它；不改则 hci0 永远起不来 |
| `arm64: dts: rockchip: add the W132D` | 中——需在 binding 里登记 compatible |
| `ASoC: rockchip: RK3528 codec + ES7202` | 低——2359 行两个新驱动，需正经 binding 与 review |

## 硬件支持

以下都在实机上验证过（在迁移前的自研构建链上）：

| 功能 | 状态 | 说明 |
|---|---|---|
| eMMC | 可用 | HS400 Enhanced Strobe，RK3528 DLL tap 6/6/3 |
| USB 2.0 / 有线网络 | 可用 | **7.2 起 USB2 PHY 驱动与 DT 节点由主线自带**。出厂 MAC 由 `w132d-vendor-mac` 开机从 eMMC 的 vendor storage 读出设上（厂商 U-Boot 没把它修进主线 DTB） |
| Wi-Fi / 蓝牙 / BLE 遥控 | 可用 | UWE5623 / Marlin3E。固件是 **CoreELEC 公开仓库 [uwe5631-aml](https://github.com/CoreELEC/uwe5631-aml) 里的 `MARLIN3E_20A_W23.03.2`**，bsp 包构建时按钉住的提交下载、校 sha256、装成 `uwe5622/wcnmodem-marlin3e.bin`（本板实测：关联 OK、下行 17–19 MB/s、上行 14 MB/s、0 断言、遥控器稳定），仓库里没有二进制、没有私有输入。Armbian 包自带的 `wcnmodem-38222.bin`（W21.03.3）扫描正常但一关联就 CP2 断言；旁边的 `wcnmodem.bin` 是 SC2355 的，不能用；出厂的 W25.45.3 第一次扫描就崩。三天线 RF 配置随 overlay。驱动是 Armbian 的 `armbian/uwe5622` + 一行 vfree 补丁（见下），**新驱动本身未在本板实测** |
| 红外遥控 | 可用 | GPIO4_C6，rc-core + NEC |
| 3.5 mm 音频 | 可用 | acodec 输出，ES7202/PDM 输入 |
| Mali-450 GPU | 可用 | Lima，300–800 MHz，含热降频。Armbian 的 rk3528 pmdomain 补丁会把 GPU 电源域丢掉（`w132d-armbian-0004` 改回主线语义，待报 Armbian） |
| H.264 / HEVC 解码 | 可用 | 主线 RKVDEC |
| 温控 / DVFS / 看门狗 / pstore | 可用 | ramoops 的 console 通路由板级 config 钩子打开（Armbian 默认没开 `PSTORE_CONSOLE`，硬挂时会零现场） |
| 面板双色指示灯 · 软件待机 | 可用 | 红外/BLE 电源键；Linux 与网络保持运行 |
| HDMI | **本版不含** | 主线 7.2 对 RK3528 显示链零支持（VOP2/dw-hdmi/inno-hdmi 里 rk3528 命中数全为 0）。作为独立系列后补 |

暂不支持 suspend-to-RAM；4G 模组驱动不在项目范围内。

引导走 **extlinux.conf**（`SRC_EXTLINUX=yes`）：厂商 U-Boot 的 distro boot 先找它，迁移前
的构建链就是这么起的；Armbian 默认的 boot.scr 依赖厂商 U-Boot 环境里的一堆变量与命令，
在本板上没起来过。内核参数只有 `SRC_CMDLINE` 一处，串口控制台 **UART0 / ttyS0，115200**
（Armbian 对非 rk3576 的 SoC 默认 ttyS2，板级配置设了 `SERIALCON=ttyS0` 给 getty）。

> [!NOTE]
> 这份镜像**还没有整体上过真机**：五个内核补丁、DTS 与 rootfs 定制都在迁移前的
> 构建链上验证过，但换到 Armbian 的 7.2 内核、Armbian 的无线驱动与引导脚本之后，
> 只做了 `tools/verify-image.sh` 的离线校验。首次刷写请把它当作待验证版本。

## CI 构建与设备更新

[`.github/workflows/build-packages.yml`](.github/workflows/build-packages.yml) 在 GitHub
Actions 上用 armbian/build 的 `main` 构建 **deb 包**（`linux-image/dtb/headers-edge-rockchip64`
与 `armbian-bsp-cli-w132d-edge`），`push` / 每周一 / 手动触发；每周与手动 `publish` 会发成
GitHub Release。产出先过 [`tools/verify-debs.sh`](tools/verify-debs.sh)（DTB 在不在、
16 条关键属性、板级模块、pstore config、bsp 里的 unit 与 apt pin）。

不产整盘镜像：整盘镜像要 `--privileged` 的 loop 设备，在本机构建；设备的更新路径是 deb。
每次都是全新 runner、Armbian 与内核都取 HEAD，所以**构建成功与否本身就是漂移检测**。

版本号是 `26.11.0-trunk.<日期>.<运行序号>`（Armbian 的 VERSION 固定不变，apt 看不到升级，
所以要追加单调递增的后缀，经 `REVISION=` 传入）。

> [!IMPORTANT]
> 本板内核包与 Armbian 官方的**同名**（family 共用内核），而官方那份没有本板 DTB 与补丁。
> 镜像里带了 `/etc/apt/preferences.d/w132d-kernel`，禁止从 apt.armbian.com 取这三个包；
> 没有它，官方版本号追上来的那天 `apt upgrade` 会把设备打死。补丁进了 armbian/build
> 之后这条 pin 和整个自建构建都可以退役。

设备上安装（顺序：dtb → image → bsp）：

```sh
dpkg -i linux-dtb-edge-rockchip64_*.deb linux-image-edge-rockchip64_*.deb armbian-bsp-cli-w132d-edge_*.deb
```

下一步是把 Release 里的包做成签名的 apt 源，设备直接 `apt upgrade`。

## 引导链：保留设备自己的

镜像不含引导链，刷写**只写 GPT（扇区 0–63）和扇区 24576 起**，完全不碰 64–24575。
那一段是设备自己的 idbloader、vendor storage（SN/MAC/HDCP/IMEI）、RKSS 和 U-Boot ——
用它自己的就能启动，所以不需要备份 L0，逐机数据也不会被覆盖。板级配置里对应
`BOOTCONFIG="none"`（先例：`aml-s9xx-box.tvb` 等 8 块板）。

这也意味着 HDMI 旁那个针孔行为与原厂一致：实测它是 **SARADC 通道 1 的下载键**（按下
读数 10，静息 1019），不是硬复位；读它的是我们永不覆盖的厂商 miniloader。

> [!NOTE]
> 出厂 BL31 有一个每约 32 分钟打死整机的缺陷：Rockchip 的安全侧串口调试器（uartdbg）第 30 次
> 定时 tick 起检查 GRF `0xff370220` 里有没有握手 cookie `0x2b4d1f7a`（厂商内核的 fiq_debugger
> 负责写，主线内核没有），没有就往 console 喷训练帧并改写 UART 时钟分频。rkbin 的 v1.21 同样没修。
> 镜像里的 `w132d-bl31-cookie.service` 开机早期写这个 cookie
> （`userpatches/extensions/src/w132d-bl31-cookie.c`）。**2026-09-04 在原版（未打补丁）BL31 上实测：
> 42 分钟无挂死无复位**，两个历史爆点（1919 s / 1979 s）都过了。所以**不需要碰 BL31**，
> 也不需要 rkbin 的任何 blob；早先"给 atf-1 打 4 字节补丁"那条路已退役。

## 已知的漂移点

除了内核补丁（由 `check-drift.sh` 盯着），还有两处在 Armbian 的构建代码里、
补丁干跑测不出来：

* **无线驱动有版本闸**：`lib/functions/compilation/patch/drivers_network.sh` 的
  `driver_uwe5622()` 只对 `5.15 ≤ 内核 < 7.3` 加入驱动。Armbian 把 edge 提到 7.3 的那天，
  Wi-Fi/蓝牙模块会**无声消失**——`verify-image.sh` 不查模块，要看 `kernel` 构建产物里
  有没有 `sprdwl_ng.ko`。
* **extlinux 的生成**在 `lib/functions/rootfs/distro-agnostic.sh` 与 `image/partitioning.sh`
  两处（`kernel/initrd/fdt` 与 `append root=`），`verify-image.sh` 逐行核对。
