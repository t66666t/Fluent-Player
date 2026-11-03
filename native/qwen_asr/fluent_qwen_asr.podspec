Pod::Spec.new do |s|
  s.name = 'fluent_qwen_asr'
  s.version = '1.0.0'
  s.summary = 'Private Qwen audio runtime with embedded Japanese and Korean dictionaries'
  s.homepage = 'https://github.com/CrispStrobe/CrispASR'
  s.license = { :type => 'MIT', :file => 'prebuilt/ios-arm64/licenses/CrispASR-MIT.txt' }
  s.author = 'Fluent Player'
  s.source = { :path => '.' }
  s.platform = :ios, '16.4'
  s.vendored_frameworks = 'prebuilt/FluentQwenAsr.xcframework'
  s.preserve_paths = 'prebuilt/ios-*/licenses/*'
  s.frameworks = 'Metal', 'Foundation', 'Accelerate', 'Security', 'SystemConfiguration'
  s.libraries = 'c++', 'resolv'
  # The Swift bridge resolves these functions using dlsym; retain the C ABI.
  s.user_target_xcconfig = { 'OTHER_LDFLAGS' => '$(inherited) -Wl,-u,_fluent_qwen_create -Wl,-u,_fluent_qwen_request -Wl,-u,_fluent_qwen_cancel -Wl,-u,_fluent_qwen_destroy' }
end
