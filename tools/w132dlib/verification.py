# SPDX-License-Identifier: MIT
"""Fail-closed source, schema and policy checks shared by CI and local builds."""
import ast
import importlib.util
import os
import platform
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile

from .common import ROOT, digest_tree, output, require, run, write_json
from .inputs import fetch, validate_lock


def maintained_files():
    for directory in ("tools", "flash", ".github", "config", "userpatches", "vendor", "tests"):
        for p in (ROOT / directory).rglob("*"):
            if p.is_file() and not p.is_symlink() and not any(x in p.parts for x in ("__pycache__", "local", ".git")):
                if p.name != "customize-image.sh":
                    yield p


def static():
    errors = []
    han = re.compile(r"[\u3400-\u9fff]")
    maintained = list(maintained_files())
    shell_files = []
    for path in maintained:
        if path.suffix.lower() in (".md", ".gpg", ".bin") or path.name in ("COPYING", "license.txt"):
            continue
        try:
            text = path.read_text()
        except UnicodeDecodeError:
            continue
        for number, line in enumerate(text.splitlines(), 1):
            if path.suffix == ".patch" and not line.startswith("+"):
                continue
            # This exact device name is a matching value, not user-facing text.
            if path.name in ("ble-remote.py", "w132d-ble-pair"):
                line = line.replace("\u7535\u4fe1", "")
            if han.search(line):
                errors.append(f"Non-English maintained text: {path.relative_to(ROOT)}:{number}")
        if path.suffix == ".py" or text.startswith("#!/usr/bin/env python3"):
            ast.parse(text, filename=str(path))
        if path.suffix == ".sh" or text.startswith(("#!/bin/bash", "#!/usr/bin/env bash")):
            shell_files.append(path)
            run(["bash", "-n", path])
    require(not errors, "\n".join(errors))
    require(not (ROOT / "patches").exists() and not (ROOT / "userpatches/kernel/archive").exists(), "Duplicate kernel patch sources remain")
    require(not (ROOT / "userpatches/overlay/rootfs-edits").exists(), "Image-only board configuration remains")
    for private_path in ("userpatches/customize-image.sh", "userpatches/config-example.conf", "userpatches/overlay/local"):
        require(not output(["git", "ls-files", "--", private_path], cwd=ROOT), "Private file is tracked: " + private_path)
    if shutil.which("shellcheck") and shell_files:
        run(["shellcheck", *shell_files], cwd=ROOT)
    if shutil.which("actionlint"):
        run(["actionlint"], cwd=ROOT)
    else:
        require(not os.environ.get("CI"), "CI requires actionlint")
    print("Static and English-language checks passed")


def tests():
    run([sys.executable, "-m", "unittest", "discover", "-s", ROOT / "tests", "-v"], cwd=ROOT)


def strict_apply(tree, patches):
    # A standalone Git root prevents git-apply silently skipping paths when
    # the unpacked source is nested in this repository.
    require((Path(tree) / ".git").exists(), "Patch verification needs an isolated Git root")
    for patch in patches:
        run(["git", "apply", "--check", patch], cwd=tree)
        # Armbian applies patches with GNU patch, whose context matching
        # differs from git apply. Require both engines before changing files.
        result = subprocess.run(["patch", "--batch", "-p1", "-N", "--fuzz=0", "--dry-run",
                                 "--reject-file=-", "--quoting-style=c"],
                                cwd=tree, input=Path(patch).read_text(), capture_output=True, text=True)
        require(result.returncode == 0, f"GNU patch rejected {Path(patch).name}:\n" + result.stdout + result.stderr)
        result = run(["git", "apply", "--verbose", patch], cwd=tree, capture_output=True, text=True)
        require("Skipped patch" not in result.stderr, "Git skipped a required patch")


