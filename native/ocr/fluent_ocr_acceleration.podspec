Pod::Spec.new do |s|
  s.name = 'fluent_ocr_acceleration'
  s.version = '3.6.1'
  s.summary = 'Private FP32 OCR Metal accelerator'
  s.homepage = 'https://github.com/alibaba/MNN'
  s.license = { :type => 'Apache-2.0', :file => 'prebuilt/ios/arm64/MNN-LICENSE' }
  s.author = 'Fluent Player'
  s.source = { :path => '.' }
  s.platform = :ios, '16.4'
  s.vendored_frameworks = 'prebuilt/ios/arm64/FluentOcrAcceleration.xcframework'
  s.preserve_paths = 'prebuilt/ios/arm64/*-LICENSE'
  s.frameworks = 'Metal', 'Foundation', 'CoreGraphics'
  s.libraries = 'c++'
  # Dart reaches the entrypoint by dlsym; retain the framework at link time.
  s.user_target_xcconfig = { 'OTHER_LDFLAGS' => '$(inherited) -Wl,-u,_fluent_ocr_abi' }
end
