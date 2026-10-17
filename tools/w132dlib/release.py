# SPDX-License-Identifier: MIT
"""Seal artifacts, preserve immutable releases, then promote after APT deploys."""
import configparser
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import time
import zipfile

from .common import ROOT, PACKAGES, digest_tree, output, read_json, require, run, sha256, write_json
from .build import checkout
from .inputs import fetch, validate_lock


def source_archive(dest, lock):
    files = fetch(lock)
    cache = ROOT / "cache"
    cache.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=cache, prefix="release-source-") as temporary:
        work = Path(temporary)
        for name in ("uboot", "armbian", "project"):
            if name == "project":
                repository = ROOT
            else:
                repository = checkout(lock[name], ROOT / "cache/release-sources" / lock[name]["commit"])
            commit = lock["project_commit"] if name == "project" else lock[name]["commit"]
            prefix = "w132d/" if name == "project" else name + "/"
            run(["git", "archive", "--format=tar", "--prefix=" + prefix, "-o", work / (name + ".tar"), commit],
                cwd=repository)
        with tarfile.open(dest / "sources.tar.gz", "w:gz", compresslevel=1) as archive:
            archive.add(files["linux"], arcname=Path(files["linux"]).name)
            for name in ("project", "uboot", "armbian"):
                archive.add(work / (name + ".tar"), arcname=name + ".tar")
            archive.add(dest / "manifest.json", arcname="manifest.json")


def loader(lock, work):
    files = fetch(lock)
    for name in ("loader_ddr", "usbplug", "spl", "loader_config", "boot_merger", "rkbin_license"):
        target = work / lock["blobs"][name]["path"]
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(files[name], target)
    executable = work / lock["blobs"]["boot_merger"]["path"]
    executable.chmod(0o755)
    run([executable, "RKBOOT/RK3528MINIALL.ini"], cwd=work)
    config = configparser.ConfigParser()
    config.read(work / "RKBOOT/RK3528MINIALL.ini")
    result = (work / config["OUTPUT"]["PATH"]).resolve()
    require(result.is_relative_to(work.resolve()) and result.is_file(), "Loader output is missing or unsafe")
    return result


def slice_image(image, dest, start, length):
    require(start % 512 == 0 and length > 0 and length % 512 == 0, "Unaligned image segment")
    with image.open("rb") as src, dest.open("wb") as target:
        src.seek(start)
        left = length
        while left:
            chunk = src.read(min(left, 8 * 1024 * 1024))
            require(bool(chunk), "Image segment extends beyond the image")
            target.write(chunk)
            left -= len(chunk)
    return {"file": dest.name, "sector": start // 512, "size": length, "sha256": sha256(dest)}


def flash_bundle(dest, lock, binaries):
    image = dest / "w132d.img"
    report = read_json(dest / "image-verification.json")
    require(sha256(image) == report["sha256"], "Image changed after verification")
    low, high = lock["layout"]["reserved_start_sector"], lock["layout"]["reserved_end_sector"]
    require(image.stat().st_size > high * 512, "Image is too small")
    cache = ROOT / "cache"
    cache.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=cache, prefix="flash-bundle-") as temporary:
        work = Path(temporary)
        boot = work / "rkbin"
        boot.mkdir()
        shutil.copy2(loader(lock, boot), work / "loader.bin")
        shutil.copy2(boot / "LICENSE", work / "COPYING.rkbin")
        shutil.rmtree(boot)
        for name in ("flash.sh", "flash.ps1", "flash.py", "README.md"):
            shutil.copy2(ROOT / "flash" / name, work / name)
        # Preserve device-specific storage while keeping native GPT geometry.
        # The trailing backup GPT remains at the image end; Armbian relocates
        # it to the actual device end during the normal first-boot expansion.
        segments = [slice_image(image, work / "image-head.bin", 0, low * 512),
                    slice_image(image, work / "image-system.bin", high * 512, image.stat().st_size - high * 512)]
        platforms = read_json(ROOT / "config/flash-tools.json")["platforms"]
        tools = {}
        for platform in platforms:
            src = Path(binaries) / platform
            if not src.exists():
                with tarfile.open(Path(binaries) / f"rkdeveloptool-{platform}.tar.gz") as archive:
                    archive.extractall(binaries, filter="data")
            info = read_json(src / "build.json")
            require(info["platform"] == platform and info["source_sha256"] == digest_tree(ROOT / "vendor/rkdeveloptool"), "Flashing-tool source mismatch")
            require(sha256(src / "rkdeveloptool") == info["sha256"], "Flashing-tool binary mismatch")
            target = work / "tools" / platform
            shutil.copytree(src, target)
            (target / "rkdeveloptool").chmod(0o755)
            with tarfile.open(dest / f"rkdeveloptool-{platform}.tar.gz", "w:gz") as archive:
                archive.add(target, arcname=platform)
            tools[platform] = {"file": f"tools/{platform}/rkdeveloptool", "sha256": info["sha256"]}
        write_json(work / "flash-manifest.json", {"schema": 1, "version": lock["version"], "sector_size": 512,
                   "preserve_sectors": [low, high], "layout": lock["layout"], "image_sha256": report["sha256"], "image_size": image.stat().st_size,
                   "segments": segments, "boot_components": report["boot_components"],
                   "loader": {"file": "loader.bin", "sha256": sha256(work / "loader.bin")}, "tools": tools})
        run(["python3", work / "flash.py", work, "--dry-run"])
        with zipfile.ZipFile(dest / "w132d-flash.zip", "w", zipfile.ZIP_DEFLATED, compresslevel=1) as archive:
            for path in sorted(work.rglob("*")):
                if path.is_file():
                    archive.write(path, path.relative_to(work))


