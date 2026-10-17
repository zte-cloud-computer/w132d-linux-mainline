# SPDX-License-Identifier: MIT
"""Exercise release selection, immutable publication and package boundaries."""
import copy
import importlib.util
import json
from datetime import datetime, timezone
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from urllib.error import HTTPError

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from w132dlib import build, inputs, packages, repository, release, verification
from w132dlib.common import ROOT, PACKAGES, digest_tree, read_json, run, sha256, write_json


def make_deb(directory, name, version, filename='opaque.deb', payload=None):
    directory = Path(directory)
    with tempfile.TemporaryDirectory() as temporary:
        tree = Path(temporary)
        (tree / 'DEBIAN').mkdir()
        (tree / 'DEBIAN/control').write_text(
            f'Package: {name}\nVersion: {version}\nArchitecture: arm64\n'
            'Maintainer: Test <test@example.invalid>\nDescription: Test fixture\n')
        if payload:
            for relative, text in payload.items():
                target = tree / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text(text)
            conffiles = [r for r in payload if r.startswith('etc/')]
            if conffiles:
                (tree / 'DEBIAN/conffiles').write_text('\n'.join('/' + r for r in conffiles) + '\n')
        dest = directory / filename
        run(['dpkg-deb', '--root-owner-group', '--build', tree, dest], stdout=subprocess.DEVNULL)
        return dest


def lock(version='20261015.100.1', channel='stable'):
    return {'schema': 1, 'version': version, 'channel': channel, 'project_commit': 'a' * 40,
            'linux': {'tag': 'v7.2.10'}, 'armbian': {'tag': 'v26.5.1'},
            'uboot': {'tag': 'v2026.10'}, 'repository': 'https://example.invalid'}


