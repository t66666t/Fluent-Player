"""Package the community Windows runtime from CMake's explicit file lists.

This creates local ZIP/installer artifacts only. It neither installs nor publishes.
"""
from __future__ import annotations

import argparse
from collections.abc import Callable, Iterable
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import uuid
import zipfile

from release_metadata import ROOT, prefix, read_version, write_platform_manifest

RUNNER = "fluent-player.exe"
REQUIRED = frozenset({RUNNER, "flutter_windows.dll", "onnxruntime.dll",
    "data/app.so", "data/icudtl.dat", "data/flutter_assets/AssetManifest.bin",
    "msvcp140.dll", "vcruntime140.dll", "vcruntime140_1.dll"})
SYMBOL_SUFFIXES = frozenset({".pdb", ".ilk", ".lib", ".exp", ".map", ".obj"})
NOTICES = frozenset({"LICENSE", "NOTICE", "THIRD_PARTY_NOTICES.md", "PRIVACY.md"})
USER_PARTS = frozenset({"communityplayerdata", "videoplayerdata", "composedvideos",
    "downloads", "web_media_browser", "douyin_browser", "shared_preferences.json",
    "library.json", "library.json.bak", "layout.json", "storage_runtime_registry.json"})
# These are supplied by Windows or the GPU driver, never copied from a user's PC.
# Optional acceleration modules are loaded only after the existing capability checks.
DRIVER_DLLS = frozenset({"nvcuda.dll", "nvml.dll", "vulkan-1.dll", "opencl.dll"})
DEBUG_CRT = re.compile(r"^(?:(?:msvcp|msvcr|vcruntime|concrt)[0-9][a-z0-9_]*d|ucrtbased)\.dll$")
VC_RUNTIME = re.compile(r"^(?:msvcp|msvcr|vcruntime|concrt|vccorlib|vcomp)[0-9][a-z0-9_]*\.dll$")


def pe_dependencies(path: Path) -> set[str]:
    """Read ordinary and delay-import DLL names from a PE32/PE32+ image."""
    data = path.read_bytes()
    def integer(offset: int, width: int = 4) -> int:
        if offset < 0 or offset + width > len(data):
            raise ValueError(f"Truncated PE image: {path.name}")
        return int.from_bytes(data[offset:offset + width], "little")
    if data[:2] != b"MZ":
        raise ValueError(f"Not a Windows PE image: {path.name}")
    pe = integer(0x3c)
    if data[pe:pe + 4] != b"PE\0\0":
        raise ValueError(f"Invalid PE signature: {path.name}")
    sections, optional_size = integer(pe + 6, 2), integer(pe + 20, 2)
    optional = pe + 24
    magic = integer(optional, 2)
    if magic not in (0x10b, 0x20b):
        raise ValueError(f"Unsupported PE image: {path.name}")
    directory = optional + (96 if magic == 0x10b else 112)
    directory_count = integer(directory - 4)
    image_base = integer(optional + (28 if magic == 0x10b else 24), 4 if magic == 0x10b else 8)
    table = optional + optional_size
    headers = integer(optional + 60)
    def offset(rva: int) -> int:
        if rva < headers and rva < len(data):
            return rva
        for index in range(sections):
            section = table + index * 40
            size, address = integer(section + 8), integer(section + 12)
            raw_size, raw = integer(section + 16), integer(section + 20)
            if address <= rva < address + max(size, raw_size):
                delta = rva - address
                if delta >= raw_size or raw + delta >= len(data):
                    break
                return raw + delta
        raise ValueError(f"Invalid PE import address: {path.name}")
    names = set()
    for number, stride in ((1, 20), (13, 32)):
        if directory_count <= number:
            continue
        address, size = integer(directory + number * 8), integer(directory + number * 8 + 4)
        if not address or not size:
            continue
        start = offset(address)
        terminated = False
        for position in range(start, start + size, stride):
            if position + stride > len(data):
                raise ValueError(f"Truncated PE import table: {path.name}")
            if not any(data[position:position + stride]):
                terminated = True
                break
            name_rva = integer(position + (12 if number == 1 else 4))
            if number == 13 and not integer(position) & 1:
                name_rva -= image_base
            name_start = offset(name_rva)
            name_end = data.find(b"\0", name_start, min(len(data), name_start + 512))
            if name_end < 0:
                raise ValueError(f"Invalid PE dependency name: {path.name}")
            name = data[name_start:name_end].decode("ascii", errors="strict")
            if not re.fullmatch(r"[a-zA-Z0-9_.+-]+\.dll", name, re.I):
                raise ValueError(f"Unsafe PE dependency name: {path.name}")
            names.add(name.lower())
        if not terminated:
            raise ValueError(f"Unterminated PE import table: {path.name}")
    return names


def _reparse(path: Path) -> bool:
    return path.is_symlink() or bool(getattr(path.lstat(), "st_file_attributes", 0) & 0x400)


