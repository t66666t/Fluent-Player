"""Verify an explicitly built Qwen component; never run at application startup."""
import argparse
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream,'sha256').hexdigest()


def verify(directory, platform=None, arch=None):
    directory=Path(directory).resolve()
    manifest=json.loads((directory/'manifest.json').read_text(encoding='utf-8'))
    if platform and manifest['platform']!=platform: raise ValueError('Qwen platform mismatch')
    if arch and manifest['arch']!=arch: raise ValueError('Qwen architecture mismatch')
    for name,expected in manifest['sources'].items():
        source=(ROOT/name).resolve()
        if not source.is_relative_to(ROOT) or not source.is_file() or sha(source)!=expected:
            raise ValueError('Qwen component needs rebuilding: '+name)
    for name,expected in manifest['files'].items():
        path=(directory/name).resolve()
        if not path.is_relative_to(directory) or not path.is_file() or sha(path)!=expected:
            raise ValueError('Qwen artifact mismatch: '+name)
    if manifest['platform']=='windows':
        binary=directory/'qwen_asr_worker.exe'
        data=binary.read_bytes()
        at=int.from_bytes(data[60:64],'little')
        machine=int.from_bytes(data[at+4:at+6],'little')
        if data[:2]!=b'MZ' or machine!=({'x64':0x8664,'arm64':0xaa64}[manifest['arch']]):
            raise ValueError('Qwen helper has an invalid PE architecture')
    if manifest['platform']=='android':
        data=(directory/'libfluent_qwen_asr.so').read_bytes()
        if data[:6]!=b'\x7fELF\x02\x01' or int.from_bytes(data[18:20],'little')!=({'arm64':183,'x64':62}[manifest['arch']]):
            raise ValueError('Qwen library has an invalid ELF architecture')
        offset=int.from_bytes(data[32:40],'little'); size=int.from_bytes(data[54:56],'little'); count=int.from_bytes(data[56:58],'little')
        for i in range(count):
            header=offset+i*size
            if int.from_bytes(data[header:header+4],'little')==1 and int.from_bytes(data[header+48:header+56],'little')<16384:
                raise ValueError('Qwen Android library lacks 16 KB alignment')
        # Inspect real exported ELF symbols rather than scanning source text.
        section_offset=int.from_bytes(data[40:48],'little')
        section_size=int.from_bytes(data[58:60],'little')
        section_count=int.from_bytes(data[60:62],'little')
        headers=[data[section_offset+i*section_size:section_offset+(i+1)*section_size] for i in range(section_count)]
        exports=set()
        for header in headers:
            if int.from_bytes(header[4:8],'little') != 11: continue
            strings=headers[int.from_bytes(header[40:44],'little')]
            string_offset=int.from_bytes(strings[24:32],'little')
            at=int.from_bytes(header[24:32],'little')
            size=int.from_bytes(header[32:40],'little')
            for symbol in range(at,at+size,24):
                if data[symbol+4]>>4 not in (1,2) or int.from_bytes(data[symbol+6:symbol+8],'little')==0: continue
                begin=string_offset+int.from_bytes(data[symbol:symbol+4],'little')
                name=data[begin:data.index(b'\0',begin)].decode('ascii')
                exports.add(name)
        if any(name.startswith(('ggml_','gguf_')) for name in exports):
            raise ValueError('Qwen mobile component exports unisolated GGML symbols')
        if not {'fluent_qwen_create','fluent_qwen_request','fluent_qwen_cancel','fluent_qwen_destroy'} <= exports:
            raise ValueError('Qwen mobile C ABI is incomplete')
        for operation in ['Create','Request','Cancel','Destroy']:
            if 'Java_com_example_video_1player_1app_QwenAsrService_native'+operation not in exports:
                raise ValueError('Qwen Android JNI entrypoint is missing: '+operation)
    return manifest


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory',type=Path)
    parser.add_argument('--platform')
    parser.add_argument('--arch')
    args=parser.parse_args()
    verify(args.directory,args.platform,args.arch)
    print('Qwen component: sources, files and target verified.')
