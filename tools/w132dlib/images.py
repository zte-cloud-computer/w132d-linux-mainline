# SPDX-License-Identifier: MIT
"""Verify the native Armbian image without changing its partition layout."""
from contextlib import contextmanager
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

from .common import PACKAGES, output, require, run, sha256, write_json
from .packages import check_dtb


def layout(path):
    data = json.loads(output(["sfdisk", "--json", path]))["partitiontable"]
    require(data["label"] == "gpt", "Image must use GPT")
    require(data["sectorsize"] == 512, "Unsupported sector size")
    require(len(data["partitions"]) == 2, "Expected native Armbian boot and root partitions")
    return data


@contextmanager
def mounted(path):
    privilege = [] if os.geteuid() == 0 else ["sudo"]
    with tempfile.TemporaryDirectory(prefix="w132d-image-") as temp:
        root = Path(temp)
        loop = output([*privilege, "losetup", "--find", "--show", "--read-only", "--partscan", Path(path).resolve()])
        mounts = []
        try:
            for number, name, options in ((2, "root", "ro,noload"), (1, "boot", "ro")):
                target = root / name
                target.mkdir()
                run([*privilege, "mount", "-o", options, loop + f"p{number}", target])
                mounts.append(target)
            yield root / "root", root / "boot"
        finally:
            for target in reversed(mounts):
                run([*privilege, "umount", target])
            run([*privilege, "losetup", "-d", loop])


def installed(root):
    return output(["dpkg-query", "--admindir=" + str(root / "var/lib/dpkg"), "-W",
                   "-f=${Package}\t${Version}\t${Architecture}\t${db:Status-Status}\n"]).splitlines()


def matches_version(path, version):
    with mounted(path) as (root, boot):
        rows = [r.split("\t") for r in installed(root)]
        return [r[1] for r in rows if r[0] == PACKAGES[5] and r[3] == "installed"] == [version]


def verify_image(path, lock, destination):
    path = Path(path)
    dest = Path(destination)
    table = layout(path)
    parts = table["partitions"]
    require(parts[0]["start"] == lock["layout"]["partition_offset_mib"] * 2048, "Unexpected boot partition offset")
    require(parts[0]["start"] + parts[0]["size"] <= parts[1]["start"], "Overlapping partitions")
    # sgdisk reports some failures on stdout even when it exits successfully.
    gpt = output(["sgdisk", "--verify", path])
    require("No problems found" in gpt, "GPT verification failed: " + gpt)
    with mounted(path) as (root, boot):
        rows = [r.split("\t") for r in installed(root)]
        versions = {r[0]: r[1] for r in rows if r[3] == "installed"}
        for name in (PACKAGES[0], PACKAGES[1], PACKAGES[4], PACKAGES[5]):
            require(versions.get(name) == lock["version"], "Image package version mismatch: " + name)
        (dest / "userspace-packages.tsv").write_text("\n".join("\t".join(r) for r in rows if r[3] == "installed") + "\n")
        source = (root / "etc/apt/sources.list.d/w132d.sources").read_text()
        require("Suites: stable" in source and lock["repository"] in source, "Image must default to stable APT")
        experimental = (root / "etc/apt/sources.list.d/w132d-experimental.sources").read_text()
        require("Enabled: no" in experimental, "Experimental APT must be disabled in new images")
        pin = (root / "etc/apt/preferences.d/w132d-kernel").read_text()
        require("Pin: release o=W132D,a=experimental\nPin-Priority: -1" in pin, "Experimental pin is not disabled")
        firmware = root / "lib/firmware/uwe5622/wcnmodem-marlin3e.bin"
        require(sha256(firmware) == lock["blobs"]["wcn"]["sha256"], "Image firmware mismatch")
        for unit in ("w132d-wireless", "w132d-ble-remote", "w132d-ir-keymap", "w132d-led-status", "w132d-soft-standby"):
            require((root / f"etc/systemd/system/multi-user.target.wants/{unit}.service").is_symlink(), "Service not enabled: " + unit)
        require(any(p.is_symlink() for p in (root / "etc/systemd/system").rglob("*resize*")), "Missing native first-boot resize service")
        extlinux = boot / "extlinux/extlinux.conf"
        text = extlinux.read_text()
        require("rk3528-w132d.dtb" in text, "extlinux selects the wrong DTB")
        for kind, value in re.findall(r"(?im)^\s*(linux|initrd|fdt)\s+(\S+)", text):
            require((boot / value.lstrip("/")).is_file(), f"Missing extlinux {kind}: {value}")
        dtbs = list(boot.rglob("rk3528-w132d.dtb"))
        require(len(dtbs) == 1, "Expected one boot DTB")
        check_dtb(dtbs[0])
        bootdir = root / "usr/lib/linux-u-boot-edge-w132d"
        from .packages import check_bootloader
        check_bootloader(bootdir, lock["layout"])
        components = {}
        with path.open("rb") as image:
            for name, key in (("idbloader.img", "idbloader_sector"), ("u-boot.itb", "uboot_sector")):
                data = (bootdir / name).read_bytes()
                image.seek(lock["layout"][key] * 512)
                require(image.read(len(data)) == data, "Image boot component differs from package: " + name)
                components[name] = {"sector": lock["layout"][key], "size": len(data), "sha256": sha256(bootdir / name)}
    report = {"schema": 1, "image": path.name, "sha256": sha256(path), "size": path.stat().st_size,
              "version": lock["version"], "layout": table, "boot_components": components}
    write_json(dest / "image-verification.json", report)
    print("Native image verification passed")
    return report
