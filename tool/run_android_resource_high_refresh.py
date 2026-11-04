"""Explicit isolated high-refresh diagnostic; never changes system settings.

Run only after the matching private high-refresh-v2 APK has been installed by
the maintainer. Video position is checked at 1x; UI VSync is counted separately
from Flutter's batched FrameTiming reports and the fixture's 60 fps video.
"""
from __future__ import annotations

import argparse
import json
import re
import time

from run_android_resource_audit import AUDIT, PACKAGE, adb, request, save, screenshot


def display_sample() -> dict:
    text = adb("shell", "dumpsys", "display")
    lines = [line.strip() for line in text.splitlines() if "DisplayDeviceInfo{" in line and 'uniqueId="local:' in line]
    if not lines:
        raise RuntimeError("No internal display details; cannot establish actual high refresh")
    line = lines[0]
    current = re.search(r"\bmodeId (\d+)", line)
    render = re.search(r"\brenderFrameRate ([\d.]+)", line)
    modes = {int(mode): float(hz) for mode, hz in re.findall(r"\{id=(\d+),[^}]*?\bfps=([\d.]+)", line)}
    mode = int(current.group(1)) if current else None
    actual = float(render.group(1)) if render else None
    mode_hz = modes.get(mode)
    return {"modeId": mode, "modeHz": mode_hz, "renderFrameRate": actual,
            "verified144Hz": mode_hz is not None and actual is not None and abs(mode_hz - 144) < 1 and abs(actual - 144) < 1,
            "raw": line}


def wait_high_refresh() -> list[dict]:
    samples = []
    deadline = time.monotonic() + 6
    while True:
        sample = display_sample(); samples.append(sample)
        if sample["verified144Hz"]:
            return samples
        if time.monotonic() >= deadline:
            raise RuntimeError({"limitation": "System did not select an actual 144Hz mode/render rate; no system setting was changed", "displaySamples": samples})
        time.sleep(.5)


def measure(name: str, seconds: float = 6.5) -> dict:
    request("/animation?active=1&light=1")
    displays = wait_high_refresh()
    initial_display = displays[-1]
    full_before = request("/status"); cpu_start = time.monotonic()
    # PSS sampling can block Android's UI thread. Keep both full native snapshots
    # outside the direct VSync/position window and reset after the first snapshot.
    before = request("/animation?active=1&reset=1&light=1"); start = time.monotonic()
    samples = [{"wallSeconds": 0, "status": before}]
    while time.monotonic() - start < seconds:
        time.sleep(min(.25, max(0, seconds - (time.monotonic() - start))))
        value = request("/status?light=1")
        samples.append({"wallSeconds": time.monotonic() - start, "status": value})
    after = samples[-1]["status"]; elapsed = samples[-1]["wallSeconds"]
    full_after = request("/status"); cpu_elapsed = time.monotonic() - cpu_start
    displays.append(display_sample())
    position = "nativePositionMs" if before["managedByMediaKit"] else "positionMs"
    advance = after[position] - before[position]
    intervals = after["animationIntervals"] - before["animationIntervals"]
    interval_us = after["animationIntervalSumUs"] - before["animationIntervalSumUs"]
    ui_hz = intervals * 1e6 / interval_us if interval_us else 0
    jumps = []
    for a, b in zip(samples, samples[1:]):
        wall_ms = (b["wallSeconds"] - a["wallSeconds"]) * 1000
        delta = b["status"][position] - a["status"][position]
        if delta < -200 or (before["managedByMediaKit"] and delta > wall_ms * 1.8 + 200):
            jumps.append({"wallMs": wall_ms, "advanceMs": delta})
    checks = {"actual144HzAtBothEnds": all(d["verified144Hz"] for d in (initial_display, displays[-1])),
              "lightSamplesHonoredByMatchingProbe": all(s["status"].get("lightSample") is True and s["status"].get("native") is None for s in samples),
              "video1x": elapsed * 750 <= advance <= elapsed * 1300 and not jumps,
              "playing": after["playing"] is True,
              "animationStillExplicitlyActive": after["animationRequested"] and after["animationRunning"],
              "uiVsyncNear144Hz": 129.6 <= ui_hz <= 158.4,
              "uiIntervalsCoverWindow": elapsed * .85 <= interval_us / 1e6 <= elapsed * 1.15}
    row = {"name": name, "actualWallMs": elapsed * 1000, "videoAdvanceMs": advance,
           "videoAdvancePerWall": advance / (elapsed * 1000), "fixtureVideoFps": 60,
           "animationVsyncHz": ui_hz, "animationFrames": after["animationFrames"] - before["animationFrames"],
           "animationIntervalCount": intervals, "animationIntervalSumUs": interval_us,
           "animationMaxIntervalUsSinceReset": after["animationMaxIntervalUs"],
           "animationOverBudgetCount": after["animationOverBudget"] - before["animationOverBudget"],
           "animationFrameBudgetUs": after["animationFrameBudgetUs"],
           "animationBudgetToleranceUs": after["animationBudgetToleranceUs"],
           "cpuObservationWallMs": cpu_elapsed * 1000,
           "processCpuMsPerWallSecond": (full_after["native"]["cpuMs"] - full_before["native"]["cpuMs"]) / cpu_elapsed,
           "frameTimingReportCount": after["frames"] - before["frames"],
           "rasterUsFromBatchedReports": after["rasterUs"] - before["rasterUs"],
           "displaySamples": displays, "before": before, "after": after, "samples": samples,
           "nativeObservationBefore": full_before, "nativeObservationAfter": full_after,
           "positionDiscontinuities": jumps, "checks": checks, "passed": all(checks.values())}
    return row


