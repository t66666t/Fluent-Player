Pod::Spec.new do |s|
  s.name = 'app_network'
  s.version = '1.0.0'
  s.summary = 'Device proxy and PAC resolution.'
  s.description = s.summary
  s.homepage = 'https://github.com/flutter/flutter'
  s.license = { :type => 'MIT' }
  s.author = { 'Fluent Player' => 'dev@example.invalid' }
  s.source = { :path => '.' }
  s.source_files = '../darwin/Classes/**/*'
  s.public_header_files = '../darwin/Classes/*.h'
  s.dependency 'FlutterMacOS'
  s.platform = :osx, '12.0'
  s.frameworks = 'CFNetwork', 'Network', 'WebKit'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17' }
end
