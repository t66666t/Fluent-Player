"""Tiny runtime fixtures; no real builds, installer execution or device changes."""
from contextlib import redirect_stdout
import io
from pathlib import Path
import struct
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tool"))
from package_windows_release import NOTICES, REQUIRED, RUNNER, pe_dependencies, stage_runtime
import package_windows_release as packager


class CommunityWindowsPackageTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="community package ")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = self.root / "build files"
        self.source.mkdir()
        self.stage = self.root / "stage files"
        self.manifest = self.root / "install manifest.txt"
        self.runtime = self.root / "runtime files.txt"
        self.installed = []
        for name in sorted((REQUIRED | NOTICES) - {RUNNER}):
            self.add(name)
        (self.source / RUNNER).write_bytes(b"fixture native image")
        self.runtime.write_text(str(self.source / RUNNER) + "\n", encoding="utf-8")

    def add(self, name, content=b"runtime fixture"):
        path = self.source / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content)
        self.installed.append(path)
        self.manifest.write_text("\n".join(map(str, self.installed)) + "\n", encoding="utf-8")
        return path

    def stage_files(self, **kwargs):
        return stage_runtime(self.source, self.manifest, self.runtime, self.stage,
                             dependency_reader=kwargs.pop("dependency_reader", lambda path: ()),
                             system_directories=[], **kwargs)

    def test_spaces_declared_runtime_and_unlisted_user_files(self):
        user = self.source / "CommunityPlayerData/library.json"
        user.parent.mkdir()
        user.write_bytes(b"private library fixture")
        (self.source / "unlisted.dll").write_bytes(b"unlisted fixture")
        self.add("debug symbols.pdb")
        self.add("native_assets.json", b"{}")
        self.add("data/flutter_assets/assets/licenses/yt-dlp-ThirdPartyNotices.txt", b"retained notice fixture")
        result = self.stage_files()
        self.assertTrue((self.stage / RUNNER).is_file())
        self.assertEqual(result["files"], len(REQUIRED | NOTICES) + 2)
        self.assertTrue((self.stage / "native_assets.json").is_file())
        self.assertFalse((self.stage / "debug symbols.pdb").exists())
        self.assertFalse((self.stage / "unlisted.dll").exists())
        self.assertFalse((self.stage / "CommunityPlayerData").exists())
        self.assertEqual(user.read_bytes(), b"private library fixture")

    def test_existing_or_overlapping_destination_is_refused(self):
        for destination in (self.source, self.source / "stage", self.root):
            with self.subTest(destination=destination):
                with self.assertRaisesRegex(ValueError, "destination"):
                    stage_runtime(self.source, self.manifest, self.runtime, destination,
                                  dependency_reader=lambda path: ())
        self.stage.mkdir()
        with self.assertRaisesRegex(ValueError, "destination"):
            self.stage_files()

    def test_manifest_cannot_adopt_another_directory(self):
        outside = self.root / "unrelated.dll"
        outside.write_bytes(b"private fixture")
        with self.manifest.open("a", encoding="utf-8") as stream:
            stream.write(str(outside) + "\n")
        with self.assertRaisesRegex(ValueError, "escapes"):
            self.stage_files()
        self.assertFalse(self.stage.exists())

    def test_missing_file_and_missing_crt_fail_before_copying(self):
        (self.source / "vcruntime140_1.dll").unlink()
        with self.assertRaises(FileNotFoundError):
            self.stage_files()
        self.assertFalse(self.stage.exists())

    def test_unlisted_dependency_is_rejected_even_if_present(self):
        (self.source / "missing-from-manifest.dll").write_bytes(b"fixture")
        with self.assertRaisesRegex(ValueError, "Missing or unlisted native dependency"):
            self.stage_files(dependency_reader=lambda path: ["missing-from-manifest.dll"] if path.name == RUNNER else [])
        self.assertFalse(self.stage.exists())

    def test_declared_local_dependency_matches_windows_case_rules(self):
        self.add("MixedCase.dll")
        result = self.stage_files(dependency_reader=lambda path: ["mixedcase.dll"] if path.name == RUNNER else [])
        self.assertTrue((self.stage / "MixedCase.dll").is_file())
        self.assertEqual(result["files"], len(REQUIRED | NOTICES) + 1)

    def test_developer_installed_debug_crt_cannot_satisfy_a_release(self):
        system = self.root / "developer System32"
        system.mkdir()
        (system / "vcruntime140d.dll").write_bytes(b"debug CRT fixture")
        with self.assertRaisesRegex(ValueError, "Developer-only debug dependency"):
            stage_runtime(self.source, self.manifest, self.runtime, self.stage,
                dependency_reader=lambda path: ["vcruntime140d.dll"] if path.name == RUNNER else [],
                system_directories=[system])
        self.assertFalse(self.stage.exists())

    def test_child_native_module_requires_its_own_local_crt(self):
        self.add("resources/asr/model_runtime.dll")
        with self.assertRaisesRegex(ValueError, "Missing app-local VC runtime"):
            self.stage_files(dependency_reader=lambda path: ["msvcp140.dll"] if path.name == "model_runtime.dll" else [])
        self.assertFalse(self.stage.exists())
        self.add("resources/asr/msvcp140.dll")
        self.stage_files(dependency_reader=lambda path: ["msvcp140.dll"] if path.name == "model_runtime.dll" else [])
        self.assertTrue((self.stage / "resources/asr/msvcp140.dll").is_file())

    def test_listed_user_data_and_retired_runtimes_fail_closed(self):
        for name in ("CommunityPlayerData/library.json", "data/flutter_assets/library.json",
                     "WebView2Loader.dll", "resources/yt_dlp/python313.dll"):
            with self.subTest(name=name):
                original = list(self.installed)
                self.add(name)
                with self.assertRaises(ValueError):
                    self.stage_files()
                self.assertFalse(self.stage.exists())
                self.installed = original
                self.manifest.write_text("\n".join(map(str, original)) + "\n", encoding="utf-8")

    def test_required_runtime_must_be_declared(self):
        self.runtime.write_text("", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "Required runtime absent"):
            self.stage_files()

    def test_pe_reader_checks_normal_and_delay_imports(self):
        image = bytearray(1024)
        image[:2] = b"MZ"
        struct.pack_into("<I", image, 0x3c, 0x80)
        image[0x80:0x84] = b"PE\0\0"
        struct.pack_into("<H", image, 0x94, 240)
        optional = 0x98
        struct.pack_into("<H", image, optional, 0x20b)
        struct.pack_into("<Q", image, optional + 24, 0x140000000)
        struct.pack_into("<I", image, optional + 60, 1024)
        struct.pack_into("<I", image, optional + 108, 16)
        struct.pack_into("<II", image, optional + 112 + 8, 0x200, 40)
        struct.pack_into("<I", image, 0x200 + 12, 0x300)
        image[0x300:0x30d] = b"KERNEL32.dll\0"
        struct.pack_into("<II", image, optional + 112 + 13 * 8, 0x240, 64)
        struct.pack_into("<II", image, 0x240, 1, 0x330)
        image[0x330:0x33d] = b"DELAYED1.dll\0"
        native = self.root / "fixture PE.dll"
        native.write_bytes(image)
        self.assertEqual(pe_dependencies(native), {"kernel32.dll", "delayed1.dll"})

    def test_malformed_native_binary_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "Not a Windows PE image"):
            pe_dependencies(self.source / RUNNER)

    def test_stage_only_collects_without_installer_or_release_outputs(self):
        output = self.root / "release outputs"
        arguments = ["package_windows_release.py", "--stage-only", "--source", str(self.source),
            "--manifest", str(self.manifest), "--runtime-manifest", str(self.runtime),
            "--stage", str(self.stage), "--output", str(output),
            "--iscc", str(self.root / "not installed/ISCC.exe")]
        def stage_fixture(*args):
            return stage_runtime(*args, dependency_reader=lambda path: (), system_directories=[])
        version = {"version": "1.0.0", "buildNumber": 2}
        with patch.object(sys, "argv", arguments), patch.object(packager, "read_version", return_value=version), \
                patch.object(packager, "verify_identity") as identity, \
                patch.object(packager, "stage_runtime", side_effect=stage_fixture), \
                patch.object(packager, "package") as formal_package, redirect_stdout(io.StringIO()):
            packager.main()
        identity.assert_called_once_with(self.source / RUNNER, version)
        formal_package.assert_not_called()
        self.assertTrue((self.stage / RUNNER).is_file())
        self.assertFalse(output.exists())
        self.assertFalse(any(self.stage.rglob("*.zip")))
        self.assertFalse(any(self.stage.rglob("*-manifest.json")))

    def test_stage_only_rejects_wrong_metadata_before_copying(self):
        with patch.object(packager, "verify_identity", side_effect=ValueError("wrong edition identity")):
            with self.assertRaisesRegex(ValueError, "wrong edition"):
                packager.stage_only(self.source, self.manifest, self.runtime, self.stage)
        self.assertFalse(self.stage.exists())

    def test_stage_only_keeps_real_pe_import_validation(self):
        with patch.object(packager, "verify_identity"):
            with self.assertRaisesRegex(ValueError, "Not a Windows PE image"):
                packager.stage_only(self.source, self.manifest, self.runtime, self.stage)
        self.assertFalse(self.stage.exists())


if __name__ == "__main__":
    unittest.main()