def patches(lock, jobs=4):
    validate_lock(lock)
    files = fetch(lock)
    root = ROOT / "cache/verify" / lock["version"]
    require(not root.exists(), "Verification tree already exists; use a new lock or remove this generated tree")
    root.mkdir(parents=True)
    with tarfile.open(files["linux"]) as archive:
        archive.extractall(root, filter="data")
    tree = root / ("linux-" + lock["linux"]["tag"][1:])
    run(["git", "init", "-q", tree])
    strict_apply(tree, sorted((ROOT / "userpatches/kernel/w132d").glob("*.patch")))
    run([sys.executable, ROOT / "userpatches/extensions/w132d/install-sources.py", tree])
    shutil.copy2(ROOT / "userpatches/config/kernel-base.config", tree / ".config")
    env = dict(os.environ, ARCH="arm64")
    if platform.machine() not in ("arm64", "aarch64"):
        env["CROSS_COMPILE"] = os.environ.get("CROSS_COMPILE", "aarch64-linux-gnu-")
    run(["bash", "scripts/kconfig/merge_config.sh", "-m", ".config",
         ROOT / "userpatches/extensions/w132d/kernel.config"], cwd=tree, env=env)
    run(["make", "olddefconfig"], cwd=tree, env=env)
    run(["make", f"-j{jobs}", "rockchip/rk3528-w132d.dtb"], cwd=tree, env=env)
    from .packages import check_dtb
    dtb = tree / "arch/arm64/boot/dts/rockchip/rk3528-w132d.dtb"
    check_dtb(dtb)
    # Kernel make and dt-validate can return zero after emitting schema errors.
    # Validate the maintained bindings explicitly and treat diagnostics as fatal.
    bindings = [tree / "Documentation/devicetree/bindings" / p.relative_to(ROOT / "userpatches/extensions/w132d/bindings")
                for p in sorted((ROOT / "userpatches/extensions/w132d/bindings").rglob("*.yaml"))]
    bindings += [tree / "Documentation/devicetree/bindings" / p for p in
                 ("arm/rockchip.yaml", "sound/rockchip,pdm.yaml", "sound/rockchip,rk3576-sai.yaml", "vendor-prefixes.yaml")]
    for binding in bindings:
        result = subprocess.run(["dt-doc-validate", str(binding)], capture_output=True, text=True, cwd=tree)
        require(result.returncode == 0 and not result.stdout.strip() and not result.stderr.strip(), result.stdout + result.stderr)
    run(["make", f"-j{jobs}", "dt_binding_check", "DT_SCHEMA_FILES=rockchip.yaml:rk3528:es7202:unisoc:uwe-bsp:sprd,mtty:rockchip,pdm:rockchip,rk3576-sai"],
        cwd=tree, env=env)
    result = subprocess.run(["dt-validate", "-s", tree / "Documentation/devicetree/bindings/processed-schema.json",
                  dtb],
                 cwd=tree, capture_output=True, text=True)
    require(result.returncode == 0 and not result.stdout.strip() and not result.stderr.strip(), result.stdout + result.stderr)
    from .build import checkout
    uboot_source = checkout(lock["uboot"], ROOT / "cache/release-sources" / lock["uboot"]["commit"])
    uboot = root / "uboot"
    uboot.mkdir()
    archive_path = root / "uboot.tar"
    run(["git", "archive", "--format=tar", "-o", archive_path, lock["uboot"]["commit"]], cwd=uboot_source)
    with tarfile.open(archive_path) as archive:
        archive.extractall(uboot, filter="data")
    archive_path.unlink()
    run(["git", "init", "-q", uboot])
    strict_apply(uboot, sorted((ROOT / "userpatches/u-boot/w132d").glob("*.patch")))
    dest = ROOT / "out" / lock["version"]
    write_json(dest / "patch-verification.json", {"linux": lock["linux"], "inputs": lock["inputs"],
                                                 "dtb_schema": "passed", "patches": "passed", "uboot_patches": "passed"})
    print("Strict patches, DTB and maintained schemas passed")
