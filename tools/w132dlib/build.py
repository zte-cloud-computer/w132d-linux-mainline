# SPDX-License-Identifier: MIT
"""Build through supported Armbian userpatches and extension interfaces."""
import os
import shutil
from pathlib import Path
import shlex

from .common import ROOT, output, require, run, write_json
from .inputs import fetch, maintained_digest, validate_lock
from . import packages

def tracked_tree(source, destination):
    """Copy only files tracked by Git, excluding ignored local content."""
    source, destination = Path(source), Path(destination)
    for name in output(["git", "ls-files", "-z", "--", source], cwd=ROOT).split("\0"):
        if not name:
            continue
        source_path = ROOT / name
        target_path = destination / source_path.relative_to(source)
        target_path.parent.mkdir(parents=True, exist_ok=True)
        if source_path.is_file() or source_path.is_symlink():
            shutil.copy2(source_path, target_path, follow_symlinks=False)


def checkout(spec, destination):
    destination = Path(destination)
    if not (destination / ".git").exists():
        destination.mkdir(parents=True, exist_ok=True)
        run(["git", "init", destination])
        run(["git", "-C", destination, "remote", "add", "origin", spec["repository"]])
    head = output(["git", "-C", destination, "rev-parse", "--verify", "HEAD"], stderr=None) if (destination / ".git/FETCH_HEAD").exists() else ""
    if head != spec["commit"]:
        run(["git", "-C", destination, "fetch", "--depth=1", "origin", spec["commit"]])
        run(["git", "-C", destination, "checkout", "--detach", spec["commit"]])
    require(output(["git", "-C", destination, "rev-parse", "HEAD"]) == spec["commit"], "Source checkout mismatch")
    require(not output(["git", "-C", destination, "diff", "--name-only"]), "Build framework has local modifications")
    return destination


def stage(lock, framework, files):
    """Stage only tracked public inputs; never move a private customize script."""
    dest = framework / "userpatches"
    if dest.exists():
        for child in dest.iterdir():
            if child.name != "customize-image.sh":
                if child.is_dir() and not child.is_symlink():
                    shutil.rmtree(child)
                else:
                    child.unlink()
    dest.mkdir(exist_ok=True)
    customize = dest / "customize-image.sh"
    if customize.exists():
        template = framework / "config/templates/customize-image.sh.template"
        require(template.is_file() and customize.read_bytes() == template.read_bytes(),
                "Unexpected private customize-image.sh in release workspace")
        # Armbian creates its stock no-op template during the first build.
        # A subsequent build must accept that generated file, but no other.
        customize.unlink()
    for name in ("config", "extensions", "kernel", "u-boot", "overlay"):
        target = dest / name
        tracked_tree(ROOT / "userpatches" / name, target)
    shutil.copy2(ROOT / "userpatches/config/kernel-base.config", dest / "linux-rockchip64-edge.config")
    extension = dest / "extensions/w132d"
    tracked_tree(ROOT / "tools/w132dlib", extension / "w132dlib")
    write_json(extension / "manifest.json", lock)
    firmware = extension / "inputs"
    firmware.mkdir(exist_ok=True)
    for name, path in files.items():
        if name != "linux":
            shutil.copy2(path, firmware / name)
    # Artifact caching hashes hook source, not arbitrary files read by hooks.
    # Include overlays and firmware in both BSP and U-Boot cache identities.
    input_digest = maintained_digest(lock)
    (extension / "cache.sh").write_text("".join(
        f'function {hook}__w132d_content_hash() {{\n'
        f'    : {shlex.quote(input_digest)}\n' + '}\n'
        for hook in ("post_family_tweaks_bsp", "pre_config_uboot_target")))
    (extension / "locked.sh").write_text("\n".join(f"{k}={shlex.quote(str(v))}" for k, v in {
        "W132D_LINUX_TAG": lock["linux"]["tag"], "W132D_LINUX_SHA": lock["linux"]["commit"],
        "W132D_KERNEL_SERIES": ".".join(lock["linux"]["tag"][1:].split(".")[:2]),
        "W132D_UBOOT_SHA": lock["uboot"]["commit"], "W132D_UBOOT_TAG": lock["uboot"]["tag"],
        "W132D_CONTENT_HASH": input_digest, "W132D_VERSION": lock["version"],
        "SOURCE_DATE_EPOCH": lock["source_date_epoch"],
    }.items()) + "\n")
    return dest


def build(lock, target="kernel", framework=None):
    validate_lock(lock)
    require(target in ("kernel", "image", "uboot", "bsp"), "Unsupported build target")
    files = fetch(lock)
    framework = checkout(lock["armbian"], framework or ROOT / "cache/armbian" / lock["armbian"]["commit"])
    stage(lock, framework, files)
    dest = ROOT / "out" / lock["version"]
    dest.mkdir(parents=True, exist_ok=True)
    write_json(dest / "manifest.json", lock)
    command = {"image": ["build"], "bsp": ["artifact", "WHAT=armbian-bsp-cli"]}.get(target, [target])
    args = ["BOARD=w132d", "BRANCH=edge", "RELEASE=trixie", "BUILD_MINIMAL=yes", "BUILD_DESKTOP=no",
            "KERNEL_CONFIGURE=no", "SHARE_LOG=no", "USE_CCACHE=yes", "PRIVATE_CCACHE=yes",
            "KERNEL_GIT=full", "KERNEL_BTF=yes",
            "COMPRESS_OUTPUTIMAGE=none", "KEEP_ORIGINAL_OS_RELEASE=yes", "INSTALL_HEADERS=yes",
            "BUILD_KSRC=yes", "REVISION=" + lock["version"]]
    # The same extension finalizes image-installed debs and kernel-only debs.
    env = dict(os.environ, SOURCE_DATE_EPOCH=str(lock["source_date_epoch"]))
    run(["bash", "./compile.sh", *command, *args], cwd=framework, env=env)
    if target in ("kernel", "image"):
        packages.collect(framework / "output/debs", dest / "debs", lock, target == "image")
    else:
        name = packages.PACKAGES[4 if target == "uboot" else 5]
        selected = packages.select(framework / "output/debs", lock["version"], [name])
        (dest / "debs").mkdir(exist_ok=True)
        for path in selected.values():
            packages.finalize(path, lock["source_date_epoch"])
            shutil.copy2(path, dest / "debs" / path.name)
    if target == "image":
        candidates = list((framework / "output/images").glob("*.img"))
        # Inspect each image against its installed BSP version; never select by mtime.
        from .images import matches_version, verify_image
        matches = [p for p in candidates if matches_version(p, lock["version"])]
        require(len(matches) == 1, "Expected one image matching the locked package version")
        image = dest / "w132d.img"
        shutil.copy2(matches[0], image)
        verify_image(image, lock, dest)
    return dest
