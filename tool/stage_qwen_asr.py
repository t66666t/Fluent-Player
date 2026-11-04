"""Stage a verified native Qwen component into an existing platform bundle."""
import argparse
from pathlib import Path
import shutil

from verify_qwen_artifact import ROOT,verify


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--platform',required=True,choices=['windows','linux','macos','android','ios'])
    parser.add_argument('--arch',required=True,choices=['x64','arm64'])
    parser.add_argument('--destination',required=True,type=Path)
    args=parser.parse_args()
    source=ROOT/'native/qwen_asr/prebuilt'/f'{args.platform}-{args.arch}'
    if not (source/'manifest.json').exists():
        print(f'Qwen component not staged for {args.platform}-{args.arch}; existing models retained.')
        return
    manifest=verify(source,args.platform,args.arch)
    args.destination.mkdir(parents=True,exist_ok=True)
    for name in manifest['files']:
        destination=args.destination/name
        destination.parent.mkdir(parents=True,exist_ok=True)
        shutil.copy2(source/name,destination)
    shutil.copy2(source/'manifest.json',args.destination/'manifest.json')


if __name__=='__main__': main()
