"""Explicit local CPU comparison; never runs from app startup or downloads files."""
import argparse
import json
from pathlib import Path
import re
import time

import soundfile as sf
from check_qwen_quality import ROOT, Worker


def read_cues(path):
    cues = []
    for block in re.split(r'\r?\n\s*\r?\n', path.read_text(encoding='utf-8-sig').strip()):
        lines = block.splitlines()
        if len(lines) < 3:
            continue
        times = re.findall(r'(\d\d):(\d\d):(\d\d),(\d\d\d)', lines[1])
        def seconds(t):
            return int(t[0])*3600 + int(t[1])*60 + int(t[2]) + int(t[3])/1000
        cues.append(dict(index=int(lines[0]), start=seconds(times[0]), end=seconds(times[1]), text=' '.join(lines[2:])))
    return cues


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--helper', type=Path, required=True)
    parser.add_argument('--audio', type=Path, required=True)
    parser.add_argument('--subtitles', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--threads', type=int, nargs='+', default=[1, 4, 6])
    parser.add_argument('--models', nargs='+', default=['0.6b'])
    parser.add_argument('--align', action='store_true')
    args = parser.parse_args()
    audio, rate = sf.read(args.audio, dtype='float32')
    assert rate == 16000 and audio.ndim == 1
    args.output.mkdir(parents=True, exist_ok=True)
    cues = read_cues(args.subtitles)
    selected = [c for c in cues if c['index'] in (1, 51, 59)]
    report = []
    for model in (['aligner'] if args.align else args.models):
        for threads in args.threads:
            log = (args.output / f'{model}-{threads}.log').open('w', encoding='utf-8')
            worker = Worker(args.helper.resolve(), log)
            filename = 'qwen3-forced-aligner-0.6b-f16.gguf' if args.align else f'qwen3-asr-{model}'+('-f16.gguf' if model == '1.7b' else '.gguf')
            folder = 'asr-qwen3-aligner-0.6b-f16' if args.align else f'qwen3-asr-{model}-f16'
            started = time.perf_counter()
            try:
                loaded = worker.request(op='load', kind='aligner' if args.align else 'asr', model=str(ROOT/'.artifacts/model-center/native'/folder/filename), threads=threads, backend='cpu')
                entry = dict(model=model, threads=threads, loadSeconds=time.perf_counter()-started, build=loaded['build'], samples=[])
                for cue in selected:
                    pcm = args.output/'current.f32'
                    audio[round(cue['start']*rate):round(cue['end']*rate)].astype('<f4').tofile(pcm)
                    started = time.perf_counter()
                    try:
                        value = worker.request(op='align' if args.align else 'decode', path=str(pcm.resolve()), **({'words': re.findall(r"[\w]+(?:['’][\w]+)*", cue['text'])} if args.align else {}))
                    except RuntimeError as error:
                        value = dict(error=str(error))
                    entry['samples'].append(dict(index=cue['index'], seconds=time.perf_counter()-started, audioSeconds=cue['end']-cue['start'], output=value))
                report.append(entry)
                (args.output/'report.json').write_text(json.dumps(report, indent=2, ensure_ascii=False), encoding='utf-8')
                print(model, threads, [round(s['seconds'], 3) for s in entry['samples']], flush=True)
            finally:
                worker.close()
                log.close()


if __name__ == '__main__':
    main()
