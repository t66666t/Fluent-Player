"""Check OCR asset removal and the existing runtime in release artifacts."""
import argparse
import hashlib
import json
from pathlib import Path
import zipfile


def digest(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--project', type=Path, default=Path.cwd())
    parser.add_argument('--apk', type=Path)
    parser.add_argument('--windows', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    result = {}
    if args.apk:
        with zipfile.ZipFile(args.apk) as archive:
            names = archive.namelist()
            prefix = 'assets/flutter_assets/assets/models/'
            weights = [n for n in names if n.startswith(prefix + 'ocr/')]
            assert not weights, weights
            assert prefix + 'ocr_catalog.json' in names
            onnx = [n for n in names if n.startswith('lib/') and n.endswith('/libonnxruntime.so')]
            assert onnx == ['lib/arm64-v8a/libonnxruntime.so'], onnx
            runtime_hash = hashlib.sha256(archive.read(onnx[0])).hexdigest()
            staged = args.project / 'build/generated/asr/jniLibs/arm64-v8a/libonnxruntime.so'
            staged_hash = digest(staged) if staged.exists() else None
            if staged_hash:
                assert staged_hash == runtime_hash
            sherpa = [n for n in names if n.startswith('lib/') and 'sherpa-onnx-c-api' in n]
            assert sherpa, 'Missing shared sherpa runtime'
            result['android'] = {'sha256': digest(args.apk), 'bytes': args.apk.stat().st_size,
                                 'bundledOcrWeights': weights, 'ocrCatalog': True,
                                 'onnxLibraries': onnx, 'runtimeSha256': runtime_hash,
                                 'stagedRuntimeSha256': staged_hash, 'sherpaLibraries': sherpa}
    if args.windows:
        assets = args.windows / 'data/flutter_assets/assets/models'
        weights = [str(p) for p in (assets / 'ocr').rglob('*') if p.is_file()]
        assert not weights, weights
        assert (assets / 'ocr_catalog.json').is_file()
        runtime = digest(args.windows / 'onnxruntime.dll')
        original = digest(args.project / 'windows/runtime/onnxruntime.dll')
        assert runtime == original
        result['windows'] = {'executableSha256': digest(args.windows / 'fluent_player_community.exe'),
                             'appSha256': digest(args.windows / 'data/app.so'),
                             'bundledOcrWeights': weights, 'ocrCatalog': True,
                             'runtimeSha256': runtime, 'originalRuntimeSha256': original}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2), encoding='utf-8')
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
