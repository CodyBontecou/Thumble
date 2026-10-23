# Separate simulator-only UI witness. Never adds private XCTest helpers to the app target.
require 'xcodeproj'
require 'pathname'
root = Pathname.new(__dir__).parent
project_path = root.join('ios/ThumbleRewrite.xcodeproj')
project = Xcodeproj::Project.open(project_path)
app = project.targets.find { |target| target.name == 'ThumbleRewrite' } or abort 'Missing app target'
name = 'BankPresentationUITests'
target = project.targets.find { |candidate| candidate.name == name }
unless target
  target = project.new_target(:ui_test_bundle, name, :ios, '17.0')
  target.add_dependency(app)
  group = project.main_group.new_group(name, '../tests/ios')
  %w[BankPresentationUITests.swift BankPresentationGesture.m].each do |file|
    target.source_build_phase.add_file_reference(group.new_file(file))
  end
  resource = project.main_group.new_file('../tests/ios/SavedControllerAppProbeConfig.json')
  target.resources_build_phase.add_file_reference(resource)
end
app.build_configurations.each do |configuration|
  configuration.build_settings['CODE_SIGN_STYLE[sdk=iphonesimulator*]'] = 'Manual'
  configuration.build_settings['CODE_SIGN_IDENTITY[sdk=iphonesimulator*]'] = '-'
  configuration.build_settings['CODE_SIGN_ENTITLEMENTS[sdk=iphonesimulator*]'] = '../tests/ios/Simulator.entitlements'
end
target.build_configurations.each do |configuration|
  configuration.build_settings.merge!({
    'PRODUCT_NAME' => name,
    'PRODUCT_BUNDLE_IDENTIFIER' => 'com.codybontecou.thumble.rewrite.bank-ui-tests',
    'GENERATE_INFOPLIST_FILE' => 'YES', 'SWIFT_VERSION' => '6.0',
    'TEST_TARGET_NAME' => app.name,
    'SWIFT_OBJC_BRIDGING_HEADER' => '../tests/ios/BankPresentationGesture.h',
    'CODE_SIGN_STYLE[sdk=iphonesimulator*]' => 'Manual',
    'CODE_SIGN_IDENTITY[sdk=iphonesimulator*]' => '-',
    'LD_RUNPATH_SEARCH_PATHS' => ['$(inherited)', '@executable_path/Frameworks', '@loader_path/Frameworks']
  })
end
project.root_object.attributes['TargetAttributes'] ||= {}
project.root_object.attributes['TargetAttributes'][target.uuid] = { 'TestTargetID' => app.uuid }
# Guard the packaging boundary even if this script is run repeatedly.
abort 'Private QA helper leaked into app target' if app.source_build_phase.files.any? { |file| file.file_ref&.path&.include?('BankPresentationGesture') }
project.save
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(app)
scheme.add_test_target(target)
scheme.set_launch_target(app)
scheme.test_action.build_configuration = 'Release'
scheme.save_as(project_path, name, true)
puts 'Prepared separate bank artwork UI-test target'
