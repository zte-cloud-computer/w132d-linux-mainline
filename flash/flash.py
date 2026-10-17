#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Flash a verified native W132D image using the bundled platform binary."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import sys
import tempfile
import time


def digest(path):
    h = hashlib.sha256()
    with Path(path).open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def contained(root, name):
    p = (root / name).resolve()
    if not p.is_relative_to(root.resolve()) or not p.is_file():
        raise ValueError("Missing or unsafe artifact path: " + name)
    return p


def validate(directory):
    root = Path(directory)
    manifest = json.loads((root / "flash-manifest.json").read_text())
    if manifest["schema"] != 1 or manifest["sector_size"] != 512:
        raise ValueError("Unsupported flash manifest")
    low, high = manifest["preserve_sectors"]
    if not 0 < low < high or manifest["image_size"] <= high * 512:
        raise ValueError("Invalid reserved storage range or image size")
    segments = sorted(manifest["segments"], key=lambda s: s["sector"])
    if len(segments) != 2 or segments[0]["sector"] != 0 or segments[1]["sector"] != high:
        raise ValueError("Expected the native image split around reserved storage")
    end = 0
    for item in segments:
        p = contained(root, item["file"])
        if p.stat().st_size != item["size"] or digest(p) != item["sha256"]:
            raise ValueError("Artifact checksum or size mismatch: " + item["file"])
        if item["sector"] < end or item["size"] % 512 or item["size"] <= 0:
            raise ValueError("Overlapping or unaligned flash segments")
        end = item["sector"] + item["size"] // 512
        if item["sector"] < high and end > low:
            raise ValueError("Flash segment overlaps reserved device storage")
    if segments[0]["size"] != low * 512 or end * 512 != manifest["image_size"]:
        raise ValueError("Flash segments do not cover the complete native image")
    components = manifest["boot_components"]
    if set(components) != {"idbloader.img", "u-boot.itb"}:
        raise ValueError("Missing boot components")
    for name, key, limit in (("idbloader.img", "idbloader_sector", low * 512),
                             ("u-boot.itb", "uboot_sector", manifest["layout"]["partition_offset_mib"] * 1024**2)):
        item = components[name]
        start, size = item["sector"] * 512, item["size"]
        if item["sector"] != manifest["layout"][key] or start < 0 or size <= 0 or start + size > limit:
            raise ValueError("Boot component exceeds its layout bounds: " + name)
        segment = next((s for s in segments if s["sector"] * 512 <= start and
                        start + size <= s["sector"] * 512 + s["size"]), None)
        if segment is None:
            raise ValueError("Boot component is outside the flashed image: " + name)
        with contained(root, segment["file"]).open("rb") as source:
            source.seek(start - segment["sector"] * 512)
            if hashlib.sha256(source.read(size)).hexdigest() != item["sha256"]:
                raise ValueError("Boot component checksum mismatch: " + name)
    loader = manifest["loader"]
    if digest(contained(root, loader["file"])) != loader["sha256"]:
        raise ValueError("Loader checksum mismatch")
    return manifest


def native_platform():
    system = {"Linux": "linux", "Darwin": "macos", "Windows": "windows"}.get(platform.system())
    arch = {"x86_64": "amd64", "AMD64": "amd64", "arm64": "arm64", "aarch64": "arm64"}.get(platform.machine())
    return f"{system}-{arch}"


