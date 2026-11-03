"""Check both ASR frontends against the official pinned feature processors."""
import json
import sys
import numpy as np
import soundfile as sf
from check_qwen_quality import ROOT, WORK, Worker

sys.path.insert(0,str(WORK/'reference/Qwen3-ASR-7c6daf77a2421100f5fb066495372c00129d39ff'))
import qwen_asr  # Registers the pinned architecture with AutoProcessor.
from transformers import AutoProcessor

entries=json.loads((WORK/'reference/models.json').read_text(encoding='utf-8'))
audio,rate=sf.read(WORK/'quality/ja-00.wav',dtype='float32');audio=audio[:32000]
assert rate==16000
pcm=WORK/'quality/features.f32';audio.astype('<f4').tofile(pcm)
report=[]
for size in ['0.6B','1.7B']:
    processor=AutoProcessor.from_pretrained(entries['Qwen/Qwen3-ASR-'+size]['path'],local_files_only=True,fix_mistral_regex=True)
    reference=processor.feature_extractor(audio,sampling_rate=16000,padding='longest',return_tensors='np')['input_features'][0]
    log=(WORK/f'features-{size}.stderr.log').open('w',encoding='utf-8')
    worker=Worker(ROOT/'native/qwen_asr/prebuilt/windows-x64/qwen_asr_worker.exe',log)
    filename='qwen3-asr-0.6b.gguf' if size=='0.6B' else 'qwen3-asr-1.7b-f16.gguf'
    try:
        worker.request(op='load',kind='asr',model=str(WORK.parent/'model-center/native'/('qwen3-asr-'+size.lower()+'-f16')/filename),threads=4,backend='cpu')
        features=worker.request(op='features',path=str(pcm))
        native=np.asarray(features['values'],dtype=np.float32).reshape(features['melBins'],features['frames'])
        assert native.shape==reference.shape
        maximum=float(np.max(np.abs(native-reference)))
        assert maximum<.001
        report.append({'model':size,'shape':list(native.shape),'maximumAbsoluteError':maximum,
                       'meanAbsoluteError':float(np.mean(np.abs(native-reference)))})
    finally: worker.close();log.close()
(WORK/'audio-feature-parity.json').write_text(json.dumps(report,indent=2),encoding='utf-8')
print('Both native ASR mel frontends match the official processors within 0.001.')
