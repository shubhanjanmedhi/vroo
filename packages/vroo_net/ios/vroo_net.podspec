#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint vroo_net.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'vroo_net'
  s.version          = '0.0.1'
  s.summary          = "Vroo's network plugin: the box's Wi-Fi, and datagrams to the box and the internet."
  s.description      = <<-DESC
Joins the Vroo box's Wi-Fi and carries datagrams to the box and to the internet.
                       DESC
  s.homepage         = 'http://example.com'
  s.license          = { :type => 'GPL-3.0-or-later', :file => '../../../LICENSE' }
  s.author           = { 'Your Company' => 'email@example.com' }
  s.source           = { :path => '.' }
  s.source_files = 'vroo_net/Sources/vroo_net/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '17.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'

  # If your plugin requires a privacy manifest, for example if it uses any
  # required reason APIs, update the PrivacyInfo.xcprivacy file to describe your
  # plugin's privacy impact, and then uncomment this line. For more information,
  # see https://developer.apple.com/documentation/bundleresources/privacy_manifest_files
  # s.resource_bundles = {'vroo_net_privacy' => ['vroo_net/Sources/vroo_net/PrivacyInfo.xcprivacy']}
end
