#!/bin/bash
# SPDX-License-Identifier: MIT
# 把整盘镜像 w132d.img 刷进 W132D。
#
# 用法：
#   tools/flash.sh [发布目录或镜像文件]        默认 out/release
#   --dry-run 只做检查、不写任何东西；--verify-only 只把 eMMC 回读与镜像比对
#   W132D_SPL_LOADER=<path> 指向 rkbin 的 rk3528 loader；不给就用发布目录或 cache/rkbin 里的
#
# 需要设备进入 MaskROM：用顶针按住 HDMI 口旁的 Reset 针孔，保持按住插入电源，
# 用 USB-A 直连电脑（别经 hub）。针孔是 SARADC ch1 下载键，由 U-Boot proper 读到后
# 写 BOOT_BROM_DOWNLOAD 复位，BootROM 进 MaskROM（2026-09-04 实测）。
# 还在跑厂商 U-Boot 的设备按针孔进的是厂商 Loader 模式，本脚本用 `rd 3` 把它复位进 MaskROM。
#
# ## 整盘覆盖，不保留任何逐机数据
#
# 引导链全是主线的（rkbin DDR/BL31 blob + 主线 SPL/U-Boot），镜像自带，所以从扇区 0 整盘写。
# 出厂 vendor storage（扇区 7168 起，Rockchip 私有格式，主线两边都没有驱动）一并清零 ——
# 里面唯一有用的出厂 MAC 不抢救：U-Boot 按 OTP cpuid 派生一个固定地址注入 DT（主线 Rockchip
# 板的标准做法），每台机器固定、不同机器不同。2026-09-05 试过把出厂 MAC 迁进 U-Boot env，
# 能做但要维护一整套 env 生成（只写一条会让设备停在 U-Boot 提示符），不值得，作罢。
#
# ## ⚠️ 厂商 miniloader 写大文件会静默截断（2026-09-04 实测，两次刷写都栽在这）
#
# 厂商 Loader 模式用它 `wl` 2.4 GB，rkdeveloptool 一路报到 100%、返回成功，
# **但 eMMC 上只有前 16–24 MB 是对的**，后面全是 0xCC。所以：
#   1. 写入一律走 rkbin 的 loader（usbplug）：MaskROM 下 `db` 下载，再写。
#   2. 写完**必须回读抽样比对**（含 p3 的 ext4 超级块），"100%" 不算数。
#
# ## 三个设了闸的坑
#
# 1. `db` 在 Loader 模式下会被拒绝，只有 MaskROM 才需要。所以必须**先看 `ld`
#    报的模式再决定**，不能无脑 db。
# 2. 原厂 loader 在大批量读写后会崩，`ld` 会从 Loader 变成 Maskrom，此后所有命令
#    报 failed。看到这种情况先重新读一次模式，别急着怀疑别的。
# 3. `cmd | grep` 之后取 `$?` 拿到的是 grep 的状态，会把 rkdeveloptool 的失败
#    读成成功。这里一律用 `if cmd; then` 直接判。
set -uo pipefail

SELF="$(cd "$(dirname "$0")" && pwd)"
HERE="$(cd "$SELF/.." && pwd)"
DRY=0; VERIFY_ONLY=0; TARGET=""
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --verify-only) VERIFY_ONLY=1 ;;
    *) TARGET="$a" ;;
  esac
done
# 默认目标：在发布包里（脚本旁边就是 w132d.img）就用脚本所在目录；在仓库里就是 out/release
if [ -z "$TARGET" ]; then
  if [ -f "$SELF/w132d.img" ]; then TARGET="$SELF"; else TARGET="$HERE/out/release"; fi
fi
if [ -d "$TARGET" ]; then DIR="$TARGET"; IMG="$DIR/w132d.img"; else IMG="$TARGET"; DIR="$(dirname "$IMG")"; fi

GPT_SECTORS=64
VS_START=7168                          # 出厂 vendor storage 位置：镜像里必须是零
P1_START=16384; P2_START=24576; P3_START=1073152
# loader：发布包里自带一份；仓库里跑就用 cache/rkbin 的（tools/fetch-inputs.sh 生成）
LOADER="${W132D_SPL_LOADER:-}"
[ -n "$LOADER" ] || for c in "$DIR/rk3528_loader_v1.13.107.bin" "$HERE/cache/rkbin/rk3528_loader_v1.13.107.bin"; do [ -f "$c" ] && { LOADER="$c"; break; }; done

