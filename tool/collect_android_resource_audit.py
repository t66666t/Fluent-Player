"""Seal final diagnostic APK/source provenance without reading application data."""
from __future__ import annotations

import hashlib
import argparse
import json
from pathlib import Path
import struct
import zipfile

ROOT = Path(__file__).resolve().parents[1]
AUDIT = ROOT / "build/android-resource-audit-20261101"


def sha(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def elf_sections(contents: bytes) -> dict:
    offset = struct.unpack_from('<Q', contents, 40)[0]
    size, count, names_index = struct.unpack_from('<HHH', contents, 58)
    rows = [struct.unpack_from('<IIQQQQIIQQ', contents, offset + i * size) for i in range(count)]
    string_header = rows[names_index]
    names = contents[string_header[4]:string_header[4] + string_header[5]]
    return {names[row[0]:].split(b'\0', 1)[0].decode(): {
        'sha256': hashlib.sha256(contents[row[4]:row[4] + row[5]]).hexdigest(),
        'bytes': row[5], 'flags': row[2]} for row in rows}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--variant', choices=('v2', 'high-refresh-v2'), required=True)
    args = parser.parse_args()
    report = {"variant": args.variant, "package": "com.example.video_player_app.android_resource_audit",
              "deviceSerial": "983d4e11", "arms": {}, "historicalLogsRetained": True,
              "diagnosticOnly": "Same counters/deadlines and synthetic 60s/720p/60fps/no-audio fixture in both snapshots. No production identity, preferences, models or limits changed.",
              "compatibilityFixtureSha256": sha(ROOT / "test/fixtures/local_model_compatibility.json"),
              "limitations": ["USB-powered measurements are work/RAM counters, not energy or battery-life measurements.",
                              "Android compositor FrameTiming differs from requested Dart frames.",
                              "Diagnostic PSS/CPU sampling and JNI counters add equal observer overhead to both arms.",
                              "Initial short-clip EOF behavior, ICC classifier failure and installation rejections are retained separately."]}
    for arm in ("before", "after"):
        source = AUDIT / 'v2-frozen' / arm if args.variant == 'v2' else AUDIT / (arm + '-source')
        apk = AUDIT / 'v2-frozen' / (arm + '-release.apk') if args.variant == 'v2' else AUDIT / ('high-v2-' + arm + '-release.apk')
        manifest = json.loads((AUDIT / (arm + "-snapshot-manifest.json")).read_text(encoding="utf-8"))
        libraries = {}
        with zipfile.ZipFile(apk) as archive:
            dart_jni_sections = elf_sections(archive.read('lib/arm64-v8a/libdartjni.so'))
            for name in sorted(archive.namelist()):
                if name.startswith("lib/arm64-v8a/") and name.endswith(".so"):
                    digest = hashlib.sha256()
                    with archive.open(name) as stream:
                        for block in iter(lambda: stream.read(1024 * 1024), b""):
                            digest.update(block)
                    libraries[name] = digest.hexdigest()
        report["arms"][arm] = {
            "apkPath": str(apk), "apkBytes": apk.stat().st_size, "apkSha256": sha(apk),
            "diagnosticSourceRoot": str(source),
            "productionBeforeInstrumentation": manifest["productionBeforeInstrumentation"],
            "instrumentedProduction": manifest["instrumented"],
            "finalDiagnosticSha256": {str(relative): sha(source / relative) for relative in (
                Path("scripts/android_resource_audit_probe.dart"), Path("scripts/android_resource_compose_audit.dart"),
                Path("android/app/src/main/kotlin/com/example/video_player_app/ResourceAuditBridge.kt"),
                Path("android/app/src/main/kotlin/com/example/video_player_app/ResourceAuditCounters.kt"))},
            "fixtureSha256": sha(source / "assets/resource-audit/fixture.mp4"),
            "pubspecLockSha256": sha(source / "pubspec.lock"), "arm64Libraries": libraries,
            "dartJniElfSections": dart_jni_sections,
        }
    before = report["arms"]["before"]
    after = report["arms"]["after"]
    report["sameDiagnostics"] = before["finalDiagnosticSha256"] == after["finalDiagnosticSha256"]
    report["sameFixture"] = before["fixtureSha256"] == after["fixtureSha256"]
    report["sameLock"] = before["pubspecLockSha256"] == after["pubspecLockSha256"] == sha(ROOT / "pubspec.lock")
    report["changedRuntimeLibraries"] = [name for name in before["arm64Libraries"]
        if name != "lib/arm64-v8a/libapp.so" and before["arm64Libraries"][name] != after["arm64Libraries"].get(name)]
    report["runtimeLibraryNamesSame"] = before["arm64Libraries"].keys() == after["arm64Libraries"].keys()
    report["dartJniDifferingSections"] = [name for name in before["dartJniElfSections"]
        if before["dartJniElfSections"][name] != after["dartJniElfSections"].get(name)]
    report["runtimeDifferenceIsBuildIdOnly"] = (
        report["changedRuntimeLibraries"] == ["lib/arm64-v8a/libdartjni.so"] and
        report["dartJniDifferingSections"] == ['.note.gnu.build-id'])
    destination = AUDIT / (args.variant + '-artifact-manifest.json')
    destination.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    if not (report["sameDiagnostics"] and report["sameFixture"] and report["sameLock"] and
            (not report["changedRuntimeLibraries"] or report["runtimeDifferenceIsBuildIdOnly"]) and report["runtimeLibraryNamesSame"]):
        raise SystemExit("Artifact symmetry mismatch: " + str(destination))
    print(destination)


if __name__ == "__main__":
    main()
