"""Explicit maintainer runs, scoped to one private package and known fixtures.

No global media keys/settings/battery reset, no production app stop/data access.
"""
from __future__ import annotations

import argparse
import hashlib
from io import BytesIO
import json
import os
from pathlib import Path
import subprocess
import time
import urllib.request
import urllib.error

ROOT = Path(__file__).resolve().parents[1]
AUDIT = ROOT / "build/android-resource-audit-20261101"
PACKAGE = "com.example.video_player_app.android_resource_audit"
SERIAL = os.environ.get("ANDROID_SERIAL", "")
if not SERIAL:
    raise SystemExit("Set ANDROID_SERIAL to the device used for this audit.")
ADB = Path(os.environ.get("ANDROID_SDK_ROOT", "")) / "platform-tools" / ("adb.exe" if os.name == "nt" else "adb")
BASE = "http://127.0.0.1:8783"


def adb(*arguments: str, binary: bool = False, timeout: int = 240):
    result = subprocess.run([str(ADB), "-s", SERIAL, *arguments], check=False,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
    if result.returncode:
        details = {"arguments": arguments, "exitCode": result.returncode,
                   "stdout": result.stdout.decode("utf-8", errors="replace"),
                   "stderr": result.stderr.decode("utf-8", errors="replace")}
        save(AUDIT / f"adb-failure-{time.time_ns()}.json", details)
        raise RuntimeError(details)
    return result.stdout if binary else result.stdout.decode("utf-8", errors="replace").strip()


def request(path: str, body: dict | None = None, timeout: int = 330) -> dict:
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(BASE + path, data=data,
                                 headers={"Content-Type": "application/json"} if body is not None else {})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as response:
            value = json.load(response)
    except urllib.error.HTTPError as error:
        body = error.read().decode("utf-8", errors="replace")
        try:
            body = json.loads(body)
        except ValueError:
            pass
        details = {"path": path, "httpStatus": error.code, "responseBody": body}
        save(AUDIT / f"http-failure-{time.time_ns()}.json", details)
        raise RuntimeError(details) from error
    if value.get("error"):
        raise RuntimeError(value)
    return value


def save(path: Path, value) -> None:
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding="utf-8")


def environment() -> dict:
    display = adb("shell", "dumpsys", "display")
    battery = adb("shell", "dumpsys", "battery")
    thermal = adb("shell", "dumpsys", "thermalservice")
    return {"display": [line.strip()[:250] for line in display.splitlines() if "DisplayDeviceInfo{" in line][:1],
            "battery": [line.strip() for line in battery.splitlines() if any(key in line for key in ("USB powered:", "level:", "temperature:"))],
            "thermal": [line.strip() for line in thermal.splitlines() if "Thermal Status:" in line],
            "formalAppPidReadOnly": adb("shell", "pidof", "com.example.video_player_app")}


