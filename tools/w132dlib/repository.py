# SPDX-License-Identifier: MIT
"""Signed, retained APT distributions with immutable pool objects and By-Hash."""
from datetime import datetime, timedelta, timezone
from email.utils import format_datetime
import gzip
import hashlib
from pathlib import Path
import shutil
import tempfile
import subprocess
from urllib.error import HTTPError

from .common import ROOT, api, download, output, read_json, require, run, sha256, write_json
from .inputs import maintained_digest
from .packages import metadata

RETENTION = {"stable": 3, "experimental": 2}
MAX_BYTES = 900 * 1024 * 1024  # Leave headroom under the Pages 1 GB site limit.


def remote_state(url, missing_ok=False):
    try:
        state = api(url.rstrip("/") + "/state.json")
    except HTTPError as error:
        if error.code != 404 or not missing_ok:
            raise
        return {"schema": 1, "channels": {}}
    require(state.get("schema") == 1 and isinstance(state.get("channels"), dict), "Invalid deployed repository state")
    return state


def version_newer(candidate, installed):
    return subprocess.run(["dpkg", "--compare-versions", candidate, "gt", installed]).returncode == 0


def next_state(previous, lock, records):
    state = {"schema": 1, "channels": {k: list(previous.get("channels", {}).get(k, [])) for k in RETENTION}}
    channel = lock["channel"]
    history = state["channels"][channel]
    if history:
        current = history[0]
        if current["version"] == lock["version"]:
            require(current["packages"] == records, "An immutable version already has different package bytes")
            require(current["project_commit"] == lock["project_commit"], "An immutable version already has another commit")
            return state
        require(version_newer(lock["version"], current["version"]), "Refusing stale publication")
        # An old Actions run can be restarted on a later calendar day. The
        # new date must not let that older task replace a newer publication.
        task = tuple(map(int, lock["version"].split("~", 1)[0].split(".")[1:]))
        current_task = tuple(map(int, current["version"].split("~", 1)[0].split(".")[1:]))
        require(task > current_task, "Refusing stale publication task")
        if channel == "stable":
            for name in ("linux", "armbian", "uboot"):
                if name == "uboot" and name not in current:
                    continue  # Older repository state did not record U-Boot.
                candidate_tag = tuple(map(int, lock[name]["tag"].removeprefix("v").split(".")))
                current_tag = tuple(map(int, current[name]["tag"].removeprefix("v").split(".")))
                require(candidate_tag >= current_tag, "Refusing an upstream version regression: " + name)
                require(candidate_tag != current_tag or lock[name].get("commit") == current[name].get("commit"),
                        "Upstream tag points to a different commit: " + name)
    entry = {"version": lock["version"], "project_commit": lock["project_commit"],
             "linux": lock["linux"], "armbian": lock["armbian"], "uboot": lock["uboot"], "packages": records}
    entry["inputs_digest"] = maintained_digest(lock)
    state["channels"][channel] = ([entry] + history)[:RETENTION[channel]]
    return state


