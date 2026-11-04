"""Exercise packaging rejection paths using inert PE headers, not executable code."""
import json
from pathlib import Path
import struct
import tempfile
import unittest

from verify_asr_artifact import ROOT, SOURCES, sha, verify


class ArtifactValidationTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='asr-package-')
        self.directory = Path(self.temporary.name)
        header = bytearray(256)
        header[:2] = b'MZ'
        struct.pack_into('<I', header, 60, 128)
        header[128:132] = b'PE\0\0'
        struct.pack_into('<H', header, 132, 0x8664)
        (self.directory / 'asr_worker.exe').write_bytes(header)
        (self.directory / 'onnxruntime.dll').write_bytes(header)
        self.manifest = dict(sherpa='1.12.12', platform='windows', arch='x64',
            sourceHashes={name: sha(ROOT / name) for name in SOURCES},
            files={file.name: sha(file) for file in self.directory.iterdir()})
        self.save()

    def tearDown(self):
        self.temporary.cleanup()

    def save(self):
        (self.directory / 'manifest.json').write_text(json.dumps(self.manifest), encoding='utf-8')

    def test_matching_architecture_and_files(self):
        self.assertEqual(verify(self.directory, 'windows', 'x64')['sherpa'], '1.12.12')

    def test_tampered_runtime_is_rejected_even_with_unchanged_helper(self):
        (self.directory / 'onnxruntime.dll').write_bytes(b'changed runtime')
        with self.assertRaisesRegex(RuntimeError, 'Invalid native ASR file'):
            verify(self.directory)

    def test_foreign_machine_is_rejected_even_with_matching_hash(self):
        file = self.directory / 'asr_worker.exe'
        header = bytearray(file.read_bytes())
        struct.pack_into('<H', header, 132, 0xaa64)
        file.write_bytes(header)
        self.manifest['files'][file.name] = sha(file)
        self.save()
        with self.assertRaisesRegex(RuntimeError, 'Wrong PE architecture'):
            verify(self.directory)

    def test_source_change_invalidates_staging(self):
        self.manifest['sourceHashes'][SOURCES[0]] = '0' * 64
        self.save()
        with self.assertRaisesRegex(RuntimeError, 'Native sources changed'):
            verify(self.directory)

    def test_new_architecture_header_invalidates_staging(self):
        self.manifest['sourceHashes']['native/asr/firered_ctc.h'] = '0' * 64
        self.save()
        with self.assertRaisesRegex(RuntimeError, 'Native sources changed'):
            verify(self.directory)

    def test_manifest_cannot_reference_files_outside_component(self):
        self.manifest['files']['../outside.dll'] = '0' * 64
        self.save()
        with self.assertRaisesRegex(RuntimeError, 'Invalid native ASR file'):
            verify(self.directory)


if __name__ == '__main__': unittest.main()