def notes(lock, full):
    return (f"W132D {lock['version']} ({lock['channel']})\n\n"
            f"Linux: {lock['linux']['tag']} ({lock['linux']['commit']})\n"
            f"Armbian: {lock['armbian']['tag']} ({lock['armbian']['commit']})\n"
            f"Project: {lock['project_commit']}\n\n"
            + ("Debian trixie minimal image, kernel, DTB, headers, libc-dev, U-Boot and BSP.\n" if full
               else "Experimental kernel, DTB, headers and libc-dev packages.\n")
            + "New images default to the stable APT channel. Experimental kernel updates require explicit opt-in.\n"
            "SHA256SUMS, manifest.json and corresponding sources accompany this release.\n"
            "Hardware support and limitations: docs/hardware.md in the source archive.\n")


def publication_files(dest, candidate):
    """GitHub assets use basenames; the raw image stays in the CI candidate."""
    paths = [Path(dest) / name for name in candidate["files"] if name != "w132d.img"]
    paths += [Path(dest) / "candidate.json", Path(dest) / "SHA256SUMS"]
    require(len({p.name for p in paths}) == len(paths), "Ambiguous release asset names")
    return sorted(paths)


def publication_sums(dest, candidate):
    return "".join(f"{sha256(p)}  {p.name}\n" for p in publication_files(dest, candidate) if p.name != "SHA256SUMS")


def patch_gate(dest, lock):
    patch = read_json(Path(dest) / "patch-verification.json")
    require(patch["inputs"] == lock["inputs"] and patch["linux"] == lock["linux"] and
            patch["dtb_schema"] == patch["patches"] == patch["uboot_patches"] == "passed", "Patch gate is missing or stale")


def prepare(directory, binaries):
    from .packages import verify as verify_packages
    dest = Path(directory)
    require(not (dest / "candidate.json").exists(), "Candidate is already sealed; reuse it for publication")
    lock = read_json(dest / "manifest.json")
    validate_lock(lock)
    require(not lock["project_dirty"], "Release candidates require a clean, committed project checkout")
    patch_gate(dest, lock)
    full = (dest / "w132d.img").exists()
    require(lock["channel"] != "stable" or full, "Stable requires a complete image and package set")
    verify_packages(dest / "debs", lock, full)
    if full:
        from .images import verify_image
        verify_image(dest / "w132d.img", lock, dest)
        flash_bundle(dest, lock, binaries)
    source_archive(dest, lock)
    (dest / "release-notes.md").write_text(notes(lock, full))
    paths = [p for p in dest.rglob("*") if p.is_file() and p.name not in ("SHA256SUMS", "candidate.json")]
    records = {p.relative_to(dest).as_posix(): {"sha256": sha256(p), "size": p.stat().st_size} for p in sorted(paths)}
    candidate = {"schema": 1, "version": lock["version"], "full": full, "files": records}
    write_json(dest / "candidate.json", candidate)
    (dest / "SHA256SUMS").write_text(publication_sums(dest, candidate))
    verify(dest)


