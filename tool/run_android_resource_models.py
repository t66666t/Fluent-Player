"""Sequential native requests against the isolated Android resource probe only."""
from __future__ import annotations

import argparse
import array
import concurrent.futures
import json
from pathlib import Path
import re
import shlex
import time
import wave

from run_android_resource_audit import AUDIT, PACKAGE, ROOT, adb, request, save


class AdmissionSkipped(RuntimeError):
    """The existing mobile admission policy declined this diagnostic allocation."""


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("arm", choices=("before", "after"))
    parser.add_argument("--push", action="store_true", help="Transfer missing prepared fixtures only after admission; reuse same-size own-package files")
    args = parser.parse_args()
    initial = request("/status")
    external = initial["native"]["externalFiles"]
    if f"/Android/data/{PACKAGE}/files" not in external:
        raise SystemExit("Refusing storage outside isolated probe")
    directory = external + "/resource-audit"
    models = directory + "/models"
    adb("shell", "mkdir", "-p", models + "/sensevoice")
    pcm = AUDIT / "fixtures/speech.f32"
    with wave.open(str(ROOT / "assets/models/asr/speech_probe_zh.wav"), "rb") as source:
        assert source.getframerate() == 16000 and source.getnchannels() == 1 and source.getsampwidth() == 2
        signed = array.array("h", source.readframes(4 * 16000))
    pcm.write_bytes(array.array("f", (sample / 32768 for sample in signed)).tobytes())
    japanese_pcm = AUDIT / "fixtures/speech-ja.f32"
    with wave.open(str(ROOT / "assets/models/asr/speech_probe_ja.wav"), "rb") as source:
        assert source.getframerate() == 16000 and source.getnchannels() == 1 and source.getsampwidth() == 2
        signed = array.array("h", source.readframes(4 * 16000))
    japanese_pcm.write_bytes(array.array("f", (sample / 32768 for sample in signed)).tobytes())
    records = []
    path = AUDIT / f"{args.arm}-models.json"
    report = {"arm": args.arm, "package": PACKAGE, "records": records,
              "admissionPolicy": {"source": "InferenceResourceSession.admitsAdditional",
                  "mobileReserveBytes": 256 * 1024 * 1024, "pendingAllocationBytes": 0,
                  "note": "Serial diagnostic owners/controllers are closed before each fresh MemAvailable sample. No production budget or backend changes."},
              "note": "Prepared weights only; serial models. Timeout callback is explicitly fired early in own probe, not elapsed wall-clock timeout."}
    save(path, report)
    active_owners: set[tuple[str, str]] = set()
    asr_connected = False

    def call(kind: str, body: dict, method="request", checked=True):
        nonlocal asr_connected
        started = time.monotonic()
        value = request(f"/bridge?kind={kind}&method={method}", body, timeout=720)
        row = {"kind": kind, "method": method, "request": body,
               "wallSeconds": time.monotonic() - started, "response": value.get("result"),
               "stats": value.get("native")}
        records.append(row); save(path, report)
        response = row["response"]
        payload = response.get("result", response) if isinstance(response, dict) else {}
        if not isinstance(payload, dict):
            payload = {}
        brief = {key: payload[key] for key in ("text", "backend", "gpuOperators", "error") if key in payload}
        if isinstance(response, dict):
            brief.update({key: response[key] for key in ("ok", "acceleratedNodes", "error") if key in response})
        print(f"{kind} {body.get('op', method)} {row['wallSeconds']:.2f}s {brief}", flush=True)
        if kind == "asr":
            asr_connected = method != "close"
        elif method == "close":
            active_owners.discard((kind, body["owner"]))
        elif body.get("op") == "open" and not (isinstance(response, dict) and response.get("ok") is False):
            active_owners.add((kind, body["owner"]))
        if checked and isinstance(row["response"], dict) and row["response"].get("ok") is False:
            raise RuntimeError(row)
        return row

    def timeout_count(kind: str) -> dict:
        return request("/status")["native"]

    def ensure_prepared(source: Path, destination: str) -> None:
        if not destination.startswith(directory + "/"):
            raise RuntimeError("Refusing fixture path outside isolated probe directory")
        quoted = shlex.quote(destination)
        present = adb("shell", f"if test -f {quoted}; then stat -c %s {quoted}; else echo missing; fi")
        expected = source.stat().st_size
        if present.strip() == str(expected):
            return
        if not args.push:
            raise RuntimeError(f"Prepared fixture missing or wrong size: {destination}; rerun diagnostic with --push")
        print(f"Pushing admitted prepared fixture {source.name} ({expected} B)", flush=True)
        adb("push", str(source), destination, timeout=360)
        if adb("shell", "stat", "-c", "%s", destination).strip() != str(expected):
            raise RuntimeError(f"Prepared fixture transfer size mismatch: {destination}")

    # Retire only this private probe's known owners, including an interrupted
    # previous arm, before its first allocation. Never stop another application.
    request("/dispose")
    call("asr", {}, "close", checked=False)
    for kind, owners in (
        ("qwen", [f"resource-audit-{arm}-{backend}" for arm in ("before", "after") for backend in ("cpu", "vulkan")] + ["resource-audit-completed"]),
        ("japanese", ["resource-audit-japanese"]),
        ("cohere", ["resource-audit-cohere"]),
    ):
        for owner in owners:
            call(kind, {"owner": owner}, "close", checked=False)
    for source, destination in ((pcm, directory + "/speech.f32"), (japanese_pcm, directory + "/speech-ja.f32")):
        ensure_prepared(source, destination)

    def load_admitted(component: str, configuration: dict, estimated: int,
                      files: list[tuple[Path, str]], item: dict, stage: str):
        # No overlapping models, live playback controllers, or pending model
        # allocations are charged to this fresh diagnostic admission snapshot.
        request("/dispose")
        if asr_connected:
            call("asr", {}, "close", checked=False)
        for kind, owner in tuple(active_owners):
            call(kind, {"owner": owner}, "close", checked=False)
        # Binder close can return before the private ASR process and its GPU
        # allocations finish retiring. The initial run observed headroom recover
        # two seconds later. Wait only for this probe's owners, with a hard bound.
        settle_started = time.monotonic()
        settle_rows = []
        while True:
            private_pid = adb("shell", f"pidof {shlex.quote(PACKAGE + ':asr_accel')} || true").strip()
            native = request("/status")["native"]
            elapsed = time.monotonic() - settle_started
            ready = not private_pid and all(native.get(key) == 0 for key in ("asrPending", "qwenPending", "qwenClosing"))
            settle_rows.append({"elapsedSeconds": elapsed, "ownAsrPid": private_pid or None, "pendingZero": ready})
            if ready and elapsed >= 2:
                break
            if elapsed >= 8:
                raise AdmissionSkipped(f"Own model resources did not settle within 8 seconds: {settle_rows}")
            time.sleep(.25)
        item.setdefault("ownedReleaseSettles", []).append({"stage": stage, "observations": settle_rows})
        def sample_admission(phase: str) -> None:
            native = request("/status")["native"]
            pending = {key: native.get(key) for key in ("asrPending", "qwenPending", "qwenClosing")}
            meminfo = adb("shell", "cat", "/proc/meminfo")
            match = re.search(r"(?m)^MemAvailable:\s+(\d+)", meminfo)
            available = int(match.group(1)) * 1024 if match else None
            reserve = 256 * 1024 * 1024
            needed = max(0, estimated) + reserve  # pendingAllocationBytes == 0
            admission = {"stage": stage, "phase": phase, "component": component, "backend": configuration.get("backend"),
                "availableMemoryBytes": available, "estimatedAllocationBytes": estimated,
                "reserveBytes": reserve, "pendingAllocationBytes": 0, "neededBytes": needed,
                "nativePendingAfterClose": pending,
                "admitted": available is not None and available >= needed and all(value == 0 for value in pending.values())}
            item.setdefault("admissions", []).append(admission)
            save(path, report)
            print(f"{component} {configuration.get('backend')} {stage}: admission {admission}", flush=True)
            if not admission["admitted"]:
                raise AdmissionSkipped(f"Existing mobile allocation admission declined {stage}: {admission}")
        sample_admission("before-prepared-weights")
        # Large prepared weights are transferred only after their own backend's
        # admission succeeds. A later arm reuses an own-package file by size.
        for source, destination in files:
            ensure_prepared(source, destination)
        # A multi-GB first transfer can change OS headroom; sample again right
        # before native open/load rather than relying on the pre-transfer value.
        sample_admission("before-native-load")
        if component != "asr":
            call(component, {"op": "open", "owner": configuration["owner"]})
        return call(component, configuration)["response"]

    # Actual ASR private process request completion exercises the bridge even if
    # this device rejects a particular GPU graph. Report such limits explicitly.
    sensevoice = ROOT / ".artifacts/asr-gpu/models/sensevoice-small-int8-gpu/model.onnx"
    sensevoice_files = [(sensevoice, models + "/sensevoice/model.onnx"),
        (sensevoice.with_name("tokens.txt"), models + "/sensevoice/tokens.txt")]
    asr_result = {"passed": False, "status": "pending", "modelBytes": sensevoice.stat().st_size, "admissions": []}
    report["asr"] = asr_result
    try:
        capabilities = call("asr", {"op": "capabilities", "probeBackend": "system"})["response"]
        devices = list(capabilities.get("devices", []))
        for optional in capabilities.get("optionalBackends", []):
            backend = optional if isinstance(optional, str) else optional.get("backend")
            if backend in ("vulkan", "opencl"):
                extra = call("asr", {"op": "capabilities", "probeBackend": backend})["response"]
                devices.extend(extra.get("devices", []))
        selected = next((d for d in devices if d.get("backend") == "vulkan"), None)
        if selected is None: selected = next((d for d in devices if d.get("backend") == "nnapi"), None)
        if selected is None: raise RuntimeError("No advertised ASR GPU backend")
        configuration = {"op": "load", "engine": "sensevoice", "modelId": "sensevoice-small-int8",
            "directory": models + "/sensevoice", "floatWeights": True, "threads": 2,
            "language": "zh", "backend": selected["backend"], "device": selected.get("device", 0),
            "profileRoot": directory + "/asr-profiles", "cacheRoot": directory + "/asr-cache",
            "weightsIdentity": "isolated-existing-sensevoice-fp32", "sampleRate": 16000, "featureDim": 80}
        load_admitted("asr", configuration, sensevoice.stat().st_size * 2, sensevoice_files, asr_result, "initial-load")
        first = call("asr", {"op": "decode", "path": directory + "/speech.f32"})["response"]
        call("asr", {}, "close")
        closed = timeout_count("asr")
        load_admitted("asr", configuration, sensevoice.stat().st_size * 2, sensevoice_files, asr_result, "cancel-load")
        with concurrent.futures.ThreadPoolExecutor(max_workers=1) as executor:
            pending = executor.submit(call, "asr", {"op": "decode", "path": directory + "/speech.f32"}, "request", False)
            time.sleep(.03)
            call("asr", {}, "close", checked=False)
            cancelled = pending.result(timeout=90)["response"]
        load_admitted("asr", configuration, sensevoice.stat().st_size * 2, sensevoice_files, asr_result, "reopen-load")
        second = call("asr", {"op": "decode", "path": directory + "/speech.f32"})["response"]
        first_text = first.get("result", first).get("text")
        second_text = second.get("result", second).get("text")
        if not first_text or first_text != second_text or not first.get("acceleratedNodes"):
            raise RuntimeError("ASR empty or reopen transcript differs")
        call("asr", {}, "close")
        asr_result.update(passed=True, status="passed", first=first, second=second, closed=closed, cancelledResponse=cancelled)
    except AdmissionSkipped as error:
        asr_result.update(status="skipped", reason=str(error))
    except Exception as error:
        asr_result.update(status="failed", error=repr(error))
        try: call("asr", {}, "close", checked=False)
        except Exception: pass
    report["asr"] = asr_result; save(path, report)
    time.sleep(2)

    qwen_results = []
    qwen_source = ROOT / ".artifacts/model-center/native/qwen3-asr-0.6b-f16/qwen3-asr-0.6b.gguf"
    qwen_files = [(qwen_source, models + "/qwen.gguf")]
    report["qwen"] = qwen_results
    for backend in ("cpu", "vulkan"):
        owner = f"resource-audit-{args.arm}-{backend}"
        item = {"backend": backend, "passed": False, "status": "pending", "modelBytes": qwen_source.stat().st_size, "admissions": []}
        qwen_results.append(item)
        try:
            load = {"op": "load", "owner": owner, "kind": "asr", "model": models + "/qwen.gguf",
                    "threads": 2, "backend": backend, "language": "zh"}
            loaded = load_admitted("qwen", load, qwen_source.stat().st_size * 2, qwen_files, item, "initial-load")
            first = call("qwen", {"op": "decode", "owner": owner, "path": directory + "/speech.f32"})["response"]
            first_payload = first.get("result", first)
            if not first_payload.get("text"): raise RuntimeError("Qwen empty transcript")
            if backend != "cpu" and not first_payload.get("gpuOperators"):
                raise RuntimeError("Qwen advertised GPU without executed GPU operators")
            call("qwen", {"owner": owner}, "close")
            closed = timeout_count("qwen")
            load_admitted("qwen", load, qwen_source.stat().st_size * 2, qwen_files, item, "cancel-load")
            # Actual native decode cancellation; CPU closeOwner uses nativeCancel.
            with concurrent.futures.ThreadPoolExecutor(max_workers=1) as executor:
                pending = executor.submit(call, "qwen", {"op": "decode", "owner": owner, "path": directory + "/speech.f32"}, "request", False)
                time.sleep(.15)
                cancelled = call("qwen", {"owner": owner}, "close", checked=False)
                cancelled_decode = pending.result(timeout=90)
            load_admitted("qwen", load, qwen_source.stat().st_size * 2, qwen_files, item, "reopen-load")
            if args.arm == "after" and backend == "cpu":
                with concurrent.futures.ThreadPoolExecutor(max_workers=1) as executor:
                    pending = executor.submit(call, "qwen", {"op": "decode", "owner": owner, "path": directory + "/speech.f32"}, "request", False)
                    time.sleep(.15)
                    fired = request("/fire-timeout?label=QwenAsrBridge.kt")
                    timed_out = pending.result(timeout=90)
                item["simulatedEarlyTimeout"] = {"trigger": fired.get("result"), "response": timed_out["response"]}
                if not fired.get("result", {}).get("fired") or timed_out["response"].get("ok") is not False:
                    raise RuntimeError("Did not exercise a pending request's production timeout callback")
                load_admitted("qwen", load, qwen_source.stat().st_size * 2, qwen_files, item, "timeout-recovery-load")
            reopened = call("qwen", {"op": "decode", "owner": owner, "path": directory + "/speech.f32"})["response"]
            if not reopened.get("result", reopened).get("text"): raise RuntimeError("Qwen reopen empty transcript")
            call("qwen", {"owner": owner}, "close")
            item.update(actualBackend=loaded.get("result", loaded).get("backend"), passed=True, status="passed",
                    first=first, reopened=reopened, closed=closed,
                    cancelledResponse=cancelled_decode["response"], cancelClose=cancelled["response"])
        except AdmissionSkipped as error:
            item.update(status="skipped", reason=str(error))
        except Exception as error:
            item.update(status="failed", error=repr(error))
            try: call("qwen", {"owner": owner}, "close", checked=False)
            except Exception: pass
        save(path, report)
        time.sleep(2)
    reused = []
    report["reusedComponents"] = reused
    for component, kind, source, working_set in (
        ("japanese", "parakeet-ja", ROOT / ".artifacts/model-center/native/parakeet-ja-0.6b-q8/parakeet-tdt-0.6b-ja-q8_0.gguf", 673554880 * 2 + 768 * 1024 * 1024),
        ("cohere", "cohere-asr", ROOT / ".artifacts/model-center/native/cohere-transcribe-03-2026-q8/cohere-transcribe-03-2026-Q8_0.gguf", 2410655232 + 1536 * 1024 * 1024),
    ):
        if component == "cohere":
            working_set = source.stat().st_size + 1536 * 1024 * 1024
        item = {"component": component, "modelBytes": source.stat().st_size,
                "existingWorkingSetEstimateBytes": working_set, "passed": False, "status": "pending", "admissions": []}
        reused.append(item)
        destination = models + "/" + component + ".gguf"
        owner = f"resource-audit-{component}"
        try:
            results = []
            for index in range(2):
                load_admitted(component, {"op": "load", "owner": owner, "kind": kind,
                    "model": destination, "threads": 2, "backend": "cpu"}, working_set,
                    [(source, destination)], item, f"load-{index + 1}")
                decoded = call(component, {"op": "decode", "owner": owner, "path": directory + ("/speech.f32" if component == "cohere" else "/speech-ja.f32"), "language": "zh" if component == "cohere" else "ja"})["response"]
                if not decoded.get("result", decoded).get("text"): raise RuntimeError("Reused component empty transcript")
                results.append(decoded)
                call(component, {"owner": owner}, "close")
            item.update(passed=True, status="passed", results=results, closed=request("/status")["native"])
        except AdmissionSkipped as error:
            item.update(status="skipped", reason=str(error))
        except Exception as error:
            item.update(status="failed", error=repr(error))
            try: call(component, {"owner": owner}, "close", checked=False)
            except Exception: pass
        save(path, report)
        time.sleep(2)
    # Quick completed real requests at the end prevent long inference duration
    # from concealing the original 60s timer accumulation through natural expiry.
    for _ in range(8): call("asr", {"op": "capabilities", "probeBackend": "system"}, checked=False)
    call("asr", {}, "close", checked=False)
    owner = "resource-audit-completed"
    call("qwen", {"op": "open", "owner": owner})
    for _ in range(8): call("qwen", {"op": "open", "owner": owner})
    call("qwen", {"owner": owner}, "close")
    report["final"] = request("/status")
    if args.arm == "after" and report["final"]["native"]["scheduledTimeouts"]:
        raise RuntimeError("Completed request timeout callbacks retained after close")
    report["complete"] = True
    save(path, report)
    print(json.dumps({"arm": args.arm, "asrPassed": asr_result["passed"],
                      "qwen": [{key: item.get(key) for key in ("backend", "passed", "status", "reason", "error")} for item in qwen_results],
                      "scheduledTimeouts": report["final"]["native"]["scheduledTimeouts"]}, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()
