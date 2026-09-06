# ZTE W132D — 主线 Linux 整盘镜像

这是 ZTE W132D 主线 Linux 项目（仓库根目录的 README）的发布包：Armbian（Debian trixie，minimal）+ 主线内核 + 主线 U-Boot，
适用于 ZTE Cloud Computer W132D（Rockchip RK3528）。

## 包内文件

| 文件 | 说明 |
|---|---|
| `w132d.img` | 整盘镜像：GPT + 引导链（rkbin DDR/BL31 + 主线 U-Boot）+ bootfs + rootfs |
| `SHA256SUMS` | 校验和（`sha256sum -c SHA256SUMS`） |
| `flash.sh` | macOS / Linux 刷写脚本（需要 `rkdeveloptool`） |
| `flash.ps1` | Windows 刷写脚本（需要 `rkdeveloptool.exe`），未在 Windows 上实测 |
| `rk3528_loader_v1.13.107.bin` | 刷写用的 Rockchip USB loader（rkbin 原样组件，MaskROM 下载后才能读写 eMMC） |

## 刷写会抹掉什么

**整张 eMMC**，包括出厂 Android、厂商 U-Boot 和 Rockchip vendor storage（出厂 MAC / SN）。
刷完后有线网卡的 MAC 是 U-Boot 按芯片 OTP 派生的固定地址，每台机器不同但**不等于机身标签上的值**，
路由器里若有按 MAC 的绑定要改一次。想回到出厂系统需要你自己事先做的完整备份。

## 刷写步骤

1. 准备工具
   - macOS：`brew install rkdeveloptool`
   - Linux：发行版包 `rkdeveloptool`，或从 <https://github.com/rockchip-linux/rkdeveloptool> 编译
   - Windows：`rkdeveloptool.exe`（社区构建）放到 PATH，或用 Rockchip 官方 RKDevTool（见下）
2. 校验：`sha256sum -c SHA256SUMS`（macOS：`shasum -a 256 -c SHA256SUMS`）
3. 进 MaskROM：设备**断电**，用顶针按住 HDMI 旁的 Reset 针孔，保持按住的同时接通电源，
   USB-A 口直连电脑（不经 hub），按住约 5 秒再松。`rkdeveloptool ld` 应显示 `Maskrom`。
   - 还在跑出厂系统或厂商 U-Boot 的机器按针孔进的是 `Loader` 模式，脚本会自动 `rd 3` 复位进 MaskROM。
4. 刷写
   - macOS / Linux：`./flash.sh`（在解压目录里运行；写完自动回读比对再重启）
   - Windows：`powershell -ExecutionPolicy Bypass -File flash.ps1`
5. 首次开机要几分钟（扩容 rootfs、生成 SSH 密钥），面板灯亮后等待即可。之后用
   `ssh root@<ip>`，首次登录走 Armbian 的初始化向导。设备的 IP 看路由器（新 MAC）。

### 用 RKDevTool（Windows 图形工具）

1. 打开 RKDevTool，设备进 MaskROM 后左下角显示"发现一个 MASKROM 设备"。
2. "高级功能"页：Loader 选 `rk3528_loader_v1.13.107.bin`，点"下载"。
3. "下载镜像"页：一行，起始地址 `0x0`，文件选 `w132d.img`，勾选后点"执行"。
4. 完成后断电重启。RKDevTool 不做回读校验，写完建议再用 `flash.sh --verify-only` 比对一次。

## 遇到问题

- **`rkdeveloptool ld` 找不到设备**：换 USB 线/口，别经 hub；确认是按住针孔的同时上电。
- **写完不启动**：先 `./flash.sh --verify-only` 回读比对；不一致就重刷。一致仍不起，到项目仓库提 issue。
- **救砖**：只要 BootROM 还在（永远在），按住针孔上电就能进 MaskROM 重刷；没有变砖的路径。
- **蓝牙遥控器**：重刷后需要重新配对：`w132d-ble-pair --force 10`，然后按遥控器的配对组合键。

## 版本

镜像由 [armbian/build](https://github.com/armbian/build) 构建，内核 `linux-7.2.y`（edge），
U-Boot v2026.07 + rkbin DDR v1.13 / BL31 v1.21，Wi-Fi 固件 CoreELEC 公开的 Marlin3E W23.03.2。
详细的硬件支持状态、构建方法与已知问题见项目 README。