def verify(directory):
    dest = Path(directory)
    candidate = read_json(dest / "candidate.json")
    require(candidate["schema"] == 1, "Invalid candidate schema")
    lock = read_json(dest / "manifest.json")
    validate_lock(lock)
    require(not lock["project_dirty"] and candidate["version"] == lock["version"], "Candidate lock mismatch")
    require(lock["channel"] != "stable" or candidate["full"], "Incomplete stable candidate")
    required = {"manifest.json", "patch-verification.json", "sources.tar.gz", "debs/packages.json", "release-notes.md"}
    if candidate["full"]:
        required |= {"w132d.img", "w132d-flash.zip", "image-verification.json", "userspace-packages.tsv"}
    require(required <= set(candidate["files"]), "Candidate is missing required release files")
    for name, item in candidate["files"].items():
        path = (dest / name).resolve()
        require(path.is_relative_to(dest.resolve()) and path.is_file(), "Unsafe candidate path")
        require(path.stat().st_size == item["size"] and sha256(path) == item["sha256"], "Sealed artifact changed: " + name)
    patch_gate(dest, lock)
    require((dest / "SHA256SUMS").read_text() == publication_sums(dest, candidate), "Publication checksum list mismatch")
    require((dest / "release-notes.md").read_text() == notes(lock, candidate["full"]), "Release notes do not match the manifest")
    if candidate["full"]:
        report = read_json(dest / "image-verification.json")
        require(report["version"] == lock["version"] and
                report["sha256"] == candidate["files"]["w132d.img"]["sha256"] and
                report["size"] == candidate["files"]["w132d.img"]["size"], "Image verification report mismatch")
    records = read_json(dest / "debs/packages.json")
    require({r["package"] for r in records} == set(PACKAGES if candidate["full"] else PACKAGES[:4]), "Incomplete package set")
    for item in records:
        require(item["version"] == lock["version"] and candidate["files"]["debs/" + item["file"]]["sha256"] == item["sha256"], "Package manifest mismatch")
        from .packages import metadata
        info = metadata(dest / "debs" / item["file"])
        require(info["Package"] == item["package"] and info["Version"] == item["version"] and
                info["Architecture"] == item["architecture"] == "arm64", "Package metadata mismatch")
    print("Sealed candidate verification passed")
    return lock


def immutable(directory, repository):
    """Create once; retries compare existing assets and never overwrite them."""
    dest = Path(directory)
    lock = verify(dest)
    require(bool(repository), "GitHub repository is required")
    files = publication_files(dest, read_json(dest / "candidate.json"))
    from .repository import next_state, remote_state
    records = read_json(dest / "debs/packages.json")
    for item in records:
        item["path"] = f"pool/main/{item['package']}/{item['sha256']}/{item['file']}"
    next_state(remote_state(lock["repository"], lock.get("initialize_repository", False)), lock, records)
    tag = "v" + lock["version"].replace("~", "-")
    query = run(["gh", "api", f"repos/{repository}/releases?per_page=100"], capture_output=True, text=True)
    import json
    existing = next((r for r in json.loads(query.stdout) if r["tag_name"] == tag), None)
    if existing is None:
        run(["gh", "release", "create", tag, "--repo", repository, "--target", lock["project_commit"],
             "--prerelease", "--latest=false", "--title", "W132D " + lock["version"], "--notes-file", dest / "release-notes.md"])
    assets = json.loads(output(["gh", "release", "view", tag, "--repo", repository, "--json", "assets"]))["assets"]
    if existing is not None:
        require(existing["target_commitish"] == lock["project_commit"], "Release points to another project commit")
        require(not existing["draft"], "Existing GitHub release is still a draft")
        # Stable candidates remain prereleases until APT deployment succeeds.
        require(lock["channel"] == "stable" or existing["prerelease"], "Existing release channel mismatch")
        require({asset["name"] for asset in assets} <= {p.name for p in files},
                "Existing GitHub release has unexpected assets")
    # Resolve the tag itself, including annotated tags. target_commitish alone
    # does not establish where a previously existing Git tag points.
    commit = output(["gh", "api", f"repos/{repository}/commits/{tag}", "--jq", ".sha"])
    require(commit == lock["project_commit"], "Release tag points to another project commit")
    with tempfile.TemporaryDirectory(prefix="w132d-assets-") as tmp:
        for path in files:
            if any(a["name"] == path.name for a in assets):
                run(["gh", "release", "download", tag, "--repo", repository, "--pattern", path.name, "--dir", tmp])
                require(sha256(Path(tmp) / path.name) == sha256(path), "Immutable release asset mismatch: " + path.name)
            else:
                run(["gh", "release", "upload", tag, "--repo", repository, path])


def latest(directory, repository, attempts=12, delay=5):
    from .repository import remote_state
    lock = verify(directory)
    history = []
    for attempt in range(attempts):
        state = remote_state(lock["repository"], lock.get("initialize_repository", False))
        history = state.get("channels", {}).get(lock["channel"], [])
        if history and history[0]["version"] == lock["version"]:
            break
        if history:
            from .repository import version_newer
            require(not version_newer(history[0]["version"], lock["version"]), "A newer APT candidate is already deployed")
        if attempt + 1 < attempts:
            time.sleep(delay)
    require(bool(history) and history[0]["version"] == lock["version"], "APT deployment is not serving this candidate; Latest was not changed")
    require(history[0]["project_commit"] == lock["project_commit"], "Deployed project commit mismatch")
    tag = "v" + lock["version"].replace("~", "-")
    if lock["channel"] == "stable":
        run(["gh", "release", "edit", tag, "--repo", repository, "--prerelease=false", "--latest"])
        require(output(["gh", "api", f"repos/{repository}/releases/latest", "--jq", ".tag_name"]) == tag,
                "GitHub Latest release points to another version")
    else:
        print("Experimental artifacts remain prereleases")
