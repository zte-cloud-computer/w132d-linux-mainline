# 安装与首次启动

适用 W132D / RK3528 / UWE5621DS。从本仓库 Releases 的 Latest 下载 `w132d-flash.zip`，校验下载页面的 SHA256，再完整解压。预发布版本属于实验构建，不代表新的稳定版本。

刷写会替换操作系统、分区表和引导链。先备份需要的数据。刷写清单保留设备的 vendor storage / RKSS 区间，但不能以此代替完整备份；镜像不含原厂 Android 恢复材料。

Linux amd64、Linux arm64、macOS arm64 使用包内 `tools/<platform>/rkdeveloptool`，无需安装发行版或 Homebrew 的 rkdeveloptool。需要 Python 3.9 或更新版本；Linux 需要设备访问权限，通常用 sudo 执行。

```sh
# Run from the extracted bundle
chmod +x flash.sh tools/*/rkdeveloptool
./flash.sh --dry-run
# Linux
sudo ./flash.sh
# macOS
./flash.sh
```

1. 设备断电，用顶针按住 HDMI 旁 Reset 针孔，同时接通电源，用支持数据的 USB 线将设备直连电脑，不经过 hub。
2. 保持按住约五秒。电脑应只连接一台 Rockchip 设备。脚本识别 Loader / MaskROM；遇到厂商 Loader 会先切换 MaskROM，再下载本次发布附带的固定 loader。
3. 确认提示后，脚本按清单写入，并逐字节回读校验。成功后自动重启；失败不会继续重启。
4. 第一次启动等待 Armbian 原生扩容和 SSH 密钥生成。通过路由器确认 IP，使用 Armbian 首次登录流程创建账户、修改凭据。不要将未初始化的系统直接暴露到公网。

镜像采用原生 GPT、独立 FAT boot 分区和 ext4 根分区，首次启动扩容到设备实际容量，不使用固定 eMMC 容量重新拼接分区表。有线 MAC 来自 U-Boot 按 SoC OTP 派生的地址，可能与机身标签不同。

Windows 使用 Python 3 和兼容的 `rkdeveloptool.exe`：

```powershell
powershell -ExecutionPolicy Bypass -File flash.ps1 --dry-run --tool C:\Tools\rkdeveloptool.exe
powershell -ExecutionPolicy Bypass -File flash.ps1 --tool C:\Tools\rkdeveloptool.exe
```

PowerShell 和 Shell 都调用同一 `flash.py`；Windows USB 驱动安装与实际写入仍需实机验证。不要把图形版 RKDevTool 当作兼容的命令行程序传给 `--tool`。
