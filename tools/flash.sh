#!/bin/bash
# SPDX-License-Identifier: MIT
# 把两段式发布物刷进 W132D。
#
# 用法：
#   tools/flash.sh [发布目录]        默认 out/release
#   加 --dry-run 只做检查、不写任何东西；--verify-only 只把 eMMC 回读与发布物比对
#   W132D_SPL_LOADER=<path> 指向 rkbin 的 rk3528 SPL loader（必需，见下）
#
# 需要设备进入 Loader 或 MaskROM：用顶针按住 HDMI 口旁的 Reset 针孔，
# 保持按住插入电源，用 USB-A 直连电脑（别经 hub）。
#
# ## 只写两段，中间那段永不触碰
#
#   扇区 0–63        GPT（保护性 MBR + 主 GPT + 保留区）        ← 写
#   扇区 64–16383    idbloader（DDR 训练 + SPL）、vendor storage ← **永不写**
#                    （SN / MAC / HDCP Key / IMEI）、RKSS
#   扇区 16384–24575 p1，厂商 U-Boot FIT                        ← **永不写**
#   扇区 24576 起    bootfs + rootfs                            ← 写
#
# 中间那段是**设备自己的**：DDR blob 与内存批次绑定，别人的刷进来起不来；
# vendor storage 里是逐机身份，覆盖了就找不回。用它自己的就能启动本项目的
# Linux（2026-08-28 实测），所以既不需要事先备份 L0，也不会丢身份。
#
# 本脚本因此**不提供任何写入 64–24575 的路径**，连选项都没有。
#
# ## ⚠️ 厂商 miniloader 写大文件会静默截断（2026-09-04 实测，两次刷写都栽在这）
#
# 按针孔进的 Loader 是设备自己 idbloader 里的厂商 miniloader。用它 `wl` 2.4 GB 的净荷，
# rkdeveloptool 一路报到 100%、返回成功，**但 eMMC 上只有前 16–24 MB 是对的**，
# 后面全是 0xCC 填充 —— Image/uInitrd 都在那之后，设备当然起不来。回读比对才发现。
# 所以：
#   1. 写入一律走 rkbin 的 SPL loader（usbplug）：`rd 3` 让设备从 Loader 复位进 MaskROM，
#      `db` 下载 loader，再写。老构建链就是这么刷的（"db 下去后能驱动本机 eMMC"）。
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

HERE="$(cd "$(dirname "$0")/.." && pwd)"
DIR="${1:-$HERE/out/release}"
[ "${1:-}" = "--dry-run" ] && { DIR="$HERE/out/release"; }
DRY=0; VERIFY_ONLY=0
for a in "$@"; do [ "$a" = "--dry-run" ] && DRY=1; [ "$a" = "--verify-only" ] && VERIFY_ONLY=1; done
[ "$VERIFY_ONLY" = 1 ] && DIR="${DIR%--verify-only}"

GPT="$DIR/w132d-gpt.bin"
PAYLOAD="$DIR/w132d-p2p3.img"
P2_START=24576
GPT_SECTORS=64
LOADER="${W132D_SPL_LOADER:-}"

step(){ echo; echo "########## $* ##########"; }
die(){ echo "❌ $*" >&2; exit 1; }

# 回读抽样：GPT 全部 64 扇区逐字节；净荷按等距 16 个点 + 末尾 + p3 的 ext4 超级块所在扇区，
# 每点 8 扇区与文件比对。厂商 miniloader 截断时前 16 MB 是对的、后面全 0xCC，
# 这样的采样一定抓得住；SPL loader 出问题时也一样。
verify_written() {
  local tmp; tmp=$(mktemp -d); local fail=0
  rkdeveloptool rl 0 "$GPT_SECTORS" "$tmp/gpt" >/dev/null 2>&1 && cmp -s "$tmp/gpt" "$GPT" \
    && echo "    ✅ GPT 逐字节一致" || { echo "    ❌ GPT 回读不一致"; fail=1; }
  local total=$(( $(stat -f%z "$PAYLOAD" 2>/dev/null || stat -c%s "$PAYLOAD") / 512 ))
  local pts=() i
  for i in $(seq 0 15); do pts+=( $(( total * i / 16 )) ); done
  pts+=( $(( total - 8 )) $(( 1073152 - P2_START + 2 )) )   # 末尾、p3 超级块（分区起点+1 KiB）
  for off in "${pts[@]}"; do
    dd if="$PAYLOAD" bs=512 skip="$off" count=8 2>/dev/null > "$tmp/f"
    if rkdeveloptool rl $((P2_START + off)) 8 "$tmp/d" >/dev/null 2>&1 && cmp -s "$tmp/d" "$tmp/f"; then
      :
    else
      printf '    ❌ 扇区 %d（净荷偏移 %d MB）回读不一致\n' $((P2_START + off)) $((off / 2048)); fail=1
    fi
  done
  [ "$fail" = 0 ] && echo "    ✅ 净荷 ${#pts[@]} 个采样点全部一致（含 p3 超级块）"
  rm -rf "$tmp"; return $fail
}

command -v rkdeveloptool >/dev/null \
  || die "缺 rkdeveloptool（https://github.com/rockchip-linux/rkdeveloptool）"

