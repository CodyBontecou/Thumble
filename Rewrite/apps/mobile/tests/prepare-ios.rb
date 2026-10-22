# Generate only QA project plumbing after Expo prebuild. Never edits app sources.
require 'xcodeproj'
require 'pathname'
root = Pathname.new(__dir__).parent
project_path = root.join('ios/ThumbleRewrite.xcodeproj')
project = Xcodeproj::Project.open(project_path)
app = project.targets.find { |t| t.name == 'ThumbleRewrite' } or abort 'Missing Expo app target'
name = 'NativePortalTests'
target = project.targets.find { |t| t.name == name }
unless target
  target = project.new_target(:unit_test_bundle, name, :ios, '17.0')
  target.add_dependency(app)
  group = project.main_group.new_group(name, '../tests/ios')
  target.source_build_phase.add_file_reference(group.new_file('NativePortalTests.swift'))
  resource = project.main_group.new_file('../../../packages/fixtures/controller-layout-v1.json')
  target.resources_build_phase.add_file_reference(resource)
end
target.build_configurations.each do |configuration|
  configuration.build_settings.merge!({
    'PRODUCT_NAME' => name,
    'PRODUCT_BUNDLE_IDENTIFIER' => 'com.codybontecou.thumble.rewrite.portal-tests',
    'GENERATE_INFOPLIST_FILE' => 'YES',
    'SWIFT_VERSION' => '6.0',
    'TEST_HOST' => '$(BUILT_PRODUCTS_DIR)/ThumbleRewrite.app/ThumbleRewrite',
    'BUNDLE_LOADER' => '$(TEST_HOST)',
    'CODE_SIGNING_ALLOWED' => 'NO',
    'SWIFT_INCLUDE_PATHS' => ['$(inherited)', *%w[ThumbleNativeInput MobileInputCore MobileInputUIKit ThumbleContracts].map { |m| "$(BUILT_PRODUCTS_DIR)/#{m}" }],
    'HEADER_SEARCH_PATHS' => ['$(inherited)'],
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
marker = "  # Thumble hosted UIKit tests"
unless contents.include?(marker)
  anchor = "  use_expo_modules!"
  abort 'Missing Expo Podfile anchor' unless contents.include?(anchor)
  contents.sub!(anchor, "#{anchor}\n#{marker}\n  target '#{name}' do\n    inherit! :search_paths\n  end")
  podfile.write(contents)
end
puts 'Prepared hosted native portal test target'
