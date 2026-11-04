"""Read-only APK identity preflight. Never installs, stops or removes an app."""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import re
import subprocess

COMMUNITY_APPLICATION_ID = "com.example.video_player_app.community"


def verify_apk(apk: Path, aapt2: Path, *, run=subprocess.run) -> str:
    if not apk.is_file() or apk.suffix.lower() != ".apk":
        raise ValueError("The compiled community APK must exist before preflight")
    result = run([str(aapt2), "dump", "badging", str(apk)], check=True,
                 capture_output=True, text=True, encoding="utf-8", errors="replace")
    match = re.search(r"^package: name='([^']+)'", result.stdout, re.MULTILINE)
    if match is None:
        raise ValueError("aapt2 did not report an APK application ID")
    application_id = match[1]
    if application_id != COMMUNITY_APPLICATION_ID:
        raise ValueError("Refusing device test: APK application ID is not the community ID")
    return application_id


def find_aapt2() -> Path:
    roots = [os.environ.get("ANDROID_SDK_ROOT"), os.environ.get("ANDROID_HOME")]
    local = Path(__file__).resolve().parents[1] / "android" / "local.properties"
    if local.is_file():
        match = re.search(r"^sdk\.dir=(.+)$", local.read_text(encoding="utf-8"), re.MULTILINE)
        if match:
            roots.append(match[1].replace("\\:", ":").replace("\\\\", "\\"))
    for root in filter(None, roots):
        candidates = sorted((Path(root) / "build-tools").glob("*/aapt2*"), reverse=True)
        for candidate in candidates:
            if candidate.is_file() and candidate.name in {"aapt2", "aapt2.exe"}:
                return candidate
    raise ValueError("Pass --aapt2 or configure an Android SDK with build-tools")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apk", required=True, type=Path)
    parser.add_argument("--aapt2", type=Path)
    args = parser.parse_args()
    try:
        application_id = verify_apk(args.apk, args.aapt2 or find_aapt2())
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        parser.exit(1, f"Community APK preflight failed: {error}\n")
    print(f"Verified APK application ID: {application_id}")
    print("Use flutter test --no-uninstall for device integration tests.")


if __name__ == "__main__":
    main()
