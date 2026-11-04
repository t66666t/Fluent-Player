"""Verify the Xcode-consumed XCFramework as well as its source-library receipts."""
import json
from verify_qwen_artifact import ROOT, verify, sha

base=ROOT/'native/qwen_asr/prebuilt'
package=base/'FluentQwenAsr.xcframework'
for name in ['ios-arm64','ios-arm64-sim']:
    verify(base/name,'ios','arm64')
receipt=json.loads((package/'receipt.json').read_text(encoding='utf-8'))
for name,expected in receipt['inputs'].items():
    path=(base/name).resolve()
    if not path.is_relative_to(base.resolve()) or sha(path)!=expected:
        raise ValueError('Qwen XCFramework needs repackaging: '+name)
for name,expected in receipt['files'].items():
    path=(package/name).resolve()
    if not path.is_relative_to(package.resolve()) or sha(path)!=expected:
        raise ValueError('Qwen XCFramework file mismatch: '+name)
print('Qwen iOS package matches its pinned source libraries.')
