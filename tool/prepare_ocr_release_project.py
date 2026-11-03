"""Copy source inputs into an isolated OCR release project without build state."""
from pathlib import Path
import argparse
import shutil


def main():
    source = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=source / '.artifacts/ocr-upgrade/release-project')
    target = parser.parse_args().output.resolve()
    if target.exists():
        raise SystemExit(f'Isolated project already exists: {target}')
    target.mkdir(parents=True)
    ignored = shutil.ignore_patterns('.git', '.dart_tool', '.gradle', '.cxx',
                                     'build', 'ephemeral', '__pycache__', '*.pyc', 'Vendor',
                                     'key.properties', 'local.properties', '*.jks', '*.keystore',
                                     'GeneratedPluginRegistrant.java')
    for name in ['lib', 'assets', 'android', 'windows', 'native', 'packages',
                 'tool', 'tooling', 'scripts', 'third_party']:
        directory = source / name
        if directory.exists():
            shutil.copytree(directory, target / name, ignore=ignored)
            print(name, flush=True)
    for name in ['pubspec.yaml', 'pubspec.lock', 'analysis_options.yaml', '.metadata',
                 'LICENSE', 'NOTICE', 'THIRD_PARTY_NOTICES.md', 'PRIVACY.md', 'README.md']:
        if (source / name).exists():
            shutil.copy2(source / name, target / name)
    print(target)


if __name__ == '__main__':
    main()
