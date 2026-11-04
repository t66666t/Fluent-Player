"""Measure legacy transcoding versus packet copy using generated speech only.

Usage: python tool/gongyi_audio_benchmark.py <synthetic.m4a> <output-directory>
Outputs remain local; the separate opt-in Dart probe exercises the real service.
"""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import time


def main():
    source = Path(sys.argv[1]).resolve(strict=True)
    output = Path(sys.argv[2]).resolve()
    output.mkdir(parents=True, exist_ok=True)
    bundled = Path(__file__).resolve().parents[1] / "assets/binaries/windows/ffmpeg.exe"
    ffmpeg = str(bundled) if bundled.exists() else shutil.which("ffmpeg")
    ffprobe = shutil.which("ffprobe")

    def run(arguments):
        return subprocess.run(arguments, check=True, capture_output=True, text=True)

    def info(path):
        return json.loads(run([ffprobe, "-v", "error", "-show_streams",
                               "-show_format", "-of", "json", str(path)]).stdout)

    def audio_hash(path):
        return run([ffmpeg, "-v", "error", "-i", str(path), "-map", "0:a:0",
                    "-c:a", "copy", "-f", "hash", "-hash", "sha256", "-"]).stdout.strip()

    original_hash = hashlib.sha256(source.read_bytes()).hexdigest()
    video = output / "benchmark-video.mp4"
    run([ffmpeg, "-y", "-hide_banner", "-loglevel", "error", "-f", "lavfi",
         "-i", "color=size=16x16:rate=1", "-i", str(source), "-map", "0:v:0",
         "-map", "1:a:0", "-c:v", "mpeg4", "-c:a", "copy", "-shortest", str(video)])
    duration = float(info(source)["format"]["duration"])
    results = {}
    for name, options in [
        ("legacy-transcode", ["-c:a", "aac", "-ac", "1", "-ar", "16000",
                              "-b:a", "48k", "-threads", "1"]),
        ("optimized-copy", ["-c:a", "copy"]),
    ]:
        target = output / f"{name}.m4a"
        started = time.perf_counter()
        run([ffmpeg, "-y", "-nostdin", "-hide_banner", "-loglevel", "error",
             "-t", str(duration), "-i", str(video), "-map", "0:a:0", "-vn",
             "-sn", "-dn", *options, str(target)])
        elapsed = time.perf_counter() - started
        metadata = info(target)
        stream = metadata["streams"][0]
        results[name] = {"seconds": round(elapsed, 6), "bytes": target.stat().st_size,
                         "sampleRate": stream["sample_rate"], "channels": stream["channels"],
                         "duration": float(metadata["format"]["duration"])}

    source_packet_hash = audio_hash(video)
    copied_packet_hash = audio_hash(output / "optimized-copy.m4a")
    assert source_packet_hash == copied_packet_hash, "Audio packets changed during copy"
    assert hashlib.sha256(source.read_bytes()).hexdigest() == original_hash
    report = {
        "syntheticSource": source.name,
        "durationSeconds": duration,
        "sourceBytes": source.stat().st_size,
        "results": results,
        "preparationSpeedup": round(results["legacy-transcode"]["seconds"] /
                                     results["optimized-copy"]["seconds"], 2),
        "audioPacketsUnchanged": True,
        "sourceUnchanged": True,
        "directAudioPath": "No FFmpeg process or temporary copy is needed.",
    }
    (output / "benchmark.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
