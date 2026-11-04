"""Run actual native GPU recognition without loading GPU DLLs in the player."""
import argparse
import array
import json
from pathlib import Path
import subprocess
import time
import wave

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--worker', type=Path, required=True)
parser.add_argument('--model', required=True)
parser.add_argument('--directory', type=Path, required=True)
parser.add_argument('--float', action='store_true')
parser.add_argument('--device', type=int, default=0)
parser.add_argument('--backend', default='directml', choices=['directml', 'cuda', 'coreml', 'nnapi', 'vulkan', 'opencl', 'metal'])
args = parser.parse_args()
root = ROOT / '.artifacts/asr-gpu/smoke'
root.mkdir(parents=True, exist_ok=True)
model = next(m for m in json.loads((ROOT / 'assets/models/catalog.json').read_text(encoding='utf-8'))['models'] if m['id'] == args.model)
source = ROOT / ('assets/models/asr/speech_probe.wav' if 'en' in model['languages'] else 'assets/models/asr/speech_probe_zh.wav')
with wave.open(str(source)) as audio:
    assert audio.getframerate() == 16000 and audio.getnchannels() == 1 and audio.getsampwidth() == 2
    samples = array.array('h', audio.readframes(audio.getnframes()))
pcm = root / ('probe-' + model['id'] + '.f32')
pcm.write_bytes(array.array('f', (n / 32768 for n in samples)).tobytes())
messages = [dict(op='capabilities', id=1), dict(op='load', id=2, engine=model['engine'], modelId=model['id'],
    directory=str(args.directory.resolve()), floatWeights=args.float, backend=args.backend, device=args.device,
    language='en' if 'en' in model['languages'] else 'zh', threads=2, profileRoot=str(root.resolve()))]
messages += [dict(op='decode', id=i, path=str(pcm.resolve())) for i in range(3, 7)]
start = time.perf_counter()
with (root / ('native-' + model['id'] + '-' + args.backend + '.stderr.log')).open('wb') as errors:
    process = subprocess.run([str(args.worker.resolve())], cwd=args.worker.resolve().parent,
        input=''.join(json.dumps(m, ensure_ascii=False) + '\n' for m in messages).encode('utf-8'),
        stdout=subprocess.PIPE, stderr=errors, timeout=240)
replies = [json.loads(line) for line in process.stdout.decode('utf-8').splitlines() if line.startswith('{')]
record = dict(model=model['id'], floating=args.float, device=args.device, backend=args.backend, exitCode=process.returncode,
              elapsedMs=round((time.perf_counter() - start) * 1000), replies=replies)
name = model['id'] + ('-float' if args.float else '-int8') + '-device' + str(args.device)
if args.backend != 'directml': name += '-' + args.backend
(root / (name + '.json')).write_text(json.dumps(record, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
print(json.dumps(record, ensure_ascii=False))
raise SystemExit(0 if process.returncode == 0 and len(replies) == len(messages) and all(r.get('ok') for r in replies) else 1)