class Inputs(unittest.TestCase):
    def test_repeat_build_accepts_only_the_framework_customization_template(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            template = root / 'config/templates/customize-image.sh.template'
            template.parent.mkdir(parents=True)
            template.write_text('#!/bin/bash\ntrue\n')
            candidate = read_json(ROOT / 'config/sources.json')
            candidate.update(version='20261015.100.1', source_date_epoch=1000, inputs={'test': 'digest'})
            build.stage(candidate, root, {})
            customize = root / 'userpatches/customize-image.sh'
            shutil.copy2(template, customize)
            build.stage(candidate, root, {})
            customize.write_text('#!/bin/bash\necho private\n')
            with self.assertRaisesRegex(ValueError, 'private customize-image.sh'):
                build.stage(candidate, root, {})
            self.assertIn('private', customize.read_text())

    def test_official_armbian_excludes_trunk_drafts_and_preview(self):
        releases = [{'tag_name': tag, 'draft': draft, 'prerelease': preview} for tag, draft, preview in
                    [('v26.5.1', False, False), ('v26.8.0-trunk.99', False, False),
                     ('v26.8.0', True, False), ('v26.9.0', False, True)]]
        self.assertEqual([r['tag_name'] for r in inputs.official_armbian(releases)], ['v26.5.1'])

    def test_new_kernel_series_and_combined_updates(self):
        def api(url):
            if 'kernel.org' in url:
                return {'releases': [{'moniker': 'stable', 'version': '7.3'}, {'moniker': 'stable', 'version': '7.2.12'},
                                     {'moniker': 'mainline', 'version': '7.4-rc1'}]}
            if '/u-boot/' in url:
                return [{'name': name} for name in ('v2026.07', 'v2026.10', 'v2027.01-rc1', 'c2027.01')]
            return [{'tag_name': 'v26.8.1', 'draft': False, 'prerelease': False}]
        with patch.object(inputs, 'api', side_effect=api), patch.object(inputs, 'resolve_tag', return_value='b' * 40):
            result = inputs.upstreams()
        self.assertEqual(result['linux']['tag'], 'v7.3')
        self.assertEqual(result['armbian']['tag'], 'v26.8.1')
        self.assertEqual(result['uboot']['tag'], 'v2026.10')

    def test_no_change_skips_but_detection_errors_fail(self):
        current = lock()
        current.update(inputs={'driver.c': 'source-hash'}, blobs={'loader': {'sha256': 'blob-hash'}})
        state = repository.next_state({}, current, [])
        with patch.object(repository, 'remote_state', return_value=state):
            self.assertFalse(inputs.changed(current))
            newer = copy.deepcopy(current)
            newer['linux']['tag'] = 'v7.3'
            self.assertTrue(inputs.changed(newer))
            for name in ('inputs', 'blobs'):
                with self.subTest(changed=name):
                    newer = copy.deepcopy(current)
                    newer[name]['new-input'] = 'changed'
                    self.assertTrue(inputs.changed(newer))
            newer = copy.deepcopy(current)
            newer.update(version='20261016.101.1', project_commit='b' * 40)
            self.assertFalse(inputs.changed(newer))
        error = HTTPError('https://example.invalid', 503, 'Unavailable', None, None)
        with patch.object(repository, 'api', side_effect=error):
            with self.assertRaises(HTTPError):
                repository.remote_state('https://example.invalid')

    def test_missing_history_or_digest_requires_publication(self):
        current = lock()
        current['inputs'] = {'driver.c': 'source-hash'}
        for state in ({'channels': {}}, {'channels': {'stable': [current]}}):
            with self.subTest(state=state), patch.object(repository, 'remote_state', return_value=state):
                self.assertTrue(inputs.changed(current))

    @unittest.skipUnless(shutil.which('dpkg'), 'dpkg version comparison is required')
    def test_shanghai_version_and_experimental_order(self):
        stamp = datetime(2026, 10, 14, 18, tzinfo=timezone.utc)
        stable = inputs.release_version('stable', stamp, 123, 2)
        experimental = inputs.release_version('experimental', stamp, 123, 2)
        self.assertEqual(stable, '20261015.123.2')
        self.assertTrue(repository.version_newer(stable, experimental))

    def test_cache_digest_tracks_contents_paths_and_modes(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            path = root / 'driver.c'
            path.write_text('original')
            before = digest_tree(root)
            path.write_text('changed')
            self.assertNotEqual(before, digest_tree(root))
            before = digest_tree(root)
            path.chmod(0o755)
            self.assertNotEqual(before, digest_tree(root))
            before = digest_tree(root)
            path.rename(root / 'board.c')
            self.assertNotEqual(before, digest_tree(root))
        self.assertIn('userpatches/extensions/w132d', inputs.INPUT_DIRS)
        self.assertIn('userpatches/overlay', inputs.INPUT_DIRS)

    def test_patch_conflict_is_fatal(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            run(['git', 'init', '-q', root])
            (root / 'file').write_text('before\n')
            patchfile = root / 'change.patch'
            patchfile.write_text('diff --git a/file b/file\n--- a/file\n+++ b/file\n@@ -1 +1 @@\n-before\n+after\n')
            verification.strict_apply(root, [patchfile])
            self.assertEqual((root / 'file').read_text(), 'after\n')
            with self.assertRaises(subprocess.CalledProcessError):
                verification.strict_apply(root, [patchfile])


@unittest.skipUnless(shutil.which('dpkg-deb'), 'Debian package tools are required')
class Packages(unittest.TestCase):
    def test_metadata_selection_ignores_names_and_rejects_duplicates(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            p = make_deb(root, PACKAGES[0], '20261015.1.1', 'unexpected-name.deb')
            make_deb(root, PACKAGES[0], '20261014.1.1', 'newest-looking.deb')
            selected = packages.select(root, '20261015.1.1', [PACKAGES[0]])
            self.assertEqual(selected[PACKAGES[0]], p)
            make_deb(root, PACKAGES[0], '20261015.1.1', 'conflict.deb', {'usr/share/changed': 'changed'})
            with self.assertRaisesRegex(ValueError, 'Conflicting packages'):
                packages.select(root, '20261015.1.1', [PACKAGES[0]])

    def test_dependencies_and_repacking_are_deterministic(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            first = make_deb(root, PACKAGES[0], '20261015.1.1')
            second = root / 'second.deb'
            shutil.copy2(first, second)
            packages.finalize(first, 1000)
            packages.finalize(second, 1000)
            self.assertEqual(sha256(first), sha256(second))
            before = sha256(first)
            packages.finalize(first, 1000)
            self.assertEqual(before, sha256(first))
            self.assertEqual(packages.metadata(first)['Depends'], f'{PACKAGES[1]} (= 20261015.1.1)')


class Publication(unittest.TestCase):
    @unittest.skipUnless(shutil.which('dpkg'), 'dpkg version comparison is required')
    def test_retention_stale_rejection_and_idempotency(self):
        state = {'channels': {}}
        for n in range(1, 6):
            state = repository.next_state(state, lock(f'20261015.{n}.1'), [])
        self.assertEqual(len(state['channels']['stable']), 3)
        self.assertEqual(repository.next_state(state, lock('20261015.5.1'), []), state)
        with self.assertRaisesRegex(ValueError, 'stale'):
            repository.next_state(state, lock('20261015.4.1'), [])
        with self.assertRaisesRegex(ValueError, 'stale publication task'):
            repository.next_state(state, lock('20261016.4.2'), [])
        with self.assertRaisesRegex(ValueError, 'different package bytes'):
            repository.next_state(state, lock('20261015.5.1'), [{'sha256': 'changed'}])
        before = copy.deepcopy(state)
        for n in range(6, 9):
            state = repository.next_state(state, lock(f'20261015.{n}.1~experimental', 'experimental'), [])
        self.assertEqual(state['channels']['stable'], before['channels']['stable'])
        self.assertEqual(len(state['channels']['experimental']), 2)

    def test_pages_failure_cannot_promote_latest(self):
        with patch.object(release, 'verify', return_value=lock()), patch.object(repository, 'remote_state', return_value={'channels': {}}), patch.object(release, 'run') as gh:
            with self.assertRaisesRegex(ValueError, 'APT deployment'):
                release.latest(Path('/unused'), 'owner/repo', attempts=1)
            gh.assert_not_called()

    def test_latest_waits_for_pages_propagation(self):
        current = lock()
        with patch.object(release, 'verify', return_value=current), patch.object(repository, 'remote_state', side_effect=[{'channels': {}}, {'channels': {'stable': [current]}}]), patch.object(release.time, 'sleep'), patch.object(release, 'output', return_value='v'+current['version'].replace('~','-')), patch.object(release, 'run') as gh:
            release.latest(Path('/unused'), 'owner/repo', attempts=2)
            self.assertIn('--latest', gh.call_args.args[0])

    @unittest.skipUnless(shutil.which('dpkg'), 'dpkg version comparison is required')
    def test_upstream_regression_is_rejected(self):
        current = lock()
        state = repository.next_state({}, current, [])
        for name, tag in [('linux', 'v7.1.20'), ('armbian', 'v26.2.1')]:
            candidate = lock('20261016.101.1')
            candidate[name]['tag'] = tag
            with self.assertRaisesRegex(ValueError, 'upstream version regression'):
                repository.next_state(state, candidate, [])

    def test_downloaded_release_checksums_use_exact_flat_assets(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / 'debs').mkdir()
            for name in ('manifest.json', 'candidate.json', 'w132d.img', 'debs/kernel.deb'):
                (root / name).write_text(name)
            candidate = {'files': {'manifest.json': {}, 'w132d.img': {}, 'debs/kernel.deb': {}}}
            sums = release.publication_sums(root, candidate)
            self.assertEqual({line.split()[1] for line in sums.splitlines()}, {'manifest.json', 'candidate.json', 'kernel.deb'})
            (root / 'SHA256SUMS').write_text(sums)
            download = root / 'download'
            download.mkdir()
            for path in release.publication_files(root, candidate):
                shutil.copy2(path, download / path.name)
            for line in (download / 'SHA256SUMS').read_text().splitlines():
                digest, name = line.split()
                self.assertEqual(sha256(download / name), digest)

    @unittest.skipUnless(shutil.which('python3') and importlib.util.find_spec('yaml'), 'PyYAML is required for workflow checks')
    def test_workflow_serializes_and_separates_secrets(self):
        import yaml
        workflow = yaml.load((ROOT / '.github/workflows/build.yml').read_text(), Loader=yaml.BaseLoader)
        self.assertEqual(workflow['concurrency']['cancel-in-progress'], 'false')
        self.assertEqual(workflow['permissions']['contents'], 'read')
        self.assertEqual(workflow['on']['schedule'][1]['cron'], '43 2 * * *')
        self.assertEqual(workflow['jobs']['checks']['runs-on'], 'ubuntu-26.04-arm')
        self.assertEqual(workflow['jobs']['compile']['runs-on'], 'ubuntu-26.04-arm')
        for name, job in workflow['jobs'].items():
            if name != 'publish':
                self.assertNotIn('secrets.', str(job))
        steps = workflow['jobs']['publish']['steps']
        archive = next(i for i, x in enumerate(steps) if 'release immutable' in x.get('run', ''))
        sign = next(i for i, x in enumerate(steps) if 'tools/w132d repo' in x.get('run', ''))
        deploy = next(i for i, x in enumerate(steps) if 'actions/deploy-pages' in x.get('uses', ''))
        latest = next(i for i, x in enumerate(steps) if 'release latest' in x.get('run', ''))
        self.assertLess(archive, sign)
        self.assertLess(sign, deploy)
        self.assertLess(deploy, latest)


class ImmutablePublication(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.current = lock()
        self.repo = 'owner/repo'
        self.assets = {}
        self.commands = []
        self.existing = {'tag_name': 'v' + self.current['version'],
                         'target_commitish': self.current['project_commit'],
                         'draft': False, 'prerelease': False}
        write_json(self.root / 'manifest.json', self.current)
        write_json(self.root / 'debs/packages.json', [])
        (self.root / 'debs/kernel.deb').write_bytes(b'sealed package')
        (self.root / 'release-notes.md').write_text('release notes')
        candidate = {'files': {name: {} for name in
                              ('manifest.json', 'debs/packages.json', 'debs/kernel.deb', 'release-notes.md')}}
        write_json(self.root / 'candidate.json', candidate)
        (self.root / 'SHA256SUMS').write_text(release.publication_sums(self.root, candidate))
        self.files = {path.name: path.read_bytes() for path in release.publication_files(self.root, candidate)}
        for target, name, options in (
                (release, 'verify', {'return_value': self.current}),
                (repository, 'remote_state', {'return_value': {'channels': {}}}),
                (release, 'run', {'side_effect': self.gh}),
                (release, 'output', {'side_effect': lambda args: self.gh(args).stdout.strip()})):
            mock = patch.object(target, name, **options)
            mock.start()
            self.addCleanup(mock.stop)

    def gh(self, args, **kwargs):
        args = [str(arg) for arg in args]
        self.commands.append(args)
        if args == ['gh', 'api', f'repos/{self.repo}/releases?per_page=100']:
            result = json.dumps([self.existing] if self.existing else [])
        elif args[:2] == ['gh', 'api'] and args[2].startswith(f'repos/{self.repo}/commits/'):
            result = self.current['project_commit']
        elif args[:3] == ['gh', 'release', 'view']:
            result = json.dumps({'assets': [{'name': name} for name in self.assets]})
        elif args[:3] == ['gh', 'release', 'create']:
            self.existing = {'tag_name': args[3], 'target_commitish': self.current['project_commit'],
                             'draft': False, 'prerelease': True}
            result = ''
        elif args[:3] == ['gh', 'release', 'download']:
            name = args[args.index('--pattern') + 1]
            (Path(args[args.index('--dir') + 1]) / name).write_bytes(self.assets[name])
            result = ''
        elif args[:3] == ['gh', 'release', 'upload']:
            path = Path(args[-1])
            self.assertNotIn(path.name, self.assets)
            self.assets[path.name] = path.read_bytes()
            result = ''
        else:
            self.fail(f'Unexpected command: {args}')
        return subprocess.CompletedProcess(args, 0, stdout=result)

    def test_new_stable_release_starts_as_prerelease(self):
        self.existing = None
        release.immutable(self.root, self.repo)
        self.assertEqual(self.assets, self.files)
        create = next(cmd for cmd in self.commands if cmd[:3] == ['gh', 'release', 'create'])
        self.assertIn('--prerelease', create)
        self.assertIn('--latest=false', create)

    def test_retries_reuse_complete_or_partial_assets_in_each_channel(self):
        for channel, prerelease in (('stable', True), ('stable', False), ('experimental', True)):
            for count in (0, 1, len(self.files)):
                with self.subTest(channel=channel, prerelease=prerelease, assets=count):
                    self.current['channel'] = channel
                    self.current['version'] = '20261015.100.1' + ('~experimental' if channel == 'experimental' else '')
                    self.existing['tag_name'] = 'v' + self.current['version'].replace('~', '-')
                    self.existing['prerelease'] = prerelease
                    self.assets = dict(list(self.files.items())[:count])
                    self.commands.clear()
                    release.immutable(self.root, self.repo)
                    self.assertEqual(self.assets, self.files)
                    self.assertFalse(any(cmd[:3] in (['gh', 'release', 'create'], ['gh', 'release', 'edit'])
                                         for cmd in self.commands))
                    uploads = [cmd for cmd in self.commands if cmd[:3] == ['gh', 'release', 'upload']]
                    self.assertEqual(len(uploads), len(self.files) - count)

    def test_experimental_release_cannot_be_promoted(self):
        self.current['channel'] = 'experimental'
        self.current['version'] += '~experimental'
        self.existing['tag_name'] = 'v' + self.current['version'].replace('~', '-')
        with self.assertRaisesRegex(ValueError, 'channel mismatch'):
            release.immutable(self.root, self.repo)

    def test_retry_rejects_unexpected_assets(self):
        self.assets['unexpected.txt'] = b'unexpected'
        with self.assertRaisesRegex(ValueError, 'unexpected assets'):
            release.immutable(self.root, self.repo)

    def test_retry_rejects_changed_asset_bytes(self):
        self.assets = dict(self.files)
        self.assets['kernel.deb'] = b'different package'
        with self.assertRaisesRegex(ValueError, 'Immutable release asset mismatch: kernel.deb'):
            release.immutable(self.root, self.repo)


if __name__ == '__main__':
    unittest.main()
