# 安装与首次启动

适用于 RK3528 / UWE5621DS 的 ZTE W132D。安装会替换操作系统、分区表和引导器；请先备份个人数据，并单独保存原厂系统的恢复材料。

## 准备

从 [Latest Release](https://github.com/zte-cloud-computer/w132d-linux-mainline/releases/latest) 下载同一版本的 `w132d-flash.zip` 和 `SHA256SUMS`。将压缩包的 SHA256 与清单中 `w132d-flash.zip` 对应项比较：

```sh
# Linux
sha256sum w132d-flash.zip
# macOS
shasum -a 256 w132d-flash.zip
```

摘要一致后完整解压。准备稳定供电、支持数据传输的 USB 线和有线网络。主机需要 Python 3.9+；Linux amd64、Linux arm64、macOS arm64 的 rkdeveloptool 已包含在包内。

## 刷写

在解压目录中检查文件：

```sh
chmod +x flash.sh tools/*/rkdeveloptool
./flash.sh --dry-run
```

输出 `FLASH_DRY_RUN_OK` 表示包内文件、布局和工具摘要检查通过，此步骤不访问 USB。

1. 设备断电，按住 HDMI 旁的 Reset 针孔按键。
2. 保持按住，接通电源并用 USB 数据线直连电脑，约五秒后松开。电脑只连接一台 Rockchip 设备。
3. 运行对应平台的刷写命令，阅读提示后输入 `yes`。

```sh
# Linux
sudo ./flash.sh
# macOS
./flash.sh
```

脚本识别 Loader / MaskROM，加载包内 loader，检查设备容量后按清单写入并完整回读。出现 `FLASH_OK` 后设备自动重启。失败时停止操作并查看[恢复指南](recovery.md)。

刷写保留设备的 vendor storage / RKSS 区间，其他系统数据会被替换。

## 首次启动

首次启动会生成 SSH 密钥并扩展根分区，期间保持供电。通过路由器查看设备 IP，使用 `ssh root@<设备IP>` 登录。默认初始密码为 `1234`，首次登录会要求修改密码并创建普通用户。本地控制台也可完成初始化。

后续使用普通用户登录，通过 `sudo` 管理系统；完成账户初始化后再开放远程访问。

登录后更新软件：

```sh
sudo apt update
sudo apt upgrade
sudo reboot
```

镜像采用 GPT、独立 FAT boot 分区和 ext4 根分区，容量由首次启动流程自动适配。有线 MAC 按 SoC OTP 派生，可能与机身标签不同。

音频、遥控器及待机设置见[日常使用](usage.md)，后续更新见[升级与通道](upgrades.md)。

## Windows

Windows 需要 Python 3.9+、Rockchip USB 驱动，以及兼容的命令行 `rkdeveloptool.exe`。刷写包不附带 Windows 二进制；该路径尚未确认实机兼容性。

```powershell
powershell -ExecutionPolicy Bypass -File flash.ps1 --dry-run --tool C:\Tools\rkdeveloptool.exe
powershell -ExecutionPolicy Bypass -File flash.ps1 --tool C:\Tools\rkdeveloptool.exe
```

Windows 使用相同的下载模式操作和确认提示。`--tool` 接受命令行 rkdeveloptool，图形版 RKDevTool 无法替代。

## 旧系统迁移

旧实验镜像和旧 Release `apt` 源不提供原地迁移。请备份数据后使用完整刷写包重新安装，再恢复应用和个人配置。
