#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint fluent_sqflite.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'fluent_sqflite'
  s.version          = '0.0.1'
  s.summary          = 'A powerful, developer-friendly DAO-based database engine for Flutter. Features automated schema synchronization, smart migrations, and built-in relation management for sqflite.'
  s.description      = <<-DESC
A powerful, developer-friendly DAO-based database engine for Flutter. Features automated schema synchronization, smart migrations, and built-in relation management for sqflite.
                       DESC
  s.homepage         = 'http://example.com'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Your Company' => 'email@example.com' }

  s.source           = { :path => '.' }
  s.source_files = 'Classes/**/*'

  # If your plugin requires a privacy manifest, for example if it collects user
  # data, update the PrivacyInfo.xcprivacy file to describe your plugin's
  # privacy impact, and then uncomment this line. For more information,
  # see https://developer.apple.com/documentation/bundleresources/privacy_manifest_files
  # s.resource_bundles = {'fluent_sqflite_privacy' => ['Resources/PrivacyInfo.xcprivacy']}

  s.dependency 'FlutterMacOS'

  s.platform = :osx, '10.11'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version = '5.0'
end
