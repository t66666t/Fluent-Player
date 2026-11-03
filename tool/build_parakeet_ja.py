"""Build Japanese Parakeet against the existing pinned CrispASR/GGML versions."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

from build_qwen_asr import archive, extract, sha, source_lock
from build_cohere_asr import download
from prepare_qwen_native import prepare

ROOT=Path(__file__).resolve().parents[1]
NATIVE=ROOT/'native/parakeet_ja'
LOCK=json.loads((NATIVE/'runtime.lock.json').read_text(encoding='utf-8'))


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--platform',required=True,choices=['windows','linux','macos','android','ios'])
    parser.add_argument('--arch',default='x64',choices=['x64','arm64'])
    parser.add_argument('--ndk',type=Path);parser.add_argument('--cmake');parser.add_argument('--parallel',default='8')
    parser.add_argument('--ios-simulator',action='store_true')
    args=parser.parse_args()
    if args.platform in ('macos','ios') and sys.platform!='darwin':parser.error('Apple builds require an Apple host')
    work=ROOT/'.artifacts/parakeet-ja-integration';work.mkdir(exist_ok=True)
    deps=ROOT/'.artifacts/qwen-integration/deps'
    sources=work/('source-'+sha(Path(__file__))[:12]);ready=sources/'prepared.json'
    with source_lock(work/'prepare.lock'):
        if not ready.exists():
            sources.mkdir(parents=True,exist_ok=True)
            source=extract(archive(deps,'crispasr',LOCK['crispasr']),sources)
            ggml=extract(archive(deps,'ggml',LOCK['ggml']),sources)
            symbols=sources/'symbols.h';prepare(source,ggml,symbols)
            header=symbols.read_text().replace('fluent_qwen_','fluent_parakeet_ja_')
            # iOS links these archives into the application alongside Qwen.
            # Hidden visibility alone does not prevent static ODR collisions.
            identifiers=set()
            for part in [source/'src',source/'include']:
                for candidate in part.rglob('*'):
                    if candidate.suffix in ('.h','.hpp','.cpp'):
                        identifiers.update(re.findall(r'\b(?:core_\w+|crispasr_imatrix_\w+|parakeet_\w+)\b',candidate.read_text(encoding='utf-8')))
            header+='\n'+''.join(f'#define {name} fluent_parakeet_ja_private_{name}\n' for name in sorted(identifiers))
            symbols.write_text(header,encoding='utf-8')
            file=source/'src/parakeet.cpp'
            file.write_text(file.read_text(encoding='utf-8')+'''
extern "C" void fluent_parakeet_abort(parakeet_context* ctx, bool (*callback)(void*), void* data) {
    auto backend=ctx->backend_cpu ? ctx->backend_cpu : ctx->backend;
#ifdef GGML_BACKEND_DL
    auto device=ggml_backend_get_device(backend);
    auto registry=device ? ggml_backend_dev_backend_reg(device) : nullptr;
    using setter=void (*)(ggml_backend_t,bool (*)(void*),void*);
    auto set=registry ? reinterpret_cast<setter>(ggml_backend_reg_get_proc_address(registry,"ggml_backend_set_abort_callback")) : nullptr;
    if(set)set(backend,callback,data);
#else
    ggml_backend_cpu_set_abort_callback(backend,callback,data);
#endif
}
''',encoding='utf-8')
            ready.write_text(json.dumps({'source':str(source),'ggml':str(ggml)}),encoding='utf-8')
    prepared=json.loads(ready.read_text(encoding='utf-8'))
    download(deps/'json.hpp',LOCK['json']);license=download(deps/'nlohmann-json-MIT.txt',LOCK['jsonLicense'])
    paths=[p for p in NATIVE.rglob('*') if p.is_file() and 'prebuilt' not in p.parts]
    paths += [ROOT/'tool'/name for name in ['build_parakeet_ja.py','build_qwen_asr.py','build_cohere_asr.py','prepare_qwen_native.py']]
    hashes={p.relative_to(ROOT).as_posix():sha(p) for p in sorted(paths)}
    build_id=hashlib.sha256(json.dumps({'sources':hashes,'pins':LOCK,'platform':args.platform,'arch':args.arch,'iosSimulator':args.ios_simulator},sort_keys=True).encode()).hexdigest()
    cmake=args.cmake or shutil.which('cmake')
    if not cmake and os.name=='nt':cmake=next(str(p) for p in Path('D:/Microsoft Visual Studio').glob('*/**/CommonExtensions/Microsoft/CMake/CMake/bin/cmake.exe'))
    suffix='-sim' if args.ios_simulator else ''
    build=work/f'build-{args.platform}-{args.arch}{suffix}'
    configure=[cmake,'-S',str(NATIVE),'-B',str(build),'-DCMAKE_BUILD_TYPE=Release','-DPARAKEET_SOURCE='+prepared['source'],'-DPARAKEET_GGML_SOURCE='+prepared['ggml'],'-DPARAKEET_JSON_INCLUDE='+str(deps),'-DPARAKEET_SYMBOL_PREFIX_HEADER='+str(sources/'symbols.h'),'-DPARAKEET_BUILD_ID='+build_id,'-DGGML_VULKAN=OFF','-DGGML_CUDA=OFF','-DGGML_METAL=OFF']
    if args.platform=='windows':configure+=['-A','ARM64' if args.arch=='arm64' else 'x64']
    if args.platform=='android':
        if not args.ndk:parser.error('Android requires --ndk')
        configure+=['-G','Ninja','-DCMAKE_TOOLCHAIN_FILE='+str(args.ndk/'build/cmake/android.toolchain.cmake'),'-DANDROID_ABI='+('arm64-v8a' if args.arch=='arm64' else 'x86_64'),'-DANDROID_PLATFORM=24','-DANDROID_STL=c++_static','-DGGML_CPU_ARM_ARCH=armv8-a']
        if os.name=='nt' and not shutil.which('ninja'):configure+=['-DCMAKE_MAKE_PROGRAM='+str(Path(cmake).parent.parent.parent/'Ninja/ninja.exe')]
    if args.platform in ('macos','ios'):configure+=['-DCMAKE_OSX_ARCHITECTURES='+('arm64' if args.arch=='arm64' else 'x86_64')]
    if args.platform=='ios':configure+=['-DCMAKE_SYSTEM_NAME=iOS','-DCMAKE_OSX_SYSROOT='+('iphonesimulator' if args.ios_simulator else 'iphoneos')]
    subprocess.run(configure,check=True)
    targets=['fluent_parakeet_ja' if args.platform in ('android','ios') else 'parakeet_ja_worker']
    if args.platform not in ('android','ios'):targets+=['ggml-cpu-x64','ggml-cpu-haswell','ggml-cpu-alderlake'] if args.arch=='x64' else ['ggml-cpu']
    subprocess.run([cmake,'--build',str(build),'--config','Release','--parallel',args.parallel,'--target',*targets],check=True)
    stage=NATIVE/'prebuilt'/f'{args.platform}-{args.arch}{suffix}';stage.mkdir(parents=True,exist_ok=True)
    if args.platform=='windows':files=list(build.rglob('*.dll'))+[next(build.rglob('parakeet_ja_worker.exe'))]
    elif args.platform=='ios':
        combined=build/'libfluent_parakeet_ja_combined.a';subprocess.run(['xcrun','libtool','-static','-o',str(combined),*[str(p) for p in build.rglob('*.a') if p!=combined]],check=True);files=[combined]
    else:files=[p for p in build.rglob('*') if p.is_file() and (re.search(r'\.so(?:\.\d+)*$',p.name) or p.name.endswith('.dylib') or p.name=='parakeet_ja_worker')]
    checks={}
    for file in files:
        output=stage/file.name;shutil.copy2(file,output);checks[output.name]=sha(output)
    for name,file in [('Fluent-Player-MIT.txt',NATIVE/'LICENSE'),('CrispASR-MIT.txt',Path(prepared['source'])/'LICENSE'),('ggml-MIT.txt',Path(prepared['ggml'])/'LICENSE'),('nlohmann-json-MIT.txt',license)]:
        output=stage/'licenses'/name;output.parent.mkdir(exist_ok=True);shutil.copy2(file,output);checks[output.relative_to(stage).as_posix()]=sha(output)
    manifest={'version':1,'platform':args.platform,'arch':args.arch,'backend':'cpu','build':build_id,'sources':hashes,'pins':LOCK,'files':checks,'batchSize':1,'maxSpeechSeconds':8}
    (stage/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n',encoding='utf-8');print('Japanese Parakeet native component staged:',stage,flush=True)


if __name__=='__main__':main()
