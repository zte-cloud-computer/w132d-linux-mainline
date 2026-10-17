# SPDX-License-Identifier: MIT
"""Resolve official upstream versions and freeze every maintained input."""
import copy
import hashlib
import json
from datetime import datetime
import os
from pathlib import Path
import re
from zoneinfo import ZoneInfo

from .common import ROOT, api, download, output, read_json, require, write_json

INPUT_DIRS = ("userpatches/kernel/w132d", "userpatches/extensions/w132d",
              "userpatches/extensions/rkbin-tools",
              "userpatches/overlay", "userpatches/u-boot", "userpatches/config",
              "tools", "vendor/rkdeveloptool", "flash", "config", ".github", "tests")


def release_version(channel, now=None, run_id=None, attempt=None):
    now = now or datetime.now(ZoneInfo("Asia/Shanghai"))
    run_id = str(run_id or os.environ.get("GITHUB_RUN_ID", int(now.timestamp())))
    attempt = str(attempt or os.environ.get("GITHUB_RUN_ATTEMPT", "1"))
    require(run_id.isdigit() and attempt.isdigit(), "Run ID and attempt must be numeric")
    version = f"{now.astimezone(ZoneInfo('Asia/Shanghai')):%Y%m%d}.{run_id}.{attempt}"
    return version + ("~experimental" if channel == "experimental" else "")


def official_armbian(releases):
    return [r for r in releases if not r["draft"] and not r["prerelease"]
            and re.fullmatch(r"v\d+\.\d+\.\d+", r["tag_name"])]


def resolve_tag(repository, tag):
    data = api(f"https://api.github.com/repos/{repository}/commits/{tag}")
    require(re.fullmatch(r"[a-f0-9]{40}", data["sha"]), "Invalid upstream commit")
    return data["sha"]


def upstreams():
    data = api("https://www.kernel.org/releases.json")
    versions = [r["version"] for r in data["releases"]
                if r["moniker"] in ("stable", "mainline") and re.fullmatch(r"\d+\.\d+(?:\.\d+)?", r["version"])]
    require(bool(versions), "kernel.org did not report a stable release")
    kernel = max(versions, key=lambda v: tuple(map(int, v.split("."))))
    # Trunk releases can be marked non-prerelease. Never use /releases/latest.
    releases = []
    for page in range(1, 101):
        batch = api(f"https://api.github.com/repos/armbian/build/releases?per_page=100&page={page}")
        releases.extend(official_armbian(batch))
        if len(batch) < 100:
            break
    require(bool(releases), "No official Armbian release found")
    armbian = max(releases, key=lambda r: tuple(map(int, r["tag_name"][1:].split("."))))["tag_name"]
    # U-Boot publishes signed Git tags rather than GitHub Releases. Include
    # maintenance releases, but exclude RC, concept and vendor tags.
    tags = []
    for page in range(1, 101):
        batch = api(f"https://api.github.com/repos/u-boot/u-boot/tags?per_page=100&page={page}")
        tags.extend(t["name"] for t in batch if re.fullmatch(r"v\d{4}\.\d{2}(?:\.\d+)?", t["name"]))
        if len(batch) < 100:
            break
    require(bool(tags), "No official U-Boot release found")
    uboot = max(tags, key=lambda tag: tuple(map(int, tag[1:].split("."))))
    return {
        "linux": {"tag": "v" + kernel, "commit": resolve_tag("gregkh/linux", "v" + kernel)},
        "armbian": {"tag": armbian, "commit": resolve_tag("armbian/build", armbian)},
        "uboot": {"tag": uboot, "commit": resolve_tag("u-boot/u-boot", uboot)},
    }


def source_hashes():
    """Hash the committed contents and modes of every maintained input path."""
    path_arguments = []
    for directory in INPUT_DIRS:
        path_arguments.extend(["--", directory])
    names = output(["git", "ls-files", "-z", "--"] + path_arguments, cwd=ROOT).split("\0")
    hashes = {}
    for name in names:
        if not name:
            continue
        path = ROOT / name
        if path.is_symlink():
            data = b"link:" + os.readlink(path).encode()
        elif path.is_file():
            data = str(path.stat().st_mode & 0o111).encode() + b":" + path.read_bytes()
        else:
            continue
        digest = hashlib.sha256()
        digest.update(name.encode() + b"\0" + data + b"\0")
        hashes[name] = digest.hexdigest()
    return hashes


