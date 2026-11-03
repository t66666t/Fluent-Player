"""Package only the explicitly built, verified Japanese Parakeet Android component."""
import shutil
from verify_parakeet_ja_artifact import ROOT, verify

source = ROOT / 'native/parakeet_ja/prebuilt/android-arm64'
output = ROOT / 'build/generated/parakeet_ja'
library = output / 'jniLibs/arm64-v8a/libfluent_parakeet_ja.so'
if not (source / 'manifest.json').exists():
    library.unlink(missing_ok=True)
    print('Japanese Parakeet Android component not built; existing models retained.')
else:
    manifest = verify(source, 'android', 'arm64')
    for name in manifest['files']:
        destination = library.parent / name if name.endswith('.so') else output / 'assets/parakeet_ja' / name
        destination.parent.mkdir(parents=True, exist_ok=True); shutil.copy2(source / name, destination)
    shutil.copy2(source / 'manifest.json', output / 'assets/parakeet_ja/manifest.json')
