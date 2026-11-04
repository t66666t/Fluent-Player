"""Reject the identity/version mistakes which prevent in-place APK updates."""
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tool'))
from build_android_upgrade import LEGACY_PACKAGE, validate_upgrade


class AndroidUpgradeTest(unittest.TestCase):
    def setUp(self):
        self.previous = dict(package=LEGACY_PACKAGE, versionCode=2,
                             certificates=['legacy-certificate'], debuggable=True)
        self.candidate = dict(self.previous, versionCode=3, debuggable=False)

    def test_profile_to_release_keeps_identity(self):
        validate_upgrade(self.previous, self.candidate)

    def test_production_package_cannot_replace_profile(self):
        self.candidate['package'] = 'com.example.video_player_app'
        with self.assertRaisesRegex(ValueError, 'Package name'):
            validate_upgrade(self.previous, self.candidate)

    def test_production_certificate_cannot_replace_profile(self):
        self.candidate['certificates'] = ['production-certificate']
        with self.assertRaisesRegex(ValueError, 'Signing certificate'):
            validate_upgrade(self.previous, self.candidate)

    def test_build_number_must_increase(self):
        for number in (1, 2):
            with self.subTest(number=number):
                self.candidate['versionCode'] = number
                with self.assertRaisesRegex(ValueError, 'build number'):
                    validate_upgrade(self.previous, self.candidate)

    def test_debuggable_candidate_is_rejected(self):
        self.candidate['debuggable'] = True
        with self.assertRaisesRegex(ValueError, 'non-debuggable'):
            validate_upgrade(self.previous, self.candidate)


if __name__ == '__main__':
    unittest.main()
