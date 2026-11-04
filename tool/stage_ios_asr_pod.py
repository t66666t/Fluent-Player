"""Select the verified unified static sherpa pod, leaving Pub cache untouched."""
import json
import re
from pathlib import Path
import shutil

from assemble_ios_asr import ROOT, verify

source = ROOT / 'native/asr/prebuilt/ios-unified'
if not (source / 'manifest.json').exists():
    print('ASR CoreML archive not staged; original CPU plugin retained.')
    raise SystemExit(0)
try:
    verify(source)
except (ValueError, KeyError, OSError, RuntimeError) as error:
    print('ASR CoreML archive is invalid or stale; original CPU plugin retained: ' + str(error))
    raise SystemExit(0)
destination = ROOT / '.artifacts/asr-gpu/ios-pod/ios'
destination.mkdir(parents=True, exist_ok=True)
framework = destination / 'FluentAsr.xcframework'
if framework.exists():
    if not framework.resolve().is_relative_to(destination.resolve()): raise RuntimeError('Unsafe pod staging path')
    shutil.rmtree(framework)
shutil.copytree(source / framework.name, framework)
for name in ['LICENSE', 'ThirdPartyNotices.txt', 'ffi-symbols.txt']: shutil.copy2(source / name, destination / name)
symbols = (source / 'ffi-symbols.txt').read_text(encoding='utf-8').splitlines()
if not symbols or any(not re.fullmatch(r'_(?:SherpaOnnx[A-Za-z0-9_]+|FluentAsr(?:Request|Free))', value) for value in symbols):
    raise RuntimeError('Invalid iOS static FFI retention symbols')
retention = ' '.join('-Wl,-u,' + value for value in symbols)
(destination / 'sherpa_onnx_ios.podspec').write_text('''Pod::Spec.new do |s|
  s.name = 'sherpa_onnx_ios'
  s.version = '1.12.12'
  s.summary = 'Pinned sherpa ASR with optional CoreML and a single application ORT'
  s.homepage = 'https://github.com/k2-fsa/sherpa-onnx'
  s.author = { 'sherpa-onnx' => 'csukuangfj@gmail.com' }
  s.license = { :type => 'Apache-2.0', :file => 'LICENSE' }
  s.source = { :path => '.' }
  s.platform = :ios, '16.4'
  s.static_framework = true
  s.dependency 'Flutter'
  s.dependency 'onnxruntime-objc', '1.23.0'
  s.vendored_frameworks = 'FluentAsr.xcframework'
  s.preserve_paths = ['LICENSE', 'ThirdPartyNotices.txt', 'ffi-symbols.txt']
  s.libraries = 'c++'
  # Dart FFI and Swift dlsym need symbols that have no static call site.
  s.user_target_xcconfig = { 'OTHER_LDFLAGS' => '$(inherited) -Wl,-force_load,"${PODS_XCFRAMEWORKS_BUILD_DIR}/sherpa_onnx_ios/libfluent_asr_accel.a" __FFI_RETENTION__' }
end
'''.replace('__FFI_RETENTION__', retention), encoding='utf-8')
link = ROOT / 'ios/.symlinks/plugins/sherpa_onnx_ios'
if not link.is_symlink(): raise RuntimeError('Expected a generated Flutter plugin symlink')
link.unlink()
link.symlink_to(destination.parent, target_is_directory=True)
print('Using unified sherpa 1.12.12 archive and OCR\'s existing ORT 1.23.0; no second ORT is embedded.')
