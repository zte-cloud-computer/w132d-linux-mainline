#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Flash a verified native W132D image using the bundled platform binary."""
import argparse
import hashlib
import json
from pathlib import Path
import platform
import re
import subprocess
import sys
import tempfile
import time


COMMAND_TIMEOUT = 60
PROBE_TIMEOUT = 5
READBACK_CHUNK_SIZE = 16 * 1024**2


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

    def run(self, *args, live=False, timeout=COMMAND_TIMEOUT):
        command = [self.tool, *map(str, args)]
        try:
            proc = subprocess.run(command, text=True, stdout=None if live else subprocess.PIPE,
                                  stderr=subprocess.STDOUT, timeout=timeout)
        except subprocess.TimeoutExpired as exc:
            output = (exc.output or b"").decode(errors="replace").strip()
            raise RuntimeError(f"rkdeveloptool {args[0]} timed out after {timeout:g} seconds. " +
                               (output or "Check the USB connection and re-enter download mode before retrying.")) from exc
        output = re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", proc.stdout or "")
        if proc.returncode:
            detail = output.strip() or ("See tool output above." if live else "No tool output.")
            raise RuntimeError(f"rkdeveloptool {args[0]} failed (exit {proc.returncode}): " + detail)
        return output

    def one(self, listing=None, allow_absent=False):
        if listing is None:
            listing = self.run("ld", timeout=PROBE_TIMEOUT)
        devices = [line for line in listing.splitlines() if re.search(r"\bDevNo\s*=", line, re.I)]
        if not devices and allow_absent:
            return None
        if len(devices) != 1:
            raise RuntimeError(f"Expected exactly one Rockchip device; found {len(devices)}")
        identity = re.search(r"\bVid\s*=\s*0x([0-9a-f]+)\s*,\s*Pid\s*=\s*0x([0-9a-f]+)", devices[0], re.I)
        if identity is None or tuple(int(value, 16) for value in identity.groups()) != (0x2207, 0x350c):
            raise RuntimeError("Expected an RK3528 device (2207:350c): " + devices[0])
        if "maskrom" in devices[0].lower():
            return "maskrom"
        if "loader" in devices[0].lower():
            return "loader"
        raise RuntimeError("Unsupported device mode: " + devices[0])

    def wait(self, mode):
        self._wait(mode, 20)

    def wait_storage(self):
        # USB plug firmware can retain the Maskrom descriptor. A successful
        # storage command, rather than that descriptor, establishes readiness.
        return self._wait(None, 60)

    def _wait(self, mode, timeout):
        deadline = time.monotonic() + timeout
        listing, error = "", "No device found"
        while (remaining := deadline - time.monotonic()) > 0:
            try:
                listing = self.run("ld", timeout=min(PROBE_TIMEOUT, remaining))
            except (RuntimeError, subprocess.TimeoutExpired) as exc:
                error = str(exc)
            else:
                # Multiple or unsupported devices must fail immediately.
                current = self.one(listing, allow_absent=True)
                if mode is not None and current == mode:
                    return
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    break
                if mode is None and current is not None:
                    try:
                        return self.run("rfi", timeout=min(PROBE_TIMEOUT, remaining))
                    except (RuntimeError, subprocess.TimeoutExpired) as exc:
                        error = str(exc)
                else:
                    error = "Device mode: " + (current or "absent")
            time.sleep(min(1, max(0, deadline - time.monotonic())))
        state = "Storage did not become ready" if mode is None else "Device did not enter " + mode + " mode"
        raise RuntimeError(state + "; no image data was written.\n"
                           "Last USB listing: " + (listing.strip() or "(empty)") + "\nLast error: " + error)


class Progress:
    def __init__(self, label, total):
        self.label, self.total = label, total
        self.terminal = sys.stdout.isatty()
        self.last_percent = -1

    def __enter__(self):
        self.update(0)
        return self

    def update(self, done):
        percent = min(100, done * 100 // self.total)
        if percent == self.last_percent:
            return
        if not self.terminal and percent // 10 == self.last_percent // 10:
            return
        filled = percent * 24 // 100
        bar = "#" * filled + "-" * (24 - filled)
        text = f"{self.label} [{bar}] {percent:3d}%  {done / 1024**2:.1f}/{self.total / 1024**2:.1f} MiB"
        print(("\r" if self.terminal else "") + text, end="" if self.terminal else "\n", flush=True)
        self.last_percent = percent

    def __exit__(self, *args):
        if self.terminal:
            print(flush=True)


def verify_segment(device, item, path, readback):
    with Progress("Verifying " + item["file"], item["size"]) as progress, path.open("rb") as expected:
        offset = 0
        while offset < item["size"]:
            size = min(READBACK_CHUNK_SIZE, item["size"] - offset)
            readback.unlink(missing_ok=True)
            device.run("rl", item["sector"] + offset // 512, size // 512, readback)
            if not readback.is_file() or readback.stat().st_size != size or readback.read_bytes() != expected.read(size):
                raise RuntimeError("Readback mismatch; device has NOT been rebooted")
            offset += size
            progress.update(offset)


def flash(directory, manifest, device, verify_only=False):
    root = Path(directory)
    if not verify_only:
        if device.one() == "loader":
            print("Restarting device in MaskROM mode...", flush=True)
            device.run("rd", "3", live=True)
            device.wait("maskrom")
        print("Downloading bundled loader...", flush=True)
        device.run("db", contained(root, manifest["loader"]["file"]), live=True)
        print("Waiting for device storage (up to 60 seconds)...", flush=True)
        info = device.wait_storage()
    else:
        device.one()
        info = device.run("rfi", timeout=PROBE_TIMEOUT)
    capacities = re.findall(r"Flash Size:\s*(\d+)\s+Sectors\b", info, re.I)
    if len(capacities) != 1 or int(capacities[0]) * 512 < manifest["image_size"]:
        raise RuntimeError("Cannot confirm sufficient device capacity; no image data was written")
    print(f"Storage ready: {int(capacities[0]) * 512 / 1024**3:.2f} GiB", flush=True)
    with tempfile.TemporaryDirectory(prefix="w132d-readback-") as temp:
        rb = Path(temp) / "readback.bin"
        for item in manifest["segments"]:
            path = contained(root, item["file"])
            device.one()
            if not verify_only:
                print(f"Writing {item['file']} ({item['size'] / 1024**2:.1f} MiB)...", flush=True)
                # Allow a conservative 1 MiB/s plus startup time for the whole
                # write. The bundled tool also bounds each USB request.
                device.run("wl", item["sector"], path, live=True,
                           timeout=COMMAND_TIMEOUT + (item["size"] + 1024**2 - 1) // 1024**2)
            verify_segment(device, item, path, rb)
    if not verify_only:
        device.one()
        print("All image bytes verified; rebooting device...", flush=True)
        device.run("rd", live=True)
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
    print("Checking bundle artifacts, checksums and image layout...", flush=True)
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
    print("Bundle checks passed", flush=True)
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
    except KeyboardInterrupt:
        print("\nERROR: Interrupted; re-enter download mode before retrying.", file=sys.stderr)
        sys.exit(130)
    except (OSError, ValueError, RuntimeError, KeyError, subprocess.SubprocessError) as error:
        print("ERROR: " + str(error), file=sys.stderr)
        sys.exit(1)
