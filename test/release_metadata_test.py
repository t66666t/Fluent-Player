"""Release integrity checks using tiny fixtures; no builds, signing or uploads."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tool'))
import release_metadata as release
from package_android_release import validate_badging
from package_apple_release import macos_architecture, verify_version
from prepare_android_signing import property_value
try:
    from publish_release_draft import check_draft_assets, validate_target
except ModuleNotFoundError as error:
    if error.name != 'publish_release_draft':
        raise
    check_draft_assets = validate_target = None


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        (self.root / 'pubspec.yaml').write_text('version: 1.0.0+2\n')
        root_patch = patch.object(release, 'ROOT', self.root)
        root_patch.start()
        self.addCleanup(root_patch.stop)
        self.commit = 'a' * 40
        self.notes = self.root / 'notes.md'
        self.notes.write_text('# Release\n\nActual changes.\n')
        self.inputs = self.root / 'inputs'
        self.output = self.root / 'public'

    def platform(self, platform='linux', commit=None):
        directory = self.inputs / platform
        directory.mkdir(parents=True)
        for suffix in release.EXTENSIONS[platform]:
            (directory / (release.prefix(platform, 'x64') + suffix)).write_bytes(b'fixture, not an executable')
        with patch.object(release.subprocess, 'check_output', return_value=(commit or self.commit) + '\n'):
            return release.write_platform_manifest(directory, platform, 'x64', 'fixture')

    def collect(self, platforms=('linux',)):
        release.collect(self.inputs, self.output, platforms, self.commit, self.notes)

    def test_collects_verified_assets_and_checksums(self):
        record = self.platform()
        self.collect()
        for item in record['files']:
            self.assertEqual(release.sha(self.output / item['name']), item['sha256'])
        self.assertIn('release-manifest.json', (self.output / 'SHA256SUMS.txt').read_text())
        self.assertIn(self.commit, (self.output / 'RELEASE_NOTES.md').read_text(encoding='utf-8'))

    def test_rejects_an_asset_changed_after_recording(self):
        record = self.platform()
        (self.inputs / 'linux' / record['files'][0]['name']).write_bytes(b'tampered')
        with self.assertRaisesRegex(ValueError, 'integrity'):
            self.collect()
        self.assertFalse(self.output.exists())

    def test_rejects_mixed_source_commits(self):
        self.platform(commit='b' * 40)
        with self.assertRaisesRegex(ValueError, 'mixed versions or source commits'):
            self.collect()

    def test_rejects_mixed_versions(self):
        self.platform()
        (self.root / 'pubspec.yaml').write_text('version: 1.0.1+3\n')
        with self.assertRaisesRegex(ValueError, 'mixed versions or source commits'):
            self.collect()

    def test_does_not_silently_omit_a_required_platform(self):
        self.platform()
        with self.assertRaisesRegex(ValueError, 'Missing platforms: windows'):
            self.collect(('linux', 'windows'))
        self.assertFalse(self.output.exists())

    def test_rejects_missing_package_format(self):
        self.platform()
        path = self.inputs / 'linux/linux-manifest.json'
        record = json.loads(path.read_text())
        record['files'] = [item for item in record['files'] if not item['name'].endswith('.deb')]
        path.write_text(json.dumps(record))
        with self.assertRaisesRegex(ValueError, 'Missing linux release asset'):
            self.collect()

    def test_rejects_unsafe_asset_path(self):
        self.platform()
        path = self.inputs / 'linux/linux-manifest.json'
        record = json.loads(path.read_text())
        record['files'][0]['name'] = '../private.apk'
        path.write_text(json.dumps(record))
        with self.assertRaisesRegex(ValueError, 'filename'):
            self.collect()

    @unittest.skipIf(validate_target is None, 'Community project has no automatic release publishing tool')
    def test_refuses_public_release_or_tag_movement(self):
        with self.assertRaisesRegex(ValueError, 'public release'):
            validate_target({'draft': False, 'target_commitish': self.commit}, self.commit, self.commit)
        with self.assertRaisesRegex(ValueError, 'will not be moved'):
            validate_target(None, 'b' * 40, self.commit)
        validate_target({'draft': True, 'target_commitish': self.commit}, self.commit, self.commit)

    @unittest.skipIf(validate_target is None, 'Community project has no automatic release publishing tool')
    def test_resolves_draft_when_tag_endpoint_returns_404(self):
        from publish_release_draft import find_release
        draft = {'tag_name': 'v1.0.0', 'draft': True, 'id': 42}
        with patch('publish_release_draft.api', side_effect=[None, [draft]]):
            self.assertEqual(find_release('repos/owner/repo', 'v1.0.0'), draft)

    @unittest.skipIf(validate_target is None, 'Community project has no automatic release publishing tool')
    def test_draft_lookup_checks_later_pages(self):
        from publish_release_draft import find_release
        draft = {'tag_name': 'v1.0.0', 'draft': True, 'id': 42}
        older = [{'tag_name': f'v0.0.{i}'} for i in range(100)]
        with patch('publish_release_draft.api', side_effect=[None, older, [draft]]):
            self.assertEqual(find_release('repos/owner/repo', 'v1.0.0'), draft)

    @unittest.skipIf(validate_target is None, 'Community project has no automatic release publishing tool')
    def test_duplicate_drafts_are_not_modified(self):
        from publish_release_draft import find_release
        with patch('publish_release_draft.api', side_effect=[None, [{'tag_name': 'v1.0.0'}] * 2]):
            with self.assertRaisesRegex(ValueError, 'Multiple drafts'):
                find_release('repos/owner/repo', 'v1.0.0')

    @unittest.skipIf(validate_target is None, 'Community project has no automatic release publishing tool')
    def test_draft_can_add_platform_but_cannot_replace_old_binary(self):
        binary = self.root / 'existing.apk'
        binary.write_bytes(b'original')
        metadata = self.root / 'release-manifest.json'
        metadata.write_text('{}')
        existing = {binary.name: {'digest': 'sha256:' + release.sha(binary)},
                    metadata.name: {'digest': 'sha256:older-metadata'}}
        self.assertEqual(check_draft_assets(existing, [binary, metadata]), {metadata.name})
        binary.write_bytes(b'replaced')
        with self.assertRaisesRegex(ValueError, 'different asset bytes'):
            check_draft_assets(existing, [binary, metadata])

    def test_android_and_apple_versions_must_match_release(self):
        badging = "package: name='cn.teezy.fluentplayer.standard' versionCode='2' versionName='1.0.0'"
        validate_badging(badging, release.read_version())
        for other_package in ('com.example.video_player_app', 'cn.teezy.fluentplayer.pro'):
            with self.subTest(package=other_package):
                with self.assertRaisesRegex(ValueError, 'name'):
                    validate_badging(badging.replace('cn.teezy.fluentplayer.standard', other_package), release.read_version())
        with self.assertRaisesRegex(ValueError, 'versionCode'):
            validate_badging(badging.replace("versionCode='2'", "versionCode='1'"), release.read_version())
        with self.assertRaisesRegex(ValueError, 'debuggable'):
            validate_badging(badging + '\napplication-debuggable', release.read_version())
        with self.assertRaisesRegex(ValueError, 'version differs'):
            verify_version({'CFBundleShortVersionString': '1.0.0', 'CFBundleVersion': '1'})

    def test_mac_framework_can_narrow_universal_runner(self):
        app = self.root / 'test.app'
        executable = app / 'Contents/MacOS/player'
        plugin = app / 'Contents/Frameworks/plugin.dylib'
        for path in (executable, plugin):
            path.parent.mkdir(parents=True)
            path.write_bytes(b'\xcf\xfa\xed\xfe' + bytes(32))
        with patch('package_apple_release.subprocess.check_output', side_effect=['x86_64 arm64', 'arm64']):
            self.assertEqual(macos_architecture(app, 'player'), 'arm64')
        with patch('package_apple_release.subprocess.check_output', side_effect=['x86_64', 'arm64']):
            with self.assertRaisesRegex(ValueError, 'compatible slice'):
                macos_architecture(app, 'player')

    def test_java_properties_preserve_password_characters(self):
        self.assertEqual(property_value(' a:b=c\\d\n'), r'\ a\:b\=c\\d\n')
        self.assertEqual(property_value('密🔑'), r'\u5bc6\ud83d\udd11')


if __name__ == '__main__':
    unittest.main()
