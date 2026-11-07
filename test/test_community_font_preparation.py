"""The bundled OFL fonts must not require an external build-time download."""

import importlib.util
from pathlib import Path
import sys
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    'release_assets_for_font_test', ROOT / 'tool' / 'prepare_release_assets.py'
)
release_assets = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release_assets)


class BundledFontPreparationTest(unittest.TestCase):
    def test_fonts_only_never_downloads_or_requires_a_release_lock(self):
        with mock.patch.object(release_assets, 'download', side_effect=AssertionError('unexpected download')):
            with mock.patch.object(release_assets, 'LOCK', ROOT / 'missing-lock-for-font-test.json'):
                with mock.patch.object(sys, 'argv', ['prepare_release_assets.py', '--fonts-only']):
                    release_assets.main()


if __name__ == '__main__':
    unittest.main()
