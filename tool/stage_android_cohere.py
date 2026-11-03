"""Package only the explicitly built, verified Cohere Android component."""
import shutil
from verify_cohere_artifact import ROOT, verify

source = ROOT / 'native/cohere_asr/prebuilt/android-arm64'
output = ROOT / 'build/generated/cohere_asr'
library = output / 'jniLibs/arm64-v8a/libfluent_cohere_asr.so'
if not (source / 'manifest.json').exists():
    library.unlink(missing_ok=True)
    print('Cohere Android component not built; existing models retained.')
else:
    manifest = verify(source, 'android', 'arm64')
    for name in manifest['files']:
        destination = library.parent / name if name.endswith('.so') else output / 'assets/cohere_asr' / name
        destination.parent.mkdir(parents=True, exist_ok=True); shutil.copy2(source / name, destination)
    shutil.copy2(source / 'manifest.json', output / 'assets/cohere_asr/manifest.json')
