# 启动链与约 30 分钟故障

## 镜像布局

W132D 继续使用板级原厂启动链来完成 DDR 初始化和安全固件加载，Linux 镜像采用自定义 GPT：

```text
sector 64           vendor idbloader / DDR init
partition 1         4 MiB U-Boot FIT (U-Boot + BL31 segments + OP-TEE)
partition 2         FAT32 bootfs (Image, uInitrd, DTB, extlinux, boot.scr)
partition 3         ext4 rootfs, first boot expands to the eMMC end
```

原始启动组件不在本仓库中。`scripts/repack_wdt_bootchain_wsl.sh` 只描述如何从用户自有备份
提取、校验、修改并重打包；文件名里的 `wdt` 是历史命名，当前修复点并不是 Linux watchdog。

## 已确认的固定串口帧来源

早期镜像在约 30 分钟出现由 `#`、`8`、`-`、`]` 和乱码组成的固定帧，随后 TTL/SSH 失联。
反汇编原机 Android 9 BL31 后，定位到其周期性安全侧 UART callback：计数达到阈值后进入固定
UART frame 输出路径。Linux watchdog 寄存器检查表明当时非安全 WDT 并未运行，Wi-Fi/蓝牙
RX 边界诊断也未命中。

Android 9 `atf-1` 的严格版本信息：

```text
原始 SHA256  4f8d9fc2e2a27a6e553bc5e213b13124b2108fddb93e8a484fee3bc5c46d74b1
文件偏移     100564 (0x188d4)
原始指令     89 fe ff 54
替换指令     f4 ff ff 17
修补后 SHA256 5d5540795a7b72b92b7d77c6907bafd0c5f2de8ca1fd302352f833bf0882bc02
```

替换的是一条 AArch64 条件分支，使其跳到 callback 既有的完成/定时器确认路径，跳过固定帧
输出，同时保留原控制流的收尾。`atf-2`、`atf-3` 和配套 OP-TEE 仍从同一 Android 9 FIT
成组提取并逐项校验，避免混用不同安全固件版本。

## 已知坏版本

`w132d-armbian-20260820-185142-UTC+8-cannot-boot.img` 曾把 callback 入口直接改为 `ret`。
这破坏了调用约定/确认路径，设备可能在 Linux 之前停止启动，并出现 loader 模式刷写约 70%
卡住、只能用 maskrom 恢复的现象。该方案已经弃用，不能再次采用。

## 当前结果和限制

采用分支跳转补丁的 `20260820-200141` 镜像已连续运行超过 2 小时，没有再次出现固定帧、
整机卡死或复位。这对当前二进制和硬件组合是强实证，但仍不是形式化证明。补丁完全依赖上述
输入 SHA256、偏移和邻接字节；如果任一校验失败，脚本必须退出，禁止把相同偏移套到其他
BL31 版本。

该二进制修改的可公开内容仅限脚本、哈希、偏移和分析说明。原始/修补后的 BL31、OP-TEE、
U-Boot FIT 和 SPL 不进入 Git，也不因本仓库的 MIT/GPL 许可而获得再分发授权。