step(){ echo; echo "########## $* ##########"; }
die(){ echo "❌ $*" >&2; exit 1; }
fsize(){ stat -f%z "$1" 2>/dev/null || stat -c%s "$1"; }

# 回读抽样：GPT 全部 64 扇区逐字节；idbloader 与 u-boot.itb 整段逐字节；p2/p3 按等距
# 16 个点 + 末尾 + p3 的 ext4 超级块所在扇区，每点 8 扇区与镜像比对。厂商 miniloader
# 截断时前 16 MB 是对的、后面全 0xCC，这样的采样一定抓得住。
verify_written() {
  local tmp; tmp=$(mktemp -d); local fail=0
  local total=$(( $(fsize "$IMG") / 512 ))
  chk() {  # chk <起始扇区> <扇区数> <说明>
    dd if="$IMG" bs=512 skip="$1" count="$2" 2>/dev/null > "$tmp/f"
    if rkdeveloptool rl "$1" "$2" "$tmp/d" >/dev/null 2>&1 && cmp -s "$tmp/d" "$tmp/f"; then
      return 0
    else
      printf '    ❌ 扇区 %d 起 %d 扇区回读不一致（%s）\n' "$1" "$2" "$3"; fail=1; return 1
    fi
  }
  chk 0 $GPT_SECTORS "GPT" && echo "    ✅ GPT 逐字节一致"
  chk 64 340 "idbloader" && echo "    ✅ idbloader（64–403）逐字节一致"
  chk $VS_START 64 "vendor storage 位置（应为零）" && echo "    ✅ 7168 起已清零"
  chk $P1_START 1536 "u-boot.itb" && echo "    ✅ u-boot.itb（16384 起 1536 扇区）逐字节一致"
  local pts=() i
  for i in $(seq 0 15); do pts+=( $(( P2_START + (total - P2_START) * i / 16 )) ); done
  pts+=( $(( total - 8 )) $(( P3_START + 2 )) )   # 末尾、p3 超级块（分区起点 + 1 KiB）
  local ok=1
  for off in "${pts[@]}"; do chk "$off" 8 "p2/p3 采样" || ok=0; done
  [ "$ok" = 1 ] && echo "    ✅ p2/p3 ${#pts[@]} 个采样点全部一致（含 p3 超级块）"
  rm -rf "$tmp"; return $fail
}

command -v rkdeveloptool >/dev/null \
  || die "缺 rkdeveloptool（https://github.com/rockchip-linux/rkdeveloptool）"

step "1/5 核对发布物"
[ -f "$IMG" ] || die "缺 $IMG —— 先跑 tools/make-release.sh"
img_size=$(fsize "$IMG")
[ $((img_size % 512)) = 0 ] || die "镜像大小 $img_size 不是 512 的倍数"
[ "$img_size" -gt $((P3_START * 512)) ] || die "镜像只有 $img_size B，连 p3 起点都没到"
echo "  ✅ 镜像 $img_size B（$((img_size / 512)) 扇区）"
hole_nz=$(dd if="$IMG" bs=512 skip=$VS_START count=3072 2>/dev/null | tr -d '\0' | wc -c | tr -d ' ')
[ "$hole_nz" = 0 ] || die "镜像 7168–10239 有 $hole_nz 个非零字节 —— 这段该是零，别用这份镜像"
echo "  ✅ 镜像 7168–10239 全零（不带任何机器的 vendor storage）"
if [ -f "$DIR/SHA256SUMS" ]; then
  if (cd "$DIR" && shasum -a 256 -c SHA256SUMS >/dev/null 2>&1 \
       || sha256sum -c SHA256SUMS >/dev/null 2>&1); then
    echo "  ✅ SHA256 对得上"
  else
    die "SHA256 对不上 —— 发布物可能损坏，重新跑 make-release.sh"
  fi
fi

step "2/5 找设备"
LD_OUT=$(rkdeveloptool ld 2>&1) || true
echo "$LD_OUT" | sed 's/^/  /'
case "$LD_OUT" in
  *"not found any devices"*) die "没找到设备：确认按住 Reset 后再上电，USB-A 直连（别经 hub）" ;;
