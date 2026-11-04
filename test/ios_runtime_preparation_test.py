"""Offline regressions for repeated CocoaPods runtime preparation; no app build."""
import importlib.util
import io
import os
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    'prepare_ios_runtime', Path(__file__).resolve().parents[1] / 'tool/prepare_ios_runtime.py')
prepare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prepare)


class PythonFrameworkPreparationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.vendor = self.root / 'Vendor'
        vendor_patch = patch.object(prepare, 'VENDOR', self.vendor)
        vendor_patch.start()
        self.addCleanup(vendor_patch.stop)

    def archive(self, name='python.tar.gz', *, extra=None, metadata=True):
        archive = self.root / name
        with tarfile.open(archive, 'w:gz') as sink:
            files = {
                'Python.xcframework/ios-arm64/Python.framework/Python': b'framework binary',
                'Python.xcframework/lib/python3.13/LICENSE.txt': b'license',
                'testbed/unused.txt': b'not shipped',
            }
            if metadata:
                files['Python.xcframework/Info.plist'] = b'framework metadata'
            if extra:
                files.update(extra)
            for name, content in files.items():
                member = tarfile.TarInfo(name)
                member.size = len(content)
                member.mode = 0o755
                sink.addfile(member, io.BytesIO(content))
            link = tarfile.TarInfo('Python.xcframework/ios-arm64/lib/libpython3.13.dylib')
            link.type = tarfile.SYMTYPE
            link.linkname = '../Python.framework/Python'
            sink.addfile(link)
        return archive

    def test_repeated_preparation_replaces_framework_and_removes_stale_files(self):
        archive = self.archive()
        prepare.prepare_python(archive)
        framework = self.vendor / 'Python.xcframework'
        (framework / 'stale-file').write_bytes(b'old runtime')
        # Equivalent to another pod install after Flutter's automatic install.
        prepare.prepare_python(archive)
        self.assertFalse((framework / 'stale-file').exists())
        self.assertFalse((self.vendor / 'testbed').exists())
        self.assertEqual(list(self.vendor.glob('python-support-*')), [])
        binary = framework / 'ios-arm64/Python.framework/Python'
        link = framework / 'ios-arm64/lib/libpython3.13.dylib'
        self.assertEqual(link.read_bytes(), binary.read_bytes())
        if os.name != 'nt':
            self.assertTrue(link.is_symlink())
            self.assertEqual(os.readlink(link), '../Python.framework/Python')
            self.assertEqual(binary.stat().st_mode & 0o777, 0o755)

    def test_failed_extraction_keeps_previous_framework(self):
        prepare.prepare_python(self.archive())
        framework = self.vendor / 'Python.xcframework'
        (framework / 'previous').write_text('kept')
        with self.assertRaisesRegex(ValueError, 'missing Python.xcframework'):
            prepare.prepare_python(self.archive('incomplete.tar.gz', metadata=False))
        self.assertEqual((framework / 'previous').read_text(), 'kept')
        self.assertEqual(list(self.vendor.glob('python-support-*')), [])

    def test_rejects_archive_traversal_without_replacing_previous_framework(self):
        prepare.prepare_python(self.archive())
        archive = self.archive('unsafe.tar.gz', extra={
            'Python.xcframework/../../escape': b'outside staging',
        })
        with self.assertRaisesRegex(ValueError, 'outside vendor directory'):
            prepare.prepare_python(archive)
        self.assertTrue((self.vendor / 'Python.xcframework/Info.plist').is_file())
        self.assertFalse((self.vendor / 'escape').exists())


if __name__ == '__main__':
    unittest.main()
