#!/bin/bash
# SPDX-License-Identifier: MIT
# 把 Armbian 出的镜像切成两段式发布物：设备形状的 GPT + 扇区 24576 起的净荷。
#
# 用法（容器里，需要 losetup 权限）：
#   bash /w/tools/make-release.sh [镜像] [输出目录]
#   默认取 armbian-build/output/images/ 下最新的，输出到 /w/out/release/
#
# ## 为什么不直接刷整个镜像
#
# 设备 eMMC 的扇区 64–24575 里是**它自己的**东西，碰了就变砖或丢身份：
#
#   64–16383      idbloader（DDR 训练 + SPL）与 vendor storage
#                 （SN / MAC / HDCP Key / IMEI）、RKSS 安全存储
#                 —— DDR blob 与内存批次绑定，别人的刷进来起不来
#   16384–24575   p1，厂商 U-Boot FIT
#
# 所以刷写只写两段：GPT（扇区 0–63）和扇区 24576 起。这段中间的空白**原样保留**，
# 用设备自己的就能启动（2026-08-28 实测）。附带三个好处：不需要事先备份 L0、
# 逐机数据不会被覆盖、发布物里没有任何厂商引导二进制。
#
# ## GPT 为什么要自己生成
#
# Armbian 的镜像在 BOOTCONFIG=none 下只有两个分区（bootfs、rootfs），没有厂商
# uboot 那个 —— 因为它压根没编 u-boot，自然不会给它建条目。而设备上是三个。
#
# 我们**不用镜像自带的 GPT**：镜像只是净荷的容器，GPT 由这里按设备形状重建，
# 三个分区、固定 UUID、bootfs 带 LegacyBIOSBootable（厂商 U-Boot 走 distro boot
# 靠它找 boot.scr，缺了不启动）。
#
# ## last-lba 必须按目标 eMMC 算
#
# GPT 头里记着磁盘大小与 last-lba。镜像是 2.6 GB 而设备 eMMC 是 29.3 GB，
# 直接抄镜像的 GPT 会让 rootfs 只能用到 2.6 GB 处。这里按 --emmc-sectors 生成，
# 默认取实测值。
set -euo pipefail

W="${W132D_ROOT:-/w}"
IMG="${1:-}"
OUT="${2:-$W/out/release}"

# 设备 eMMC 的总扇区数（29.3 GB）。实测自本机 `sfdisk -d`：last-lba 61472734。
EMMC_SECTORS="${W132D_EMMC_SECTORS:-61472768}"
P2_START=24576

# 与设备一致的 GPT 身份。这些不是逐机数据，是镜像格式的一部分。
GPT_LABEL_ID="9460D758-5782-409D-ACD6-FE1596D204B3"
UUID_P1="A67F44A9-997D-4AA6-A64C-14CED9E9CFD6"
UUID_P2="6EA179DE-730E-4C8D-A85C-AE1CC68EF1D7"
UUID_P3="EF7972D4-085A-44C6-B550-DB6494052869"
TYPE_LINUX="0FC63DAF-8483-4772-8E79-3D69D8477DE4"
TYPE_ESP_DATA="EBD0A0A2-B9E5-4433-87C0-68B6B72699C7"

step(){ echo; echo "########## $* ##########"; }
die(){ echo "❌ $*" >&2; exit 1; }

for t in sfdisk sgdisk losetup dd; do
  command -v "$t" >/dev/null || die "缺 $t（apt-get install fdisk gdisk mount coreutils）"
done

