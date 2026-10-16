# SPDX-License-Identifier: MIT
"""Package selection, dependency finalization and artifact verification."""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

from .common import PACKAGES, ROOT, output, require, run, sha256, write_json

RUNTIME_DEPENDS = "bluez, rfkill, ir-keytable, python3, python3-dbus, python3-gi, alsa-utils, util-linux, kmod, dbus, init-system-helpers, v4l-utils, libdrm-tests, wireless-regdb"
MODULES = ("snd-soc-rk3528", "snd-soc-es7202", "sprdwl_ng", "uwe5622_bsp_sdio",
           "sprdbt_tty", "rockchip-vdec", "lima", "gpio-ir-recv", "rockchipdrm",
           "phy-rockchip-inno-hdmi", "snd-soc-rockchip-sai")


def metadata(path):
    fields = output(["dpkg-deb", "--field", path])
    result = {}
    for line in fields.splitlines():
        if line and not line[0].isspace() and ":" in line:
            key, value = line.split(":", 1)
            result[key] = value.strip()
    return result


def select(directory, version, required):
    found = {}
    for p in sorted(Path(directory).rglob("*.deb")):
        m = metadata(p)
        if m.get("Package") not in required or m.get("Version") != version:
            continue
        name = m["Package"]
        require(m["Architecture"] == "arm64", f"Unexpected architecture: {p}")
        if name in found:
            require(sha256(found[name]) == sha256(p), f"Conflicting packages: {name} {version}")
        found[name] = p
    require(set(found) == set(required), f"Missing packages: {sorted(set(required) - set(found))}")
    return found


def finalize(path, epoch=None):
    """Finalize before image installation and collection, with identical bytes.

    Armbian has no control-field extension hook. This changes only the locally
    produced packages, never the framework or the hashed upstream cache.
    """
    path = Path(path)
    m = metadata(path)
    if m["Package"] not in (PACKAGES[0], PACKAGES[5]):
        return
    addition = (f"{PACKAGES[1]} (= {m['Version']})" if m["Package"] == PACKAGES[0]
                else RUNTIME_DEPENDS)
    if all(x.strip() in m.get("Depends", "").split(", ") for x in addition.split(", ")):
        return
    with tempfile.TemporaryDirectory(prefix="w132d-deb-") as temp:
        directory = Path(temp) / "pkg"
        run(["dpkg-deb", "--raw-extract", path, directory], stdout=subprocess.DEVNULL)
        control = directory / "DEBIAN/control"
        text = control.read_text()
        if "Depends:" in text:
            text = re.sub(r"^Depends: (.*)$", lambda x: x[0] + ", " + addition, text, flags=re.M)
        else:
            text += "Depends: " + addition + "\n"
        control.write_text(text)
        epoch = int(epoch if epoch is not None else os.environ.get("SOURCE_DATE_EPOCH", "0"))
        for p in [directory, *directory.rglob("*")]:
            if not p.is_symlink():
                os.utime(p, (epoch, epoch))
        result = path.with_suffix(".finalized.deb")
        run(["dpkg-deb", "--root-owner-group", "-Zxz", "--build", directory, result], stdout=subprocess.DEVNULL,
            env=dict(os.environ, SOURCE_DATE_EPOCH=str(epoch)))
        result.replace(path)


def collect(directory, destination, lock, full=False):
    required = PACKAGES if full else PACKAGES[:4]
    selected = select(directory, lock["version"], required)
    dest = Path(destination)
    dest.mkdir(parents=True, exist_ok=True)
    for name, path in selected.items():
        finalize(path, lock["source_date_epoch"])
        target = dest / f"{name}_{lock['version']}_arm64.deb"
        if target.resolve() != path.resolve():
            shutil.copy2(path, target)
    return verify(dest, lock, full)


def check_dtb(path):
    expected = {
        ("/", "compatible"): "zte,w132d rockchip,rk3528",
        ("/soc/vop@ff840000", "compatible"): "rockchip,rk3528-vop",
        ("/soc/hdmi@ff8d0000", "compatible"): "rockchip,rk3528-dw-hdmi",
        ("/soc/phy@ffe00000", "compatible"): "rockchip,rk3528-hdmi-phy",
        ("/uwe-bsp", "unisoc,btwf-file-name"): "/lib/firmware/uwe5622/wcnmodem-marlin3e.bin",
    }
    for (node, prop), value in expected.items():
        require(output(["fdtget", "-t", "s", path, node, prop]) == value, f"Invalid DTB property: {node} {prop}")
    for node, prop in (("/soc/mmc@ffbf0000", "mmc-hs400-1_8v"),
                       ("/soc/mmc@ffbf0000", "mmc-hs400-enhanced-strobe"),
                       ("/regulator-vdd-cpu", "pwm-dutycycle-range"),
                       ("/soc/watchdog@ffac0000", "compatible"),
                       ("/soc/tsadc@ffad0000", "status"),
                       ("/soc/hdmi@ff8d0000", "hpd-gpios"),
                       ("/reserved-memory/ramoops@110000", "reg")):
        output(["fdtget", path, node, prop])
    for node, prop in (("/soc/vop@ff840000", "iommus"), ("/ir-receiver", "wakeup-source")):
        probe = subprocess.run(["fdtget", str(path), node, prop], capture_output=True)
        require(probe.returncode != 0, f"Unexpected DTB property: {node} {prop}")


