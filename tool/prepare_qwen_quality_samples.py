"""Explicitly prepare a fixed FLEURS dev subset for maintainer ASR comparisons.

Not called by the application. Audio is CC-BY-4.0, google/fleurs at the revision
below. Select distinct utterances in archive order, preserving the transcripts.
"""
import csv
import hashlib
import io
import json
from pathlib import Path
import tarfile
from urllib.request import urlopen
import wave
import numpy as np
import soundfile as sf

ROOT = Path(__file__).resolve().parents[1]
REVISION = '70bb2e84b976b7e960aa89f1c648e09c59f894dd'


def main():
    output = ROOT / '.artifacts/qwen-integration/quality'
    output.mkdir(parents=True, exist_ok=True)
    manifest = []
    for locale, language, count in [('ja_jp', 'ja', 20), ('ko_kr', 'ko', 20),
                                    ('en_us', 'en', 4), ('cmn_hans_cn', 'zh', 4)]:
        prefix = f'https://huggingface.co/datasets/google/fleurs/resolve/{REVISION}/data/{locale}'
        with urlopen(prefix + '/dev.tsv', timeout=90) as response:
            tsv = response.read()
        (output / (locale + '.tsv')).write_bytes(tsv)
        rows = {row[1]: row for row in csv.reader(io.StringIO(tsv.decode('utf-8')), delimiter='\t')}
        selected, seen = [], set()
        cached = output / (locale + '.json')
        if cached.exists():
            selected = json.loads(cached.read_text(encoding='utf-8'))
        else:
            with urlopen(prefix + '/audio/dev.tar.gz', timeout=180) as response:
                with tarfile.open(fileobj=response, mode='r|gz') as archive:
                    for member in archive:
                        name = member.name.rsplit('/', 1)[-1]
                        row = rows.get(name)
                        if not member.isfile() or not row or row[0] in seen:
                            continue
                        if int(row[-2]) > 24 * 16000 or int(row[-2]) < 16000:
                            continue
                        audio = archive.extractfile(member).read()
                        path = output / f'{language}-{len(selected):02}.wav'
                        path.write_bytes(audio)
                        selected.append({'id': path.stem, 'language': language,
                                         'path': path.as_posix(), 'reference': row[2],
                                         'source': name, 'sha256': hashlib.sha256(audio).hexdigest()})
                        seen.add(row[0])
                        if len(selected) == count:
                            break
            if len(selected) != count:
                raise ValueError('Incomplete fixed sample set: ' + locale)
            cached.write_text(json.dumps(selected, ensure_ascii=False, indent=2), encoding='utf-8')
        manifest.extend(selected)
        print(locale, len(selected), flush=True)
    # Deterministic instrumental background music stress: 12 dB SNR, no voices.
    for language in ['ja', 'ko']:
        source = next(item for item in manifest if item['language'] == language)
        samples, rate = sf.read(source['path'], dtype='float32')
        assert rate == 16000 and samples.ndim == 1
        t = np.arange(len(samples)) / 16000
        music = sum(np.sin(t * 2 * np.pi * frequency) for frequency in [220, 277.18, 329.63, 440])
        music *= (np.sqrt(np.mean(samples**2)) / max(np.sqrt(np.mean(music**2)), 1e-8)) / 10**(.6)
        mixed = np.clip(samples + music, -.999, .999)
        path = output / (language + '-bgm.wav')
        with wave.open(str(path), 'wb') as wav:
            wav.setparams((1, 2, 16000, 0, 'NONE', 'not compressed'))
            wav.writeframes((mixed * 32767).astype('<i2').tobytes())
        manifest.append({**source, 'id': path.stem, 'path': path.as_posix(),
                         'sha256': hashlib.sha256(path.read_bytes()).hexdigest(), 'stress': 'synthetic-music-12dB'})
    (output / 'samples.json').write_text(json.dumps({'dataset': 'google/fleurs', 'revision': REVISION,
        'license': 'CC-BY-4.0', 'split': 'dev', 'samples': manifest}, ensure_ascii=False, indent=2), encoding='utf-8')


if __name__ == '__main__':
    main()
