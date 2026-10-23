Pod::Spec.new do |s|
  s.name = 'MobileInputCore'
  s.version = '0.0.0'
  s.summary = 'Thumble shared native input sources'
  s.homepage = 'https://github.com/CodyBontecou/Thumble'
  s.author = 'Thumble contributors'
  s.source = { :git => 'https://github.com/CodyBontecou/Thumble.git' }
  s.platforms = { :ios => '17.0' }
  s.swift_version = '6.0'
  s.static_framework = true
  s.source_files = 'Sources/MobileInputCore/**/*.swift'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.dependency 'ThumbleContracts'
end
