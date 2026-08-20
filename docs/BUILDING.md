# 构建说明

## 1. 环境

已验证环境为 Windows 11 + WSL2 Debian 13，以 root 运行镜像组装。需要 Git、GNU patch、
交叉编译器 `aarch64-linux-gnu-*`、CMake、DTC、U-Boot tools、`sgdisk`、`losetup`、
`dosfstools`、`e2fsprogs`、`debugfs`、`rsync`、`chroot`、`modinfo` 和 Armbian 构建依赖。

本项目不会访问已经下线的远程编译机。

## 2. 取得精确源码基线

```bash
git clone https://github.com/armbian/build.git armbian-build
git -C armbian-build checkout 48cb69f26b1a29f015f327191eebcdd6144d0038

git clone https://github.com/KryptonLee/uwe5621ds-aml.git uwe5621ds-aml
git -C uwe5621ds-aml checkout 0c12c46df48da9592abc7848335482e68d23e28a

git clone https://github.com/CoreELEC/uwe5631-aml.git uwe5631-aml
git -C uwe5631-aml checkout 08165b5d56f46b569ee6461d7082ff795efafb2e

git clone https://github.com/rockchip-linux/mpp.git rockchip-mpp
git -C rockchip-mpp checkout c08762ebfadeb4e986d2fed993bc7a54862d3ebe
```

当前 Armbian 缓存 Linux 基线为 `c6157104418d012823413c02f9222f3fe123dd25`，U-Boot
工具树为 `39cd993e5d6296635438e84f4576b3a9bf76f86e`。Armbian 会在缓存工作树上叠加自身补丁，
所以不要要求缓存 Linux/U-Boot 工作树保持 clean；可追溯输入是 Armbian build commit、板卡
文件、用户补丁和构建参数。

## 3. 接入 Armbian

把本仓库文件放入 Armbian 构建树：

```bash
install -m 0644 board/w132d.csc "$ARMBIAN_BUILD_DIR/config/boards/w132d.csc"
install -m 0644 board/rk3528-w132d.dts \
  "$ARMBIAN_BUILD_DIR/userpatches/kernel/rk35xx-vendor-6.1/dt/rk3528-w132d.dts"
install -m 0644 patches/linux/0001-hid-hfd-024f-use-hid-generic.patch \
  "$ARMBIAN_BUILD_DIR/userpatches/kernel/rk35xx-vendor-6.1/"
```

然后在 Armbian 根目录构建基础 rootfs/内核镜像：

```bash
./compile.sh build BOARD=w132d BRANCH=vendor RELEASE=trixie \
  BUILD_MINIMAL=yes ALLOW_ROOT=yes KERNEL_GIT=shallow CPUTHREADS=12 \
  EXTRAWIFI=no USE_CCACHE=yes KERNEL_CONFIGURE=no KERNEL_BTF=no
```

Armbian 目录布局可能随版本变化。上述路径只对记录的 `48cb69f...` 基线负责；若升级 Armbian，
先检查其 userpatches 文档并重新验证补丁，不能直接假定兼容。

## 4. 准备私有输入

在仓库外创建目录，例如 `/mnt/c/w132d-private`：

```text
w132d-private/
  vendor-blobs/
    head.bin
    p2_uboot.img
  w132d-a9/
    2.uboot.img
    15.vendor.img
```

这些文件应来自你自己的原机备份。脚本会核对已知哈希，并在
`vendor-blobs/` 生成 `p2_uboot-wdt.img`。任何哈希不匹配都应停止，不要修改脚本跳过验证。

## 5. 设置路径并构建

```bash
export W132D_BUILD_ROOT=/root/w132d-build
export ARMBIAN_BUILD_DIR=/root/w132d-build/armbian-build
export W132D_PRIVATE_DIR=/mnt/c/w132d-private
export W132D_PUBLISH_DIR=/mnt/c/w132d-output
export W132D_WIFI_SRC=/root/src/uwe5621ds-aml
export W132D_BT_SRC=/root/src/uwe5631-aml
export W132D_MPP_SRC=/root/src/rockchip-mpp

bash scripts/build_uwe5622_wsl.sh
bash scripts/repack_wdt_bootchain_wsl.sh
W132D_REUSE_COMPONENTS=1 bash scripts/assemble_image_wsl.sh
bash scripts/verify_image.sh
```

若要验证指定文件而不是输出目录中最新的镜像：

```bash
W132D_IMAGE=/mnt/c/w132d-output/w132d-armbian-YYYYMMDD-HHMMSS-UTC+8.img \
  bash scripts/verify_image.sh
```

构建脚本不会生成 XZ；最终是原始 `.img` 和 `.img.sha256`。

## 6. 安全边界

组装脚本会使用 loop device、mount、chroot 和文件系统格式化工具。只在专用构建环境中以 root
执行；不要把 `W132D_BUILD_ROOT` 指向 `/`、home 根目录或存放重要文件的目录。不要并行运行两
个组装任务，因为固定挂载点 `/mnt/aroot`、`/mnt/oboot`、`/mnt/oroot` 是共享的。
