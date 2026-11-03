"""Assemble already built device and simulator libraries on an Apple host."""
import subprocess
import json
from verify_qwen_artifact import ROOT, verify, sha

base = ROOT / 'native/qwen_asr/prebuilt'
command = ['xcodebuild', '-create-xcframework']
for name in ['ios-arm64', 'ios-arm64-sim']:
    directory = base / name
    verify(directory, 'ios', 'arm64')
    command += ['-library', str(directory / 'libfluent_qwen_asr_combined.a')]
command += ['-output', str(base / 'FluentQwenAsr.xcframework')]
subprocess.run(command, check=True)
package=base/'FluentQwenAsr.xcframework'
receipt={'inputs':{name+'/libfluent_qwen_asr_combined.a':sha(base/name/'libfluent_qwen_asr_combined.a')
                   for name in ['ios-arm64','ios-arm64-sim']},
         'files':{p.relative_to(package).as_posix():sha(p) for p in package.rglob('*') if p.is_file()}}
(package/'receipt.json').write_text(json.dumps(receipt,indent=2),encoding='utf-8')
