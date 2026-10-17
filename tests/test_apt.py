# SPDX-License-Identifier: MIT
"""Use real, isolated APT and dpkg databases; never touch host repositories."""
import copy
import importlib.machinery
import importlib.util
import pwd
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from test_release import make_deb, lock
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from w132dlib import repository
from w132dlib.common import ROOT, PACKAGES, output, run, sha256, write_json

loader = importlib.machinery.SourceFileLoader('channel', str(ROOT / 'userpatches/overlay/bsp-cli/usr/bin/w132d-channel'))
spec = importlib.util.spec_from_loader('channel', loader)
channel = importlib.util.module_from_spec(spec)
loader.exec_module(channel)


@unittest.skipUnless(shutil.which('apt-get') and shutil.which('gpg'), 'APT and GnuPG are required')
class Apt(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='w132d-apt-test-')
        self.root = Path(self.temporary.name)
        self.gpg = self.root / 'gpg'
        self.gpg.mkdir(mode=0o700)
        self.environment = patch.dict(os.environ, GNUPGHOME=str(self.gpg))
        self.environment.start()
        run(['gpg', '--batch', '--pinentry-mode', 'loopback', '--passphrase', '', '--quick-generate-key',
             'W132D Test <test@example.invalid>', 'rsa2048', 'sign', '0'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.key = output(['gpg', '--with-colons', '--list-keys']).split('fpr:::::::::')[1].split(':')[0]
        self.keyring = self.root / 'public.gpg'
        with self.keyring.open('wb') as f:
            run(['gpg', '--export', self.key], stdout=f)
        trusted = self.root / 'userpatches/overlay/bsp-cli/usr/share/keyrings/w132d-archive-keyring.gpg'
        trusted.parent.mkdir(parents=True)
        shutil.copy2(self.keyring, trusted)
        self.root_patch = patch.object(repository, 'ROOT', self.root)
        self.root_patch.start()
        self.apt = self.root / 'apt'
        shutil.copytree(ROOT / 'userpatches/overlay/bsp-cli/etc/apt', self.apt / 'etc/apt')
        for name in ('state/lists/partial', 'cache/archives/partial', 'log'):
            (self.apt / name).mkdir(parents=True, exist_ok=True)
        (self.apt / 'status').touch()
        (self.apt / 'etc/apt/sources.list').touch()
        self.options = ['-o', 'Dir::Etc=' + str(self.apt / 'etc/apt'),
                        '-o', 'Dir::State=' + str(self.apt / 'state'),
                        '-o', 'Dir::State::status=' + str(self.apt / 'status'),
                        '-o', 'Dir::Cache=' + str(self.apt / 'cache'), '-o', 'Dir::Log=' + str(self.apt / 'log'),
                        '-o', 'APT::Architecture=arm64', '-o', 'APT::Architectures::=arm64',
                        '-o', 'APT::Sandbox::User=' + pwd.getpwuid(os.getuid()).pw_name, '-o', 'Acquire::Languages=none']

    def tearDown(self):
        self.root_patch.stop()
        self.environment.stop()
        subprocess.run(['gpgconf', '--homedir', str(self.gpg), '--kill', 'all'], capture_output=True)
        self.temporary.cleanup()

    def package_set(self, version):
        dest = self.root / version
        dest.mkdir()
        records = []
        for i, name in enumerate(PACKAGES[:4]):
            p = make_deb(dest, name, version, f'package-{i}-{version}.deb')
            records.append({'package': name, 'version': version, 'architecture': 'arm64', 'file': p.name,
                            'sha256': sha256(p), 'size': p.stat().st_size})
        write_json(dest / 'packages.json', records)
        return dest

    def update(self):
        run(['apt-get', *self.options, 'update'], stdout=subprocess.DEVNULL)

    def candidate(self):
        text = output(['apt-cache', *self.options, 'policy', PACKAGES[0]])
        return next(line.split(': ', 1)[1] for line in text.splitlines() if 'Candidate: ' in line)

    def test_signed_repository_channels_and_external_kernel_isolation(self):
        stable = '20261015.1.1'
        experimental = '20261015.2.1~experimental'
        first = self.root / 'site-first'
        state = repository.build(self.package_set(stable), first, lock(stable), self.key)
        site = self.root / 'site'
        state = repository.build(self.package_set(experimental), site, lock(experimental, 'experimental'),
                                 self.key, state, first.as_uri())
        for name, suite, enabled in (('w132d.sources', 'stable', 'yes'), ('w132d-experimental.sources', 'experimental', 'no')):
            (self.apt / 'etc/apt/sources.list.d' / name).write_text(
                f'Types: deb\nURIs: {site.as_uri()}\nSuites: {suite}\nComponents: main\nArchitectures: arm64\n'
                f'Signed-By: {self.keyring}\nEnabled: {enabled}\n')
        # A higher version from a different origin must not replace the board kernel.
        foreign = self.root / 'foreign'
        foreign.mkdir()
        bad = make_deb(foreign, PACKAGES[0], '99999999.1.1')
        paragraph = output(['dpkg-deb', '--field', bad])
        (foreign / 'Packages').write_text(paragraph + f'\nFilename: {bad.name}\nSize: {bad.stat().st_size}\nSHA256: {sha256(bad)}\n')
        (self.apt / 'etc/apt/sources.list.d/foreign.list').write_text(f'deb [trusted=yes] {foreign.as_uri()} ./\n')
        self.update()
        self.assertEqual(self.candidate(), stable)
        channel.switch(self.apt, 'experimental')
        self.update()
        self.assertEqual(self.candidate(), experimental)
        (self.apt / 'status').write_text(f'Package: {PACKAGES[0]}\nStatus: install ok installed\nArchitecture: arm64\nVersion: {experimental}\nDescription: Test fixture\n\n')
        channel.switch(self.apt, 'stable')
        self.update()
        self.assertEqual(self.candidate(), experimental, 'Disabling experimental must not auto-downgrade')
        newer = '20261016.3.1'
        final = self.root / 'site-new'
        repository.build(self.package_set(newer), final, lock(newer), self.key, state, site.as_uri())
        source = self.apt / 'etc/apt/sources.list.d/w132d.sources'
        source.write_text(source.read_text().replace(site.as_uri(), final.as_uri()))
        self.update()
        self.assertEqual(self.candidate(), newer)
        self.assertTrue(list((site / 'dists/stable/main/binary-arm64/by-hash/SHA256').iterdir()))

    def test_custom_pin_failure_leaves_both_files_untouched(self):
        pin = self.apt / 'etc/apt/preferences.d/w132d-kernel'
        source = self.apt / 'etc/apt/sources.list.d/w132d-experimental.sources'
        pin.write_text('# Administrator supplied configuration\n')
        previous = source.read_bytes()
        with self.assertRaisesRegex(ValueError, 'unique'):
            channel.switch(self.apt, 'experimental')
        self.assertEqual(source.read_bytes(), previous)
        self.assertEqual(pin.read_text(), '# Administrator supplied configuration\n')

    def test_signing_failure_does_not_mutate_previous_state(self):
        previous = {'schema': 1, 'channels': {}}
        with patch.object(repository, 'sign', side_effect=RuntimeError('Signing failed')):
            with self.assertRaisesRegex(RuntimeError, 'Signing failed'):
                repository.build(self.package_set('20261015.1.1'), self.root / 'failed-site', lock('20261015.1.1'), self.key, previous)
        self.assertEqual(previous, {'schema': 1, 'channels': {}})
        self.assertFalse((self.root / 'failed-site/state.json').exists())

    @unittest.skipUnless(os.geteuid() == 0, 'Isolated dpkg install requires root')
    def test_dpkg_conffile_upgrade_preserves_user_changes(self):
        root = self.root / 'device'
        (root / 'var/lib/dpkg').mkdir(parents=True)
        (root / 'var/lib/dpkg/status').touch()
        one = make_deb(self.root, 'w132d-config-test', '1', 'v1.deb', {'etc/w132d-test.conf': 'default=one\n'})
        two = make_deb(self.root, 'w132d-config-test', '2', 'v2.deb', {'etc/w132d-test.conf': 'default=two\n'})
        options = ['dpkg', '--force-architecture', '--root=' + str(root), '--force-confold', '--install']
        run([*options, one], stdout=subprocess.DEVNULL)
        (root / 'etc/w132d-test.conf').write_text('custom=yes\n')
        run([*options, two], stdout=subprocess.DEVNULL)
        self.assertEqual((root / 'etc/w132d-test.conf').read_text(), 'custom=yes\n')


if __name__ == '__main__':
    unittest.main()