class Device:
    def __init__(self, tool):
        self.tool = str(tool)

    def run(self, *args):
        proc = subprocess.run([self.tool, *map(str, args)], text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        if proc.returncode:
            raise RuntimeError("rkdeveloptool failed: " + proc.stdout.strip())
        return proc.stdout

    def one(self):
        listing = self.run("ld")
        devices = [line for line in listing.splitlines() if re.search(r"\bDevNo\s*=", line, re.I)]
        if len(devices) != 1:
            raise RuntimeError(f"Expected exactly one Rockchip device; found {len(devices)}")
        if "Maskrom" in devices[0] or "MaskROM" in devices[0]:
            return "maskrom"
        if "Loader" in devices[0]:
            return "loader"
        raise RuntimeError("Unsupported device mode: " + devices[0])

    def wait(self, mode):
        for attempt in range(20):
            listing = self.run("ld")
            count = len(re.findall(r"\bDevNo\s*=", listing, re.I))
            if count > 1:
                raise RuntimeError("Multiple devices appeared during mode transition")
            if count == 1 and self.one() == mode:
                return
            time.sleep(1)
        raise RuntimeError("Device did not enter " + mode + " mode")


def flash(directory, manifest, device, verify_only=False):
    root = Path(directory)
    if not verify_only:
        if device.one() == "loader":
            device.run("rd", "3")
            device.wait("maskrom")
        device.run("db", contained(root, manifest["loader"]["file"]))
        device.wait("loader")
    elif device.one() != "loader":
        raise RuntimeError("Readback requires the verified loader to be running")
    capacities = re.findall(r"Flash Size:\s*(\d+)\s+Sectors\b", device.run("rfi"), re.I)
    if len(capacities) != 1 or int(capacities[0]) * 512 < manifest["image_size"]:
        raise RuntimeError("Cannot confirm sufficient device capacity; no image data was written")
    with tempfile.TemporaryDirectory(prefix="w132d-readback-") as temp:
        rb = Path(temp) / "readback.bin"
        for item in manifest["segments"]:
            path = contained(root, item["file"])
            if device.one() != "loader":
                raise RuntimeError("Loader disappeared before flashing")
            if not verify_only:
                print("Writing " + item["file"], flush=True)
                device.run("wl", item["sector"], path)
            print("Verifying all bytes: " + item["file"], flush=True)
            with path.open("rb") as expected:
                offset = 0
                while offset < item["size"]:
                    size = min(16 * 1024 * 1024, item["size"] - offset)
                    rb.unlink(missing_ok=True)
                    device.run("rl", item["sector"] + offset // 512, size // 512, rb)
                    if not rb.is_file() or rb.stat().st_size != size or rb.read_bytes() != expected.read(size):
                        raise RuntimeError("Readback mismatch; device has NOT been rebooted")
                    offset += size
    if not verify_only:
        device.one()
        device.run("rd")
    print("FLASH_VERIFY_OK" if verify_only else "FLASH_OK: device rebooted; allow time for first-boot expansion")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", nargs="?", default=str(Path(__file__).resolve().parent))
    parser.add_argument("--dry-run", action="store_true", help="Validate artifacts without accessing USB")
    parser.add_argument("--verify-only", action="store_true", help="Read and compare without writing or rebooting")
    parser.add_argument("--yes", action="store_true", help="Confirm replacement of the operating system")
    parser.add_argument("--tool", type=Path, help="Explicit external tool override, required on Windows")
    args = parser.parse_args(argv)
    root = Path(args.directory)
    manifest = validate(root)
    if args.tool:
        tool = args.tool.resolve()
        if not tool.is_file():
            raise ValueError("External flashing tool is missing")
    else:
        record = manifest["tools"].get(native_platform())
        if not record:
            raise ValueError("No bundled binary for this platform; use --tool with a compatible executable")
        tool = contained(root, record["file"])
        if digest(tool) != record["sha256"]:
            raise ValueError("Bundled flashing tool checksum mismatch")
    if args.dry_run:
        print("FLASH_DRY_RUN_OK: artifacts, layout and tool checksum verified")
        return
    device = Device(tool)
    device.one()
    if not args.verify_only and not args.yes:
        answer = input("This replaces the installed operating system. Type yes to continue: ")
        if answer != "yes":
            raise RuntimeError("Cancelled")
    flash(root, manifest, device, args.verify_only)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, KeyError, subprocess.SubprocessError) as error:
        print("ERROR: " + str(error), file=sys.stderr)
        sys.exit(1)
