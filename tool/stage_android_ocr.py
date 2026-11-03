"""Stage verified OCR-only GPU libraries; never replace the application's ORT."""
from pathlib import Path
import shutil
from build_ocr_acceleration import ROOT, verify

source = ROOT / 'native/ocr/prebuilt/android/arm64'
manifest = verify(source, 'android', 'arm64')
output = ROOT / 'build/generated/ocr'
libraries = output / 'jniLibs/arm64-v8a'
notices = output / 'assets/ocr'
libraries.mkdir(parents=True, exist_ok=True)
notices.mkdir(parents=True, exist_ok=True)
for name in manifest['files']:
    target = (libraries if name.endswith('.so') else notices) / name
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source / name, target)
print('Verified OCR Vulkan/OpenCL/QNN components staged; device/model checks remain runtime-specific.')
