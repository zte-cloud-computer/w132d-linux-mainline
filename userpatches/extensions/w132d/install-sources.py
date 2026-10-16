#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Install locally maintained sources into a clean kernel checkout."""
from pathlib import Path
import shutil
import sys


def install(tree):
    source = Path(__file__).resolve().parent
    tree = Path(tree)
    for name, target in (("uwe5621ds", "drivers/net/wireless/uwe5621ds"),
                         ("codecs", "sound/soc/codecs/w132d")):
        destination = tree / target
        if destination.exists():
            raise ValueError(f"Unexpected existing driver directory: {destination}")
        shutil.copytree(source / "drivers" / name, destination)
    additions = {
        "drivers/net/wireless/Kconfig": 'source "drivers/net/wireless/uwe5621ds/Kconfig"',
        "drivers/net/wireless/Makefile": 'obj-$(CONFIG_SPARD_WLAN_SUPPORT) += uwe5621ds/',
        "sound/soc/codecs/Kconfig": 'source "sound/soc/codecs/w132d/Kconfig"',
        "sound/soc/codecs/Makefile": 'obj-y += w132d/',
        "arch/arm64/boot/dts/rockchip/Makefile": 'dtb-$(CONFIG_ARCH_ROCKCHIP) += rk3528-w132d.dtb',
    }
    for name, line in additions.items():
        path = tree / name
        with path.open("a") as f:
            f.write("\n" + line + "\n")
    for p in (source / "dts").iterdir():
        shutil.copy2(p, tree / "arch/arm64/boot/dts/rockchip" / p.name)
    if (source / "bindings").exists():
        shutil.copytree(source / "bindings", tree / "Documentation/devicetree/bindings", dirs_exist_ok=True)


if __name__ == "__main__":
    install(sys.argv[1])