def screenshot(path: Path) -> dict:
    # Do not capture a user screen if a probe launch failed or another app took over.
    activities = adb("shell", "dumpsys", "activity", "activities")
    resumed = [line for line in activities.splitlines() if "topResumedActivity=" in line or "mResumedActivity:" in line]
    if not any(PACKAGE in line for line in resumed):
        raise RuntimeError("Refusing screenshot: private probe is not resumed")
    focused = [line for line in adb("shell", "dumpsys", "window", "windows").splitlines() if "mCurrentFocus=" in line]
    if focused and not any(PACKAGE in line for line in focused):
        raise RuntimeError("Refusing screenshot: another window covers the private probe")
    path.write_bytes(adb("exec-out", "screencap", "-p", binary=True))
    from PIL import Image, ImageCms
    captured = Image.open(path)
    profile_name = None
    if captured.info.get("icc_profile"):
        profile = ImageCms.ImageCmsProfile(BytesIO(captured.info["icc_profile"]))
        profile_name = ImageCms.getProfileName(profile).strip()
        image = ImageCms.profileToProfile(captured, profile, ImageCms.createProfile("sRGB"), outputMode="RGB")
    else:
        image = captured.convert("RGB")
    # Known synthetic quadrant colors must occupy substantial areas, not just UI pixels.
    colors = {"red": 0, "green": 0, "blue": 0, "yellow": 0}
    sampled = 0
    for y in range(image.height // 6, image.height * 5 // 6, 8):
        for x in range(image.width // 10, image.width * 9 // 10, 8):
            r, g, b = image.getpixel((x, y)); sampled += 1
            if r > 170 and g < 75 and b < 75: colors["red"] += 1
            if g > 170 and r < 75 and b < 75: colors["green"] += 1
            if b > 170 and r < 75 and g < 75: colors["blue"] += 1
            if r > 170 and g > 170 and b < 75: colors["yellow"] += 1
    passed = all(count > sampled * .02 for count in colors.values())
    if not passed:
        raise RuntimeError(f"Video quadrant readback failed: {colors}, samples={sampled}")
    return {"file": str(path), "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
            "size": image.size, "embeddedColorProfile": profile_name,
            "quadrantSamples": colors, "sampleCount": sampled, "passed": passed}


def measure(name: str, seconds: float = 3) -> dict:
    time.sleep(.6)
    before = request("/status"); start = time.monotonic()
    samples = [{"wallSeconds": 0, "status": before}]
    while time.monotonic() - start < seconds:
        time.sleep(min(.25, max(0, seconds - (time.monotonic() - start))))
        value = request("/status")
        samples.append({"wallSeconds": time.monotonic() - start, "status": value})
    after = samples[-1]["status"]; elapsed = samples[-1]["wallSeconds"]
    position = "nativePositionMs" if before.get("managedByMediaKit") else "positionMs"
    advance = (after.get(position) or 0) - (before.get(position) or 0)
    # Final 60s fixture never reaches EOF during a measured window. Any jump
    # remains visible and fails; do not infer a corrected loop distance.
    row = {"name": name, "wallMs": elapsed * 1000, "mediaAdvanceMs": advance,
           "frames": after["frames"] - before["frames"],
           "buildUs": after["buildUs"] - before["buildUs"],
           "rasterUs": after["rasterUs"] - before["rasterUs"],
           "processCpuMs": after["native"]["cpuMs"] - before["native"]["cpuMs"],
           "before": before, "after": after, "samples": samples}
    jumps = []
    for earlier, later in zip(samples, samples[1:]):
        delta = (later["status"].get(position) or 0) - (earlier["status"].get(position) or 0)
        wall = (later["wallSeconds"] - earlier["wallSeconds"]) * 1000
        if delta < -200 or (before.get("managedByMediaKit") and delta > wall * 1.8 + 200):
            jumps.append({"wallMs": wall, "advanceMs": delta})
    row["discontinuities"] = jumps
    if not after["playing"] or advance < elapsed * 750 or advance > elapsed * 1300 or jumps:
        save(AUDIT / f"failed-{name}-{time.time_ns()}.json", row)
        raise RuntimeError(f"Playback stalled: {name}: {row}")
    print(f"{name}: {advance}ms/{elapsed:.3f}s, frames={row['frames']}, cpu={row['processCpuMs']}ms", flush=True)
    return row


def media(arm: str, round_number: int, tag: str) -> dict:
    label = f"{arm}-r{round_number}-{tag}"
    output = AUDIT / (label + "-media.json")
    report = {"arm": arm, "round": round_number, "package": PACKAGE, "scenarios": [], "readbacks": [], "environmentStart": environment(), "activeDisplays": {}}
    for backend in ("platform", "mediakit"):
        opened = request("/open?backend=" + backend)
        if not opened["ready"] or opened["managedByMediaKit"] != (backend == "mediakit"):
            raise RuntimeError(f"Unexpected backend: {opened}")
        request("/seek?ms=1000")
        report["scenarios"].append(measure(backend + "-visible"))
        report["activeDisplays"][backend + "-visible"] = environment()["display"]
        if backend == "mediakit":
            for width, height in ((640, 360), (1280, 720), (960, 540), (1280, 720), (640, 360), (1280, 720)):
                request(f"/resize?w={width}&h={height}")
                time.sleep(.15)
            report["scenarios"].append(measure("mediakit-visible-through-retirement", 6.5))
            report["activeDisplays"]["mediakit-after-retirement"] = environment()["display"]
        request("/pause"); request("/seek?ms=3000"); time.sleep(.7)
        paused = request("/status")
        if paused["playing"] or abs(paused["positionMs"] - 3000) > 300:
            raise RuntimeError(f"Pause/seek failed: {paused}")
        report["readbacks"].append(screenshot(AUDIT / f"{label}-{backend}-paused-seek.png"))
        request("/play"); request("/visible?value=0")
        report["scenarios"].append(measure(backend + "-offstage"))
        request("/visible?value=1")
        # App lifecycle exercise only: never issue global transport/media keys.
        adb("shell", "am", "start", "-a", "android.intent.action.MAIN", "-c", "android.intent.category.HOME")
        home_started = time.monotonic()
        while request("/status")["lifecycle"] not in ("hidden", "paused"):
            if time.monotonic() - home_started > 5: raise RuntimeError("Probe did not enter background")
            time.sleep(.1)
        report["scenarios"].append(measure(backend + "-actual-background"))
        time.sleep(max(0, 6.2 - (time.monotonic() - home_started)))
        background = request("/status")
        if not background["playing"]: raise RuntimeError(f"Background unexpectedly paused: {background}")
        adb("shell", "am", "start", "-n", PACKAGE + "/com.example.video_player_app.MainActivity")
        time.sleep(.8)
        returned = request("/status")
        if not returned["playing"]: raise RuntimeError(f"Returning unexpectedly paused: {returned}")
        report[backend + "BackgroundReturn"] = {"background": background, "returnedBeforeCommands": returned}
        report["scenarios"].append(measure(backend + "-returned"))
        request("/pause"); time.sleep(.4)
        report["readbacks"].append(screenshot(AUDIT / f"{label}-{backend}-returned.png"))
        if backend == "mediakit":
            request("/seek?ms=3000"); time.sleep(.5)
            adb("shell", "am", "start", "-a", "android.intent.action.MAIN", "-c", "android.intent.category.HOME")
            time.sleep(6.2)
            held = request("/status")
            adb("shell", "am", "start", "-n", PACKAGE + "/com.example.video_player_app.MainActivity")
            time.sleep(.8)
            revealed = request("/status")
            if held["playing"] or revealed["playing"] or abs(revealed["positionMs"] - 3000) > 300:
                raise RuntimeError(f"Paused seek intent changed across lifecycle: {held}, {revealed}")
            report["mediakitPausedBackground"] = {"hidden": held, "returned": revealed}
            report["readbacks"].append(screenshot(AUDIT / f"{label}-mediakit-paused-background.png"))
        request("/dispose"); time.sleep(6)
        report[backend + "Disposed"] = request("/status")
        save(output, report)
    report["detachBefore"] = request("/status")
    for _ in range(3): request("/detach-engine")
    time.sleep(6)
    report["detachAfter"] = request("/status")
    if arm == "after" and report["detachAfter"]["native"]["jni"]["outstanding"] != 0:
        raise RuntimeError(f"JNI references retained: {report['detachAfter']}")
    report["passed"] = True
    report["environmentEnd"] = environment()
    save(output, report)
    return report


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("arm", choices=("before", "after"))
    parser.add_argument("--round", type=int, default=1)
    parser.add_argument("--apk", type=Path)
    parser.add_argument("--tag", default="v2")
    parser.add_argument("--phase", choices=("media", "status"), default="media")
    args = parser.parse_args()
    AUDIT.mkdir(exist_ok=True)
    if args.apk:
        aapt = Path(os.environ.get("ANDROID_SDK_ROOT", "")) / "build-tools" / "36.0.0" / ("aapt.exe" if os.name == "nt" else "aapt")
        badging = subprocess.check_output([str(aapt), "dump", "badging", str(args.apk)], text=True)
        if not badging.startswith(f"package: name='{PACKAGE}' "):
            raise SystemExit("Refusing APK: package identity differs from private audit")
        adb("shell", "am", "force-stop", PACKAGE)
        print(adb("install", "-r", str(args.apk)), flush=True)
    adb("forward", "tcp:8783", "tcp:8783")
    adb("shell", "am", "start", "-n", PACKAGE + "/com.example.video_player_app.MainActivity")
    deadline = time.monotonic() + 60
    while True:
        try: request("/status"); break
        except Exception:
            if time.monotonic() > deadline: raise
            time.sleep(.5)
    if args.phase == "status":
        print(json.dumps(request("/status"), indent=2)); return
    result = media(args.arm, args.round, args.tag)
    print(json.dumps({"arm": args.arm, "round": args.round, "passed": result["passed"],
                      "jni": result["detachAfter"]["native"]["jni"]}), flush=True)


if __name__ == "__main__":
    main()
