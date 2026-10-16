# 源码构建

建议在 Ubuntu 24.04+ Linux amd64 或 Ubuntu 26.04 ARM64 构建主系统，安装 Git、Python 3.12+、Docker，以及 `device-tree-compiler`、`gdisk`、`fdisk`。Armbian 会准备其构建依赖。CI 使用 GitHub 托管的 `ubuntu-26.04-arm` 原生 ARM64 runner，不需要 ARM64 交叉编译。至少预留 35 GiB 空间；完整镜像还需要可用的 loop 设备和 sudo。amd64 本机构建完整镜像时，Armbian 会按需处理 ARM64 binfmt/QEMU。macOS 只原生构建刷写工具，系统镜像在 Linux 构建。

所有入口使用 `tools/w132d --help`，默认构建内核，输出位于 `out/<version>/`：

```sh
# Use the reviewed source pins
tools/w132d fetch --download
tools/w132d build

# Or follow official upstream stable releases, including a new kernel series
tools/w132d fetch --latest --download
tools/w132d build image
```

`fetch` 生成 `out/manifest.json`，记录项目 SHA、来源标签和 SHA、补丁/驱动/DTS/配置摘要、固件校验和与构建版本。之后修改输入会使锁定检查失败，必须重新执行 fetch。开发构建可以使用未提交修改；发布封装要求干净、已提交且与锁定清单一致的源码。

构建摘要只包含 Git 跟踪文件。未签入的本地脚本会被排除；把私有配置保留在 `userpatches/overlay/local/`，需要进入发布测试时先提交。

```sh
tools/w132d build uboot
tools/w132d build bsp
version=$(python3 -c 'import json; print(json.load(open("out/manifest.json"))["version"])')
tools/w132d verify debs --lock out/manifest.json --directory "out/$version/debs" --full
tools/w132d verify image --lock out/manifest.json --image "out/$version/w132d.img"
```

镜像直接由 Armbian 生成 GPT 和首次扩容配置。工具校验实际安装的 BSP 版本后收集镜像，不按最新文件名或修改时间选择。包通过 Package / Version / Architecture 元数据收集。框架 checkout 和缓存放在 `cache/`，不会修改项目外的 Armbian 源码。

## 自动门禁的本地入口

```sh
docker build -t w132d-check -f tools/docker/Dockerfile .
# Optional workflow linting for local runs
GOBIN="$PWD/cache/check-tools/bin" go install github.com/rhysd/actionlint/cmd/actionlint@v1.7.7
PATH="$PWD/cache/check-tools/bin:$PATH" tools/w132d verify static
docker run --rm -v "$PWD:/work" w132d-check tools/w132d verify tests
docker run --rm -v "$PWD:/work" w132d-check tools/w132d verify patches --jobs 4
```

补丁校验在独立 Git 根目录中解压原生 Linux，逐个严格应用补丁、接入本地驱动、编译 DTB 并检查相关 schema。冲突不会跳过，也不会回退另一份补丁。验证目录存在时会拒绝覆盖；可保留失败现场，删除对应的生成目录 `cache/verify/<version>/` 后重新验证。

`verify tests` 使用临时 APT、dpkg 和 GPG 目录，不读取或修改主机的软件源。完整内核编译由 `build kernel` 执行；schema 通过并不代表内核已完成链接，更不代表实机通过。

## 刷写工具

本机安装 C/C++ 编译器、CMake、pkg-config、autoconf、automake、libtool 后执行：

```sh
tools/w132d build flash-tools
```

自动识别 Linux amd64 / arm64 或 macOS arm64。libusb 按固定版本和 SHA256 下载，Linux 二进制静态链接；macOS 静态链接 libusb，并仅依赖系统库，使用 ad-hoc 签名，不是 Apple 公证。三个平台通过 Actions 分别原生构建，不能将一个平台的二进制当作另一个平台使用。

## fnOS

fnOS 只提供独立手动实验构建。运行 `Manual fnOS image` 工作流，提供官方 Rockchip 基础镜像 URL 和独立核对的 SHA256。或者在 Ubuntu 24.04 上：

```sh
tools/w132d fetch --latest --channel experimental
tools/w132d build fnos --base-image /path/to/rockchip_1253.img.xz --base-sha256 "$FNOS_BASE_SHA256"
```

先将独立核对的基础镜像摘要赋给 `FNOS_BASE_SHA256`。辅助构建器及 Rockchip 平台模板固定在 `config/sources.json` 的提交；关闭辅助构建器对 main 分支固件、引导器和模板的自动下载。基础镜像摘要、项目包和产物摘要写入 fnOS 清单。fnOS 不使用 Armbian 的完整镜像门禁，不自动进入 stable，也不将其构建成功解释为实机验证完成。

fnOS 辅助构建器以文件方式替换内核，并关闭 initramfs 自动更新；它没有安装 Armbian BSP 的完整包管理状态。因此，虽然预置的项目 APT 源仍为 stable，本文的 Armbian 内核 APT 升级流程不适用于 fnOS。fnOS 当前仅提供手动整镜像实验构建，内核更新需重新构建镜像。

项目私有的 `userpatches/customize-image.sh` 和 `overlay/local/` 不参与公开构建与源码归档。不要将密钥、用户数据或本机调试配置放到受版本管理的 overlay。
