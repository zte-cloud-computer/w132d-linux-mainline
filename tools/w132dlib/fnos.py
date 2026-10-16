# SPDX-License-Identifier: MIT
"""Keep fnOS repacking independent from the stable Armbian release channel."""
import os
from pathlib import Path
import shutil
import subprocess
import tarfile

from .common import ROOT, PACKAGES, output, require, run, sha256, write_json
from .inputs import fetch, validate_lock
from . import packages
from .build import build as build_armbian, checkout


def replace_once(path, before, after):
    text = Path(path).read_text()
    require(text.count(before) == 1, 'Pinned fnOS helper entry point changed: ' + str(path))
    Path(path).write_text(text.replace(before, after))


def build(lock, base_image, expected):
    validate_lock(lock)
    require(lock['channel'] == 'experimental', 'fnOS is a manual experimental artifact')
    require(base_image is not None and expected, 'fnOS requires an explicit base image and trusted SHA256')
    base = Path(base_image).resolve()
    require(sha256(base) == expected, 'fnOS base image checksum mismatch')
    for target in ('kernel', 'uboot', 'bsp'):
        build_armbian(lock, target)
    dest = ROOT / 'out' / lock['version']
    packages.verify(dest / 'debs', lock, full=True)
    source = checkout(lock['fnos'], ROOT / 'cache/fnnas' / lock['fnos']['commit'])
    work = ROOT / 'cache/fnos-work' / lock['version']
    require(not work.exists(), 'fnOS work directory already exists; keep completed artifacts or use a new lock')
    shutil.copytree(source, work, ignore=shutil.ignore_patterns('.git'))
    resources = checkout(lock['fnos_resources'], ROOT / 'cache/fnos-resources' / lock['fnos_resources']['commit'])
    # The helper's default dependency fetch follows mutable main branches.
    # Supply only Rockchip templates from the locked resources and our own
    # bootloader/firmware; preserve files already provided by the helper.
    platform = work / 'make-fnnas/fnnas-files/platform-files/rockchip'
    upstream = resources / 'build-armbian/armbian-files/platform-files/rockchip'
    for path in sorted(upstream.rglob('*')):
        relative = path.relative_to(upstream)
        if relative.parts[:3] == ('rootfs', 'usr', 'sbin'):
            continue
        target = platform / relative
        if not target.exists() and (path.is_file() or path.is_symlink()):
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, target, follow_symlinks=False)
    replace_once(work / 'renas', '\ndownload_depends\n', '\n: # Dependencies were staged from pinned sources\n')
    extlinux = platform / 'bootfs/extlinux/extlinux.conf.bak'
    extlinux.parent.mkdir(parents=True, exist_ok=True)
    extlinux.write_text('LABEL W132D\n  LINUX /Image\n  INITRD /uInitrd\n'
                       '  FDT /dtb/rockchip/rk3528-w132d.dtb\n'
                       '  APPEND root=LABEL=ROOTFS console=ttyS0,115200 console=tty1 rootwait consoleblank=0\n')
    dependencies = (work / 'make-fnnas/scripts/ubuntu2404-make-fnnas-depends').read_text().split()
    privilege = [] if os.geteuid() == 0 else ['sudo']
    run([*privilege, 'apt-get', 'update'])
    run([*privilege, 'apt-get', 'install', '-y', *dependencies])
    selected = packages.select(dest / 'debs', lock['version'], PACKAGES)
    debs = work / 'fnnas-debs/rockchip'
    debs.mkdir(parents=True, exist_ok=True)
    for name in PACKAGES[:3]:
        shutil.copy2(selected[name], debs / selected[name].name)
    extracted = work / 'w132d-packages'
    for name in (PACKAGES[0], PACKAGES[4]):
        run(['dpkg-deb', '--extract', selected[name], extracted])
    modules = list((extracted / 'lib/modules').iterdir())
    require(len(modules) == 1, 'Expected one fnOS kernel module directory')
    kernel_release = modules[0].name
    kernel_version = kernel_release.split('-', 1)[0]
    boot = work / 'make-fnnas/u-boot/rockchip/w132d'
    boot.mkdir(parents=True)
    for name in ('idbloader.img', 'u-boot.itb'):
        shutil.copy2(extracted / 'usr/lib/linux-u-boot-edge-w132d' / name, boot / name)
    root = work / 'make-fnnas/fnnas-files/common-files'
    database = root / 'etc/model_database.conf'
    require(':w132d ' not in database.read_text(), 'Review the newly added upstream fnOS board definition')
    with database.open('a') as f:
        f.write('\n# ZTE W132D maintained kernel and bootloader\n')
        f.write('r790 :ZTE-W132D :rk3528 :rk3528-w132d.dtb :NA :u-boot.itb :idbloader.img :2GB-LPDDR4,32G-eMMC,WiFi,1Gb-Nic :rockchip/all :rockchip :rk3528 :extlinux.conf :w132d-linux-mainline :w132d :yes\n')
    overlay = ROOT / 'userpatches/overlay/bsp-cli'
    for name in ('etc/apt', 'usr/share/keyrings', 'usr/lib/firmware'):
        shutil.copytree(overlay / name, root / name, dirs_exist_ok=True)
    files = fetch(lock)
    firmware = root / 'usr/lib/firmware/uwe5622/wcnmodem-marlin3e.bin'
    shutil.copy2(files['wcn'], firmware)
    image_dir = work / 'fnnas-arm64'
    image_dir.mkdir(exist_ok=True)
    require(base.name.endswith(('.img', '.img.xz')), 'fnOS base must be an .img or .img.xz file')
    shutil.copy2(base, image_dir / base.name)
    if base.suffix == '.xz':
        run(['unxz', image_dir / base.name])
    # fnnas has no local-deb-only flag at this pinned revision. Change only
    # the private staging copy, with an exact guard; never change Armbian.
    rekernel = work / 'rekernel'
    download = '[[ "${debs_install}" =~ ^(amlogic|allwinner|rockchip)$ ]] && download_debs'
    replace_once(rekernel, download, ': # W132D packages were staged from the verified manifest')
    chroot_script = work / 'make-fnnas/scripts/chroot_fnnas.sh'
    replace_once(chroot_script, 'latest_dtb_dir="$(ls -d /usr/lib/linux-image-* 2>/dev/null | sort -V | tail -n 1)"',
                 f'latest_dtb_dir="/usr/lib/linux-image-{kernel_release}"')
    replace_once(chroot_script, 'kernel_version="$(ls /boot/config-* 2>/dev/null | head -n1 | awk -F\'config-\' \'{print $2}\')"',
                 f'kernel_version="{kernel_release}"')
    run([*privilege, './rekernel', '-e', 'rockchip', '-t', 'false'], cwd=work)
    bundles = list((work / 'fnnas/out').glob('*-rockchip.tar.gz'))
    require(len(bundles) == 1, 'Expected one fnOS kernel bundle')
    kernel_dir = work / 'make-fnnas/kernel' / kernel_version
    kernel_dir.mkdir(parents=True, exist_ok=True)
    with tarfile.open(bundles[0]) as archive:
        archive.extractall(kernel_dir, filter='data')
    kernel_dir /= kernel_version + '-rockchip'
    for name in ('boot', 'dtb', 'modules', 'header'):
        require((kernel_dir / f'{name}-rockchip-{kernel_release}.tar.gz').is_file(), 'Incomplete fnOS kernel bundle')
    run(['sha256sum', '-c', 'sha256sums'], cwd=kernel_dir)
    run([*privilege, './renas', '-b', 'w132d', '-k', kernel_version, '-a', 'false', '-n', 'w132d'], cwd=work)
    images = list((work / 'fnnas/out').glob('*.img.gz'))
    require(bool(images), 'fnOS did not produce an image')
    final = dest / 'fnos'
    final.mkdir(exist_ok=True)
    for image in images:
        shutil.copy2(image, final / image.name)
    write_json(final / 'manifest.json', {'build': lock, 'base_image': base.name, 'base_sha256': expected,
               'kernel_release': kernel_release, 'hardware_tested': False,
               'images': {p.name: sha256(p) for p in images}})
    print('Manual fnOS artifacts are ready; no stable publication was performed')
