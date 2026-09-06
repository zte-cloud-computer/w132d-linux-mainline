#!/bin/bash
# SPDX-License-Identifier: MIT
# 把目录里的 .deb 做成扁平 apt 仓库的元数据并签名（Packages、Release、InRelease、Release.gpg）。
# 用法：bash tools/apt-repo.sh <debs 目录> <输出目录>；需要 apt-ftparchive 与已导入签名密钥的 gpg。
set -euo pipefail
DEBS="${1:?debs 目录}"; OUT="${2:?输出目录}"
ORIGIN="W132D"
command -v apt-ftparchive >/dev/null || { echo "缺 apt-ftparchive（apt-utils）" >&2; exit 1; }
mkdir -p "$OUT"; rm -f "$OUT"/Packages "$OUT"/Packages.gz "$OUT"/Release "$OUT"/InRelease "$OUT"/Release.gpg
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
cp "$DEBS"/*.deb "$work"/ 2>/dev/null || true
( cd "$work" && apt-ftparchive packages . ) | sed "s#^Filename: \./#Filename: #" > "$OUT/Packages"
gzip -9 -k -f "$OUT/Packages"
( cd "$OUT" && apt-ftparchive \
    -o "APT::FTPArchive::Release::Origin=$ORIGIN" \
    -o "APT::FTPArchive::Release::Label=ZTE W132D mainline Linux" \
    -o "APT::FTPArchive::Release::Suite=stable" \
    -o "APT::FTPArchive::Release::Architectures=arm64" \
    -o "APT::FTPArchive::Release::Description=Kernel, U-Boot and bsp packages for the ZTE Cloud Computer W132D" \
    release . ) > "$work/Release"
mv "$work/Release" "$OUT/Release"
gpg --batch --yes --clearsign --digest-algo SHA256 -o "$OUT/InRelease" "$OUT/Release"
gpg --batch --yes --armor --detach-sign --digest-algo SHA256 -o "$OUT/Release.gpg" "$OUT/Release"
echo "apt 仓库元数据：$(grep -c '^Package:' "$OUT/Packages") 个包 → $OUT"
