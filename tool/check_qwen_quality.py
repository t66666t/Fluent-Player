"""Explicit official-reference / native FP16 quality and timing comparison.

Requires prepared sample/weight files. No downloads or runtime installation.
Reference mode requires the separately prepared official Qwen Python source.
"""
import argparse
import gc
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import unicodedata
import numpy as np
import soundfile as sf

ROOT = Path(__file__).resolve().parents[1]
WORK = ROOT / '.artifacts/qwen-integration'


def normalized(text, words=False):
    value = unicodedata.normalize('NFKC', text).lower()
    value = ''.join(c for c in value if not unicodedata.category(c).startswith(('P', 'S')))
    return value.split() if words else list(''.join(value.split()))


def distance(a, b):
    row = list(range(len(b) + 1))
    for i, x in enumerate(a):
        new = [i + 1]
        for j, y in enumerate(b):
            new.append(min(new[-1] + 1, row[j + 1] + 1, row[j] + (x != y)))
        row = new
    return row[-1]


class Worker:
    def __init__(self, executable, log):
        self.process = subprocess.Popen([str(executable)], cwd=executable.parent,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log,
            text=True, encoding='utf-8', creationflags=0x08000000 if os.name == 'nt' else 0)

    def request(self, **value):
        self.process.stdin.write(json.dumps(value, ensure_ascii=False) + '\n')
        self.process.stdin.flush()
        line = self.process.stdout.readline()
        if not line:
            raise RuntimeError('Native worker exited: ' + str(self.process.poll()))
        result = json.loads(line)
        if not result.get('ok'):
            raise RuntimeError(result.get('error'))
        return result

    def close(self):
        self.process.stdin.close()
        try:
            self.process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--mode', choices=['reference', 'native'], required=True)
    parser.add_argument('--model', choices=['0.6B', '1.7B'], required=True)
    parser.add_argument('--backend', default='cpu', choices=['cpu', 'vulkan', 'cuda', 'metal'])
    parser.add_argument('--limit', type=int)
    parser.add_argument('--threads', type=int, default=6)
    args = parser.parse_args()
    data = json.loads((WORK/'quality/samples.json').read_text(encoding='utf-8'))
    samples = data['samples'][:args.limit]
    report_path = WORK/'quality'/f'{args.mode}-{args.model}-{args.backend}.json'
    report = {'mode': args.mode, 'model': args.model, 'backend': args.backend,
              'samplesRevision': data['revision'], 'results': []}
    if report_path.exists():
        report = json.loads(report_path.read_text(encoding='utf-8'))
    model = worker = None
    started = time.perf_counter()
    if args.mode == 'reference':
        source = WORK/'reference/Qwen3-ASR-7c6daf77a2421100f5fb066495372c00129d39ff'
        sys.path.insert(0, str(source))
        import torch
        from qwen_asr import Qwen3ASRModel
        torch.set_num_threads(args.threads)
        entries = json.loads((WORK/'reference/models.json').read_text(encoding='utf-8'))
        entry = entries['Qwen/Qwen3-ASR-' + args.model]
        model = Qwen3ASRModel.from_pretrained(entry['path'], dtype=torch.float16,
            device_map='cpu', attn_implementation='sdpa', max_inference_batch_size=1,
            max_new_tokens=512, local_files_only=True)
        report['referenceRevision'] = entry['revision']
    else:
        executable = ROOT/'native/qwen_asr/prebuilt/windows-x64/qwen_asr_worker.exe'
        log = (WORK/'quality'/f'native-{args.model}-{args.backend}.stderr.log').open('w', encoding='utf-8')
        worker = Worker(executable, log)
        report['capabilities'] = worker.request(op='capabilities')
        filename = 'qwen3-asr-0.6b.gguf' if args.model == '0.6B' else 'qwen3-asr-1.7b-f16.gguf'
        weight = WORK.parent/'model-center/native'/('qwen3-asr-'+args.model.lower()+'-f16')/filename
        report['load'] = worker.request(op='load', kind='asr', model=str(weight), backend=args.backend, threads=args.threads)
    report['loadSeconds'] = time.perf_counter() - started
    try:
        for sample in samples:
            if any(r['id'] == sample['id'] for r in report['results']):
                continue
            audio, rate = sf.read(sample['path'], dtype='float32')
            assert rate == 16000 and audio.ndim == 1
            begin = time.perf_counter()
            if worker:
                pcm = WORK/'quality'/f'current-{args.model}-{args.backend}.f32'
                audio.astype('<f4').tofile(pcm)
                output = worker.request(op='decode', path=str(pcm))['result']
                text, language = output['text'], output['lang']
                gpu_ops = output.get('gpuOperators', 0)
                if args.backend != 'cpu' and gpu_ops <= 0:
                    raise RuntimeError('No GPU operators executed')
            else:
                result = model.transcribe((audio, 16000))[0]
                text, language, gpu_ops = result.text, result.language, 0
            hypothesis = normalized(text)
            reference = normalized(sample['reference'])
            item = {'id': sample['id'], 'language': sample['language'], 'detected': language,
                    'text': text, 'reference': sample['reference'], 'seconds': len(audio)/16000,
                    'elapsed': time.perf_counter()-begin, 'gpuOperators': gpu_ops,
                    'charErrors': distance(reference, hypothesis), 'characters': len(reference),
                    'wordErrors': distance(normalized(sample['reference'], True), normalized(text, True)),
                    'words': len(normalized(sample['reference'], True))}
            report['results'].append(item)
            report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
            print(args.mode, args.model, item['id'], round(item['elapsed'], 2), flush=True)
    finally:
        if worker:
            worker.close()
            log.close()
        del model
        gc.collect()


if __name__ == '__main__':
    main()
