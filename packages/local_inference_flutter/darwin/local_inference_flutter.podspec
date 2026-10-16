#
# The device probe of local_inference_flutter, for CocoaPods hosts. Swift Package Manager hosts use
# local_inference_flutter/Package.swift, which builds the same sources.
#
Pod::Spec.new do |s|
  s.name             = 'local_inference_flutter'
  s.version          = '0.1.1'
  s.summary          = 'Device probe of local_inference_flutter: memory, disk, SHA-256, backup flag, diagnostics.'
  s.description      = <<-DESC
Memory and disk figures, the SHA-256 of a downloaded model, its exclusion from backups, and a diagnostics
snapshot, for the on-device inference packages of local_inference.
                       DESC
  s.homepage         = 'https://pub.dev/packages/local_inference_flutter'
  s.license          = { :type => 'MIT', :file => '../LICENSE' }
  s.author           = 'Cosimo Orlacchio'
  s.source           = { :path => '.' }
  s.source_files     = 'local_inference_flutter/Sources/local_inference_flutter/**/*.swift'
  s.resource_bundles = {
    'local_inference_flutter_privacy' => ['local_inference_flutter/Sources/local_inference_flutter/PrivacyInfo.xcprivacy']
  }

  # llamadart's floors: the engine cannot run below them.
  s.ios.deployment_target = '16.4'
  s.osx.deployment_target = '14.0'

  s.ios.dependency 'Flutter'
  s.osx.dependency 'FlutterMacOS'

  # Flutter.framework does not contain a i386 slice.
  s.ios.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.osx.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }

  s.swift_version = '5.0'
end
