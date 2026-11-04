"""Native packaging rejects partial, tampered or foreign model runtimes."""
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tool'))
import linux_llama_runtime as runtime


class LinuxLlamaRuntimeTests(unittest.TestCase):
    def prepare(self, root):
        libraries = root / 'runtime'
        libraries.mkdir()
        for name in runtime.REQUIRED:
            (libraries / name).write_bytes(b'\x7fELF\x02\x01' + bytes(12) + b'\x3e\x00' + name.encode())
        (libraries / 'licenses').mkdir()
        (libraries / 'licenses/LICENSE').write_text('fixture license')
        record = {'schema': 1, 'nativeTag': runtime.NATIVE_TAG,
                  'nativeCommit': runtime.NATIVE_COMMIT, 'llamaCommit': runtime.LLAMA_COMMIT,
                  'files': {name: runtime.digest(libraries / name) for name in runtime.REQUIRED}}
        (libraries / 'runtime.json').write_text(json.dumps(record))
        return libraries, record

    def test_tampered_runtime_fails_before_replacing_any_application_file(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            libraries, _ = self.prepare(root)
            (libraries / 'libllama.so').write_bytes(b'corrupted')
            app = root / 'app'
            app.mkdir()
            target = app / 'libllamadart.so'
            target.write_bytes(b'original application bytes')
            with self.assertRaises(ValueError):
                runtime.install(app, libraries)
            self.assertEqual(target.read_bytes(), b'original application bytes')

    def test_native_version_cannot_be_silently_upgraded(self):
        with tempfile.TemporaryDirectory() as temporary:
            libraries, record = self.prepare(Path(temporary))
            record['nativeCommit'] = 'f' * 40
            (libraries / 'runtime.json').write_text(json.dumps(record))
            with self.assertRaisesRegex(ValueError, 'existing model ABI'):
                runtime.verify(libraries)

    def test_soname_and_public_symbols_must_survive_rebuilding(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            libraries, _ = self.prepare(root)
            app = root / 'app'
            app.mkdir()
            (app / 'libllamadart.so').write_bytes(b'original')
            with patch.object(runtime, 'dynamic', side_effect=[([], 'abi.1'), ([], 'abi.2')]):
                with self.assertRaisesRegex(ValueError, 'SONAME'):
                    runtime.install(app, libraries)
            with patch.object(runtime, 'dynamic', return_value=([], 'abi.1')), \
                 patch.object(runtime, 'exports', side_effect=[{'llama_load'}, set()]):
                with self.assertRaisesRegex(ValueError, 'public ABI'):
                    runtime.install(app, libraries)
            self.assertEqual((app / 'libllamadart.so').read_bytes(), b'original')

    def test_player_and_worker_keep_their_existing_runtime_names(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            libraries, _ = self.prepare(root)
            app = root / 'app'
            for folder in ('lib', 'resources/translation'):
                target = app / folder / 'libllamadart.so'
                target.parent.mkdir(parents=True)
                target.write_bytes(b'old same-ABI library')
            with patch.object(runtime, 'dynamic', return_value=([], 'abi.1')), \
                 patch.object(runtime, 'exports', return_value={'llama_load'}):
                runtime.install(app, libraries)
            for folder in ('lib', 'resources/translation'):
                self.assertEqual((app / folder / 'libllamadart.so').read_bytes(),
                                 (libraries / 'libllamadart.so').read_bytes())
            self.assertTrue((app / 'licenses/llamadart-linux-runtime/LICENSE').exists())


if __name__ == '__main__':
    unittest.main()
