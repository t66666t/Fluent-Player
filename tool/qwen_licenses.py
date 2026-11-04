"""Collect the locked Rust dependency notices and embedded dictionary licenses."""
import json
from pathlib import Path
import subprocess
import tarfile


def collect(cargo, env, native, target_dir, triple, lock, sha, lindera_archive):
    metadata = json.loads(subprocess.check_output(
        [cargo, 'metadata', '--locked', '--format-version', '1',
         '--manifest-path', str(native / 'text/Cargo.toml')], env=env))
    sections = ['Qwen audio runtime and Japanese/Korean text processing\n'
                'Qwen3-ASR / Qwen3-ForcedAligner: Alibaba Qwen, Apache-2.0.\n'
                'ECAPA VoxLingua107: SpeechBrain / Tallinn University of Technology, Apache-2.0.\n'
                'GGUF exports: cstr; source revisions and checksums are in the model catalog.\n'
                'No soynlp, Galgame fine-tune or Python inference runtime is distributed.\n'
                'The following notices apply to this optional native component.\n']
    import zipfile
    with zipfile.ZipFile(lindera_archive) as package:
        name = next(n for n in package.namelist() if n.count('/') == 1 and n.endswith('/LICENSE'))
        lindera_license = package.read(name).decode('utf-8')
    for item in sorted(metadata['packages'], key=lambda p: (p['name'], p['version'])):
        if item['name'] == 'fluent-asr-text':
            continue
        directory = Path(item['manifest_path']).parent
        sections.append(f"\n=== {item['name']} {item['version']} ({item.get('license')}) ===\n"
                        f"{item.get('repository') or item.get('homepage') or item['source']}\n")
        notices = [p for p in directory.iterdir() if p.is_file() and
                   p.name.upper().startswith(('LICENSE', 'COPYING', 'NOTICE', 'UNLICENSE'))]
        if not notices and item['name'].startswith('lindera'):
            sections.append(lindera_license)
        elif not notices:
            # Some published crates put their license under a subdirectory.
            notices = [p for p in directory.rglob('*') if p.is_file() and
                       p.name.upper().startswith(('LICENSE', 'COPYING', 'NOTICE', 'UNLICENSE'))]
        if not notices and not item['name'].startswith('lindera'):
            raise ValueError('Missing dependency license text: ' + item['name'])
        for path in sorted(notices):
            sections.append(path.read_text(encoding='utf-8', errors='strict'))
    for filename, expected in lock['dictionaries'].items():
        path = next((target_dir / triple / 'release/build').rglob(filename))
        if sha(path) != expected:
            raise ValueError('Embedded dictionary differs from reviewed source: ' + filename)
        with tarfile.open(path) as package:
            name = next(n for n in package.getnames() if n.endswith('/COPYING'))
            value = package.extractfile(name).read()
            try:
                notice = value.decode('utf-8')
            except UnicodeDecodeError:
                # This pinned IPADIC COPYING is English ASCII with two trailing
                # 0xf7 separator bytes; latin-1 preserves every original byte.
                notice = value.decode('latin-1')
            sections.append('\n=== ' + filename + ' ===\n' + notice)
    return '\n'.join(sections)
