"""Compatibility checks for selective secure-prefs Android backup rules.

Only temporary XML mutation fixtures are written. No Android device, transport,
account, application preferences, Gradle, or Flutter process is used.
"""

from __future__ import annotations

from copy import deepcopy
from pathlib import Path
import tempfile
import unittest
import xml.etree.ElementTree as ET

from verify_android_secure_storage_backup import (
    ANDROID, PREFS, ROOT, check_application, check_rules, check_source,
    parse_resources, parse_xmltree,
)


class BackupRulesTest(unittest.TestCase):
    def setUp(self):
        self.legacy = ET.parse(ROOT / "android/app/src/main/res/xml/backup_rules.xml").getroot()
        self.modern = ET.parse(ROOT / "android/app/src/main/res/xml/data_extraction_rules.xml").getroot()

    def test_actual_source_covers_legacy_and_both_modern_transports(self):
        result = check_source(ROOT)
        self.assertGreaterEqual(len(result["sourceSha256"]), 3)

    def test_each_supported_api_and_transport_excludes_only_two_secure_prefs(self):
        # API >=31 ignores fullBackupContent in favor of dataExtractionRules.
        for api in (24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36):
            for transport in ("cloud-backup", "device-transfer"):
                with self.subTest(api=api, transport=transport):
                    node = self.legacy if api <= 30 else self.modern.find(transport)
                    exclusions = {(item.get("domain"), item.get("path")) for item in node}
                    self.assertEqual(exclusions, {("sharedpref", name) for name in PREFS})
                    # Keep normal preferences and app data under the previous
                    # Android defaults; an <include> would silently narrow them.
                    for domain, path in (
                        ("sharedpref", "FlutterSharedPreferences.xml"),
                        ("sharedpref", "settings.xml"),
                        ("database", "library.db"),
                        ("file", "models/model.onnx"),
                        ("file", "queue/tasks.json"),
                        ("file", "checkpoints/task.json"),
                        ("root", "app_flutter/library.json"),
                        ("external", "library/video.mp4"),
                    ):
                        self.assertNotIn((domain, path), exclusions)

    def test_missing_legacy_wrapped_key_exclusion_is_rejected(self):
        self.legacy.remove(self.legacy[1])
        with self.assertRaisesRegex(ValueError, "expected only"):
            check_rules(self.legacy, "backup_rules")

    def test_each_modern_transport_requires_both_files(self):
        for index in range(2):
            node = deepcopy(self.modern)
            node[index].remove(node[index][1])
            with self.subTest(transport=node[index].tag), self.assertRaisesRegex(ValueError, "expected only"):
                check_rules(node, "data_extraction_rules")

    def test_device_transfer_section_cannot_be_omitted(self):
        self.modern.remove(self.modern[1])
        with self.assertRaisesRegex(ValueError, "both cloud-backup and device-transfer"):
            check_rules(self.modern, "data_extraction_rules")

    def test_an_include_would_narrow_other_data_backup(self):
        ET.SubElement(self.legacy, "include", domain="file", path="library")
        with self.assertRaisesRegex(ValueError, "only selective exclusions"):
            check_rules(self.legacy, "backup_rules")

    def test_extra_settings_or_all_prefs_exclusions_are_rejected(self):
        for path in ("settings.xml", "."):
            node = deepcopy(self.legacy)
            ET.SubElement(node, "exclude", domain="sharedpref", path=path)
            with self.subTest(path=path), self.assertRaisesRegex(ValueError, "expected only"):
                check_rules(node, "backup_rules")

    def test_global_cloud_backup_restriction_is_rejected(self):
        self.modern[0].set("disableIfNoEncryptionCapabilities", "true")
        with self.assertRaisesRegex(ValueError, "backup-wide attributes"):
            check_rules(self.modern, "data_extraction_rules")

    def test_disabling_whole_app_backup_is_rejected(self):
        application = ET.Element("application", {ANDROID + "allowBackup": "false"})
        with self.assertRaisesRegex(ValueError, "do not disable"):
            check_application(application, {})

    def test_qualified_resource_cannot_weaken_the_default_rules(self):
        with tempfile.TemporaryDirectory(prefix="secure-backup-rules-") as temporary:
            root = Path(temporary)
            main = root / "android/app/src/main"
            (main / "res/xml").mkdir(parents=True)
            (main / "AndroidManifest.xml").write_bytes((ROOT / "android/app/src/main/AndroidManifest.xml").read_bytes())
            for name in ("backup_rules", "data_extraction_rules"):
                (main / "res/xml" / (name + ".xml")).write_bytes(
                    (ROOT / "android/app/src/main/res/xml" / (name + ".xml")).read_bytes())
            (main / "res/xml-v31").mkdir()
            (main / "res/xml-v31/data_extraction_rules.xml").write_text(
                "<data-extraction-rules><cloud-backup/><device-transfer/></data-extraction-rules>", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "expected only"):
                check_source(root)

    def test_aapt2_tree_resolves_actual_application_refs_and_rules(self):
        manifest = parse_xmltree('''N: android=http://schemas.android.com/apk/res/android
  E: manifest (line=1)
    A: package="fixture"
    E: application (line=2)
      A: http://schemas.android.com/apk/res/android:fullBackupContent(0x010104eb)=@0x7f010000
      A: http://schemas.android.com/apk/res/android:dataExtractionRules(0x0101063e)=@0x7f010001
''')
        check_application(manifest.find("application"), {
            "fullBackupContent": "@0x7f010000", "dataExtractionRules": "@0x7f010001",
        })
        rules = parse_xmltree('''E: full-backup-content (line=1)
  E: exclude (line=2)
    A: domain="sharedpref" (Raw: "sharedpref")
    A: path="FlutterSecureStorage.xml" (Raw: "FlutterSecureStorage.xml")
  E: exclude (line=3)
    A: domain="sharedpref" (Raw: "sharedpref")
    A: path="FlutterSecureKeyStorage.xml" (Raw: "FlutterSecureKeyStorage.xml")
''')
        check_rules(rules, "backup_rules")

    def test_aapt2_resources_include_every_compiled_configuration(self):
        resources = parse_resources('''  resource 0x7f010000 xml/backup_rules
    () (file) res/xml/backup_rules.xml type=XML
    (v31) (file) res/xml-v31/backup_rules.xml type=XML
  resource 0x7f010001 xml/data_extraction_rules
    () (file) res/xml/data_extraction_rules.xml type=XML
  resource 0x7f020001 string/title
    () "Title"
''')
        self.assertEqual(resources["backup_rules"], ("0x7f010000", [
            "res/xml/backup_rules.xml", "res/xml-v31/backup_rules.xml"]))

    def test_aapt2_manifest_path_patterns_are_not_json_escapes(self):
        root = parse_xmltree(r'''E: data (line=1)
  A: android:pathPattern(0x0101002c)=".*\.fluentpack" (Raw: ".*\.fluentpack")
''')
        self.assertEqual(root.get(ANDROID + "pathPattern"), r".*\.fluentpack")


if __name__ == "__main__":
    unittest.main(verbosity=2)
