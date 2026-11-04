"""Explicit Windows driver-fault fixture; never modifies the shipped component.

Build a private fake GPU DLL which exits its own helper on initialization. CPU
ASR and LID must still work, and a capabilities request must observe that fault.
Requires the maintainer's C++ toolchain; users never install this fixture.
"""
import array
import json
from pathlib import Path
import shutil
import subprocess
import wave
from check_qwen_quality import ROOT, WORK, Worker, normalized

source=WORK/'driver-fault-source';source.mkdir(exist_ok=True)
(source/'CMakeLists.txt').write_text('''cmake_minimum_required(VERSION 3.24)
project(qwen_fault_fixture C)
set(CMAKE_MSVC_RUNTIME_LIBRARY MultiThreaded)
add_library(qwen_fault SHARED fault.c)
set_target_properties(qwen_fault PROPERTIES OUTPUT_NAME ggml-vulkan)
''',encoding='utf-8')
(source/'fault.c').write_text('''#include <windows.h>
BOOL WINAPI DllMain(HINSTANCE h, DWORD reason, LPVOID p) {
    if (reason == DLL_PROCESS_ATTACH) ExitProcess(91);
    return TRUE;
}
''',encoding='utf-8')
cmake=shutil.which('cmake') or next(str(p) for p in Path('D:/Microsoft Visual Studio').glob('*/**/CommonExtensions/Microsoft/CMake/CMake/bin/cmake.exe'))
build=WORK/'driver-fault-build'
subprocess.run([cmake,'-S',str(source),'-B',str(build),'-A','x64'],check=True)
subprocess.run([cmake,'--build',str(build),'--config','Release'],check=True)
component=ROOT/'native/qwen_asr/prebuilt/windows-x64'
fixture=WORK/'driver-fault-component';fixture.mkdir(exist_ok=True)
receipt=json.loads((component/'manifest.json').read_text(encoding='utf-8'))
for name in receipt['files']:
    if name=='ggml-vulkan.dll': continue
    path=fixture/name;path.parent.mkdir(parents=True,exist_ok=True)
    shutil.copy2(component/name,path)
shutil.copy2(next(build.rglob('ggml-vulkan.dll')),fixture/'ggml-vulkan.dll')
with wave.open(str(ROOT/'assets/models/asr/speech_probe.wav')) as wave_file:
    assert wave_file.getframerate()==16000 and wave_file.getsampwidth()==2
    samples=array.array('h',wave_file.readframes(wave_file.getnframes()))
pcm=WORK/'driver-fault-audio.f32'
with pcm.open('wb') as stream: array.array('f',(value/32768 for value in samples)).tofile(stream)
report={'componentBuild':receipt['build']}
with (WORK/'driver-fault.stderr.log').open('w',encoding='utf-8') as log:
    worker=Worker(fixture/'qwen_asr_worker.exe',log)
    try:
        worker.request(op='load',kind='asr',backend='cpu',threads=2,
            model=str(WORK.parent/'model-center/native/qwen3-asr-0.6b-f16/qwen3-asr-0.6b.gguf'))
        result=worker.request(op='decode',path=str(pcm))['result']
        assert result['text'] and result['backend'].startswith('CPU')
        report['cpuAsr']=result['text']
        worker.request(op='load',kind='lid',backend='cpu',threads=2,
            model=str(WORK.parent/'model-center/native/asr-language-id-voxlingua107-f16/ecapa-lid-107-f16.gguf'))
        report['cpuLid']=worker.request(op='identify',path=str(pcm))
    finally: worker.close()
    worker=Worker(fixture/'qwen_asr_worker.exe',log)
    try:
        try: worker.request(op='capabilities')
        except RuntimeError: pass
        assert worker.process.wait(timeout=10)==91
        report['gpuInitializationFaultExitCode']=91
    finally: worker.close()
(WORK/'driver-fault.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
print('CPU ASR/LID independent of faulty GPU initialization; fixture:',fixture)

# The startup correction must preserve numerical recognition on both backends.
import soundfile as sf
report['postFixRegression']=[]
for size in ['0.6B','1.7B']:
    for backend in ['cpu','vulkan']:
        golden={item['id']:item for item in json.loads((WORK/'quality'/f'native-{size}-{backend}.json').read_text(encoding='utf-8'))['results']}
        with (WORK/f'postfix-{size}-{backend}.stderr.log').open('w',encoding='utf-8') as log:
            worker=Worker(component/'qwen_asr_worker.exe',log)
            try:
                filename='qwen3-asr-0.6b.gguf' if size=='0.6B' else 'qwen3-asr-1.7b-f16.gguf'
                worker.request(op='load',kind='asr',threads=4,backend=backend,
                    model=str(WORK.parent/'model-center/native'/('qwen3-asr-'+size.lower()+'-f16')/filename))
                for language in ['ja','ko']:
                    key=language+'-00';audio,rate=sf.read(WORK/'quality'/(key+'.wav'),dtype='float32')
                    assert rate==16000
                    audio.astype('<f4').tofile(pcm)
                    result=worker.request(op='decode',path=str(pcm))['result']
                    assert normalized(result['text'])==normalized(golden[key]['text'])
                    if backend!='cpu': assert result['gpuOperators']>0
                    report['postFixRegression'].append({'model':size,'backend':backend,'sample':key,
                        'normalizedExact':True,'gpuOperators':result['gpuOperators']})
            finally:worker.close()
(WORK/'driver-fault.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
print('Both model sizes / CPU and Vulkan / Japanese and Korean: unchanged recognition.')
