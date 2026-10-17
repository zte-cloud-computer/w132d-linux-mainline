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
from .packages import check_board_overlay, check_dtb


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


def check_extlinux(boot):
    boot = Path(boot)
    text = (boot / "extlinux/extlinux.conf").read_text()
    require("rk3528-w132d.dtb" in text, "extlinux selects the wrong DTB")
    entries = re.findall(r"(?im)^\s*(linux|kernel|initrd|fdt)\s+(\S+)", text)
    kinds = {kind.lower() for kind, _ in entries}
    require(bool(kinds & {"linux", "kernel"}) and {"initrd", "fdt"} <= kinds,
            "extlinux is missing a kernel, initrd or DTB entry")
    for kind, value in entries:
        require((boot / value.lstrip("/")).is_file(), f"Missing extlinux {kind}: {value}")
    require(re.search(r"(?im)^\s*append\s+.*\broot=(?:UUID|PARTUUID)=\S+", text), "extlinux has no persistent root device")
    require("console=ttyS0,115200" in text, "extlinux is missing the UART0 console")
    require(not (boot / "boot.scr").exists(), "Unexpected boot.scr alongside extlinux")


def check_board_runtime(root):
    root = Path(root)
    check_board_overlay(root)
    for module in ("dbus", "gi"):
        require((root / "usr/lib/python3/dist-packages" / module).is_dir(), "Missing Python runtime module: " + module)
    units = root / "usr/lib/systemd/system"
    for unit in [*units.glob("w132d-*.service"), *units.glob("*.service.d/*w132d*.conf")]:
        text = unit.read_text()
        for executable in re.findall(r"(?m)^Exec\w+=-?(/\S+)", text):
            target = root / executable.lstrip("/")
            require(target.is_file() and target.stat().st_mode & 0o111, "Missing service executable: " + executable)
        for dependencies in re.findall(r"(?m)^(?:Requires|After|Before|Wants|PartOf)=(.*)$", text):
            for dependency in re.findall(r"\bw132d-[\w-]+\.service\b", dependencies):
                require(any((directory / dependency).is_file() for directory in
                            (units, root / "etc/systemd/system")), "Missing board service dependency: " + dependency)
    getty = root / "etc/systemd/system/getty.target.wants"
    require((getty / "serial-getty@ttyS0.service").is_symlink(), "UART0 serial getty is not enabled")
    require(not (getty / "serial-getty@ttyS2.service").is_symlink(), "Unexpected UART2 serial getty")


def check_apt_sources(root, repository):
    sources = Path(root) / "etc/apt/sources.list.d"
    require(not list(sources.glob("w132d*.sources.disabled")), "Build-only APT source files remain in the image")
    source = (sources / "w132d.sources").read_text()
    require("Suites: stable" in source and repository in source, "Image must default to stable APT")
    require(not re.search(r"(?im)^Enabled:\s*no\s*$", source), "Stable APT must be enabled in new images")
    experimental = (sources / "w132d-experimental.sources").read_text()
    require("Enabled: no" in experimental, "Experimental APT must be disabled in new images")
    pin = (Path(root) / "etc/apt/preferences.d/w132d-kernel").read_text()
    require("Pin: release o=W132D,a=experimental\nPin-Priority: -1" in pin, "Experimental pin is not disabled")


def verify_image(path, lock, destination):
    path = Path(path)
    dest = Path(destination)
    table = layout(path)
    parts = table["partitions"]
    require(parts[0]["start"] == lock["layout"]["partition_offset_mib"] * 2048, "Unexpected boot partition offset")
    require(parts[0]["size"] == lock["layout"]["boot_size_mib"] * 2048, "Unexpected boot partition size")
    require("LegacyBIOSBootable" in parts[0].get("attrs", ""), "Boot partition is not marked bootable")
    require(parts[0]["start"] + parts[0]["size"] <= parts[1]["start"], "Overlapping partitions")
    # sgdisk reports some failures on stdout even when it exits successfully.
    gpt = output(["sgdisk", "--verify", path])
    require("No problems found" in gpt, "GPT verification failed: " + gpt)
    with path.open("rb") as image:
        image.seek(lock["layout"]["reserved_start_sector"] * 512)
        size = (lock["layout"]["reserved_end_sector"] - lock["layout"]["reserved_start_sector"]) * 512
        require(image.read(size) == bytes(size), "Image contains data in vendor storage / RKSS")
    with mounted(path) as (root, boot):
        check_board_runtime(root)
        rows = [r.split("\t") for r in installed(root)]
        versions = {r[0]: r[1] for r in rows if r[3] == "installed"}
        for name in (PACKAGES[0], PACKAGES[1], PACKAGES[4], PACKAGES[5]):
            require(versions.get(name) == lock["version"], "Image package version mismatch: " + name)
        (dest / "userspace-packages.tsv").write_text("\n".join("\t".join(r) for r in rows if r[3] == "installed") + "\n")
        check_apt_sources(root, lock["repository"])
        firmware = root / "lib/firmware/uwe5622/wcnmodem-marlin3e.bin"
        require(sha256(firmware) == lock["blobs"]["wcn"]["sha256"], "Image firmware mismatch")
        for unit in ("w132d-wireless", "w132d-ble-remote", "w132d-ir-keymap", "w132d-led-status", "w132d-soft-standby"):
            require((root / f"etc/systemd/system/multi-user.target.wants/{unit}.service").is_symlink(), "Service not enabled: " + unit)
        require(any(p.is_symlink() for p in (root / "etc/systemd/system").rglob("*resize*")), "Missing native first-boot resize service")
        check_extlinux(boot)
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
