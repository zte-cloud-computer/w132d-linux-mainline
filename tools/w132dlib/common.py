# SPDX-License-Identifier: MIT
"""Deterministic input handling and checked subprocess helpers."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
PACKAGES = (
    "linux-image-edge-rockchip64", "linux-dtb-edge-rockchip64",
    "linux-headers-edge-rockchip64", "linux-libc-dev-edge-rockchip64",
    "linux-u-boot-w132d-edge", "armbian-bsp-cli-w132d-edge",
)


def run(args, **kwargs):
    return subprocess.run([str(x) for x in args], check=True, **kwargs)


def output(args, **kwargs):
    return run(args, stdout=subprocess.PIPE, text=True, **kwargs).stdout.strip()


def sha256(path):
    h = hashlib.sha256()
    with Path(path).open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def digest_tree(path, exclude=()):
    """Include paths, executable bits, symlink targets and contents."""
    h = hashlib.sha256()
    for p in sorted(Path(path).rglob("*")):
        if "__pycache__" in p.parts or p.name == ".DS_Store" or any(x in p.relative_to(path).parts for x in exclude):
            continue
        if p.is_symlink():
            data = b"link:" + os.readlink(p).encode()
        elif p.is_file():
            data = str(p.stat().st_mode & 0o111).encode() + b":" + p.read_bytes()
        else:
            continue
        h.update(p.relative_to(path).as_posix().encode() + b"\0" + data + b"\0")
    return h.hexdigest()


def read_json(path):
    return json.loads(Path(path).read_text())


def write_json(path, value):
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_suffix(p.suffix + ".tmp")
    tmp.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    tmp.replace(p)


def request(url):
    headers = {"User-Agent": "W132D-release"}
    if url.startswith("https://api.github.com/") and os.environ.get("GH_TOKEN"):
        headers["Authorization"] = "Bearer " + os.environ["GH_TOKEN"]
    return urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=120)


def api(url):
    with request(url) as f:
        return json.load(f)


def download(url, dest, expected):
    p = Path(dest)
    if p.exists() and sha256(p) == expected:
        return p
    p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_suffix(p.suffix + ".part")
    with request(url) as source, tmp.open("wb") as target:
        import shutil
        shutil.copyfileobj(source, target)
    if sha256(tmp) != expected:
        tmp.unlink()
        raise ValueError(f"SHA256 mismatch: {url}")
    tmp.replace(p)
    return p


def require(condition, message):
    if not condition:
        raise ValueError(message)
