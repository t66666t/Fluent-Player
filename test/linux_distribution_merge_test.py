"""Require every tested distro and unchanged bytes before assembling artifacts."""
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tool'))
import merge_linux_packages as packages


class LinuxDistributionMergeTests(unittest.TestCase):
    def fixtures(self, root):
        for distro in packages.DISTRIBUTIONS:
            directory = root / distro
            directory.mkdir()
            files = []
            for suffix in ('.deb', '.tar.gz'):
                path = directory / (packages.prefix('linux', 'x64') + '-' + distro + suffix)
                path.write_bytes(b'tiny checksum fixture, not an installer')
                files.append({'name': path.name, 'size': path.stat().st_size, 'sha256': packages.sha(path)})
            (directory / 'linux-manifest.json').write_text(json.dumps({
                'schema': 1, **packages.read_version(), 'commit': 'a' * 40, 'platform': 'linux',
                'architecture': 'x64', 'signing': 'not signed; ' + distro, 'files': files,
            }))

    def test_all_four_matching_builds_produce_a_single_manifest(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / 'input'
            source.mkdir()
            self.fixtures(source)
            with patch.object(packages.subprocess, 'check_output', return_value='a' * 40):
                packages.merge(source, root / 'output')
            result = json.loads((root / 'output/linux-manifest.json').read_text())
            self.assertEqual(len(result['files']), 8)
            self.assertEqual(result['commit'], 'a' * 40)

    def test_missing_distribution_does_not_create_a_partial_output(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / 'input'
            source.mkdir()
            self.fixtures(source)
            (source / 'debian-13/linux-manifest.json').unlink()
            with patch.object(packages.subprocess, 'check_output', return_value='a' * 40):
                with self.assertRaisesRegex(ValueError, 'Missing native'):
                    packages.merge(source, root / 'output')
            self.assertFalse((root / 'output').exists())

    def test_modified_package_is_rejected_before_output_is_created(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / 'input'
            source.mkdir()
            self.fixtures(source)
            next((source / 'debian-13').glob('*.deb')).write_bytes(b'changed fixture')
            with patch.object(packages.subprocess, 'check_output', return_value='a' * 40):
                with self.assertRaisesRegex(ValueError, 'checksum mismatch'):
                    packages.merge(source, root / 'output')
            self.assertFalse((root / 'output').exists())


if __name__ == '__main__':
    unittest.main()
