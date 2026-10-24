Pod::Spec.new do |s|
  s.name = 'TappingLink'
  s.version = '0.1.0'
  s.summary = 'Certificate-pinned local controller transport'
  s.description = s.summary
  s.license = { :type => 'UNLICENSED' }
  s.author = 'Thumble'
  s.homepage = 'https://example.invalid/tapping'
  s.platform = :ios, '16.4'
  s.swift_version = '5.9'
  s.source = { :path => '.' }
  s.static_framework = true
  s.dependency 'ExpoModulesCore'
  s.source_files = '**/*.swift'
end
