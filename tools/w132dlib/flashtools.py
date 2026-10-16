# SPDX-License-Identifier: MIT
"""Build native standalone flashing tools from the maintained source tree."""
import os
from pathlib import Path
import platform
import shutil
import tarfile

from .common import ROOT, digest_tree, download, output, read_json, require, run, sha256, write_json


def build(destination):
    machine = {"x86_64": "amd64", "aarch64": "arm64", "arm64": "arm64"}.get(platform.machine())
    system = {"Linux": "linux", "Darwin": "macos"}.get(platform.system())
    name = f"{system}-{machine}"
    config = read_json(ROOT / "config/flash-tools.json")
    require(name in config["platforms"], "Unsupported flashing-tool build platform: " + name)
    spec = config["libusb"]
    work = ROOT / "cache/flash-tools" / name
    work.mkdir(parents=True, exist_ok=True)
    archive = download(spec["url"], work / "libusb.tar.bz2", spec["sha256"])
    source = work / ("libusb-" + spec["version"])
    if not source.exists():
        with tarfile.open(archive) as tar:
            tar.extractall(work, filter="data")
    prefix = work / "prefix"
    env = dict(os.environ)
    if system == "macos":
        env["MACOSX_DEPLOYMENT_TARGET"] = "11.0"
    run(["./configure", "--disable-shared", "--enable-static", "--disable-udev", "--prefix=" + str(prefix)], cwd=source, env=env)
    run(["make", "-j", str(os.cpu_count() or 2)], cwd=source, env=env)
    run(["make", "install"], cwd=source, env=env)
    env["PKG_CONFIG_LIBDIR"] = str(prefix / "lib/pkgconfig")
    run(["cmake", "-S", ROOT / "vendor/rkdeveloptool", "-B", work / "build", "-DCMAKE_BUILD_TYPE=Release",
         "-DPKG_CONFIG_ARGN=--static", "-DW132D_STATIC=" + ("ON" if system == "linux" else "OFF")], env=env)
    run(["cmake", "--build", work / "build", "-j", str(os.cpu_count() or 2)], env=env)
    dest = Path(destination) / name
    if dest.exists():
        shutil.rmtree(dest)
    dest.mkdir(parents=True, exist_ok=True)
    tool = dest / "rkdeveloptool"
    shutil.copy2(work / "build/rkdeveloptool", tool)
    if system == "macos":
        # Ad-hoc signing permits local execution; this is not Apple notarization.
        run(["codesign", "--force", "--sign", "-", tool])
        linked = output(["otool", "-L", tool])
        require("/opt/" not in linked and "/usr/local/" not in linked, "Binary still depends on Homebrew paths")
    else:
        require("statically linked" in output(["file", tool]), "Linux tool must be statically linked")
    run([tool, "--version"])
    run([tool, "--help"])
    shutil.copy2(ROOT / "vendor/rkdeveloptool/license.txt", dest / "COPYING.rkdeveloptool")
    shutil.copy2(source / "COPYING", dest / "COPYING.libusb")
    shutil.copy2(archive, dest / archive.name)
    with tarfile.open(dest / "rkdeveloptool-source.tar.xz", "w:xz") as tar:
        tar.add(ROOT / "vendor/rkdeveloptool", arcname="rkdeveloptool")
    write_json(dest / "build.json", {"platform": name, "source_sha256": digest_tree(ROOT / "vendor/rkdeveloptool"),
                                    "sha256": sha256(tool), "libusb": spec,
                                    "compiler": output([os.environ.get("CXX", "c++"), "--version"]),
                                    "hardware_tested": False})
    return dest
