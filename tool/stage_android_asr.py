"""Stage a matching optional JNI component; otherwise retain CPU-only ASR."""
from pathlib import Path
import shutil

from verify_asr_artifact import ROOT, verify

source = ROOT / 'native/asr/prebuilt/android/arm64-v8a'
output = ROOT / 'build/generated/asr'
library = output / 'jniLibs/arm64-v8a/libfluent_asr_accel.so'
try:
    verify(source, 'android', 'arm64')
except (OSError, ValueError, KeyError, RuntimeError) as error:
    if library.is_file(): library.unlink()
    optional = library.parent / 'libfluent_asr_mnn.so'
    if optional.is_file(): optional.unlink()
    print('ASR NNAPI component unavailable; CPU retained:', error)
else:
    library.parent.mkdir(parents=True, exist_ok=True)
    notices = output / 'assets/asr'
    notices.mkdir(parents=True, exist_ok=True)
    manifest = verify(source, 'android', 'arm64')
    for name in manifest['files']:
        shutil.copy2(source / name, (library.parent if name.endswith('.so') else notices) / name)
    print('ASR NNAPI and optional Vulkan/OpenCL components staged; device/model checks remain required.')
