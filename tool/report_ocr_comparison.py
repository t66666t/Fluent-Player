"""Report local OCR timings and time-weighted text errors against our fixture.

Samples every 100 ms. This small synthetic fixture is not an OCR dataset score
and its character error rate also counts late or missing subtitle intervals.
"""
import json
from pathlib import Path
import re
import statistics

ROOT = Path('.artifacts/ocr-upgrade')


def cues(srt):
    result = []
    def milliseconds(value):
        h, m, s, ms = map(int, re.split('[:,]', value))
        return ((h * 60 + m) * 60 + s) * 1000 + ms
    for block in re.split(r'\n\s*\n', srt.strip()):
        lines = block.splitlines()
        if len(lines) >= 3:
            a, b = lines[1].split(' --> ')
            result.append((milliseconds(a), milliseconds(b),
                           ''.join(c for c in ''.join(lines[2:]) if c.isalnum())))
    return result


def distance(a, b):
    previous = list(range(len(b) + 1))
    for i, c in enumerate(a):
        current = [i + 1]
        for j, d in enumerate(b):
            current.append(min(current[-1] + 1, previous[j + 1] + 1,
                               previous[j] + (c != d)))
        previous = current
    return previous[-1]


def score(srt, media_ms, phrases):
    samples = cues(srt)
    errors = characters = 0
    for t in range(50, media_ms, 100):
        expected = phrases[(t % 12000) // 2000]
        actual = next((c for a, b, c in samples if a <= t < b), '')
        errors += distance(expected, actual)
        characters += len(expected)
    return len(samples), errors / characters


def main():
    phrases = json.loads((ROOT / 'fixture/reference.json').read_text(encoding='utf-8'))['phrases']
    report = {}
    for name in ['comparison', 'comparison-cpu']:
        data = json.loads((ROOT / f'{name}.json').read_text(encoding='utf-8'))
        records = []
        for record in data['records']:
            count, rate = score(record['srt'], data['mediaMs'], phrases)
            records.append({**{k: record[k] for k in ['mode', 'regions', 'wallMs', 'peakResidentBytes']},
                            'cues': count, 'sampledCharacterErrorRate': rate})
        report[name] = records
        for regions in sorted({r['regions'] for r in records}):
            before = statistics.mean(r['wallMs'] for r in records if r['regions'] == regions and r['mode'] == 'old')
            after = statistics.mean(r['wallMs'] for r in records if r['regions'] == regions and r['mode'] == 'new')
            print(f'{name}, {regions} region(s): {before:.0f} -> {after:.0f} ms, {1-after/before:.1%} less time')
    report['models'] = []
    for record in json.loads((ROOT / 'model-video-comparison.json').read_text(encoding='utf-8')):
        count, rate = score(record['srt'], 12000, phrases)
        report['models'].append({'modelId': record['modelId'], 'wallMs': record['wallMs'],
                                 'cues': count, 'sampledCharacterErrorRate': rate,
                                 'peakResidentBytes': record['phases']['peakResidentBytes']})
    (ROOT / 'quality-comparison.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
    print(json.dumps(report['models'], indent=2))


if __name__ == '__main__':
    main()