def build(directory, destination, lock, key, previous=None, previous_url=None):
    directory, dest = Path(directory), Path(destination)
    if dest.exists():
        require(dest.is_dir() and not any(dest.iterdir()), "Repository destination must be empty")
    dest.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=dest.name + ".", dir=dest.parent) as temporary:
        work = Path(temporary) / "repo"
        records = read_json(directory / "packages.json")
        for item in records:
            p = directory / item["file"]
            require(sha256(p) == item["sha256"], "Package changed after verification")
            require(item["version"] == lock["version"] and item["architecture"] == "arm64", "Repository package version mismatch")
            item["path"] = f"pool/main/{item['package']}/{item['sha256']}/{item['file']}"
        previous = previous or {"schema": 1, "channels": {}}
        state = next_state(previous, lock, records)
        for history in state["channels"].values():
            for release in history:
                for item in release["packages"]:
                    target = work / item["path"]
                    target.parent.mkdir(parents=True, exist_ok=True)
                    source = directory / item["file"]
                    if source.is_file() and sha256(source) == item["sha256"]:
                        shutil.copy2(source, target)
                    else:
                        require(previous_url is not None, "Previous repository URL required for retained packages")
                        download(previous_url.rstrip("/") + "/" + item["path"], target, item["sha256"])
        for channel, history in state["channels"].items():
            distribution = work / "dists" / channel
            binary = distribution / "main/binary-arm64"
            binary.mkdir(parents=True, exist_ok=True)
            paragraphs = []
            for release in history:
                for item in release["packages"]:
                    p = work / item["path"]
                    text = output(["dpkg-deb", "--field", p])
                    paragraphs.append(text + f"\nFilename: {item['path']}\nSize: {item['size']}\nSHA256: {item['sha256']}\n")
            data = ("\n".join(paragraphs) + "\n").encode()
            (binary / "Packages").write_bytes(data)
            (binary / "Packages.gz").write_bytes(gzip.compress(data, mtime=0))
            indexes = [binary / "Packages", binary / "Packages.gz"]
            for index in indexes:
                by_hash = binary / "by-hash/SHA256" / sha256(index)
                by_hash.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(index, by_hash)
            # Retain indexes referenced by the immediately previous Release so an
            # update racing the Pages switch can still finish using By-Hash.
            for item in previous.get("indexes", {}).get(channel, []):
                if previous_url:
                    download(previous_url.rstrip("/") + "/" + item["path"], work / item["path"], item["sha256"])
            now = datetime.now(timezone.utc)
            text = (f"Origin: W132D\nLabel: W132D\nSuite: {channel}\nCodename: {channel}\n"
                    f"Date: {format_datetime(now, usegmt=True)}\n"
                    "Architectures: arm64\nComponents: main\nAcquire-By-Hash: yes\n"
                    "Description: ZTE W132D maintained packages\n")
            # Stable releases can be months apart. Do not expire a valid stable
            # repository merely because no new upstream version has appeared.
            if channel == "experimental":
                text += "NotAutomatic: yes\nButAutomaticUpgrades: yes\n"
            text += "SHA256:\n"
            for index in indexes:
                text += f" {sha256(index)} {index.stat().st_size} {index.relative_to(distribution)}\n"
            (distribution / "Release").write_text(text)
            sign(distribution, key)
        state["indexes"] = {}
        for channel in RETENTION:
            state["indexes"][channel] = [
                {"path": p.relative_to(work).as_posix(), "sha256": sha256(p)}
                for p in sorted((work / f"dists/{channel}/main/binary-arm64/by-hash/SHA256").iterdir())
                if p.name in (sha256(work / f"dists/{channel}/main/binary-arm64/Packages"),
                              sha256(work / f"dists/{channel}/main/binary-arm64/Packages.gz"))]
        write_json(work / "state.json", state)
        (work / ".nojekyll").touch()
        size = sum(p.stat().st_size for p in work.rglob("*") if p.is_file())
        require(size < MAX_BYTES, f"Pages capacity exceeded: {size} bytes")
        if dest.exists():
            dest.rmdir()
        shutil.move(work, dest)
    print(f"Signed repository ready: {size} bytes")
    return state


def sign(directory, key):
    for args in (("--clearsign", "InRelease"), ("--detach-sign", "Release.gpg")):
        run(["gpg", "--batch", "--yes", "--local-user", key, "--digest-algo", "SHA256",
             "--output", directory / args[1], args[0], directory / "Release"])
    run(["gpg", "--verify", directory / "InRelease"])
    run(["gpg", "--verify", directory / "Release.gpg", directory / "Release"])
    # A valid signature by an unrelated imported key is not enough.
    keyring = ROOT / "userpatches/overlay/bsp-cli/usr/share/keyrings/w132d-archive-keyring.gpg"
    run(["gpgv", "--keyring", keyring, directory / "InRelease"])

