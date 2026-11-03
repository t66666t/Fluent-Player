Pod::Spec.new do |s|
  s.name = 'fluent_parakeet_ja'
  s.version = '1.0.0'
  s.summary = 'Private Japanese Parakeet CPU audio runtime'
  s.homepage = 'https://github.com/CrispStrobe/CrispASR'
  s.license = { :type => 'MIT', :file => 'parakeet_ja/LICENSE' }
  s.author = 'Fluent Player'
  s.source = { :path => '.' }
  s.platform = :ios, '16.4'
  s.vendored_frameworks = 'parakeet_ja/prebuilt/FluentParakeetJa.xcframework'
  s.preserve_paths = 'parakeet_ja/prebuilt/ios-*/licenses/*'
  s.frameworks = 'Foundation', 'Accelerate', 'Security', 'SystemConfiguration'
  s.libraries = 'c++'
  s.user_target_xcconfig = { 'OTHER_LDFLAGS' => '$(inherited) -Wl,-u,_fluent_parakeet_ja_create -Wl,-u,_fluent_parakeet_ja_request -Wl,-u,_fluent_parakeet_ja_cancel -Wl,-u,_fluent_parakeet_ja_destroy' }
end
