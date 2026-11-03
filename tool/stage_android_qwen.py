"""Stage only the checksummed private Qwen JNI component for Android."""
import shutil
from verify_qwen_artifact import ROOT, verify

source = ROOT / 'native/qwen_asr/prebuilt/android-arm64'
output = ROOT / 'build/generated/qwen_asr'
library = output / 'jniLibs/arm64-v8a/libfluent_qwen_asr.so'
if not (source / 'manifest.json').exists():
    library.unlink(missing_ok=True)
    print('Qwen Android component not built; existing ASR retained.')
else:
    manifest = verify(source, 'android', 'arm64')
    for name in manifest['files']:
        destination = ((library.parent / name) if name.endswith('.so') else
                       (output / 'assets/qwen_asr' / name))
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source / name, destination)
    shutil.copy2(source / 'manifest.json', output / 'assets/qwen_asr/manifest.json')
