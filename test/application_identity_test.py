"""Cross-platform edition identity contracts, including rejection of mixed builds."""
import importlib.util
from pathlib import Path
import shutil
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('application_identity', ROOT / 'tool/verify_application_identity.py')
identity = importlib.util.module_from_spec(spec)
spec.loader.exec_module(identity)
COMMUNITY = (ROOT / 'community-contracts.json').is_file()
APP_ID = 'cn.teezy.fluentplayer.' + ('standard' if COMMUNITY else 'pro')
OTHER_ID = 'cn.teezy.fluentplayer.' + ('pro' if COMMUNITY else 'standard')


class ApplicationIdentityTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        files = [
            'android/app/build.gradle.kts', 'android/app/src/main/AndroidManifest.xml',
            'windows/CMakeLists.txt', 'windows/runner/Runner.rc', 'windows/runner/desktop_app_identity.h',
            'packaging/windows/fluent-player.iss', 'packaging/windows/edition_guard.iss',
            'ios/Runner/Info.plist', 'macos/Runner/Info.plist',
            'macos/Runner/Configs/AppInfo.xcconfig', 'ios/Runner.xcodeproj/project.pbxproj',
            'linux/CMakeLists.txt', 'lib/platform/linux_application_identity.dart',
            'lib/utils/app_branding.dart', 'lib/utils/app_data_paths.dart', 'lib/main.dart',
        ]
        for relative in files:
            target = self.root / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / relative, target)
        if COMMUNITY:
            (self.root / 'community-contracts.json').write_text('{}')

    def change(self, relative, before, after):
        path = self.root / relative
        text = path.read_text(encoding='utf-8')
        self.assertIn(before, text)
        path.write_text(text.replace(before, after), encoding='utf-8')

    def test_current_edition_has_consistent_platform_identity(self):
        self.assertEqual(identity.verify(self.root), APP_ID)

    def test_installer_does_not_inherit_the_other_editions_previous_directory(self):
        installer = (self.root / 'packaging/windows/fluent-player.iss').read_text(encoding='utf-8')
        self.assertIn('UsePreviousAppDir=no\n', installer)
        name = 'Fluent Player' if COMMUNITY else 'Fluent Player Pro'
        other_name = 'Fluent Player Pro' if COMMUNITY else 'Fluent Player'
        directories = [line for line in installer.splitlines() if line.startswith('DefaultDirName=')]
        self.assertEqual(directories, ['DefaultDirName={localappdata}\\Programs\\' + name])
        self.assertNotEqual(directories[0], 'DefaultDirName={localappdata}\\Programs\\' + other_name)

    def test_other_android_edition_cannot_be_shipped_under_this_edition(self):
        self.change('android/app/build.gradle.kts', APP_ID, OTHER_ID)
        with self.assertRaisesRegex(ValueError, 'Android applicationId'):
            identity.verify(self.root)

    def test_installer_guard_cannot_be_omitted_or_validate_the_other_publisher(self):
        self.change('packaging/windows/fluent-player.iss', '#include "edition_guard.iss"', '; omitted')
        with self.assertRaisesRegex(ValueError, 'Windows installation identity guard'):
            identity.verify(self.root)

    def test_installer_runtime_guard_blocks_both_cross_edition_and_unknown_identity(self):
        guard = (self.root / 'packaging/windows/edition_guard.iss').read_text(encoding='utf-8')
        self.assertIn('if FileExists(OtherRunner) or DirExists(OtherRunner) then', guard)
        self.assertIn('if not ReadInstalledEdition(OwnRunner, CompanyName, ProductName) then', guard)
        self.assertIn("if (CompanyName <> '{#EditionCompany}') or (ProductName <> '{#EditionProduct}') then", guard)
        self.assertIn('Please choose a different folder.', guard)
        self.assertNotIn('DeleteFile', guard)
        self.assertNotIn('DelTree', guard)
        self.assertNotIn('RenameFile', guard)

    def test_other_apple_edition_cannot_be_packaged_accidentally(self):
        self.change('ios/Runner.xcodeproj/project.pbxproj', APP_ID, OTHER_ID)
        with self.assertRaisesRegex(ValueError, 'iOS bundle ID'):
            identity.verify(self.root)

    def test_linux_launcher_and_application_id_must_match(self):
        self.change('linux/CMakeLists.txt', APP_ID, OTHER_ID)
        with self.assertRaisesRegex(ValueError, 'Linux application ID'):
            identity.verify(self.root)

    def test_windows_support_metadata_cannot_use_other_edition(self):
        company = 'Teezy Community' if COMMUNITY else 'Teezy'
        other_company = 'Teezy' if COMMUNITY else 'Teezy Community'
        self.change('windows/runner/Runner.rc', '"CompanyName", "' + company + '"',
                    '"CompanyName", "' + other_company + '"')
        with self.assertRaisesRegex(ValueError, 'Windows CompanyName'):
            identity.verify(self.root)

    def test_dart_identity_cannot_disagree_with_platform_installation(self):
        self.change('lib/utils/app_branding.dart', APP_ID, OTHER_ID)
        with self.assertRaisesRegex(ValueError, 'Dart application ID'):
            identity.verify(self.root)


if __name__ == '__main__':
    unittest.main()
