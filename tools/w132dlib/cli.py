# SPDX-License-Identifier: MIT
"""One command line for local development and release automation."""
import argparse
import json
from pathlib import Path
import subprocess
import sys

from .common import read_json


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    fetch = commands.add_parser("fetch", help="Freeze upstream versions and fetch checked inputs")
    fetch.add_argument("--lock", type=Path, default=Path("out/manifest.json"))
    fetch.add_argument("--channel", choices=("stable", "experimental"), default="experimental")
    fetch.add_argument("--latest", action="store_true", help="Resolve current official Linux and Armbian releases")
    fetch.add_argument("--detect", action="store_true", help="Skip when stable already contains both upstream versions")
    fetch.add_argument("--download", action="store_true")
    fetch.add_argument("--initialize", action="store_true", help="Allow a missing Pages state for the first stable publication")
    fetch.add_argument("--outputs", type=Path, help="Append prepare outputs for GitHub Actions")
    build = commands.add_parser("build", help="Build through the locked Armbian framework")
    build.add_argument("target", nargs="?", default="kernel", choices=("kernel", "image", "uboot", "bsp", "flash-tools", "fnos"))
    build.add_argument("--lock", type=Path, default=Path("out/manifest.json"))
    build.add_argument("--output", type=Path, default=Path("out/flash-tools"))
    build.add_argument("--framework", type=Path)
    build.add_argument("--base-image", type=Path, help="Explicit official fnOS image")
    build.add_argument("--base-sha256", help="Trusted SHA256 of the fnOS base image")
    verify = commands.add_parser("verify", help="Run release gates; failures are fatal")
    verify.add_argument("target", choices=("static", "patches", "debs", "image", "candidate", "tests"))
    verify.add_argument("--lock", type=Path, default=Path("out/manifest.json"))
    verify.add_argument("--directory", type=Path)
    verify.add_argument("--image", type=Path)
    verify.add_argument("--full", action="store_true")
    verify.add_argument("--jobs", type=int, default=4)
    release = commands.add_parser("release", help="Seal, archive and promote verified artifacts")
    release.add_argument("action", choices=("prepare", "immutable", "latest"))
    release.add_argument("--directory", type=Path, required=True)
    release.add_argument("--tools", type=Path, default=Path("out/flash-tools"))
    release.add_argument("--repository", help="GitHub owner/repository")
    repo = commands.add_parser("repo", help="Build signed Pages distributions from a sealed candidate")
    repo.add_argument("--directory", type=Path, required=True)
    repo.add_argument("--output", type=Path, required=True)
    repo.add_argument("--key", required=True, help="Signing key fingerprint")
    args = parser.parse_args(argv)
    try:
        if args.command == "fetch":
            from . import inputs
            lock = inputs.create_lock(args.lock, args.channel, args.latest, args.initialize)
            changed = not args.detect or inputs.changed(lock)
            if args.download and changed:
                inputs.fetch(lock)
            if args.outputs:
                with args.outputs.open("a") as f:
                    for key, value in {"changed": str(changed).lower(), "version": lock["version"],
                                       "commit": lock["project_commit"], "channel": lock["channel"]}.items():
                        f.write(f"{key}={value}\n")
            print(json.dumps({"changed": changed, "version": lock["version"]}))
        elif args.command == "build":
            if args.target == "flash-tools":
                from .flashtools import build
                build(args.output)
            elif args.target == "fnos":
                from .fnos import build
                build(read_json(args.lock), args.base_image, args.base_sha256)
            else:
                from .build import build
                build(read_json(args.lock), args.target, args.framework)
        elif args.command == "verify":
            from . import verification
            if args.target == "static":
                verification.static()
            elif args.target == "tests":
                verification.tests()
            elif args.target == "patches":
                verification.patches(read_json(args.lock), args.jobs)
            elif args.target == "debs":
                from .packages import verify
                verify(args.directory, read_json(args.lock), args.full)
            elif args.target == "image":
                from .images import verify_image
                verify_image(args.image, read_json(args.lock), args.directory or args.image.parent)
            else:
                from .release import verify
                verify(args.directory)
        elif args.command == "release":
            from . import release
            if args.action == "prepare":
                release.prepare(args.directory, args.tools)
            else:
                getattr(release, args.action)(args.directory, args.repository)
        else:
            from . import repository
            from .release import verify
            lock = verify(args.directory)
            previous = repository.remote_state(lock["repository"], lock.get("initialize_repository", False))
            repository.build(args.directory / "debs", args.output, lock, args.key,
                             previous, lock["repository"])
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        parser.exit(1, f"ERROR: {error}\n")
