# ZTE W132D 整盘刷写（Windows / PowerShell）。需要 rkdeveloptool.exe 在 PATH 里。
# 逻辑与 flash.sh 相同：MaskROM -> db loader -> wl 0 w132d.img -> 回读抽样比对 -> rd。
# ⚠️ 未在 Windows 上实测；没有 rkdeveloptool.exe 的话用 RKDevTool 图形工具（见 README）。
$ErrorActionPreference = "Stop"
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$Img = Join-Path $Here "w132d.img"
$Loader = Join-Path $Here "rk3528_loader_v1.13.107.bin"
$P1 = 16384; $P2 = 24576; $P3 = 1073152

function Die($m) { Write-Host "ERROR: $m" -ForegroundColor Red; exit 1 }
if (-not (Get-Command rkdeveloptool -ErrorAction SilentlyContinue)) { Die "rkdeveloptool.exe 不在 PATH 里" }
if (-not (Test-Path $Img)) { Die "缺 $Img" }
if (-not (Test-Path $Loader)) { Die "缺 $Loader" }
$ImgSize = (Get-Item $Img).Length
if ($ImgSize % 512 -ne 0) { Die "镜像大小不是 512 的倍数" }
$Total = [int64]($ImgSize / 512)
Write-Host "镜像 $ImgSize B（$Total 扇区）"

$ld = & rkdeveloptool ld 2>&1 | Out-String
Write-Host $ld
if ($ld -notmatch "DevNo") { Die "没找到设备：按住 Reset 针孔上电，USB 直连" }
if ($ld -match "Loader") {
    Write-Host "厂商 Loader 模式，rd 3 复位进 MaskROM ..."
    & rkdeveloptool rd 3 | Out-Null
    Start-Sleep -Seconds 5
    $ld = & rkdeveloptool ld 2>&1 | Out-String
    if ($ld -notmatch "Maskrom") { Die "rd 3 之后没进 MaskROM，请断电按住针孔重试" }
}
Write-Host "下载 loader ..."
& rkdeveloptool db $Loader | Out-Null
Start-Sleep -Seconds 2

Write-Host "即将整盘覆盖 eMMC（出厂系统、厂商 U-Boot、vendor storage 全部清除）。"
$a = Read-Host "输入 yes 继续"
if ($a -ne "yes") { Die "已取消" }

Write-Host "写整盘镜像（几分钟）..."
& rkdeveloptool wl 0 $Img
if ($LASTEXITCODE -ne 0) { Die "写镜像失败" }

# 回读抽样比对
$Tmp = Join-Path $env:TEMP ("w132d-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $Tmp | Out-Null
$fs = [System.IO.File]::OpenRead($Img)
function Check($start, $count, $what) {
    $rb = Join-Path $Tmp "rb.bin"
    & rkdeveloptool rl $start $count $rb | Out-Null
    $exp = New-Object byte[] ($count * 512)
    $fs.Seek([int64]$start * 512, "Begin") | Out-Null
    $n = $fs.Read($exp, 0, $exp.Length)
    $got = [System.IO.File]::ReadAllBytes($rb)
    if ($got.Length -lt $n) { Write-Host "  ✗ $what 回读不足" -ForegroundColor Red; return $false }
    for ($i = 0; $i -lt $n; $i++) { if ($got[$i] -ne $exp[$i]) { Write-Host "  ✗ $what 不一致（扇区 $start）" -ForegroundColor Red; return $false } }
    Write-Host "  ✓ $what"
    return $true
}
$ok = $true
$ok = (Check 0 64 "GPT") -and $ok
$ok = (Check 64 340 "idbloader") -and $ok
$ok = (Check 7168 64 "vendor storage 位置已清零") -and $ok
$ok = (Check $P1 1536 "u-boot.itb") -and $ok
for ($i = 0; $i -lt 16; $i++) { $off = $P2 + [int64](($Total - $P2) * $i / 16); $ok = (Check $off 8 "p2/p3 采样 $i") -and $ok }
$ok = (Check ($Total - 8) 8 "末尾") -and $ok
$ok = (Check ($P3 + 2) 8 "p3 超级块") -and $ok
$fs.Close(); Remove-Item -Recurse -Force $Tmp
if (-not $ok) { Die "回读比对失败：别重启，重刷一次" }

& rkdeveloptool rd | Out-Null
Write-Host "FLASH_OK — 设备已重启。首次开机要几分钟。"
