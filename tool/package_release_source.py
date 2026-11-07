"""Export the current application source, without Git history or private inputs.

This is the application archive, not a claim that third-party native
Corresponding Source has been collected. See docs/releasing.md.
"""
import argparse
import fnmatch
import hashlib
import json
from pathlib import Path
import subprocess
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--snapshot', type=Path,
                        help='Read a frozen source mirror using this worktree\'s Git file inventory.')
    args = parser.parse_args()
    source = args.snapshot.resolve() if args.snapshot else ROOT
    output = args.output.resolve()
    files = subprocess.check_output(
        ['git', 'ls-files', '-z', '--cached', '--others', '--exclude-standard'], cwd=ROOT
    ).decode('utf-8').split('\0')
    head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    output.parent.mkdir(parents=True, exist_ok=True)
    records, prepared = {}, {}
    with zipfile.ZipFile(output, 'x', compression=zipfile.ZIP_DEFLATED) as archive:
        for relative in sorted(set(filter(None, files))):
            path = source / relative
            if not path.is_file() or path.resolve() == output:
                continue
            if relative.startswith(('.artifacts/', 'build/', '.dart_tool/')):
                continue
            if any(fnmatch.fnmatch(path.name, pattern) for pattern in
                   ['key.properties', '*.jks', '*.keystore', '*.p12', '*.pfx', 'MiSans-*.otf',
                    'NotoSerifCJKsc-*.otf',
                    'NotoSansCJKsc-Thin.otf', 'NotoSansCJKsc-DemiLight.otf',
                    'NotoSansCJKsc-Light.otf', 'NotoSansCJKsc-Medium.otf',
                    'NotoSansCJKsc-Bold.otf', 'NotoSansCJKsc-Black.otf',
                    '_extract_notes.py', '_yt_audio_task_notes.txt']):
                continue
            if (relative.startswith(('assets/binaries/', 'windows/runtime/',
                                     'windows/ffmpeg_kit_prebuilt/')) or
                    '/prebuilt/' in relative or path.suffix.lower() in {'.whl', '.onnx', '.gguf'}):
                prepared[relative] = hashlib.sha256(path.read_bytes()).hexdigest()
                continue
            data = path.read_bytes()
            records[relative] = hashlib.sha256(data).hexdigest()
            archive.writestr(relative, data)
        archive.writestr('source-snapshot.json', json.dumps({
            'head': head, 'includesWorkingChanges': True,
            'frozenSnapshot': args.snapshot is not None, 'files': records,
            'separatelyPreparedInputs': prepared,
            'note': 'Application sources only; third-party native Corresponding Source is separate.',
        }, indent=2, ensure_ascii=False))
    print(f'{output}: {len(records)} application source/resource files')


if __name__ == '__main__':
    main()
