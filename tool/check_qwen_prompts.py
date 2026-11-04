"""Explicit language/hotword and mixed-language parity checks against Qwen."""
import json
import sys
import time
import numpy as np
import soundfile as sf
from check_qwen_quality import ROOT, WORK, Worker, normalized

sys.path.insert(0,str(WORK/'reference/Qwen3-ASR-7c6daf77a2421100f5fb066495372c00129d39ff'))
import torch
from qwen_asr import Qwen3ASRModel

torch.set_num_threads(4)
entries=json.loads((WORK/'reference/models.json').read_text(encoding='utf-8'))
samples=json.loads((WORK/'quality/samples.json').read_text(encoding='utf-8'))['samples']
report=[]
for size in ['0.6B','1.7B']:
    model=Qwen3ASRModel.from_pretrained(entries['Qwen/Qwen3-ASR-'+size]['path'],dtype=torch.float16,
        device_map='cpu',attn_implementation='sdpa',max_inference_batch_size=1,max_new_tokens=512,local_files_only=True)
    log=(WORK/f'prompt-{size}.stderr.log').open('w',encoding='utf-8')
    worker=Worker(ROOT/'native/qwen_asr/prebuilt/windows-x64/qwen_asr_worker.exe',log)
    filename='qwen3-asr-0.6b.gguf' if size=='0.6B' else 'qwen3-asr-1.7b-f16.gguf'
    weight=WORK.parent/'model-center/native'/('qwen3-asr-'+size.lower()+'-f16')/filename
    try:
        for language,name,context in [('ja','Japanese','ギャップイヤーコース'),('ko','Korean','한국어')]:
            sample=next(item for item in samples if item['language']==language)
            audio,_=sf.read(sample['path'],dtype='float32')
            pcm=WORK/'quality/prompt.f32';audio.astype('<f4').tofile(pcm)
            worker.request(op='load',kind='asr',model=str(weight),backend='cpu',threads=4,language=language,hotwords=context)
            native=worker.request(op='decode',path=str(pcm))['result']
            # Match the native hotword adapter's system context exactly.
            reference=model.transcribe((audio,16000),language=name,
                context='The following words may appear in the audio: '+context+'.')[0]
            same=normalized(native['text'])==normalized(reference.text)
            report.append({'model':size,'case':language+'-forced-with-context','native':native['text'],
                           'official':reference.text,'normalizedExact':same})
            (WORK/'prompt-parity.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
            assert same
        english=min((item for item in samples if item['language']=='en'),
                    key=lambda item:sf.info(item['path']).frames)
        for language in ['ja','ko']:
            sample=next(item for item in samples if item['language']==language)
            first,_=sf.read(sample['path'],dtype='float32');second,_=sf.read(english['path'],dtype='float32')
            audio=np.concatenate([first,np.zeros(3200,dtype=np.float32),second])
            if len(audio)>25*16000: continue
            pcm=WORK/'quality/prompt.f32';audio.astype('<f4').tofile(pcm)
            worker.request(op='load',kind='asr',model=str(weight),backend='cpu',threads=4,language='auto')
            native=worker.request(op='decode',path=str(pcm))['result']
            reference=model.transcribe((audio,16000))[0]
            same=normalized(native['text'])==normalized(reference.text)
            report.append({'model':size,'case':language+'-English-concatenated','native':native['text'],
                           'official':reference.text,'normalizedExact':same,'seconds':len(audio)/16000})
            assert same
        (WORK/'prompt-parity.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
        print(size,len(report),'prompt cases passed',flush=True)
    finally:
        worker.close();log.close();del model
