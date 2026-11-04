"""Fetch checksummed, pinned iOS build inputs. Never runs in the shipped app."""
import argparse
import hashlib
import json
import os
import re
from pathlib import Path
import shutil
import tarfile
import tempfile
import time
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = ROOT / "packages/ios_ytdlp"
VENDOR = PACKAGE / "ios/Vendor"


def download(artifact):
    cache = VENDOR / "cache"
    cache.mkdir(parents=True, exist_ok=True)
    path = cache / artifact["url"].rsplit("/", 1)[1]
    if path.exists() and hashlib.sha256(path.read_bytes()).hexdigest() == artifact["sha256"]:
        return path
    for attempt in range(3):
        try:
            request = urllib.request.Request(artifact["url"], headers={"User-Agent": "FluentPlayer-build/1.0"})
            temp = path.with_suffix(path.suffix + ".partial")
            with urllib.request.urlopen(request, timeout=45) as source, temp.open("wb") as sink:
                shutil.copyfileobj(source, sink)
            if hashlib.sha256(temp.read_bytes()).hexdigest() != artifact["sha256"]:
                raise ValueError("Runtime checksum mismatch: " + path.name)
            os.replace(temp, path)
            print("Verified " + path.name, flush=True)
            return path
        except Exception:
            if attempt == 2:
                raise
            time.sleep(2 ** attempt)


def safe_archive_path(base, name):
    target = (base / name).resolve()
    if not target.is_relative_to(base.resolve()):
        raise ValueError("Archive path outside vendor directory")
    return target


def extract_zip(archive, directory):
    directory.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(archive) as source:
        for member in source.infolist():
            safe_archive_path(directory, member.filename)
        source.extractall(directory)


def prepare_python(archive):
    # CocoaPods can evaluate the Podfile more than once (and Flutter runs pod
    # install again). copytree(..., dirs_exist_ok=True, symlinks=True) still
    # fails with FileExistsError for existing dylib symlinks. Extract into a
    # fresh sibling and move the complete framework instead of merging trees.
    VENDOR.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="python-support-", dir=VENDOR) as temporary:
        python_dir = Path(temporary)
        with tarfile.open(archive) as source:
            links = []
            for member in source.getmembers():
                if not member.name.startswith('Python.xcframework/'):
                    continue
                target = safe_archive_path(python_dir, member.name)
                if member.isdir():
                    target.mkdir(parents=True, exist_ok=True)
                elif member.isfile():
                    target.parent.mkdir(parents=True, exist_ok=True)
                    with source.extractfile(member) as content, target.open('wb') as sink:
                        shutil.copyfileobj(content, sink)
                    target.chmod(member.mode & 0o777)
                elif member.issym():
                    linked = safe_archive_path(python_dir, str(Path(member.name).parent / member.linkname))
                    links.append((target, member.linkname, linked))
                else:
                    raise ValueError('Unsupported archive entry')
            for target, link, linked in links:
                target.parent.mkdir(parents=True, exist_ok=True)
                if os.name == 'nt':
                    shutil.copy2(linked, target)
                else:
                    target.symlink_to(link)
        framework = python_dir / "Python.xcframework"
        if not (framework / "Info.plist").is_file():
            raise ValueError("Python archive is missing Python.xcframework/Info.plist")
        destination = VENDOR / "Python.xcframework"
        if destination.is_symlink():
            destination.unlink()
        elif destination.exists():
            shutil.rmtree(destination)
        framework.rename(destination)


def prepare(packages_only=False):
    manifest = json.loads((PACKAGE / "runtime.lock.json").read_text())
    site = VENDOR / "site-packages"
    staging = VENDOR / "site-packages.preparing"
    # Build from an empty directory so upgraded wheels cannot leave old
    # modules or duplicate dist-info metadata in the shipped runtime.
    if staging.exists():
        shutil.rmtree(staging)
    for wheel in manifest["wheels"]:
        extract_zip(download(wheel), staging)
    if site.exists():
        shutil.rmtree(site)
    staging.rename(site)
    extract_zip(download(manifest["quickjs"]), VENDOR / "quickjs")
    source = (VENDOR / 'quickjs/quickjs-amalgam.c').read_text(encoding='utf-8')
    licenses = list(dict.fromkeys(block for block in re.findall(r'/\*.*?\*/', source, re.S)
        if 'Copyright' in block and 'Permission is hereby granted' in block))
    (VENDOR / 'LICENSE-QuickJS-NG.txt').write_text('\n\n'.join(licenses), encoding='utf-8')
    # One shared downloader keeps Android/iOS progress and artifact validation
    # in step. It is copied at build time, never updated from the network.
    site.mkdir(parents=True, exist_ok=True)
    shutil.copy2(ROOT / "android/app/src/main/python/yt_dlp_bridge.py", site / "yt_dlp_bridge.py")
    shutil.copy2(ROOT / "android/app/src/main/python/fluent_resume.py", site / "fluent_resume.py")
    for source in (PACKAGE / "python").glob("*.py"):
        shutil.copy2(source, site / source.name)
    if packages_only:
        return
    prepare_python(download(manifest["python"]))
    (VENDOR / "prepared.json").write_text(json.dumps(manifest, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--packages-only", action="store_true")
    prepare(parser.parse_args().packages_only)