step "1/5 核对发布物"
[ -f "$GPT" ]     || die "缺 $GPT —— 先跑 tools/make-release.sh"
[ -f "$PAYLOAD" ] || die "缺 $PAYLOAD"
gpt_size=$(stat -f%z "$GPT" 2>/dev/null || stat -c%s "$GPT")
# GPT 文件必须**恰好** 64 个扇区。多一个字节就会写进 64 号扇区，
# 那是 idbloader 的地盘 —— 这条断言是本脚本最重要的一道闸。
[ "$gpt_size" = "$((GPT_SECTORS * 512))" ] \
  || die "GPT 文件是 $gpt_size B，必须恰好 $((GPT_SECTORS * 512)) B（64 扇区）；再多就会写到 idbloader 上"
echo "  ✅ GPT $gpt_size B（扇区 0–63）"
echo "  ✅ 净荷 $(stat -f%z "$PAYLOAD" 2>/dev/null || stat -c%s "$PAYLOAD") B（写到扇区 $P2_START 起）"
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

if [ "$VERIFY_ONLY" = 1 ]; then
  step "只回读比对（不写）"
  verify_written && echo "VERIFY_OK" || die "eMMC 上的内容与发布物不一致"
  exit 0
fi

step "3/5 准备写入通道"
if [ "$MODE" = Loader ] && [ -n "$LOADER" ]; then
  # 厂商 miniloader 写大文件会静默截断（见抬头）。有 SPL loader 就先复位进 MaskROM 换掉它。
  echo "  当前是厂商 Loader，复位进 MaskROM 换用 SPL loader（rd 3）"
  if [ "$DRY" = 0 ]; then
    rkdeveloptool rd 3 >/dev/null 2>&1 || true
    for _ in $(seq 1 15); do sleep 1; rkdeveloptool ld 2>&1 | grep -qi Maskrom && break; done
    rkdeveloptool ld 2>&1 | sed 's/^/  /'
    rkdeveloptool ld 2>&1 | grep -qi Maskrom && MODE=Maskrom \
      || die "rd 3 之后没进 MaskROM。请断电、按住针孔上电重试；若仍是 Loader，说明这台的 miniloader 不认 rd 3"
  fi
elif [ "$MODE" = Loader ]; then
  die "只有厂商 Loader 而没有 SPL loader：它写大文件会静默截断，不能用。设 W132D_SPL_LOADER=<rkbin 的 rk3528 loader>"
fi
if [ "$MODE" = Maskrom ]; then
  # MaskROM 下 eMMC 还没初始化，必须先把 loader 下到 SRAM 里跑起来
  [ -n "$LOADER" ] || die "MaskROM 模式需要 SPL loader：设 W132D_SPL_LOADER=<path>
     它由 rkbin 的 boot_merger 按 RKBOOT/RK3528MINIALL.ini 打出来
     （DDR blob + usbplug + SPL），产物名形如 rk3528_loader_v1.13.107.bin"
  [ -f "$LOADER" ] || die "loader 不存在：$LOADER"
  echo "  下载 loader：$(basename "$LOADER")"
  [ "$DRY" = 1 ] || rkdeveloptool db "$LOADER" || die "db 失败"
  sleep 2
  # db 之后应当变成 Loader
  rkdeveloptool ld 2>&1 | sed 's/^/  /'
fi

step "4/5 写入"
cat <<EOF
  即将写入：
    扇区 0       <- $(basename "$GPT")（64 扇区）
    扇区 $P2_START   <- $(basename "$PAYLOAD")
  **不会**触碰扇区 64–24575（idbloader / vendor storage / 厂商 U-Boot）
EOF
if [ "$DRY" = 1 ]; then
  echo "  （--dry-run，不写）"
else
  printf '  确认写入？输入 yes 继续：'
  read -r answer
  [ "$answer" = "yes" ] || die "已取消"
  echo "  写 GPT ..."
  rkdeveloptool wl 0 "$GPT" || die "写 GPT 失败（若 ld 已变成 Maskrom，重新上电再来）"
  echo "  写净荷 ...（2.5 GB，几分钟）"
  rkdeveloptool wl "$P2_START" "$PAYLOAD" || die "写净荷失败"
  echo "  ✅ 两段都写完了 —— 但 100% 不算数，回读比对："
  verify_written || die "回读比对失败：eMMC 上的内容与发布物不一致，设备不会启动。别重启，换 loader 重刷"
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

⚠️ 关于出厂 BL31 每约 32 分钟打死整机的缺陷（安全侧串口调试器在宽限期后扫
   波特率，往 console 喷训练帧并改写 UART 时钟分频），镜像里带了两条路：

   1. **实验性**：w132d-bl31-cookie.service 开机早期往 GRF 0xff370220 写握手
      cookie 0x2b4d1f7a，BL31 查到就直接返回。零补丁、对 rkbin 各版本都有效，
      但尚未在未打补丁的 BL31 上实机验证。看结果：
        systemctl status w132d-bl31-cookie   （应为 active、"cookie present"）
        uptime > 40 min 且 console 没有 #/8/--/] 帧 → 成立
   2. **已验证**：给设备自己那份 BL31 打 4 字节补丁 —— p1 内 atf-1 偏移 0x188d4，
      `89 fe ff 54` -> `f4 ff ff 17`，并同步改 FIT 里 atf-1 的 sha256。
      换 rkbin 新 blob 没用（v1.21 同样有这个问题）。
EOF
