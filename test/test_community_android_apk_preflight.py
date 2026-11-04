import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location(
    "community_apk_preflight", ROOT / "tool" / "verify_community_android_apk.py")
preflight = importlib.util.module_from_spec(spec)
spec.loader.exec_module(preflight)


class CommunityApkPreflightTest(unittest.TestCase):
    def test_accepts_only_the_compiled_community_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            apk = Path(directory) / "community.apk"
            apk.write_bytes(b"identity-fixture")
            called = []

            def output(application_id):
                def run(command, **kwargs):
                    called.append(command)
                    return subprocess.CompletedProcess(command, 0,
                        stdout=f"package: name='{application_id}' versionCode='1'\n")
                return run

            self.assertEqual(preflight.verify_apk(apk, Path("aapt2"),
                run=output(preflight.COMMUNITY_APPLICATION_ID)), preflight.COMMUNITY_APPLICATION_ID)
            for application_id in ["com.example.video_player_app", "example.other", ""]:
                with self.assertRaises(ValueError):
                    preflight.verify_apk(apk, Path("aapt2"), run=output(application_id))
            self.assertTrue(all(command[1:3] == ["dump", "badging"] for command in called))

    def test_missing_or_unreported_apk_identity_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            apk = Path(directory) / "community.apk"
            with self.assertRaises(ValueError):
                preflight.verify_apk(apk, Path("aapt2"))
            apk.write_bytes(b"identity-fixture")
            with self.assertRaises(ValueError):
                preflight.verify_apk(apk, Path("aapt2"), run=lambda *a, **k:
                    subprocess.CompletedProcess([], 0, stdout="unexpected aapt output"))


if __name__ == "__main__":
    unittest.main()
