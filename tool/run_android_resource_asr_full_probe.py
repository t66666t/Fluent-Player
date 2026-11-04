"""One full prepared Chinese fixture decode per advertised ASR GPU backend.

Maintainer-only private-package diagnostic. Keeps the original 4-second evidence,
native deadlines, model/export, threads and language unchanged. No process kill,
system setting, weight transfer, model download, or production application access.
"""
from __future__ import annotations

import argparse
import array
import hashlib
import json
import re
import sys
import time
import wave

from run_android_resource_audit import AUDIT, PACKAGE, ROOT, adb, request, save


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("arm", choices=("before", "after"))
    parser.add_argument("--backend", choices=("both", "vulkan", "opencl"), default="both")
    parser.add_argument("--tag", default="")
    args = parser.parse_args()
    if args.tag and not re.fullmatch(r"[a-z0-9-]+", args.tag):
        raise SystemExit("Unsafe diagnostic evidence tag")
    suffix = f"-{args.tag}" if args.tag else ""
    output = AUDIT / f"{args.arm}-asr-full-zh{suffix}.json"
    log = AUDIT / f"{args.arm}-asr-full-zh{suffix}.log"
    if output.exists() or log.exists():
        raise SystemExit("Refusing to overwrite full-fixture diagnostic evidence")
    initial = request("/status")
    external = initial["native"]["externalFiles"]
    if not external.endswith(f"/Android/data/{PACKAGE}/files"):
        raise SystemExit("Refusing storage outside the private diagnostic package")
    directory = external + "/resource-audit"
    baseline_path = AUDIT / "before-models.json"
    baseline = json.loads(baseline_path.read_text(encoding="utf-8"))
    advertised = {}
    original_load = None
    controls = []
    for record in baseline["records"]:
        if record["kind"] != "asr":
            continue
        body, response = record["request"], record.get("response")
        if body.get("op") == "capabilities" and isinstance(response, dict) and response.get("ok"):
            for device in response.get("devices", []):
                if device.get("backend") in ("vulkan", "opencl"):
                    advertised.setdefault(device["backend"], device)
        if body.get("op") == "load" and original_load is None:
            original_load = body
        if body.get("op") == "decode":
            controls.append(record)
    if original_load is None or original_load.get("modelId") != "sensevoice-small-int8" or original_load.get("floatWeights") is not True:
        raise SystemExit("Expected the existing registered FP32 SenseVoice diagnostic configuration")
    if original_load.get("threads") != 2 or original_load.get("language") != "zh":
        raise SystemExit("Original diagnostic threads/language differ; do not silently change configuration")
    if sys.byteorder != "little":
        raise SystemExit("This diagnostic expects the existing little-endian float32 PCM convention")
    wav = ROOT / "assets/models/asr/speech_probe_zh.wav"
    with wave.open(str(wav), "rb") as source:
        if (source.getframerate(), source.getnchannels(), source.getsampwidth()) != (16000, 1, 2):
            raise SystemExit("Prepared fixture must remain 16kHz mono signed16")
        samples = array.array("h", source.readframes(source.getnframes()))
    if not 0 < len(samples) <= 30 * 16000:
        raise SystemExit("Prepared full fixture exceeds the unchanged native 30-second limit")
    pcm_bytes = array.array("f", (sample / 32768 for sample in samples)).tobytes()
    truncated_bytes = array.array("f", (sample / 32768 for sample in samples[:4 * 16000])).tobytes()
    pcm = AUDIT / "fixtures/asr-full-zh.f32"
    pcm.write_bytes(pcm_bytes)
    report = {"arm": args.arm, "package": PACKAGE, "complete": False, "functionalPass": False,
        "baselineEvidenceFile": str(baseline_path), "baselineEvidenceSha256": hashlib.sha256(baseline_path.read_bytes()).hexdigest(),
        "fullFixture": {"source": str(wav), "sourceSha256": hashlib.sha256(wav.read_bytes()).hexdigest(),
            "frames": len(samples), "seconds": len(samples) / 16000, "pcmBytes": len(pcm_bytes),
            "pcmSha256": hashlib.sha256(pcm_bytes).hexdigest(), "sampleRate": 16000, "format": "float32-le-mono"},
        "originalFourSecondDecodeResponses": controls, "advertisedTargetsFromOriginalNativeResponses": advertised,
        "fourSecondControlPcmSha256": hashlib.sha256(truncated_bytes).hexdigest(),
        "records": [], "cases": [], "settles": [], "limits": [
            "Exactly one native load/decode/close attempt per originally advertised Vulkan/OpenCL backend.",
            "Functional pass requires nonempty actual text and acceleratedNodes > 0, not capabilities/load alone.",
            "No native timeout, model/export, threads, language, production budget or system setting is changed.",
            "Close/settle is bounded at 8 seconds and observes only this private package's ASR process; it never kills a process."]}
    known_pids = set()

    def emit(value) -> None:
        line = json.dumps(value, ensure_ascii=True)
        print(line, flush=True)
        with log.open("a", encoding="utf-8") as stream:
            stream.write(line + "\n")

    def own_workers(timeout: float = 2) -> list[dict]:
        rows = []
        for line in adb("shell", "ps", "-A", "-o", "PID,NAME", timeout=timeout).splitlines():
            columns = line.split()
            if len(columns) >= 2 and columns[0].isdigit() and columns[1] == PACKAGE + ":asr_accel":
                rows.append({"pid": int(columns[0]), "name": columns[1], "seenInPrivateResponse": int(columns[0]) in known_pids})
        return rows

    def call(body: dict, method: str = "request"):
        start = time.monotonic()
        # Same host transport limit as the original models diagnostic; native
        # request deadlines remain exactly those in the original production bridge.
        value = request("/bridge?kind=asr&method=" + method, body, timeout=720)
        response = value.get("result")
        if isinstance(response, dict) and isinstance(response.get("workerPid"), int):
            known_pids.add(response["workerPid"])
        row = {"request": body, "method": method, "wallSeconds": time.monotonic() - start,
               "response": response, "stats": value.get("native")}
        report["records"].append(row); save(output, report)
        emit({"operation": body.get("op", method), "wallSeconds": row["wallSeconds"], "response": response})
        return response

    def close_and_settle(label: str) -> dict:
        request("/dispose")
        call({}, "close")
        start = time.monotonic(); deadline = start + 8; observations = []
        available = None
        while True:
            remaining = max(.1, deadline - time.monotonic())
            native = request("/status", timeout=min(1, remaining))["native"]
            workers = own_workers(timeout=min(1, max(.1, deadline - time.monotonic())))
            ready = native.get("asrPending") == 0 and not workers
            # Read headroom only after the private process is actually gone.
            # GPU/kernel allocations can finish retiring just after its exit.
            if ready:
                meminfo = adb("shell", "cat", "/proc/meminfo", timeout=min(1, max(.1, deadline - time.monotonic())))
                match = re.search(r"(?m)^MemAvailable:\s+(\d+)", meminfo)
                available = int(match.group(1)) * 1024 if match else None
            observations.append({"wallSeconds": time.monotonic() - start, "asrPending": native.get("asrPending"),
                "ownAsrWorkers": workers, "availableMemoryBytesAfterOwnExit": available})
            enough = available is not None and available >= 937617178 * 2 + 256 * 1024 * 1024
            if (ready and enough) or time.monotonic() >= deadline:
                break
            time.sleep(min(.2, max(0, deadline - time.monotonic())))
        row = {"label": label, "ready": ready, "wallSeconds": time.monotonic() - start,
               "observations": observations, "freshAvailableMemoryBytes": available}
        report["settles"].append(row); save(output, report); emit({"settle": row})
        return row

    save(output, report)
    # Only the new synthetic full PCM is transferred; no weights are uploaded.
    adb("push", str(pcm), directory + "/asr-full-zh.f32", timeout=360)
    expected_weights = 937617178
    remote_weights = directory + "/models/sensevoice/model.onnx"
    if adb("shell", "stat", "-c", "%s", remote_weights).strip() != str(expected_weights):
        raise RuntimeError("Existing registered FP32 weights missing/wrong size; no replacement attempted")
    for backend in (("vulkan", "opencl") if args.backend == "both" else (args.backend,)):
        case = {"backend": backend, "functionalPass": False, "status": "pending"}
        report["cases"].append(case); save(output, report)
        try:
            if backend not in advertised:
                case.update(status="skipped", reason="Backend was not advertised by the original native capabilities responses")
                continue
            settled = close_and_settle("before-" + backend)
            available = settled["freshAvailableMemoryBytes"]
            estimated = expected_weights * 2; reserve = 256 * 1024 * 1024; needed = estimated + reserve
            case["admission"] = {"availableMemoryBytes": available, "estimatedAllocationBytes": estimated,
                "reserveBytes": reserve, "pendingAllocationBytes": 0, "neededBytes": needed,
                "ownWorkerExitedAndPendingZero": settled["ready"],
                "admitted": settled["ready"] and available is not None and available >= needed}
            if not case["admission"]["admitted"]:
                case.update(status="skipped", reason="Original mobile allocation admission not met after bounded own-worker settle")
                continue
            configuration = {**original_load, "directory": directory + "/models/sensevoice",
                "backend": backend, "device": advertised[backend].get("device", 0),
                "profileRoot": directory + "/asr-profiles", "cacheRoot": directory + "/asr-cache"}
            case["configuration"] = configuration
            loaded = call(configuration); case["loaded"] = loaded
            if not isinstance(loaded, dict) or loaded.get("ok") is not True:
                raise RuntimeError("Actual native model load did not succeed")
            workers = own_workers(); case["workerOwnershipAfterLoad"] = workers
            if not any(w["pid"] == loaded.get("workerPid") and w["seenInPrivateResponse"] for w in workers):
                raise RuntimeError("Native response PID is not the current private ASR process")
            decoded = call({"op": "decode", "path": directory + "/asr-full-zh.f32"}); case["decoded"] = decoded
            payload = decoded.get("result", {}) if isinstance(decoded, dict) else {}
            functional = bool(decoded and decoded.get("ok") is True and payload.get("text", "").strip()
                and decoded.get("acceleratedNodes", 0) > 0 and decoded.get("workerPid") == loaded.get("workerPid"))
            case.update(functionalPass=functional, status="passed" if functional else "failed")
            if not functional:
                case["reason"] = "Actual full-fixture native decode lacked nonempty text, accelerated nodes or matching private worker"
        except Exception as error:
            case.update(status="failed", error=repr(error))
        finally:
            try: case["closedAndSettled"] = close_and_settle("after-" + backend)
            except Exception as error: case["closeError"] = repr(error)
            save(output, report); emit({"case": case})
    report["final"] = request("/status")
    report["complete"] = True
    expected_backends = ("vulkan", "opencl") if args.backend == "both" else (args.backend,)
    report["selectedBackends"] = list(expected_backends)
    report["functionalPass"] = len(report["cases"]) == len(expected_backends) and all(c["functionalPass"] for c in report["cases"])
    report["resourceCleanupPass"] = all(c.get("closedAndSettled", {}).get("ready") and not c.get("closeError") for c in report["cases"])
    save(output, report); emit({"complete": True, "functionalPass": report["functionalPass"], "file": str(output)})
    if not report["functionalPass"] or not report["resourceCleanupPass"]:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