def maintained_digest(lock):
    """Return a single signed-ready digest of all maintained inputs."""
    digest = hashlib.sha256()
    digest.update(json.dumps({"inputs": lock.get("inputs", {}), "blobs": lock.get("blobs", {})},
                             sort_keys=True).encode())
    return digest.hexdigest()


def create_lock(path, channel="experimental", latest=False, initialize=False):
    pins = read_json(ROOT / "config/sources.json")
    lock = copy.deepcopy(pins)
    if latest:
        for name, info in upstreams().items():
            lock[name].update(info)
        version = lock["linux"]["tag"][1:]
        # Download the checksum from kernel.org over authenticated HTTPS.
        from .common import request
        base = f"https://cdn.kernel.org/pub/linux/kernel/v{version.split('.')[0]}.x"
        with request(base + "/sha256sums.asc") as f:
            sums = f.read().decode()
        matches = re.findall(rf"^([0-9a-f]{{64}})\s+linux-{re.escape(version)}\.tar\.xz$", sums, re.M)
        require(len(matches) == 1, "Missing or ambiguous Linux archive checksum")
        lock["linux"].update(url=f"{base}/linux-{version}.tar.xz", sha256=matches[0])
    lock.update(schema=1, channel=channel, version=release_version(channel),
                project_commit=output(["git", "rev-parse", "HEAD"], cwd=ROOT),
                project_dirty=bool(output(["git", "status", "--porcelain"], cwd=ROOT)),
                inputs=source_hashes(), created_at=datetime.now(ZoneInfo("UTC")).isoformat())
    lock["source_date_epoch"] = int(output(["git", "show", "-s", "--format=%ct", "HEAD"], cwd=ROOT))
    require(not initialize or channel == "stable", "Initialize the repository with a complete stable release")
    lock["initialize_repository"] = initialize
    write_json(path, lock)
    return lock


def validate_lock(lock):
    require(lock["schema"] == 1, "Unsupported manifest schema")
    require(lock["channel"] in ("stable", "experimental"), "Invalid channel")
    require(re.fullmatch(r"\d{8}\.\d+\.\d+(?:~experimental)?", lock["version"]), "Invalid package version")
    require(lock["version"].endswith("~experimental") == (lock["channel"] == "experimental"), "Version and channel disagree")
    require(lock["inputs"] == source_hashes(), "Maintained inputs changed after locking")
    require(lock["project_commit"] == output(["git", "rev-parse", "HEAD"], cwd=ROOT), "Project commit changed after locking")
    if not lock["project_dirty"]:
        require(not output(["git", "status", "--porcelain"], cwd=ROOT), "Release checkout changed after locking")
    for name in ("linux", "armbian", "uboot"):
        require(re.fullmatch(r"[0-9a-f]{40}", lock[name]["commit"]), f"Unpinned {name} source")
    require(re.fullmatch(r"v\d+\.\d+(?:\.\d+)?", lock["linux"]["tag"]), "RC kernels are not allowed")
    require(re.fullmatch(r"v\d+\.\d+\.\d+", lock["armbian"]["tag"]), "Only official Armbian releases are allowed")
    require(re.fullmatch(r"v\d{4}\.\d{2}(?:\.\d+)?", lock["uboot"]["tag"]), "Only official U-Boot releases are allowed")


def changed(lock):
    from .repository import remote_state
    history = remote_state(lock["repository"], lock.get("initialize_repository", False)).get("channels", {}).get("stable", [])
    if not history:
        return True
    if any(lock[name] != history[0].get(name) for name in ("linux", "armbian", "uboot")):
        return True
    return maintained_digest(lock) != history[0].get("inputs_digest")


def fetch(lock):
    validate_lock(lock)
    root = ROOT / "cache/inputs"
    files = {}
    for name, spec in {"linux": lock["linux"], **lock["blobs"]}.items():
        files[name] = str(download(spec["url"], root / spec["sha256"] / Path(spec["url"]).name, spec["sha256"]))
    return files