[ -n "$IMG" ] || IMG=$(ls -t /build/armbian-build/output/images/*.img 2>/dev/null | head -1)
[ -n "$IMG" ] && [ -f "$IMG" ] || die "找不到镜像：${IMG:-<空>}"
mkdir -p "$OUT"

step "1/4 核对源镜像的分区几何"
LAYOUT=$(sfdisk -d "$IMG")
boot_start=$(sed -n 's|.*start= *\([0-9]*\).*name="bootfs".*|\1|p' <<<"$LAYOUT" | tr -d ' ')
root_start=$(sed -n 's|.*start= *\([0-9]*\).*name="rootfs".*|\1|p' <<<"$LAYOUT" | tr -d ' ')
[ "$boot_start" = "24576" ]   || die "bootfs 起点是 ${boot_start:-?}，应为 24576 —— 板级配置的 OFFSET 被改了？"
[ "$root_start" = "1073152" ] || die "rootfs 起点是 ${root_start:-?}，应为 1073152 —— BOOTSIZE 被改了？"
# 取 size 要在**同一行内**匹配，而且 name= 在 size= 之后 —— 早先那句先把整行
# 用 name= 清空了，再 sed size 自然什么也取不到，结果 size 为空串，
# 第 3 个分区的起点被第 2 个吃掉，sfdisk 才报 "Sector 1073152 already used"。
boot_size=$(grep 'name="bootfs"' <<<"$LAYOUT" | sed -n 's|.*size= *\([0-9]*\).*|\1|p' | tr -d ' ')
[ -n "$boot_size" ] || die "解析不出 bootfs 的大小 —— sfdisk 输出格式变了？"
echo "  ✅ bootfs @24576（$boot_size 扇区）、rootfs @1073152"

step "2/4 生成设备形状的 GPT"
# 三个分区，与设备现状一致；rootfs 一直铺到 eMMC 末尾（留 34 扇区给备份 GPT）
GPTIMG="$OUT/w132d-gpt.bin"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
truncate -s $((EMMC_SECTORS * 512)) "$TMP/disk.img"
sfdisk --no-reread --no-tell-kernel "$TMP/disk.img" >/dev/null <<EOF
label: gpt
label-id: $GPT_LABEL_ID
unit: sectors
first-lba: 34

start=16384,   size=8192,    type=$TYPE_LINUX,    uuid=$UUID_P1, name="uboot"
start=$P2_START, size=$boot_size, type=$TYPE_ESP_DATA, uuid=$UUID_P2, name="bootfs"
start=1073152, size=$((EMMC_SECTORS - 1073152 - 34)), type=$TYPE_LINUX, uuid=$UUID_P3, name="rootfs"
EOF
# bootfs 打 LegacyBIOSBootable（属性位 2）—— 厂商 U-Boot 靠它扫到 boot.scr
sgdisk --attributes=2:set:2 "$TMP/disk.img" >/dev/null
# 只取前 64 个扇区：保护性 MBR + 主 GPT + 保留区
dd if="$TMP/disk.img" of="$GPTIMG" bs=512 count=64 status=none
echo "  ✅ $GPTIMG（$(stat -c %s "$GPTIMG") B，扇区 0–63）"
sfdisk -d "$TMP/disk.img" | grep -E "^label-id|name=" | sed 's|^|     |'

step "3/4 切出扇区 24576 起的净荷"
PAYLOAD="$OUT/w132d-p2p3.img"
dd if="$IMG" of="$PAYLOAD" bs=512 skip=$P2_START status=none
echo "  ✅ $PAYLOAD（$(stat -c %s "$PAYLOAD") B）"

step "4/4 自检"
FAIL=0
# GPT 里必须有三个分区、bootfs 带 LegacyBIOSBootable
n=$(sfdisk -d "$TMP/disk.img" | grep -c 'name=')
[ "$n" = 3 ] && echo "  ✅ GPT 三个分区" || { echo "  ❌ GPT 只有 $n 个分区"; FAIL=1; }
sfdisk -d "$TMP/disk.img" | grep -q 'LegacyBIOSBootable' \
  && echo "  ✅ bootfs 带 LegacyBIOSBootable" \
  || { echo "  ❌ bootfs 缺 LegacyBIOSBootable —— 设备起不来"; FAIL=1; }
# 净荷第一个扇区应当是 FAT（bootfs 的引导扇区）
if dd if="$PAYLOAD" bs=512 count=1 status=none | grep -qa "FAT\|mkfs"; then
  echo "  ✅ 净荷起始是 bootfs 的 FAT 引导扇区"
else
  echo "  ⚠️  净荷首扇区没认出 FAT 特征（不一定是错，但值得核对）"
fi
# 发布物里绝不能含厂商引导二进制：净荷从 24576 起，天然不含 64–24575
echo "  ✅ 发布物不含扇区 64–24575（厂商 idbloader / vendor storage / p1）"

# ⚠️ 不能为了对齐给 SHA256SUMS 的行加空格 —— `sha256sum -c` 认的是
# "<hash>␣␣<相对路径>"，原来那句 sed 把绝对路径换成两个空格，结果每行变成
# 四个空格，校验整行解析失败，刷写工具报「SHA256 对不上」，看着像发布物损坏。
(cd "$OUT" && sha256sum "$(basename "$GPTIMG")" "$(basename "$PAYLOAD")" > SHA256SUMS)
sed "s/^/  /" "$OUT/SHA256SUMS"

echo
[ "$FAIL" = 0 ] || die "自检未通过，不要用这份发布物"
echo "RELEASE_OK $OUT"
echo "  刷写：tools/flash.sh $OUT   （需要设备进 Loader/Maskrom）"
