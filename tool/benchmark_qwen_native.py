"""Explicit Windows native cold/steady/memory measurements; never app startup."""
import json
import atexit
import os
from pathlib import Path
import statistics
import subprocess
import sys
import threading
import time
import psutil
import soundfile as sf
from check_qwen_quality import ROOT, WORK, Worker


def main():
    report = {'machine': {'processors':os.cpu_count(),'ramBytes':psutil.virtual_memory().total},'runs':[]}
    contention='--contention' in sys.argv
    destination=WORK/('performance-contention.json' if contention else 'performance.json')
    playback=playback_log=None
    if contention:
        playback_log=(WORK/'playback-competition.log').open('w',encoding='utf-8')
        playback=subprocess.Popen(['ffmpeg','-hide_banner','-loglevel','verbose','-stats',
            '-stream_loop','-1','-re','-hwaccel','d3d11va','-hwaccel_output_format','d3d11',
            '-i',str(WORK/'playback.mp4'),'-an','-f','null','NUL'],stdout=subprocess.DEVNULL,stderr=playback_log)
        def cleanup_playback():
            if playback.poll() is None:
                playback.terminate(); playback.wait(timeout=10)
        atexit.register(cleanup_playback)
        time.sleep(2)
        if playback.poll() is not None: raise RuntimeError('Background hardware decode failed')
        report['contention']='Looped 720p H.264 D3D11VA real-time decode, no window or audio; not a player UI test'
    folder=WORK/'中文路径验证'
    folder.mkdir(exist_ok=True)
    audio,rate=sf.read(WORK/'quality/ja-00.wav',dtype='float32')
    assert rate==16000
    pcm=folder/'日语音频.f32'
    audio.astype('<f4').tofile(pcm)
    for model in (['1.7B'] if contention else ['0.6B','1.7B']):
        filename='qwen3-asr-0.6b.gguf' if model=='0.6B' else 'qwen3-asr-1.7b-f16.gguf'
        original=WORK.parent/'model-center/native'/('qwen3-asr-'+model.lower()+'-f16')/filename
        link=folder/filename
        if not link.exists(): os.link(original,link)
        for backend in ['cpu','vulkan']:
            log=(WORK/f'performance-{model}-{backend}.stderr.log').open('w',encoding='utf-8')
            begin=time.perf_counter()
            worker=Worker(ROOT/'native/qwen_asr/prebuilt/windows-x64/qwen_asr_worker.exe',log)
            process=psutil.Process(worker.process.pid)
            memory={'rss':0,'private':0,'availableDrop':0}
            available=psutil.virtual_memory().available
            stop=threading.Event()
            def sample():
                while not stop.wait(.02):
                    try:
                        info=process.memory_info()
                        memory['rss']=max(memory['rss'],info.rss)
                        memory['private']=max(memory['private'],getattr(info,'private',0))
                        memory['availableDrop']=max(memory['availableDrop'],available-psutil.virtual_memory().available)
                    except psutil.NoSuchProcess: return
            thread=threading.Thread(target=sample);thread.start()
            try:
                started=time.perf_counter()
                loaded=worker.request(op='load',kind='asr',model=str(link),threads=6,backend=backend)
                load=time.perf_counter()-started
                first=worker.request(op='decode',path=str(pcm))['result']
                cold=time.perf_counter()-begin
                times=[]
                for _ in range(3):
                    started=time.perf_counter()
                    result=worker.request(op='decode',path=str(pcm))['result']
                    times.append(time.perf_counter()-started)
                    assert result['text']==first['text']
                    if backend!='cpu': assert result['gpuOperators']>0
                steady=statistics.median(times)
                report['runs'].append({'model':model,'requestedBackend':backend,'actualBackend':loaded['backend'],'componentBuild':loaded['build'],
                    'modelLoadSeconds':load,'coldFirstResultSeconds':cold,'steadySeconds':times,
                    'steadyMedianSeconds':steady,'audioSeconds':len(audio)/16000,
                    'realtimeMultiple':len(audio)/16000/steady,'peakMemoryBytes':memory,
                    'gpuOperators':first.get('gpuOperators',0),'unicodePathsPassed':True})
                destination.write_text(json.dumps(report,indent=2),encoding='utf-8')
                print(model,backend,round(steady,3),memory,flush=True)
            finally:
                stop.set();thread.join();worker.close();log.close()
    if playback:
        playback.terminate(); playback.wait(timeout=10); playback_log.close()
        return
    log=(WORK/'performance-tokenizer.stderr.log').open('w',encoding='utf-8')
    worker=Worker(ROOT/'native/qwen_asr/prebuilt/windows-x64/qwen_asr_worker.exe',log)
    try:
        process=psutil.Process(worker.process.pid)
        text_memory=[]
        for language,text in [('ja','😀東京大学でPythonを使います。カ\u3099ッツ。'),('ko','한국어를  공부합니다. Python도 좋아요.')]:
            started=time.perf_counter();result=worker.request(op='tokenize',language=language,text=text)
            first=time.perf_counter()-started
            times=[]
            for _ in range(20):
                started=time.perf_counter();worker.request(op='tokenize',language=language,text=text);times.append(time.perf_counter()-started)
            text_memory.append({'language':language,'coldSeconds':first,'steadyMedianSeconds':statistics.median(times),
                'rssBytes':process.memory_info().rss,'units':result['units']})
        report['tokenizer']=text_memory
        destination.write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
    finally: worker.close();log.close()


if __name__=='__main__': main()
