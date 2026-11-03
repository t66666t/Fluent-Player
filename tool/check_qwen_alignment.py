"""Compare native and official FP16 alignment using identical Lindera units.

The official reference tokenizer is replaced only at this test's input boundary;
the official feature extractor, model forward and timestamp parsing are retained.
Native invalid-order results must fall back rather than synthesize word times.
"""
import argparse
import json
from pathlib import Path
import sys
import time
import numpy as np
import soundfile as sf
from check_qwen_quality import ROOT, WORK, Worker


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--backend', choices=['cpu', 'vulkan'], default='cpu')
    args = parser.parse_args()
    sys.path.insert(0, str(WORK/'reference/Qwen3-ASR-7c6daf77a2421100f5fb066495372c00129d39ff'))
    import torch
    from qwen_asr import Qwen3ForcedAligner
    torch.set_num_threads(4)
    entry = json.loads((WORK/'reference/models.json').read_text(encoding='utf-8'))['Qwen/Qwen3-ForcedAligner-0.6B']
    official = Qwen3ForcedAligner.from_pretrained(entry['path'], dtype=torch.float16,
        device_map='cpu', attn_implementation='sdpa', local_files_only=True)
    log = (WORK/'quality'/f'alignment-{args.backend}.stderr.log').open('w', encoding='utf-8')
    worker = Worker(ROOT/'native/qwen_asr/prebuilt/windows-x64/qwen_asr_worker.exe', log)
    report = {'backend': args.backend, 'officialRevision': entry['revision'], 'results': []}
    output = WORK/'quality'/f'alignment-{args.backend}.json'
    if output.exists():
        report = json.loads(output.read_text(encoding='utf-8'))
    try:
        report['load'] = worker.request(op='load',kind='aligner',backend=args.backend,threads=4,
            model=str(WORK.parent/'model-center/native/asr-qwen3-aligner-0.6b-f16/qwen3-forced-aligner-0.6b-f16.gguf'))
        samples = json.loads((WORK/'quality/samples.json').read_text(encoding='utf-8'))['samples']
        for sample in samples:
            if any(item['id'] == sample['id'] for item in report['results']):
                continue
            audio, rate = sf.read(sample['path'],dtype='float32')
            assert rate == 16000
            pcm = WORK/'quality'/f'align-{args.backend}.f32'
            audio.astype('<f4').tofile(pcm)
            language = sample['language']
            if language in ('ja','ko'):
                units = worker.request(op='tokenize',text=sample['reference'],language=language)['units']
                words = [word['text'] for word in units]
            else:
                words,_ = official.aligner_processor.encode_timestamp(sample['reference'],
                    'Chinese' if language == 'zh' else 'English')
            official.aligner_processor.ko_tokenizer = object()
            official.aligner_processor.tokenize_japanese = lambda _: words
            official.aligner_processor.tokenize_korean = lambda *_: words
            name = {'ja':'Japanese','ko':'Korean','zh':'Chinese','en':'English'}[language]
            input_words, text = official.aligner_processor.encode_timestamp(' '.join(words),name)
            assert input_words == words
            inputs = official.processor(text=[text],audio=[audio],return_tensors='pt',padding=True)
            inputs = inputs.to(official.model.device).to(official.model.dtype)
            with torch.inference_mode():
                logits = official.model.thinker(**inputs).logits
                classes = logits.argmax(dim=-1)[0][inputs['input_ids'][0] == official.timestamp_token_id]
            times = (classes * official.timestamp_segment_time).cpu().numpy()
            reference = official.aligner_processor.parse_timestamp(words,times)
            started = time.perf_counter()
            try:
                native = worker.request(op='align',path=str(pcm),words=words)
                delta = max(abs(native['times'][i][side+'Ms'] - reference[i][side+'_time'])
                    for i in range(len(words)) for side in ['start','end'])
                if args.backend != 'cpu' and native.get('gpuOperators',0) <= 0:
                    raise RuntimeError('No actual alignment GPU operators')
                item = {'id':sample['id'],'language':language,'words':len(words),
                        'maximumDeltaMs':float(delta),'native':native['times'],
                        'gpuOperators':native.get('gpuOperators',0),'seconds':time.perf_counter()-started}
            except RuntimeError as error:
                item = {'id':sample['id'],'language':language,'fallback':str(error),'words':len(words)}
            report['results'].append(item)
            output.write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
            print(args.backend,sample['id'],item.get('maximumDeltaMs',item.get('fallback')),flush=True)
        # Compare the same two seconds of log-mel input, independent of decoding.
        short = audio[:32000].copy()
        short.astype('<f4').tofile(pcm)
        native = worker.request(op='features',path=str(pcm))
        reference = official.processor.feature_extractor(short,sampling_rate=16000,
            padding='longest',return_tensors='np')['input_features'][0]
        candidate = np.asarray(native['values'],dtype=np.float32).reshape(native['melBins'],native['frames'])
        if candidate.shape != reference.shape:
            raise ValueError(f'Feature shape differs: {candidate.shape} / {reference.shape}')
        report['melFeatures'] = {'shape':list(candidate.shape),'maxAbsoluteError':float(np.max(np.abs(candidate-reference))),
                                'meanAbsoluteError':float(np.mean(np.abs(candidate-reference)))}
        output.write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
    finally:
        worker.close()
        log.close()


if __name__ == '__main__':
    main()