esac
DEVCOUNT=$(grep -c "DevNo" <<<"$LD_OUT" || true)
[ "$DEVCOUNT" = 1 ] || die "找到 $DEVCOUNT 台设备，必须恰好 1 台"
if grep -qi "Maskrom" <<<"$LD_OUT"; then
  MODE=Maskrom
elif grep -qi "Loader" <<<"$LD_OUT"; then
  MODE=Loader
else
  die "认不出设备模式：$LD_OUT"
fi
echo "  模式：$MODE"

step "3/5 准备写入通道"
if [ "$MODE" = Loader ]; then
  # 还在跑厂商 U-Boot 的设备。厂商 miniloader 写大文件会静默截断（见抬头），复位进 MaskROM 换 loader。
  echo "  当前是厂商 Loader，复位进 MaskROM 换用 rkbin loader（rd 3）"
  if [ "$DRY" = 0 ]; then
    rkdeveloptool rd 3 >/dev/null 2>&1 || true
    for _ in $(seq 1 15); do sleep 1; rkdeveloptool ld 2>&1 | grep -qi Maskrom && break; done
    rkdeveloptool ld 2>&1 | sed 's/^/  /'
    rkdeveloptool ld 2>&1 | grep -qi Maskrom && MODE=Maskrom \
      || die "rd 3 之后没进 MaskROM。请断电、按住针孔上电重试"
  fi
fi
[ -n "$LOADER" ] || die "需要 rkbin loader：设 W132D_SPL_LOADER=<path>
     它由 rkbin 的 boot_merger 按 RKBOOT/RK3528MINIALL.ini 打出来（DDR blob + usbplug + SPL），
     tools/fetch-inputs.sh 会生成 cache/rkbin/rk3528_loader_v1.13.107.bin"
[ -f "$LOADER" ] || die "loader 不存在：$LOADER"
if [ "$VERIFY_ONLY" = 1 ] || [ "$DRY" = 0 ]; then
  # MaskROM 下 eMMC 还没初始化，必须先把 loader 下到 SRAM 里跑起来；已经 db 过的话再 db 会被拒，无害
  if [ "$MODE" = Maskrom ]; then
    echo "  下载 loader：$(basename "$LOADER")"
    rkdeveloptool db "$LOADER" >/dev/null 2>&1 || echo "  （db 被拒：多半已经下载过，继续）"
    sleep 2
    rkdeveloptool ld 2>&1 | sed 's/^/  /'
  fi
fi

if [ "$VERIFY_ONLY" = 1 ]; then
  step "只回读比对（不写）"
  verify_written && echo "VERIFY_OK" || die "eMMC 上的内容与镜像不一致"
  exit 0
fi

step "4/5 写入"
cat <<EOF
  即将**整盘覆盖**：扇区 0 <- 镜像全部 $((img_size / 512)) 扇区
  出厂 vendor storage 一并清零；开机后 MAC 由 U-Boot 按 OTP cpuid 派生（固定，不等于出厂值）
EOF
if [ "$DRY" = 1 ]; then
  echo "  （--dry-run，不写）"
else
  printf '  确认写入？输入 yes 继续：'
  read -r answer
  [ "$answer" = "yes" ] || die "已取消"
  echo "  写整盘镜像（$img_size B，几分钟）..."
  rkdeveloptool wl 0 "$IMG" || die "写镜像失败（若 ld 已变成 Maskrom，重新上电再来）"
  echo "  ✅ 写完了 —— 但 100% 不算数，回读比对："
  verify_written || die "回读比对失败：eMMC 上的内容与镜像不一致，设备不会启动。别重启，换 loader 重刷"
fi

step "5/5 收尾"
if [ "$DRY" = 1 ]; then
  echo "  （--dry-run，不重启）"
else
  rkdeveloptool rd 2>&1 | sed 's/^/  /' || true
  echo "  已发出重启"
fi
cat <<'EOF'
FLASH_OK
ℹ️ 首次开机要几分钟：firstrun 扩容 rootfs、生成 SSH 密钥。第二次还慢就不是慢，是出问题了。
ℹ️ 出厂 BL31 每约 32 分钟打死整机的缺陷由镜像里的 w132d-bl31-cookie.service 绕过
   （开机早期往 GRF 0xff370220 写握手 cookie），rkbin 任何版本的 BL31 都适用。
   看状态：systemctl status w132d-bl31-cookie（应为 active、"cookie present"）
EOF
