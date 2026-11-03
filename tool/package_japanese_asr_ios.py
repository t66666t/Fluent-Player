"""Assemble or verify the optional Japanese ASR XCFrameworks on an Apple host."""
import argparse
import json
from pathlib import Path
import subprocess
from verify_qwen_artifact import ROOT, sha
from verify_cohere_artifact import verify as verify_cohere
from verify_parakeet_ja_artifact import verify as verify_parakeet


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--component',required=True,choices=['cohere_asr','parakeet_ja'])
    parser.add_argument('--verify-only',action='store_true')
    args=parser.parse_args()
    cohere=args.component=='cohere_asr'
    verify=verify_cohere if cohere else verify_parakeet
    framework='FluentCohereAsr' if cohere else 'FluentParakeetJa'
    base=ROOT/'native'/args.component/'prebuilt'
    package=base/(framework+'.xcframework')
    slices=['ios-arm64','ios-arm64-sim']
    archive='libfluent_'+args.component+'_combined.a'
    for name in slices: verify(base/name,'ios','arm64')
    inputs={name+'/'+archive:sha(base/name/archive) for name in slices}
    if not args.verify_only:
        command=['xcodebuild','-create-xcframework']
        for name in slices: command+=['-library',str(base/name/archive)]
        subprocess.run(command+['-output',str(package)],check=True)
        receipt={'inputs':inputs,'files':{p.relative_to(package).as_posix():sha(p) for p in package.rglob('*') if p.is_file()}}
        (package/'receipt.json').write_text(json.dumps(receipt,indent=2),encoding='utf-8')
    receipt=json.loads((package/'receipt.json').read_text(encoding='utf-8'))
    if receipt['inputs']!=inputs: raise ValueError('XCFramework inputs changed; repackage '+framework)
    for name,expected in receipt['files'].items():
        path=(package/name).resolve()
        if not path.is_relative_to(package.resolve()) or sha(path)!=expected:
            raise ValueError('XCFramework file mismatch: '+name)
    print(framework+' matches its pinned source libraries.')


if __name__=='__main__':main()
