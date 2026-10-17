# 源码构建

所有构建使用仓库根目录的 `tools/w132d`。框架与下载缓存位于 `cache/`，产物位于 `out/<version>/`。

## 环境

系统镜像在 Linux amd64 或 arm64 上构建。准备 Git、Python 3.12+、Docker、sudo，以及 `device-tree-compiler`、`gdisk` 和 `fdisk`；Armbian 负责安装其余构建依赖。

至少预留 35 GiB 空间。完整镜像构建需要可用的 loop 设备；amd64 主机由 Armbian 准备 ARM64 binfmt/QEMU。macOS 仅用于原生构建刷写工具。

## 锁定来源

使用仓库配置的来源快照：

```sh
tools/w132d fetch --download
```

或者解析 Linux、Armbian 和 U-Boot 的最新正式版：

```sh
tools/w132d fetch --latest --download
```

两者均生成 `out/manifest.json`，记录上游标签与提交、固件摘要、板级输入摘要和构建版本。修改构建输入后需重新执行 `fetch`。

默认生成 experimental 版本。`config/sources.json` 是显式快照，自动发布使用 `--latest` 跟踪三个上游的最新正式版。

## 构建目标

```sh
# Kernel packages (default)
tools/w132d build

# Complete Armbian image and packages
tools/w132d build image

# Individual board packages
tools/w132d build uboot
tools/w132d build bsp
```

| 目标 | 主要产物 |
|---|---|
| `kernel` | 内核、DTB、headers、libc-dev 软件包 |
| `image` | `w132d.img`、完整软件包集合、用户空间包清单 |
| `uboot` | U-Boot 软件包 |
| `bsp` | 板级配置、服务和固件软件包 |

完整镜像采用 Armbian 原生 GPT 与首次启动扩容。`w132d.img` 是本地构建产物；用户安装包 `w132d-flash.zip` 在完整发布流程中生成。发布配置见[维护与发布](maintenance.md)。

公开构建只接入 Git 跟踪的板级文件。新增驱动或配置需先纳入版本管理；`userpatches/customize-image.sh` 和 `userpatches/overlay/local/` 属于本地私有路径，不进入公开构建或源码归档。发布封装要求源码已提交、工作区干净且与构建清单一致。

## 构建检查

本地检查入口与 CI 一致：

```sh
docker build -t w132d-check -f tools/docker/Dockerfile .
docker run --rm -v "$PWD:/work" w132d-check tools/w132d verify static
docker run --rm -v "$PWD:/work" w132d-check tools/w132d verify tests
docker run --rm -v "$PWD:/work" w132d-check tools/w132d verify patches --jobs 4
```

`patches` 检查使用当前锁定清单，包含严格补丁应用、DTB 编译和 schema 检查。生成目录为 `cache/verify/<version>/`；同版本重复运行前需移除对应目录，或先保留失败现场用于排查。

完整包和镜像检查：

```sh
version=$(python3 -c 'import json; print(json.load(open("out/manifest.json"))["version"])')
tools/w132d verify debs --directory "out/$version/debs" --full
tools/w132d verify image --image "out/$version/w132d.img"
```

`--full` 用于完整镜像的软件包集合；仅构建内核时省略。Actions 工作流语法检查使用 actionlint，CI 会强制执行。

## 刷写工具

安装 C/C++ 编译器、CMake、pkg-config、autoconf、automake 和 libtool 后执行：

```sh
tools/w132d build flash-tools
```

输出位于 `out/flash-tools/<platform>/`。支持 Linux amd64、Linux arm64 和 macOS arm64 原生构建。libusb 按固定版本及摘要下载，Linux 工具静态链接，macOS 工具静态链接 libusb 并使用 ad-hoc 签名。

## fnOS 实验镜像

fnOS 独立于 Armbian 正式发布。使用 `Manual fnOS image` 工作流，提供官方 Rockchip 基础镜像 URL 和核对过的 SHA256；本地入口为：

```sh
tools/w132d fetch --latest --channel experimental
tools/w132d build fnos --base-image /path/to/rockchip_1253.img.xz --base-sha256 "$FNOS_BASE_SHA256"
```

执行前将基础镜像摘要赋给 `FNOS_BASE_SHA256`。辅助构建器和平台模板的提交固定在 `config/sources.json`，产物记录基础镜像和项目包摘要。

fnOS 通过文件替换内核，不具备 Armbian BSP 的完整包管理状态，仅提供整镜像更新，不支持本项目的内核 APT 升级流程。