def _runtime_name(relative: str) -> bool:
    """Allow compiled/runtime assets only; symbols are deliberately omitted."""
    parts = Path(relative).parts
    lower = relative.lower()
    retained_notice = lower.startswith("data/flutter_assets/assets/licenses/") and Path(relative).suffix.lower() in {".txt", ".md", ".html"}
    if any(part in ("..", ".") or part.startswith(".") for part in parts):
        raise ValueError(f"Unsafe runtime path: {relative}")
    if any(part.lower() in USER_PARTS for part in parts):
        raise ValueError(f"User data cannot be packaged: {relative}")
    if DEBUG_CRT.fullmatch(Path(relative).name.lower()):
        raise ValueError(f"Developer-only debug runtime cannot be packaged: {relative}")
    if (not retained_notice and (any(token in lower for token in ("yt-dlp", "yt_dlp", "ytdlp", "webview", "curl_cffi"))
            or re.search(r"(?:^|/)python[^/]*\.(?:exe|dll)$", lower)
            or Path(relative).suffix.lower() in {".py", ".pyc", ".pyd"})):
        raise ValueError(f"Retired website runtime cannot be packaged: {relative}")
    if Path(relative).suffix.lower() in SYMBOL_SUFFIXES:
        return False
    if len(parts) == 1:
        if relative in NOTICES or relative == "native_assets.json" or Path(relative).suffix.lower() in {".exe", ".dll"}:
            return True
    elif parts[0] == "resources" or relative in {"data/app.so", "data/icudtl.dat"} or parts[:2] == ("data", "flutter_assets"):
        return True
    raise ValueError(f"Unexpected non-runtime file in CMake manifest: {relative}")


def stage_runtime(source: Path, manifest: Path, runtime_manifest: Path, destination: Path,
                  *, dependency_reader: Callable[[Path], Iterable[str]] = pe_dependencies,
                  system_directories: Iterable[Path] | None = None) -> dict:
    """Validate all inputs first, then copy only the declared runtime files."""
    source = source.resolve(strict=True)
    destination = destination.resolve()
    if destination.exists() or source == destination or source in destination.parents or destination in source.parents:
        raise ValueError("Staging destination must be new and disjoint from the build directory")
    if not source.is_dir() or _reparse(source):
        raise ValueError("Runtime source must be a real build directory")
    files: dict[str, Path] = {}
    names: dict[str, str] = {}
    def include(path: Path):
        if not path.is_relative_to(source) or ".." in path.parts:
            raise ValueError(f"CMake entry escapes the build directory: {path.name}")
        resolved = path.resolve(strict=True)
        if not resolved.is_relative_to(source) or not resolved.is_file():
            raise ValueError(f"CMake entry escapes the build directory: {path.name}")
        cursor = path
        while cursor != source:
            if _reparse(cursor):
                raise ValueError(f"Reparse points are not package inputs: {path.name}")
            cursor = cursor.parent
        relative = resolved.relative_to(source).as_posix()
        if not _runtime_name(relative):
            return
        key = relative.lower()
        if key in names and names[key] != relative:
            raise ValueError(f"Case-colliding package paths: {relative}")
        names[key] = relative
        files[relative] = resolved
    for line in manifest.read_text(encoding="utf-8-sig").splitlines():
        if line.strip():
            path = Path(line.strip())
            if not path.is_absolute():
                raise ValueError("CMake install manifest entries must be absolute paths")
            include(path)
    for line in runtime_manifest.read_text(encoding="utf-8-sig").splitlines():
        if not line.strip():
            continue
        name = Path(line.strip()).name
        if not re.fullmatch(r"[a-zA-Z0-9_.+ -]+\.(?:dll|exe)", name, re.I):
            raise ValueError(f"Unexpected runtime target: {name}")
        include(source / name)
    missing = REQUIRED - files.keys()
    if missing:
        raise ValueError("Required runtime absent from CMake manifests: " + ", ".join(sorted(missing)))
    for name in NOTICES:
        if name not in files:
            raise ValueError(f"Required distribution notice absent from CMake manifests: {name}")
    system_directories = list(system_directories) if system_directories is not None else [Path(os.environ.get("SystemRoot", "C:/Windows")) / "System32"]
    driver_dependencies = set()
    for relative, path in files.items():
        if path.suffix.lower() not in {".exe", ".dll"}:
            continue
        parent = Path(relative).parent
        for dependency in dependency_reader(path):
            dependency = dependency.lower()
            if DEBUG_CRT.fullmatch(dependency):
                raise ValueError(f"Developer-only debug dependency: {relative} -> {dependency}")
            local = (parent / dependency).as_posix().lower()
            candidates = (local,) if VC_RUNTIME.fullmatch(dependency) else (local, dependency)
            if any(candidate in names for candidate in candidates):
                continue
            if VC_RUNTIME.fullmatch(dependency):
                raise ValueError(f"Missing app-local VC runtime beside native importer: {relative} -> {dependency}")
            if dependency.startswith(("api-ms-win-", "ext-ms-win-")):
                continue
            if dependency in DRIVER_DLLS:
                driver_dependencies.add(dependency)
                continue
            if any((directory / dependency).is_file() for directory in system_directories):
                continue
            raise ValueError(f"Missing or unlisted native dependency: {relative} -> {dependency}")
    destination.mkdir(parents=True)
    for relative, path in sorted(files.items()):
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, target)
    return {"files": len(files), "bytes": sum(path.stat().st_size for path in files.values()),
            "systemDriverDependencies": sorted(driver_dependencies)}


