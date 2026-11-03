Pod::Spec.new do |s|
  s.name = 'fluent_cohere_asr'
  s.version = '1.0.0'
  s.summary = 'Private Cohere CPU audio runtime'
  s.homepage = 'https://github.com/handy-computer/transcribe.cpp'
  s.license = { :type => 'MIT', :file => 'cohere_asr/LICENSE' }
  s.author = 'Fluent Player'
  s.source = { :path => '.' }
  s.platform = :ios, '16.4'
  s.vendored_frameworks = 'cohere_asr/prebuilt/FluentCohereAsr.xcframework'
  s.preserve_paths = 'cohere_asr/prebuilt/ios-*/licenses/*'
  s.frameworks = 'Foundation', 'Accelerate', 'Security', 'SystemConfiguration'
  s.libraries = 'c++'
  s.user_target_xcconfig = { 'OTHER_LDFLAGS' => '$(inherited) -Wl,-u,_fluent_cohere_create -Wl,-u,_fluent_cohere_request -Wl,-u,_fluent_cohere_cancel -Wl,-u,_fluent_cohere_destroy' }
end
