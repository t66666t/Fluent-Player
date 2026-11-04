"""Run actual OpenFilePlugin lifecycle callbacks against Flutter's JVM channel.

No device, Gradle, Flutter command, account, model, or file-opening intent runs.
The SDK Android classes supply types only; activity/context bindings are null.
The channel, codec, plugin, and its callbacks are the real implementation.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import zipfile


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--package-dir", type=Path, default=root / "third_party/open_filex")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--android-sdk", type=Path,
                        default=Path(os.environ.get("ANDROID_HOME", str(Path.home() / "AppData/Local/Android/sdk"))))
    parser.add_argument("--flutter-sdk", type=Path, default=Path("D:/FlutterSDK/flutter"))
    parser.add_argument("--java-home", type=Path, default=Path("D:/Android Studio/jbr"))
    parser.add_argument("--gradle-home", type=Path, default=Path("D:/.gradle"))
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    classes = output / "classes"
    classes.mkdir(exist_ok=True)
    android_jar = args.android_sdk / "platforms/android-36/android.jar"
    flutter_jar = args.flutter_sdk / "bin/cache/artifacts/engine/android-arm64-release/flutter.jar"
    modules = args.gradle_home / "caches/modules-2/files-2.1"
    core_aar = sorted((modules / "androidx.core/core/1.15.0").rglob("*.aar"))[0]
    annotations = sorted((modules / "androidx.annotation/annotation-jvm/1.8.2").rglob("*.jar"))[0]
    core_jar = output / "androidx-core.jar"
    with zipfile.ZipFile(core_aar) as archive:
        core_jar.write_bytes(archive.read("classes.jar"))
    classpath = os.pathsep.join(str(p) for p in [android_jar, flutter_jar, core_jar, annotations])
    source_root = args.package_dir.resolve() / "android/src/main/java"
    sources = [str(p) for p in sorted(source_root.rglob("*.java"))]
    sources.append(str(root / "tool/open_filex_lifecycle_test/OpenFileLifecycleTest.java"))
    javac = args.java_home / "bin/javac.exe"
    java = args.java_home / "bin/java.exe"
    compile_command = [str(javac), "-encoding", "UTF-8", "-cp", classpath, "-d", str(classes), *sources]
    compile_result = subprocess.run(compile_command, text=True, capture_output=True, encoding="utf-8", errors="replace")
    (output / "compile.log").write_text(compile_result.stdout + compile_result.stderr, encoding="utf-8")
    run_command = [str(java), "-cp", str(classes) + os.pathsep + classpath, "OpenFileLifecycleTest"]
    run_result = None
    if compile_result.returncode == 0:
        run_result = subprocess.run(run_command, text=True, capture_output=True, encoding="utf-8", errors="replace")
        (output / "run.log").write_text(run_result.stdout + run_result.stderr, encoding="utf-8")
        print(run_result.stdout, end="")
    else:
        print(compile_result.stderr)
    receipt = {
        "package": str(args.package_dir.resolve()),
        "compileCommand": compile_command,
        "compileExitCode": compile_result.returncode,
        "runCommand": run_command,
        "runExitCode": None if run_result is None else run_result.returncode,
        "sourceSha256": {str(p.relative_to(args.package_dir.resolve())): hashlib.sha256(p.read_bytes()).hexdigest()
                         for p in sorted(source_root.rglob("*.java"))},
        "flutterJarSha256": hashlib.sha256(flutter_jar.read_bytes()).hexdigest(),
        "scope": "real plugin/callbacks/Flutter channel+codec; fake host bindings; no Android intent/device IO",
    }
    (output / "result.json").write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
    return compile_result.returncode or (0 if run_result is None else run_result.returncode)


if __name__ == "__main__":
    raise SystemExit(main())
