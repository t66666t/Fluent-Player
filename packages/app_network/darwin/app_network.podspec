Pod::Spec.new do |s|
  s.name = 'app_network'
  s.version = '1.0.0'
  s.summary = 'Device proxy and PAC resolution.'
  s.description = s.summary
  s.homepage = 'https://github.com/flutter/flutter'
  s.license = { :type => 'MIT' }
  s.author = { 'Fluent Player' => 'dev@example.invalid' }
  s.source = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.public_header_files = 'Classes/*.h'
  s.ios.dependency 'Flutter'
  s.osx.dependency 'FlutterMacOS'
  s.ios.deployment_target = '15.1'
  s.osx.deployment_target = '12.0'
  s.frameworks = 'CFNetwork', 'Network', 'WebKit'
  # Objective-C++ does not emit Swift's automatic FlutterMacOS link directive.
  s.osx.frameworks = 'FlutterMacOS', 'CFNetwork', 'Network', 'WebKit'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17' }
end
