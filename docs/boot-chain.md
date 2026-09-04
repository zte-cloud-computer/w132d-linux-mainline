# 引导链

U-Boot v2026.07 的 `generic-rk3528` + 本板 U-Boot DT（`userpatches/u-boot/v2026.07/`），rkbin 的
DDR v1.13 / BL31 v1.21 原样使用，与 Armbian 的 radxa-e24c 同法。钩子在 `userpatches/extensions/w132d-uboot.sh`。
镜像自带完整引导链，设备上不再有任何厂商二进制。

## 镜像布局（扇区）

| 扇区 | 内容 |
|---|---|
| 0–63 | GPT（三分区、固定 UUID，last-lba 按 29.3 GB eMMC） |
| 64– | idbloader：rkbin DDR + 主线 SPL（174 KB） |
| 7168–10239 | 零。出厂时是 Rockchip 私有格式的 vendor storage（SN/MAC/HDCP/IMEI）与 RKSS，整盘刷写清掉 |
| 16384– | u-boot.itb：BL31 + U-Boot proper |
| 24576– | p2 bootfs（extlinux）、p3 rootfs |

## Reset 针孔

HDMI 旁的针孔是 SARADC ch1 下载键（按下约 10，静息约 1019），不是硬复位。U-Boot proper 读到后写
BOOT_BROM_DOWNLOAD 复位，BootROM 进 MaskROM，`rkdeveloptool ld` 显示 `Maskrom`；此后 `db` 一个 rkbin
loader 即可读写 eMMC。

主线 `rockchip_dnl_key_pressed()` 只认名字以 `saradc` 开头的 ADC 设备，而上游 rk3528.dtsi 叫
`adc@ffae0000`，所以 U-Boot DT 补丁把节点按 `saradc@ffae0000` 重建；`generic-rk3528_defconfig` 默认没开
ADC，扩展里打开 `CONFIG_ADC` / `CONFIG_SARADC_ROCKCHIP`，并给 saradc 一个固定 1.8 V 的 `vref-supply`。
上游应改成按 compatible 匹配，待投。

还在跑厂商 U-Boot 的设备按针孔进的是厂商 U-Boot 自己的 rockusb（`Loader` 模式），`flash.sh` 用 `rd 3`
把它复位进 MaskROM。厂商 miniloader 写大文件会静默截断（报 100% 但只写前 16–24 MB），所以写入一律走
rkbin loader，且写完必须回读比对。

## MAC

主线 U-Boot 不读 Rockchip 私有的 vendor storage。`misc_init_r` 按 OTP cpuid 派生一个固定地址
（`rockchip_setup_macaddr()`，主线 Rockchip 板的标准做法），起内核时按 `ethernet0` 别名注入 DT 的
`local-mac-address`。每台机器固定、不同机器不同，但不等于机身标签上的出厂值——路由器里按 MAC 的绑定要改一次。
Linux 侧 `w132d-vendor-mac` 只在 DT 里没有 MAC 时才按 OTP 派生兜底。

曾尝试把出厂 MAC 迁进 U-Boot env，见 [maintenance.md](maintenance.md) 的坑；最终决定不抢救。

## BL31 的 32 分钟缺陷

Rockchip 的 BL31 带一个安全侧串口调试器（uartdbg）：定时器第 30 次 tick 起检查 GRF `0xff370220` 有没有握手
cookie `0x2b4d1f7a`（厂商内核的 fiq_debugger 负责写，主线内核没有），没有就往 console 喷训练帧并改写 UART
时钟分频，整机挂死。rkbin 从 v1.18 到 v1.21 都带这段逻辑（v1.13 没有）。

绕过：`w132d-bl31-cookie.service` 开机早期经 `/dev/mem` 往该寄存器写 cookie
（`userpatches/extensions/src/w132d-bl31-cookie.c`），对任何版本的 BL31 都有效，实测 42 分钟无事。
不需要碰 BL31 二进制。

## 验证记录（2026-09-04/05）

1. 只换 P1（厂商 idbloader 不动）：厂商 SPL 能加载主线 binman 的 FIT，bootstd/extlinux 起 Linux。
2. 换 idbloader：先清零 64–1542 再写（中途断电 = 无 loader = BootROM 自动进 MaskROM，可救）。
3. 针孔 → MaskROM → `db` → 读写 eMMC → `rd` 闭环。
4. 整盘刷写 → 首启 14.6 s，0 失败单元。

厂商引导链的备份（idbloader、P1 FIT）不入库。
