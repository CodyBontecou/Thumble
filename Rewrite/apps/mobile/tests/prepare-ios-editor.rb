# Opt-in test-host plumbing only; never changes product app or SDK sources.
require 'xcodeproj'
require 'pathname'
require 'json'
root = Pathname.new(__dir__).parent
port = Integer(ARGV.fetch(0))
abort 'invalid fixture port' unless (1..65535).include?(port)
project_path = root.join('ios/ThumbleRewrite.xcodeproj')
project = Xcodeproj::Project.open(project_path)
app = project.targets.find { |target| target.name == 'ThumbleRewrite' } or abort 'missing app'
name = 'EditorPairedAppTests'
target = project.targets.find { |item| item.name == name }
unless target
  target = project.new_target(:unit_test_bundle, name, :ios, '17.0')
  target.add_dependency(app)
  group = project.main_group.new_group(name, '../tests/ios')
  target.source_build_phase.add_file_reference(group.new_file('EditorPairedAppTests.swift'))
  target.resources_build_phase.add_file_reference(group.new_file('EditorPairedAppProbeConfig.json'))
end
root.join('tests/ios/EditorPairedAppProbeConfig.json').write(JSON.generate({ 'fixturePort' => port }))
app.build_configurations.each do |configuration|
  configuration.build_settings['CODE_SIGN_STYLE[sdk=iphonesimulator*]'] = 'Manual'
  configuration.build_settings['CODE_SIGN_IDENTITY[sdk=iphonesimulator*]'] = '-'
  configuration.build_settings['CODE_SIGN_ENTITLEMENTS[sdk=iphonesimulator*]'] = '../tests/ios/Simulator.entitlements'
end
target.build_configurations.each do |configuration|
  configuration.build_settings.merge!({
    'PRODUCT_NAME' => name, 'PRODUCT_BUNDLE_IDENTIFIER' => 'com.codybontecou.thumble.rewrite.editor-paired-tests',
    'GENERATE_INFOPLIST_FILE' => 'YES', 'SWIFT_VERSION' => '6.0',
    'TEST_HOST' => '$(BUILT_PRODUCTS_DIR)/ThumbleRewrite.app/ThumbleRewrite', 'BUNDLE_LOADER' => '$(TEST_HOST)',
    'CODE_SIGNING_ALLOWED' => 'NO',
    'SWIFT_INCLUDE_PATHS' => ['$(inherited)', *%w[ThumbleNativeInput MobileInputCore MobileInputUIKit ThumbleContracts].map { |m| "$(BUILT_PRODUCTS_DIR)/#{m}" }],
    'SWIFT_ENABLE_EXPLICIT_MODULES' => 'NO',
    'LD_RUNPATH_SEARCH_PATHS' => ['$(inherited)', '@executable_path/Frameworks', '@loader_path/Frameworks']
  })
end
project.save
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(app)
scheme.add_test_target(target)
scheme.set_launch_target(app)
scheme.test_action.build_configuration = 'Release'
scheme.save_as(project_path, name, true)
podfile = root.join('ios/Podfile')
contents = podfile.read
unless contents.include?("target '#{name}'")
  anchor = '  use_expo_modules!'
  abort 'missing Expo anchor' unless contents.include?(anchor)
  contents.sub!(anchor, "#{anchor}\n  target '#{name}' do\n    inherit! :search_paths\n  end")
  podfile.write(contents)
end
puts 'Prepared target-UID paired editor tests (no UI automation)'