def verify(directory, lock, full=False):
    selected = select(directory, lock["version"], PACKAGES if full else PACKAGES[:4])
    with tempfile.TemporaryDirectory(prefix="w132d-verify-") as temp:
        tree = Path(temp)
        for name, path in selected.items():
            run(["dpkg-deb", "--extract", path, tree], stdout=subprocess.DEVNULL)
        dtbs = list((tree / "boot").rglob("rk3528-w132d.dtb"))
        require(len(dtbs) == 1, "Expected one installed board DTB")
        check_dtb(dtbs[0])
        configs = list((tree / "boot").glob("config-*"))
        require(len(configs) == 1, "Expected one kernel configuration")
        config = configs[0].read_text()
        for setting in ("CONFIG_RK_WIFI_DEVICE_UWE5621DS=y", "CONFIG_WLAN_UWE5621DS=m", "CONFIG_PSTORE_CONSOLE=y", "CONFIG_PSTORE_RAM=y", "CONFIG_TTY_OVERY_SDIO_HCI=y",
                        "CONFIG_ROCKCHIP_VOP2=y", "CONFIG_ROCKCHIP_DW_HDMI=y"):
            require(setting in config.splitlines(), "Missing kernel setting: " + setting)
        for setting in ("CONFIG_RK_WIFI_DEVICE_UWE5621=y", "CONFIG_WLAN_UWE5621=y", "CONFIG_WLAN_UWE5622=y", "CONFIG_WCN_BSP_DRIVER_BUILDIN=y"):
            require(setting not in config.splitlines(), "Unexpected legacy wireless setting: " + setting)
        module_paths = list(tree.rglob("*.ko*"))
        for module in MODULES:
            require(any(p.name == module + ".ko" or p.name.startswith(module + ".ko.") for p in module_paths),
                    "Missing module: " + module)
        m = metadata(selected[PACKAGES[0]])
        require(f"{PACKAGES[1]} (= {lock['version']})" in m["Depends"], "Image must depend on matching DTB")
        if full:
            firmware = tree / "usr/lib/firmware/uwe5622/wcnmodem-marlin3e.bin"
            require(firmware.exists() and sha256(firmware) == lock["blobs"]["wcn"]["sha256"], "Invalid WCN firmware")
            bootdir = tree / "usr/lib/linux-u-boot-edge-w132d"
            check_bootloader(bootdir, lock["layout"])
            for dependency in RUNTIME_DEPENDS.split(", "):
                require(dependency in metadata(selected[PACKAGES[5]])["Depends"].split(", "), "Missing BSP dependency: " + dependency)
            require((tree / "usr/bin/w132d-channel").is_file(), "Missing channel selection helper")
            control = tree / "bsp-control"
            run(["dpkg-deb", "--control", selected[PACKAGES[5]], control], stdout=subprocess.DEVNULL)
            conffiles = set((control / "conffiles").read_text().splitlines())
            for config_file in (ROOT / "userpatches/overlay/bsp-cli/etc").rglob("*"):
                if config_file.is_file():
                    relative = config_file.relative_to(ROOT / "userpatches/overlay/bsp-cli")
                    require('/' + str(relative) in conffiles, "Board configuration is not a conffile: " + str(relative))
            for script in ("postinst", "prerm", "postrm"):
                require((control / script).is_file(), "Missing BSP service lifecycle script: " + script)
    records = [{"package": name, "version": lock["version"], "architecture": "arm64",
                "file": p.name, "sha256": sha256(p), "size": p.stat().st_size}
               for name, p in sorted(selected.items())]
    write_json(Path(directory) / "packages.json", records)
    print(f"Package verification passed: {len(records)} packages")
    return records


def check_bootloader(directory, layout):
    idb = Path(directory) / "idbloader.img"
    fit = Path(directory) / "u-boot.itb"
    require(idb.is_file() and 0 < idb.stat().st_size <= (layout["reserved_start_sector"] - layout["idbloader_sector"]) * 512,
            "idbloader overlaps reserved storage")
    require(fit.is_file() and 0 < fit.stat().st_size <= layout["partition_offset_mib"] * 1024**2 - layout["uboot_sector"] * 512,
            "U-Boot overlaps the first partition")
    data = fit.read_bytes()
    require(data[:4] == b"\xd0\x0d\xfe\xed", "Invalid U-Boot FIT")
    for marker in (b"mw.l 0xff370220 0x2b4d1f7a", b"rockchip,rk3528-saradc", b"download key pressed"):
        require(marker in data, f"Missing U-Boot feature: {marker.decode()}")
