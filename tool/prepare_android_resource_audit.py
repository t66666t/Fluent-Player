"""Prepare a private source snapshot; never edits the application's sources/data.

The explicit before manifest is the sole source of the reverted production files.
Counters, package identity, fixtures, and diagnostic bridge exist only in copies.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import shutil
from urllib.parse import unquote, urljoin, urlparse

ROOT = Path(__file__).resolve().parents[1]
AUDIT = ROOT / "build/android-resource-audit-20261101"
PACKAGE = "com.example.video_player_app.android_resource_audit"
JAVA_PATH = Path("third_party/media_kit_video/android/src/main/java/com/alexmercerind/media_kit_video")


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("arm", choices=("before", "after"))
    args = parser.parse_args()
    target = AUDIT / (args.arm + "-source")
    if target.exists():
        raise SystemExit(f"Refusing to overwrite snapshot: {target}")
    target.mkdir(parents=True)
    base = AUDIT / "before-source" if args.arm == "after" else ROOT
    ignore = shutil.ignore_patterns(".gradle", "build", ".git", "__pycache__", "key.properties", "*.jks", "*.keystore")
    for directory in ("lib", "android", "assets", "third_party", "tool", "scripts", "native", "packages"):
        shutil.copytree(base / directory, target / directory, ignore=ignore)
    for name in ("pubspec.yaml", "pubspec.lock", "analysis_options.yaml", "NOTICE", "THIRD_PARTY_NOTICES.md", "PRIVACY.md", ".metadata"):
        if (base / name).exists():
            shutil.copy2(base / name, target / name)
    baseline = json.loads((AUDIT / "before-manifest.json").read_text(encoding="utf-8-sig"))
    if args.arm == "before":
        for relative, sha in baseline.items():
            if relative.startswith("test/"):
                continue
            source = AUDIT / "before" / relative
            if digest(source) != sha:
                raise SystemExit(f"Baseline hash mismatch: {relative}")
            shutil.copy2(source, target / relative)
    else:
        # Same frozen unrelated inputs, only approved five files and new helper.
        for relative in baseline:
            if not relative.startswith("test/"):
                shutil.copy2(ROOT / relative, target / relative)
        helper_dir = Path("android/app/src/main/kotlin/com/example/video_player_app")
        for helper in (ROOT / helper_dir).glob("*Timeout*.kt"):
            shutil.copy2(helper, target / helper_dir / helper.name)
    production = {p: digest(target / p) for p in baseline if not p.startswith("test/")}
    helper_relative = "android/app/src/main/kotlin/com/example/video_player_app/RequestTimeouts.kt"
    if (target / helper_relative).exists():
        production[helper_relative] = digest(target / helper_relative)
    # Rebase only repository-local package roots. External pub-cache roots stay fixed.
    config = json.loads((base / ".dart_tool/package_config.json").read_text(encoding="utf-8"))
    for package in config["packages"]:
        uri = urljoin((base / ".dart_tool/package_config.json").as_uri(), package["rootUri"])
        source_path = Path(unquote(urlparse(uri).path).lstrip("/"))
        try:
            relative = source_path.relative_to(base)
        except ValueError:
            package["rootUri"] = uri
        else:
            package["rootUri"] = (target / relative).as_uri()
    (target / ".dart_tool").mkdir()
    (target / ".dart_tool/package_config.json").write_text(json.dumps(config, indent=2), encoding="utf-8")
    shutil.copy2(base / ".dart_tool/package_graph.json", target / ".dart_tool/package_graph.json")
    plugins = json.loads((base / ".flutter-plugins-dependencies").read_text(encoding="utf-8"))
    for entries in plugins["plugins"].values():
        for plugin in entries:
            source_path = Path(plugin["path"])
            try:
                relative = source_path.relative_to(base)
            except ValueError:
                pass
            else:
                plugin["path"] = str(target / relative) + "/"
    (target / ".flutter-plugins-dependencies").write_text(json.dumps(plugins), encoding="utf-8")
    gradle = target / "android/app/build.gradle.kts"
    text = gradle.read_text(encoding="utf-8")
    assert text.count('applicationId = "com.example.video_player_app"') == (1 if args.arm == "before" else 0)
    text = text.replace('applicationId = "com.example.video_player_app"', f'applicationId = "{PACKAGE}"')
    gradle.write_text(text, encoding="utf-8")
    properties = target / "android/gradle.properties"
    if args.arm == "before":
        with properties.open("a", encoding="utf-8") as stream:
            stream.write("\n# Explicit private diagnostic release only.\nfluentDevelopmentSigning=true\n")
    fixture_dir = target / "assets/resource-audit"
    fixture_dir.mkdir(exist_ok=True)
    shutil.copy2(AUDIT / "fixtures/fixture.mp4", fixture_dir / "fixture.mp4")
    pubspec = target / "pubspec.yaml"
    text = pubspec.read_text(encoding="utf-8")
    if args.arm == "before":
        text = text.replace("  assets:\n", "  assets:\n    - assets/resource-audit/fixture.mp4\n", 1)
    pubspec.write_text(text, encoding="utf-8")
    kt_dir = target / "android/app/src/main/kotlin/com/example/video_player_app"
    if args.arm == "before":
        for name in ("ResourceAuditBridge.kt", "ResourceAuditCounters.kt"):
            shutil.copy2(ROOT / "tool/android_resource_audit" / name, kt_dir / name)
    activity = kt_dir / "MainActivity.kt"
    text = activity.read_text(encoding="utf-8")
    needle = "val qwenAsrBridge = QwenAsrBridge(applicationContext, flutterEngine.dartExecutor.binaryMessenger)"
    assert text.count(needle) == 1
    if args.arm == "before":
        text = text.replace(needle, needle + "\n        ResourceAuditBridge(this, flutterEngine, asrAccelerationBridge, qwenAsrBridge)")
    activity.write_text(text, encoding="utf-8")
    # Track actual scheduled and removed Runnables in both arms. Counters do not
    # shorten deadlines or alter callback bodies. Helper is present only after.
    for name in ("AsrAccelerationBridge.kt", "QwenAsrBridge.kt", *[p.name for p in kt_dir.glob("*Timeout*.kt")]):
        file = kt_dir / name
        if not file.exists():
            continue
        text = file.read_text(encoding="utf-8")
        text = text.replace("handler.postDelayed(", 'ResourceAuditCounters.postDelayed(handler, "' + name + '", ')
        text = text.replace("handler.removeCallbacks(", "ResourceAuditCounters.removeCallbacks(handler, ")
        file.write_text(text, encoding="utf-8")
    video = target / JAVA_PATH / "VideoOutput.java"
    text = video.read_text(encoding="utf-8")
    needle = 'private static final String TAG = "VideoOutput";'
    assert needle in text
    text = text.replace(needle, needle + "\n    private static final java.util.concurrent.atomic.AtomicLong auditCreated = new java.util.concurrent.atomic.AtomicLong();\n    private static final java.util.concurrent.atomic.AtomicLong auditDeleted = new java.util.concurrent.atomic.AtomicLong();\n    public static java.util.Map<String, Long> auditStats() {\n      java.util.Map<String, Long> result = new java.util.HashMap<>();\n      result.put(\"created\", auditCreated.get()); result.put(\"deleted\", auditDeleted.get());\n      result.put(\"outstanding\", auditCreated.get() - auditDeleted.get()); return result;\n    }")
    needle = "return (long) Objects.requireNonNull(newGlobalObjectRef.invoke(null, object));"
    assert text.count(needle) == 1
    text = text.replace(needle, "long auditRef = (long) Objects.requireNonNull(newGlobalObjectRef.invoke(null, object));\n            if (auditRef != 0) auditCreated.incrementAndGet();\n            return auditRef;")
    needle = "deleteGlobalObjectRef.invoke(null, ref);"
    assert text.count(needle) == 1
    text = text.replace(needle, needle + "\n            auditDeleted.incrementAndGet();")
    video.write_text(text, encoding="utf-8")
    instrumented = {p: digest(target / p) for p in production}
    manifest = {"arm": args.arm, "package": PACKAGE, "productionBeforeInstrumentation": production,
                "instrumented": instrumented, "baseline": baseline,
                "probeSha256": digest(target / "scripts/android_resource_audit_probe.dart"),
                "note": "Snapshot-only counters preserve deadlines/ownership; no production identity or settings."}
    (AUDIT / (args.arm + "-snapshot-manifest.json")).write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    print(target)


if __name__ == "__main__":
    main()