def hidden_animation_intent() -> dict:
    request("/visible?value=0"); time.sleep(.3)
    hidden = request("/status"); time.sleep(.6); later = request("/status")
    request("/visible?value=1"); time.sleep(.3); returned = request("/status")
    passed = (hidden["animationRequested"] and not hidden["animationRunning"] and
              hidden["animationFrames"] == later["animationFrames"] and
              returned["animationRequested"] and returned["animationRunning"] and returned["playing"])
    return {"hidden": hidden, "later": later, "returned": returned, "passed": passed}


def home_intent() -> dict:
    adb("shell", "am", "start", "-a", "android.intent.action.MAIN", "-c", "android.intent.category.HOME")
    start = time.monotonic()
    while True:
        hidden = request("/status")
        if hidden["lifecycle"] in ("hidden", "paused"):
            break
        if time.monotonic() - start > 5:
            raise RuntimeError("Private probe did not enter background")
        time.sleep(.1)
    time.sleep(1); later = request("/status")
    time.sleep(max(0, 6.2 - (time.monotonic() - start)))
    adb("shell", "am", "start", "-n", PACKAGE + "/com.example.video_player_app.MainActivity")
    time.sleep(.8); returned = request("/status")
    displays = wait_high_refresh()
    passed = (hidden["playing"] and later["playing"] and hidden["animationRequested"] and
              not hidden["animationRunning"] and hidden["animationFrames"] == later["animationFrames"] and
              returned["playing"] and returned["animationRequested"] and returned["animationRunning"])
    return {"hidden": hidden, "later": later, "returnedBeforeCommands": returned,
            "returnedDisplaySamples": displays, "passed": passed}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("arm", choices=("before", "after"))
    parser.add_argument("--round", type=int, choices=(1, 2, 3), required=True)
    args = parser.parse_args()
    label = f"{args.arm}-r{args.round}-high-refresh-v2"
    output = AUDIT / (label + ".json")
    if output.exists():
        raise SystemExit(f"Refusing to overwrite diagnostic evidence: {output}")
    report = {"arm": args.arm, "round": args.round, "variant": "high-refresh-v2", "package": PACKAGE,
              "passed": False, "windows": [], "readbacks": [], "limits": [
                  "This explicit synthetic UI stress is separate from the 60fps fixture video.",
                  "VSync callback intervals measure scheduled UI animation, not hardware video presentation timestamps.",
                  "FrameTiming reports remain batched and are not used to infer video or 144Hz UI FPS.",
                  "Middle position/VSync samples skip native PSS/RSS. Full CPU/JNI snapshots are outside the animation window; CPU uses its separate actual observation wall time.",
                  "144Hz mode/render must be observed; system settings and production refresh policy are never altered."]}
    AUDIT.mkdir(exist_ok=True); save(output, report)
    try:
        adb("forward", "tcp:8783", "tcp:8783")
        adb("shell", "am", "start", "-n", PACKAGE + "/com.example.video_player_app.MainActivity")
        deadline = time.monotonic() + 60
        while True:
            try: initial = request("/status"); break
            except Exception:
                if time.monotonic() > deadline: raise
                time.sleep(.5)
        if initial.get("probeDiagnosticRevision") != "high-refresh-v2":
            raise RuntimeError("Install the matching private high-refresh-v2 diagnostic APK first")
        for backend in ("platform", "mediakit"):
            opened = request("/open?backend=" + backend)
            if not opened["ready"] or opened["managedByMediaKit"] != (backend == "mediakit"):
                raise RuntimeError("Unexpected backend")
            request("/seek?ms=1000")
            row = measure(backend + "-visible")
            report["windows"].append(row); save(output, report)
            if not row["passed"]: raise RuntimeError("Visible high-refresh window failed")
            if backend == "mediakit":
                for width, height in ((640, 360), (1280, 720), (960, 540), (1280, 720), (640, 360), (1280, 720)):
                    request(f"/resize?w={width}&h={height}"); time.sleep(.15)
                row = measure("mediakit-visible-through-retirement")
                row["checks"]["retirementWasPendingAtStart"] = row["nativeObservationBefore"]["native"]["jni"]["outstanding"] > 1
                if args.arm == "after":
                    row["checks"]["onlyActiveReferenceAfterRetirement"] = row["nativeObservationAfter"]["native"]["jni"]["outstanding"] == 1
                row["passed"] = all(row["checks"].values())
                report["windows"].append(row); save(output, report)
                if not row["passed"]: raise RuntimeError("High-refresh retirement window failed")
            if args.round == 1:
                check = hidden_animation_intent(); report[backend + "VisibilityIntent"] = check
                save(output, report)
                if not check["passed"]: raise RuntimeError("Explicit animation visibility intent failed")
                if backend == "mediakit":
                    check = home_intent(); report[backend + "HomeIntent"] = check; save(output, report)
                    if not check["passed"]: raise RuntimeError("HOME playback/animation intent failed")
            request("/animation?active=0"); request("/pause"); request("/seek?ms=3000")
            time.sleep(.7); paused = request("/status"); time.sleep(.5); still = request("/status")
            report[backend + "Paused"] = {"first": paused, "later": still}
            if (paused["playing"] or paused["animationRunning"] or paused["animationRequested"] or
                    paused["animationFrames"] != still["animationFrames"] or abs(still["positionMs"] - 3000) > 300):
                raise RuntimeError("Paused static playback/seek unexpectedly animates or changes position")
            report["readbacks"].append(screenshot(AUDIT / f"{label}-{backend}-paused.png"))
            request("/dispose"); time.sleep(6); disposed = request("/status")
            report[backend + "Disposed"] = disposed; save(output, report)
            if disposed["animationRequested"] or disposed["animationRunning"]:
                raise RuntimeError("Disposed controller retained explicit animation")
            if args.arm == "after" and disposed["native"]["jni"]["outstanding"] != 0:
                raise RuntimeError("After JNI references retained beyond 5s retirement")
            if args.arm == "before" and backend == "mediakit" and disposed["native"]["jni"]["outstanding"] == 0:
                raise RuntimeError("Baseline did not reproduce the existing replaced-reference retention")
        report["passed"] = True
    except Exception as error:
        report["error"] = repr(error)
        raise
    finally:
        try:
            request("/animation?active=0"); request("/dispose")
        except Exception as error:
            report["cleanupError"] = repr(error)
        save(output, report)
    print(json.dumps({"arm": args.arm, "round": args.round, "passed": report["passed"], "windows": len(report["windows"])}), flush=True)


if __name__ == "__main__":
    main()
