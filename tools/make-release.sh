#!/bin/bash
# SPDX-License-Identifier: MIT
# 把 Armbian 出的镜像做成一张**设备形状的整盘镜像** w132d.img。
#
# 用法（容器里）：
#   bash /w/tools/make-release.sh [镜像] [输出目录]
#   默认取 armbian-build/output/images/ 下最新的，输出到 /w/out/release/
#
# ## 布局（扇区）
#
#   0–63          设备形状的 GPT：三个分区、固定 UUID、bootfs 带 LegacyBIOSBootable，
#                 last-lba 按目标 eMMC 算（Armbian 镜像自带的 GPT 只有两个分区且按 2.6 GB 算，不用）
#   64–7167       idbloader：rkbin DDR blob + 主线 SPL（Armbian 构建时 write_uboot_platform 写进镜像）
#   7168–10239    零。设备出厂时这里是 Rockchip 私有格式的 vendor storage（SN/MAC/HDCP/IMEI）
#                 与 RKSS，主线两边都没有驱动，整盘覆盖清掉；MAC 由 U-Boot 按 OTP cpuid 派生。
#                 镜像里这段必须是零
#   10240–16383   零
#   16384–24575   p1：u-boot.itb（BL31 + U-Boot proper）
#   24576–        p2 bootfs、p3 rootfs，与 Armbian 镜像逐字节相同
#
# 2026-09-04 之前发布物是"GPT + 24576 起的净荷"两段式，保留设备的厂商引导链；引导链换成
# 主线 U-Boot 之后镜像自带引导链，发布物就是一整张盘。
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

step "3/4 拼整盘镜像"
FULL="$OUT/w132d.img"
P1_START=16384; HOLE_START=7168; HOLE_SECTORS=3072
rm -f "$FULL"
dd if="$GPTIMG" of="$FULL" bs=512 status=none
# 64–24575：Armbian 镜像里的引导链（idbloader@64、u-boot.itb@16384），其余本来就是零
dd if="$IMG" of="$FULL" bs=512 skip=64 seek=64 count=$((P2_START - 64)) conv=notrunc status=none
# 空洞强制清零：镜像里绝不能带任何一台机器的 vendor storage / RKSS
dd if=/dev/zero of="$FULL" bs=512 seek=$HOLE_START count=$HOLE_SECTORS conv=notrunc status=none
# 24576 起：p2 + p3 原样
dd if="$IMG" of="$FULL" bs=1M skip=$((P2_START / 2048)) seek=$((P2_START / 2048)) conv=notrunc status=none
echo "  ✅ $FULL（$(stat -c %s "$FULL") B）"

step "4/4 自检"
FAIL=0
n=$(sfdisk -d "$TMP/disk.img" | grep -c 'name=')
[ "$n" = 3 ] && echo "  ✅ GPT 三个分区" || { echo "  ❌ GPT 只有 $n 个分区"; FAIL=1; }
sfdisk -d "$TMP/disk.img" | grep -q 'LegacyBIOSBootable' \
  && echo "  ✅ bootfs 带 LegacyBIOSBootable" \
  || { echo "  ❌ bootfs 缺 LegacyBIOSBootable"; FAIL=1; }
magic() { dd if="$FULL" bs=512 skip="$1" count=1 status=none | head -c 4 | od -An -tx1 | tr -d ' \n'; }
[ "$(magic 64)" = "524b4e53" ] && echo "  ✅ 扇区 64 是 idbloader（RKNS）" || { echo "  ❌ 扇区 64 不是 idbloader（$(magic 64)）—— 镜像里没写引导链？"; FAIL=1; }
[ "$(magic $P1_START)" = "d00dfeed" ] && echo "  ✅ 扇区 16384 是 u-boot.itb（FIT）" || { echo "  ❌ 扇区 16384 不是 FIT（$(magic $P1_START)）"; FAIL=1; }
nz=$(dd if="$FULL" bs=512 skip=$HOLE_START count=$HOLE_SECTORS status=none | tr -d '\0' | wc -c)
[ "$nz" = 0 ] && echo "  ✅ 7168–10239 全零（不带任何机器的 vendor storage / RKSS）" || { echo "  ❌ 空洞里有 $nz 个非零字节"; FAIL=1; }
if dd if="$FULL" bs=512 skip=$P2_START count=1 status=none | grep -qa "FAT\|mkfs"; then
  echo "  ✅ 24576 起是 bootfs 的 FAT 引导扇区"
else
  echo "  ⚠️  24576 处没认出 FAT 特征（不一定是错，但值得核对）"
fi

(cd "$OUT" && rm -f w132d-gpt.bin w132d-p2p3.img && rm -f u-boot-initial-env && sha256sum "$(basename "$FULL")" > SHA256SUMS)
sed "s/^/  /" "$OUT/SHA256SUMS"
echo
[ "$FAIL" = 0 ] || die "自检未通过，不要用这份发布物"
echo "RELEASE_OK $OUT"
echo "  刷写：tools/flash.sh $OUT   （设备按住针孔上电进 MaskROM，USB 直连）"