def verify_identity(executable: Path, version: dict) -> None:
    environment = dict(os.environ, FLUENT_PACKAGE_EXECUTABLE=str(executable.resolve(strict=True)))
    command = ('$v=(Get-Item -LiteralPath $env:FLUENT_PACKAGE_EXECUTABLE).VersionInfo; '
        '@{company=$v.CompanyName; product=$v.ProductName; description=$v.FileDescription; '
        'version="$($v.FileMajorPart).$($v.FileMinorPart).$($v.FileBuildPart)"; '
        'build=$v.FilePrivatePart; debug=$v.IsDebug} | ConvertTo-Json -Compress')
    result = subprocess.run(["powershell.exe", "-NoProfile", "-NonInteractive", "-Command", command],
        check=True, capture_output=True, text=True, encoding="utf-8-sig", env=environment)
    info = json.loads(result.stdout)
    if (info.get("company") != "Teezy Community" or info.get("product") != "Fluent Player"
            or info.get("description") != "Fluent Player" or info.get("debug") is not False
            or info.get("version") != version["version"] or info.get("build") != version["buildNumber"]):
        raise ValueError("Build the current, non-debug community Windows release before packaging")


def stage_only(source: Path, manifest: Path, runtime_manifest: Path, stage: Path) -> dict:
    """Apply the same metadata/import checks without producing release artifacts."""
    source = source.resolve(strict=True)
    verify_identity(source / RUNNER, read_version())
    report = stage_runtime(source, manifest, runtime_manifest, stage)
    return {**report, "mode": "stage-only", "stage": str(stage.resolve())}


def package(source: Path, manifest: Path, runtime_manifest: Path, output: Path,
            iscc: Path, stage: Path) -> dict:
    source, output = source.resolve(strict=True), output.resolve()
    stage = stage.resolve()
    if source == output or source in output.parents or output in source.parents:
        raise ValueError("Release output must be disjoint from the build directory")
    if stage == output or stage in output.parents or output in stage.parents:
        raise ValueError("Staging and release output directories must be disjoint")
    version = read_version()
    base = prefix("windows", "x64")
    archive, installer = output / (base + "-portable.zip"), output / (base + "-setup.exe")
    if archive.exists() or installer.exists():
        raise ValueError("Versioned release artifacts already exist; choose a fresh output directory")
    if not iscc.is_file():
        raise ValueError("Pass --iscc with an installed Inno Setup compiler")
    verify_identity(source / RUNNER, version)
    report = stage_runtime(source, manifest, runtime_manifest, stage)
    output.mkdir(parents=True, exist_ok=True)
    subprocess.run([str(iscc.resolve()), f"/DAppVersion={version['version']}",
        f"/DBundleDir={stage.resolve()}", f"/DOutputDir={output}",
        str(ROOT / "packaging/windows/fluent-player.iss")], check=True)
    if not installer.is_file() or installer.stat().st_size == 0:
        raise ValueError("Inno Setup did not produce the expected edition/version installer")
    with zipfile.ZipFile(archive, "x", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as bundle:
        for path in sorted(stage.rglob("*")):
            if path.is_file():
                bundle.write(path, path.relative_to(stage).as_posix())
    write_platform_manifest(output, "windows", "x64", "unsigned")
    return {**report, "zip": str(archive), "installer": str(installer)}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=ROOT / "build/windows/x64/runner/Release")
    parser.add_argument("--manifest", type=Path, default=ROOT / "build/windows/x64/install_manifest.txt")
    parser.add_argument("--runtime-manifest", type=Path, default=ROOT / "build/windows/x64/runtime_files_Release.txt")
    parser.add_argument("--output", type=Path, default=ROOT / "dist/windows")
    parser.add_argument("--iscc", type=Path, default=Path(os.environ.get("ProgramFiles(x86)", "C:/Program Files (x86)")) / "Inno Setup 6/ISCC.exe")
    parser.add_argument("--stage", type=Path, default=ROOT / ".artifacts/windows-package" / uuid.uuid4().hex)
    parser.add_argument("--stage-only", action="store_true",
        help="Validate release metadata/imports and collect the runtime; no Inno Setup, ZIP, installer or release manifest")
    args = parser.parse_args()
    try:
        if args.stage_only:
            report = stage_only(args.source, args.manifest, args.runtime_manifest, args.stage)
        else:
            report = package(args.source, args.manifest, args.runtime_manifest, args.output, args.iscc, args.stage)
    except (ValueError, OSError, UnicodeError, struct.error, subprocess.SubprocessError) as error:
        parser.exit(1, f"Community Windows packaging failed: {error}\n")
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
