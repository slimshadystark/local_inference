// The doctor on fixture hosts (test/fixtures/doctor/, completed by fixture_host.dart): a good Flutter host (iOS,
// Android, macOS) and a good pure-Dart host pass every check; then one broken host per failure class, each with the
// check that must catch it, its status and what it must say. Every result that is not ok says how to fix it.
import 'dart:io';

import 'package:local_inference/doctor.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'fixture_host.dart';

/// One broken host: [change] breaks the good fixture; the check [check] must end in [status] and say [says] (and
/// [fixSays] in its fix, when given).
final class _Case {
  const _Case(
    this.name,
    this.check,
    this.status,
    this.says,
    this.change, {
    this.fixture = 'flutter_host',
    this.verify = false,
    this.environment = const {},
    this.fixSays,
  });

  final String name;
  final String check;
  final CheckStatus status;
  final String says;
  final void Function(FixtureHost host) change;
  final String fixture;
  final bool verify;
  final Map<String, String> environment;
  final String? fixSays;
}

const _pbx = 'ios/Runner.xcodeproj/project.pbxproj';
const _gradle = 'android/app/build.gradle.kts';
const _bypass = {'BYPASS_PERMISSION_IOSADDTOPHOTOLIBRARY': '1', 'BYPASS_PERMISSION_IOSCHANGEPHOTOLIBRARY': '1'};

/// A Podfile.lock that builds background_downloader through CocoaPods.
void _podsBuildDownloader(FixtureHost host) {
  host.replace('ios/Runner/Info.plist', 'NSPhotoLibrary', 'NSOtherLibrary');
  host.write('ios/Podfile.lock', 'PODS:\n  - background_downloader (0.0.1):\n    - Flutter\n');
}

/// A Podfile whose post_install passes the photo-library BYPASS flags ([comment] before each flag line).
String _bypassPodfile({String comment = ''}) =>
    "platform :ios, '16.4'\n"
    'post_install do |installer|\n'
    '  installer.pods_project.targets.each do |target|\n'
    '    target.build_configurations.each do |config|\n'
    "      config.build_settings['OTHER_SWIFT_FLAGS'] ||= ['\$(inherited)'] # \"#{target.name}\"\n"
    "      ${comment}config.build_settings['OTHER_SWIFT_FLAGS'] << '-D BYPASS_PERMISSION_IOSADDTOPHOTOLIBRARY'\n"
    "      ${comment}config.build_settings['OTHER_SWIFT_FLAGS'] << '-D BYPASS_PERMISSION_IOSCHANGEPHOTOLIBRARY'\n"
    '    end\n'
    '  end\n'
    'end\n';

const _url = 'git@github.com:example/local-inference.git';
const _sha = 'a4b4c4d4e4f4a4b4c4d4e4f4a4b4c4d4e4f4a4b4';

String _lockEntry(
  String name, {
  String source = 'git',
  String version = '0.1.0',
  String commit = _sha,
  String server = 'https://pub.dev',
}) => switch (source) {
  'git' =>
    '  $name:\n    dependency: transitive\n    description:\n      path: "packages/$name"\n      ref: "$commit"\n'
        '      resolved-ref: "$commit"\n      url: "$_url"\n    source: git\n    version: "$version"\n',
  'hosted' =>
    '  $name:\n    dependency: transitive\n    description:\n      name: $name\n      sha256: "${'6' * 64}"\n'
        '      url: "$server"\n    source: hosted\n    version: "$version"\n',
  _ =>
    '  $name:\n    dependency: transitive\n    description:\n      path: "../local-inference/packages/$name"\n'
        '      relative: true\n    source: path\n    version: "$version"\n',
};

RegExp _entry(String name) => RegExp('  $name:\\n(?:    .*\\n)+');

void _addDependency(FixtureHost host, String name, String ref) => host.replace(
  'pubspec.yaml',
  'dependencies:\n',
  'dependencies:\n  $name:\n    git:\n      url: $_url\n      ref: $ref\n      path: packages/$name\n',
);

void _addLockEntry(FixtureHost host, String name) => host.replace(
  'pubspec.lock',
  'packages:\n',
  'packages:\n  $name:\n    dependency: transitive\n    description:\n'
      '      name: $name\n      sha256: "${'5' * 64}"\n      url: "https://pub.dev"\n    source: hosted\n'
      '    version: "1.0.0"\n',
);

final _cases = <_Case>[
  // hooks-block
  _Case('no hooks block', 'hooks-block', CheckStatus.error, 'has no hooks: user_defines: llamadart: block', (h) {
    h.replace('pubspec.yaml', RegExp(r'hooks:[\s\S]*$'), '');
  }),
  _Case('the runtimes select LiteRT-LM too', 'hooks-block', CheckStatus.error, 'selects llama_cpp, litert_lm', (h) {
    h.replace('pubspec.yaml', '[llama_cpp]', '[llama_cpp, litert_lm]');
  }),
  _Case('no llamadart_native_runtimes', 'hooks-block', CheckStatus.error, 'has no llamadart_native_runtimes', (h) {
    h.replace('pubspec.yaml', '      llamadart_native_runtimes: [llama_cpp]\n', '');
  }),
  _Case('a runtime llamadart does not know', 'hooks-block', CheckStatus.warning, 'llamadart ignores tflite', (h) {
    h.replace('pubspec.yaml', '[llama_cpp]', '[llama_cpp, tflite]');
  }),
  _Case('a per-platform runtimes map', 'hooks-block', CheckStatus.warning, 'per-platform map', (h) {
    h.replace('pubspec.yaml', '[llama_cpp]', '{platforms: {ios: [llama_cpp]}}');
  }),
  _Case('a workspace member with its own hooks block', 'hooks-block', CheckStatus.warning, 'is a workspace member', (
    h,
  ) {
    h.replace('pubspec.yaml', 'publish_to: none\n', 'publish_to: none\nresolution: workspace\n');
    h.write(
      '../pubspec.yaml',
      'name: root\nworkspace: [host]\nhooks:\n  user_defines:\n    llamadart:\n'
          '      llamadart_native_runtimes: [llama_cpp]\n',
    );
  }),
  // pins
  _Case('llamadart is not 0.8.23', 'pins', CheckStatus.error, 'llamadart 0.9.0 in pubspec.lock', (h) {
    h.replace('pubspec.lock', 'version: "0.8.23"', 'version: "0.9.0"');
  }),
  _Case('dinja 1.0.1', 'pins', CheckStatus.warning, 'dinja 1.0.1: in range', (h) {
    h.replace('pubspec.lock', 'version: "1.0.0"', 'version: "1.0.1"');
  }),
  _Case('dinja 1.1.0', 'pins', CheckStatus.error, 'outside >=1.0.0 <1.1.0', (h) {
    h.replace('pubspec.lock', 'version: "1.0.0"', 'version: "1.1.0"');
  }),
  // one-ref
  _Case('the packages resolve to two commits', 'one-ref', CheckStatus.error, 'the git sources differ', (h) {
    h.replace('pubspec.lock', _entry('local_inference_flutter'), _lockEntry('local_inference_flutter'));
  }),
  _Case('one package from git, one by path', 'one-ref', CheckStatus.error, 'mixed sources', (h) {
    h.replace('pubspec.lock', _entry('local_inference_flutter'), _lockEntry('local_inference_flutter', source: 'path'));
  }),
  _Case(
    'one package from git, the other from pub.dev',
    'one-ref',
    CheckStatus.error,
    'local_inference from hosted',
    (h) => h.replace('pubspec.lock', _entry('local_inference'), _lockEntry('local_inference', source: 'hosted')),
    fixSays: 'dependency_overrides',
  ),
  _Case('two package servers', 'one-ref', CheckStatus.error, 'the package servers differ', (h) {
    h.replace(
      'pubspec.lock',
      'packages:\n',
      'packages:\n${_lockEntry('local_inference_flutter', source: 'hosted', server: 'https://pub.example.com')}',
    );
  }, fixture: 'dart_host'),
  _Case(
    'two versions from pub.dev',
    'one-ref',
    CheckStatus.ok,
    'local_inference 0.1.0, local_inference_flutter 0.1.1: hosted at https://pub.dev',
    (h) => h.replace(
      'pubspec.lock',
      'packages:\n',
      'packages:\n${_lockEntry('local_inference_flutter', source: 'hosted', version: '0.1.1')}',
    ),
    fixture: 'dart_host',
  ),
  _Case('two versions', 'one-ref', CheckStatus.error, 'the versions differ', (h) {
    h.replace(
      'pubspec.lock',
      _entry('local_inference_flutter'),
      _lockEntry('local_inference_flutter', version: '0.1.1', commit: '1' * 40),
    );
  }),
  _Case('none of the packages resolved', 'one-ref', CheckStatus.error, 'pubspec.lock has none of', (h) {
    h.replace('pubspec.lock', _entry('local_inference_flutter'), '');
    h.replace('pubspec.lock', _entry('local_inference'), '');
  }),
  // sibling-ref
  _Case('local_inference next to its sibling at a tag', 'sibling-ref', CheckStatus.error, 'not a commit SHA', (h) {
    _addDependency(h, 'local_inference', 'v-0.1.0');
  }),
  _Case('local_inference next to its sibling, both at a commit', 'sibling-ref', CheckStatus.ok, 'ref $_sha', (h) {
    _addDependency(h, 'local_inference', _sha);
    h.replace('pubspec.yaml', 'ref: v-0.1.0', 'ref: $_sha');
  }),
  _Case('two refs', 'sibling-ref', CheckStatus.error, 'different url strings or refs', (h) {
    _addDependency(h, 'local_inference', 'v-0.1.1');
  }),
  // runtimes
  _Case('the Apple companion', 'runtimes', CheckStatus.error, 'llamadart_llama_cpp_flutter is resolved', (h) {
    _addLockEntry(h, 'llamadart_llama_cpp_flutter');
  }),
  _Case('another runtime', 'runtimes', CheckStatus.warning, 'flutter_gemma is another on-device model runtime', (h) {
    _addLockEntry(h, 'flutter_gemma');
  }),
  // litert-lm
  _Case('a build that selected LiteRT-LM', 'litert-lm', CheckStatus.error, 'selected more than llama_cpp', (h) {
    h.addHookRun('aaaa000003', os: 'android', arch: 'arm64', runtimes: [], logged: 'llama_cpp, litert_lm');
  }),
  _Case('a build without a log whose defines had no runtimes', 'litert-lm', CheckStatus.error, 'defines []', (h) {
    h.addHookRun('aaaa000004', os: 'macos', arch: 'x64', runtimes: [], logged: null);
  }),
  _Case('a LiteRT-LM download in the llamadart cache', 'litert-lm', CheckStatus.warning, 'selected LiteRT-LM', (h) {
    Directory(
      p.join(h.llamadartRoot, '.dart_tool', 'llamadart', 'litert_lm', '0.16.0-native.2'),
    ).createSync(recursive: true);
  }),
  // natives
  _Case('the vendored folder is missing', 'natives', CheckStatus.error, 'does not exist', (h) => h.delete('natives')),
  _Case('a bundle a build needs is not vendored', 'natives', CheckStatus.error, 'macos-x86_64 is missing from', (h) {
    h.delete('natives/v0.4.0/macos-x86_64');
  }),
  _Case('the simulator bundle is not vendored', 'natives', CheckStatus.warning, 'ios-arm64-sim is missing from', (h) {
    h.delete('natives/v0.4.0/ios-arm64-sim');
  }),
  _Case('no guard file', 'natives', CheckStatus.warning, 'has no extracted/target-bundle-not-vendored.so', (h) {
    h.delete('natives/v0.4.0/extracted/target-bundle-not-vendored.so');
  }),
  _Case(
    'a vendored library that differs from the manifest',
    'natives',
    CheckStatus.error,
    'ios-arm64/extracted/libllamadart.dylib: SHA-256',
    (h) => h.write('natives/v0.4.0/ios-arm64/extracted/libllamadart.dylib', 'changed'),
    verify: true,
  ),
  _Case(
    'a vendored library the manifest does not list',
    'natives',
    CheckStatus.error,
    'macos-arm64/extracted/libextra.dylib is not in the manifest',
    (h) => h.write('natives/v0.4.0/macos-arm64/extracted/libextra.dylib', 'extra'),
    verify: true,
  ),
  _Case(
    'a vendored file is missing',
    'natives',
    CheckStatus.error,
    'android-x64/extracted/libggml.so is missing',
    (h) => h.delete('natives/v0.4.0/android-x64/extracted/libggml.so'),
    verify: true,
  ),
  _Case(
    'a download in the hook\'s cache that differs from the manifest',
    'natives',
    CheckStatus.error,
    'macos-arm64/extracted/libllamadart.dylib: SHA-256',
    (h) => File(p.join(h.hookCache, 'macos-arm64', 'extracted', 'libllamadart.dylib')).writeAsStringSync('changed'),
    fixture: 'dart_host',
    verify: true,
  ),
  // native-output
  _Case(
    'a library a build bundled that differs from the manifest',
    'native-output',
    CheckStatus.error,
    'the manifest says',
    (h) => h.write('.dart_tool/hooks_runner/shared/llamadart/build/aaaa000002/llamadart_bin/libllamadart.dylib', 'x'),
    verify: true,
  ),
  // ios-deployment-target
  _Case('iOS 15.0', 'ios-deployment-target', CheckStatus.error, 'IPHONEOS_DEPLOYMENT_TARGET 15.0 for Debug', (h) {
    h.replace(
      'ios/Runner.xcodeproj/project.pbxproj',
      'IPHONEOS_DEPLOYMENT_TARGET = 16.4;',
      'IPHONEOS_DEPLOYMENT_TARGET = 15.0;',
    );
  }),
  _Case('a target the doctor cannot compare', 'ios-deployment-target', CheckStatus.warning, 'not a version number', (
    h,
  ) {
    h.replace(
      'ios/Runner.xcodeproj/project.pbxproj',
      'IPHONEOS_DEPLOYMENT_TARGET = 16.4;',
      'IPHONEOS_DEPLOYMENT_TARGET = "\$(RECOMMENDED_IPHONEOS_DEPLOYMENT_TARGET)";',
    );
  }),
  _Case('a Podfile at 13.0', 'ios-deployment-target', CheckStatus.warning, "platform :ios, '13.0'", (h) {
    h.write('ios/Podfile', "platform :ios, '13.0'\n");
  }),
  _Case('the target set in the xcconfig files', 'ios-deployment-target', CheckStatus.ok, 'TARGET 16.4 for Debug', (h) {
    h.replace('ios/Runner.xcodeproj/project.pbxproj', 'IPHONEOS_DEPLOYMENT_TARGET = 16.4;', '');
    for (final name in ['Debug', 'Release']) {
      h.write(
        'ios/Flutter/$name.xcconfig',
        '${h.file('ios/Flutter/$name.xcconfig').readAsStringSync()}'
            'IPHONEOS_DEPLOYMENT_TARGET = 16.4 // as a Pods or team xcconfig would\n',
      );
    }
  }),
  // ios-memory-entitlement
  _Case('no increased-memory-limit', 'ios-memory-entitlement', CheckStatus.error, 'does not grant', (h) {
    h.replace('ios/Runner/Runner.entitlements', 'increased-memory-limit', 'extended-virtual-addressing');
  }),
  _Case('no entitlements file', 'ios-memory-entitlement', CheckStatus.error, 'no CODE_SIGN_ENTITLEMENTS for Debug', (
    h,
  ) {
    h.replace('ios/Runner.xcodeproj/project.pbxproj', 'CODE_SIGN_ENTITLEMENTS = Runner/Runner.entitlements;', '');
  }),
  // ios-min-os-phase
  _Case('no Native Assets Minimum iOS phase', 'ios-min-os-phase', CheckStatus.error, 'ITMS-90208', (h) {
    h.replace('ios/Runner.xcodeproj/project.pbxproj', '7B1A0E5A2F6A000100C0FFEE /* Native Assets Minimum iOS */,', '');
  }),
  _Case('the phase before Thin Binary', 'ios-min-os-phase', CheckStatus.error, 'runs before "Thin Binary"', (h) {
    h.replace(
      'ios/Runner.xcodeproj/project.pbxproj',
      '3B06AD1E1E4923F5004D2608 /* Thin Binary */,\n\t\t\t\t7B1A0E5A2F6A000100C0FFEE /* Native Assets Minimum iOS */,',
      '7B1A0E5A2F6A000100C0FFEE /* Native Assets Minimum iOS */,\n\t\t\t\t3B06AD1E1E4923F5004D2608 /* Thin Binary */,',
    );
  }),
  _Case('the phase on dependency analysis', 'ios-min-os-phase', CheckStatus.warning, 'only when its inputs change', (
    h,
  ) {
    h.replace(
      'ios/Runner.xcodeproj/project.pbxproj',
      '/* Native Assets Minimum iOS */ = {\n\t\t\tisa = PBXShellScriptBuildPhase;\n\t\t\talwaysOutOfDate = 1;',
      '/* Native Assets Minimum iOS */ = {\n\t\t\tisa = PBXShellScriptBuildPhase;',
    );
  }),
  _Case('the script is missing', 'ios-min-os-phase', CheckStatus.error, 'which does not exist', (h) {
    h.delete('ios/scripts/native_assets_min_os.sh');
  }),
  _Case(
    'an older copy of the script',
    'ios-min-os-phase',
    CheckStatus.warning,
    'differs from local_inference_flutter',
    (h) {
      h.write('ios/scripts/native_assets_min_os.sh', '#!/bin/sh\necho an older copy\n');
    },
  ),
  _Case('an equivalent script of the host', 'ios-min-os-phase', CheckStatus.ok, 'an equivalent script of the host', (
    h,
  ) {
    h.replace('ios/Runner.xcodeproj/project.pbxproj', 'native_assets_min_os.sh', 'fix_framework_min_os.sh');
    h.write('ios/scripts/fix_framework_min_os.sh', '#!/bin/sh\n');
  }),
  // ios-script-sandboxing
  _Case('user script sandboxing on', 'ios-script-sandboxing', CheckStatus.error, 'SANDBOXING = YES for Debug', (h) {
    h.replace(
      'ios/Runner.xcodeproj/project.pbxproj',
      'ENABLE_USER_SCRIPT_SANDBOXING = NO;',
      'ENABLE_USER_SCRIPT_SANDBOXING = YES;',
    );
  }),
  // ios-notification-delegate
  _Case('no notification delegate', 'ios-notification-delegate', CheckStatus.warning, 'no source in ios/ sets', (h) {
    h.replace('ios/Runner/AppDelegate.swift', 'UNUserNotificationCenter.current().delegate = self', '');
  }),
  _Case('no background download', 'ios-notification-delegate', CheckStatus.skipped, 'not in the host', (h) {
    h.replace('pubspec.lock', _entry('background_downloader'), '');
  }),
  // ios-photo-strings
  _Case('no photo-library strings', 'ios-photo-strings', CheckStatus.warning, 'lacks NSPhotoLibraryUsageDescription', (
    h,
  ) {
    h.replace('ios/Runner/Info.plist', 'NSPhotoLibrary', 'NSOtherLibrary');
  }),
  _Case(
    'no strings, but the BYPASS variables',
    'ios-photo-strings',
    CheckStatus.ok,
    'are set here',
    (h) => h.replace('ios/Runner/Info.plist', 'NSPhotoLibrary', 'NSOtherLibrary'),
    environment: {'BYPASS_PERMISSION_IOSADDTOPHOTOLIBRARY': '1', 'BYPASS_PERMISSION_IOSCHANGEPHOTOLIBRARY': '1'},
  ),
  // ios-privacy-manifest
  _Case('no FileTimestamp C617.1', 'ios-privacy-manifest', CheckStatus.error, 'does not declare FileTimestamp C617.1', (
    h,
  ) {
    h.replace('ios/Runner/PrivacyInfo.xcprivacy', 'C617.1', '3B52.1');
  }),
  _Case('a privacy manifest the app does not bundle', 'ios-privacy-manifest', CheckStatus.error, 'Copy Bundle', (h) {
    h.replace(
      'ios/Runner.xcodeproj/project.pbxproj',
      '78B0C0DE2F6A000100A1B2C3 /* PrivacyInfo.xcprivacy in Resources */,',
      '',
    );
  }),
  // android-min-sdk
  _Case('minSdk 24', 'android-min-sdk', CheckStatus.warning, 'minSdk = 24', (h) {
    h.replace('android/app/build.gradle.kts', 'minSdk = 28', 'minSdk = 24');
  }),
  _Case('Flutter\'s minSdk', 'android-min-sdk', CheckStatus.warning, 'not a number', (h) {
    h.replace('android/app/build.gradle.kts', 'minSdk = 28', 'minSdk = flutter.minSdkVersion');
  }),
  // android-abi
  _Case('no abiFilters', 'android-abi', CheckStatus.warning, 'has no abiFilters', (h) {
    h.replace('android/app/build.gradle.kts', RegExp(r'ndk \{[^}]*\}'), '');
  }),
  _Case('a 32-bit ABI', 'android-abi', CheckStatus.warning, 'armeabi-v7a, which has no llama.cpp library', (h) {
    h.replace('android/app/build.gradle.kts', '"arm64-v8a"', '"arm64-v8a", "armeabi-v7a"');
  }),
  _Case('an ABI whose bundle is not vendored', 'android-abi', CheckStatus.error, 'whose bundle android-x64 is not in', (
    h,
  ) {
    h.replace('android/app/build.gradle.kts', '"arm64-v8a"', '"arm64-v8a", "x86_64"');
    h.delete('natives/v0.4.0/android-x64');
  }),
  // android-foreground
  _Case('an opt-in without the manifest entries', 'android-foreground', CheckStatus.error, 'lacks', (h) {
    h.write('lib/main.dart', 'final foreground = AndroidForeground.largerThan(100);\n');
  }),
  _Case(
    'entries without an opt-in',
    'android-foreground',
    CheckStatus.warning,
    'declares a dataSync',
    _addForegroundEntries,
  ),
  _Case('an opt-in with its entries', 'android-foreground', CheckStatus.ok, 'lib/main.dart:1', (h) {
    h.write('lib/main.dart', 'final foreground = AndroidForeground.always();\n');
    _addForegroundEntries(h);
  }),
  _Case('an opt-in with the permission only', 'android-foreground', CheckStatus.error, 'foregroundServiceType', (h) {
    h.write('lib/main.dart', 'final foreground = AndroidForeground.largerThan(100);\n');
    h.replace(
      'android/app/src/main/AndroidManifest.xml',
      '<application',
      '<uses-permission android:name="android.permission.FOREGROUND_SERVICE_DATA_SYNC"/>\n    <application',
    );
  }),
  // macos-deployment-target
  _Case('macOS 10.15', 'macos-deployment-target', CheckStatus.error, 'MACOSX_DEPLOYMENT_TARGET 10.15', (h) {
    h.replace(
      'macos/Runner.xcodeproj/project.pbxproj',
      'MACOSX_DEPLOYMENT_TARGET = 14.0;',
      'MACOSX_DEPLOYMENT_TARGET = 10.15;',
    );
  }),
  // macos-network-client
  _Case('sandboxed without network.client', 'macos-network-client', CheckStatus.error, 'App Sandbox is on without', (
    h,
  ) {
    h.replace('macos/Runner/Release.entitlements', 'com.apple.security.network.client', 'com.apple.security.print');
  }),
  // platform folders
  _Case('no ios/ folder', 'ios-privacy-manifest', CheckStatus.skipped, 'no ios/ folder', (h) => h.delete('ios')),
  _Case('an unreadable Xcode project', 'ios-deployment-target', CheckStatus.error, 'cannot read', (h) {
    h.write('ios/Runner.xcodeproj/project.pbxproj', '{ objects = { ');
  }),
  // pins: only an override puts another version in the lock
  _Case(
    'dinja 1.1.0 through an override',
    'pins',
    CheckStatus.error,
    'dinja 1.1.0 in pubspec.lock (dependency_overrides in pubspec.yaml)',
    (h) {
      h.replace('pubspec.lock', 'version: "1.0.0"', 'version: "1.1.0"');
      h.replace('pubspec.yaml', 'hooks:\n', 'dependency_overrides:\n  dinja: 1.1.0\n\nhooks:\n');
    },
    fixSays: 'remove dinja from dependency_overrides in pubspec.yaml',
  ),
  _Case(
    'llamadart through pubspec_overrides.yaml',
    'pins',
    CheckStatus.error,
    '(dependency_overrides in pubspec_overrides.yaml)',
    (h) {
      h.replace('pubspec.lock', 'version: "0.8.23"', 'version: "0.8.24"');
      h.write('pubspec_overrides.yaml', 'dependency_overrides:\n  llamadart: 0.8.24\n');
    },
    fixSays: 'remove llamadart from dependency_overrides in pubspec_overrides.yaml',
  ),
  // one-ref: a lock older than the pubspec
  _Case('a package listed but not locked', 'one-ref', CheckStatus.warning, 'local_inference_flutter is not in it', (h) {
    h.replace('pubspec.yaml', 'dependencies:\n', 'dependencies:\n  local_inference_flutter: ^0.1.0\n');
  }, fixture: 'dart_host'),
  _Case('a ref changed after pub get', 'one-ref', CheckStatus.warning, 'at ref v-0.1.0, the pubspec says ref v-0.1.1', (
    h,
  ) {
    h.replace('pubspec.yaml', 'ref: v-0.1.0', 'ref: v-0.1.1');
  }),
  // sibling-ref: two spellings of one commit that the lock resolves are a warning, not the sibling error
  _Case('a tag and its commit', 'sibling-ref', CheckStatus.warning, 'resolves them to one commit, ${'1' * 40}', (h) {
    _addDependency(h, 'local_inference', '"${'1' * 40}"'); // quoted: YAML reads 40 digits as a number
  }),
  // android-abi and natives: abiFilters over several lines, and ones the doctor cannot read
  _Case('abiFilters over several lines', 'android-abi', CheckStatus.error, 'whose bundle android-x64 is not in', (h) {
    h.replace(
      _gradle,
      'listOf("arm64-v8a")',
      'listOf(\n                "arm64-v8a",\n                "x86_64",\n            )',
    );
    h.delete('natives/v0.4.0/android-x64');
  }),
  _Case('abiFilters over several lines, as natives sees it', 'natives', CheckStatus.error, 'android-x64 is missing', (
    h,
  ) {
    h.replace(_gradle, 'abiFilters += listOf("arm64-v8a")', 'abiFilters.addAll(\n    listOf("arm64-v8a", "x86_64")\n)');
    h.delete('natives/v0.4.0/android-x64');
  }),
  _Case('Groovy abiFilters over two lines', 'android-abi', CheckStatus.warning, 'armeabi-v7a, which has no llama.cpp', (
    h,
  ) {
    final text = h.file(_gradle).readAsStringSync();
    h.delete(_gradle);
    h.write(
      'android/app/build.gradle',
      text.replaceFirst('abiFilters += listOf("arm64-v8a")', "abiFilters 'arm64-v8a', // 64-bit\n    'armeabi-v7a'"),
    );
  }),
  _Case(
    'abiFilters from a variable',
    'android-abi',
    CheckStatus.warning,
    'cannot read the ABIs of "abiFilters.addAll(abis)"',
    (h) {
      h.replace(_gradle, 'abiFilters += listOf("arm64-v8a")', 'abiFilters.addAll(abis)');
    },
  ),
  // android-foreground: dot shorthands, comments, arguments the doctor cannot classify, the app's other packages
  _Case(
    'an opt-in as a dot shorthand',
    'android-foreground',
    CheckStatus.error,
    'lib/download_setup.dart:2 (AndroidForeground.largerThan)',
    (h) => h.write(
      'lib/download_setup.dart',
      '// The download.\nconst downloadConfig = BackgroundDownloadConfig(androidForeground: .largerThan(100));\n',
    ),
  ),
  _Case('a typed variable as a dot shorthand', 'android-foreground', CheckStatus.error, 'lib/main.dart:1 (Android', (
    h,
  ) {
    h.write('lib/main.dart', 'final AndroidForeground foreground = .always(); // https://example.com\n');
  }),
  _Case('opt-ins in comments only', 'android-foreground', CheckStatus.ok, 'no AndroidForeground opt-in', (h) {
    h.write(
      'lib/main.dart',
      '// AndroidForeground.largerThan(100)\n/* BackgroundDownloadConfig(\n  androidForeground: .always()) */\n'
          'const url = "https://example.com/a//b";\n',
    );
  }),
  _Case(
    'a value the doctor cannot classify',
    'android-foreground',
    CheckStatus.warning,
    'lib/main.dart:2 (androidForeground: s.fg)',
    (h) {
      h.write('lib/main.dart', 'final c = BackgroundDownloadConfig(\n  androidForeground: s.fg,\n);\n');
    },
  ),
  _Case('an opt-in in a path package', 'android-foreground', CheckStatus.error, '../shared/lib/config.dart:1', (h) {
    h.replace(
      'pubspec.lock',
      'packages:\n',
      'packages:\n  shared:\n    dependency: "direct main"\n    description:\n      path: "../shared"\n'
          '      relative: true\n    source: path\n    version: "1.0.0"\n',
    );
    h.write('../shared/lib/config.dart', 'final foreground = AndroidForeground.largerThan(50);\n');
  }),
  // ios-deployment-target and macos-deployment-target: the minimums, compared as numbers, and where a value is set
  _Case('iOS 16.0', 'ios-deployment-target', CheckStatus.error, 'IPHONEOS_DEPLOYMENT_TARGET 16.0 for Debug', (h) {
    h.replace(_pbx, 'IPHONEOS_DEPLOYMENT_TARGET = 16.4;', 'IPHONEOS_DEPLOYMENT_TARGET = 16.0;');
  }),
  _Case('iOS 9.0', 'ios-deployment-target', CheckStatus.error, 'IPHONEOS_DEPLOYMENT_TARGET 9.0 for Debug', (h) {
    h.replace(_pbx, 'IPHONEOS_DEPLOYMENT_TARGET = 16.4;', 'IPHONEOS_DEPLOYMENT_TARGET = 9.0;');
  }),
  _Case('iOS 16.4.1', 'ios-deployment-target', CheckStatus.ok, 'IPHONEOS_DEPLOYMENT_TARGET 16.4.1 for Debug', (h) {
    h.replace(_pbx, 'IPHONEOS_DEPLOYMENT_TARGET = 16.4;', 'IPHONEOS_DEPLOYMENT_TARGET = 16.4.1;');
  }),
  _Case(
    'iOS 15.0 in an xcconfig file',
    'ios-deployment-target',
    CheckStatus.error,
    'IPHONEOS_DEPLOYMENT_TARGET 15.0 for Release, Profile (set in ios/Flutter/Release.xcconfig)',
    (h) => h.write(
      'ios/Flutter/Release.xcconfig',
      '${h.file('ios/Flutter/Release.xcconfig').readAsStringSync()}IPHONEOS_DEPLOYMENT_TARGET = 15.0\n',
    ),
    fixSays: 'set IPHONEOS_DEPLOYMENT_TARGET = 16.4 in ios/Flutter/Release.xcconfig',
  ),
  _Case('a Podfile without a platform line', 'ios-deployment-target', CheckStatus.ok, 'CocoaPods takes the Runner', (
    h,
  ) {
    h.write('ios/Podfile', "# platform :ios, '13.0'\ntarget 'Runner' do\nend\n");
  }),
  _Case('macOS 13.5', 'macos-deployment-target', CheckStatus.error, 'MACOSX_DEPLOYMENT_TARGET 13.5 for Debug', (h) {
    h.replace(
      'macos/Runner.xcodeproj/project.pbxproj',
      'MACOSX_DEPLOYMENT_TARGET = 14.0;',
      'MACOSX_DEPLOYMENT_TARGET = 13.5;',
    );
  }),
  // entitlements that are present but false
  _Case('increased-memory-limit set to false', 'ios-memory-entitlement', CheckStatus.error, 'does not grant', (h) {
    h.replace('ios/Runner/Runner.entitlements', '<true/>', '<false/>');
  }),
  _Case('network.client set to false', 'macos-network-client', CheckStatus.error, 'the App Sandbox is on without', (h) {
    h.replace(
      'macos/Runner/Release.entitlements',
      '<key>com.apple.security.network.client</key>\n\t<true/>',
      '<key>com.apple.security.network.client</key>\n\t<false/>',
    );
  }),
  // ios-notification-delegate: a commented-out line does not count
  _Case('the delegate line commented out', 'ios-notification-delegate', CheckStatus.warning, 'no source in ios/', (h) {
    h.replace(
      'ios/Runner/AppDelegate.swift',
      'UNUserNotificationCenter.current().delegate = self',
      '// UNUserNotificationCenter.current().delegate = self',
    );
  }),
  // ios-photo-strings: a CocoaPods build takes the Podfile's flags, not the BYPASS variables
  _Case(
    'CocoaPods with the BYPASS variables only',
    'ios-photo-strings',
    CheckStatus.warning,
    'the BYPASS variables do nothing for a CocoaPods build',
    _podsBuildDownloader,
    environment: _bypass,
    fixSays: "config.build_settings['OTHER_SWIFT_FLAGS'] << '-D BYPASS_PERMISSION_IOSADDTOPHOTOLIBRARY'",
  ),
  _Case('CocoaPods with the BYPASS flags', 'ios-photo-strings', CheckStatus.ok, 'the Podfile passes -D BYPASS', (h) {
    _podsBuildDownloader(h);
    h.write('ios/Podfile', _bypassPodfile());
  }),
  _Case('CocoaPods with the flags commented out', 'ios-photo-strings', CheckStatus.warning, 'lacks NSPhotoLibrary', (
    h,
  ) {
    _podsBuildDownloader(h);
    h.write('ios/Podfile', _bypassPodfile(comment: '# '));
  }),
  // natives: the fixes name the fetch script of the local_inference the host resolves, and the hook's rebuild
  _Case('an empty vendored folder', 'natives', CheckStatus.error, 'vendored in natives/v0.4.0: no bundle', (h) {
    h.delete('natives/v0.4.0');
    Directory(p.join(h.dir, 'natives', 'v0.4.0')).createSync(recursive: true);
  }, fixSays: '--dest natives/v0.4.0 <bundle>... (it writes the guard file'),
  _Case(
    'a vendored bundle missing, with local_inference\'s fetch script',
    'natives',
    CheckStatus.error,
    'macos-x86_64 is missing from',
    (h) {
      h.delete('natives/v0.4.0/macos-x86_64');
      File(p.join(h.base, 'git', 'local_inference', 'tool', 'native', 'fetch_llamadart_native.sh'))
        ..createSync(recursive: true)
        ..writeAsStringSync('#!/bin/sh\n');
    },
    fixSays: '/git/local_inference/tool/native/fetch_llamadart_native.sh --dest natives/v0.4.0 macos-x86_64',
  ),
  _Case(
    'a changed download in the hook\'s cache: the hook fetches it on the next build',
    'natives',
    CheckStatus.error,
    'macos-arm64/extracted/libllamadart.dylib: SHA-256',
    (h) => File(p.join(h.hookCache, 'macos-arm64', 'extracted', 'libllamadart.dylib')).writeAsStringSync('changed'),
    fixture: 'dart_host',
    verify: true,
    fixSays: 'then flutter clean (or delete .dart_tool/hooks_runner) and build again',
  ),
];

/// The entries of a host that opts in to the dataSync foreground service (local_inference_flutter's README).
void _addForegroundEntries(FixtureHost host) {
  const manifest = 'android/app/src/main/AndroidManifest.xml';
  host.replace(
    manifest,
    '<application',
    '<uses-permission android:name="android.permission.FOREGROUND_SERVICE_DATA_SYNC"/>\n    <application',
  );
  host.replace(
    manifest,
    '</application>',
    '    <service android:name="androidx.work.impl.foreground.SystemForegroundService"\n'
        '            android:foregroundServiceType="dataSync" tools:node="merge"/>\n    </application>',
  );
}

void main() {
  group('a good Flutter host (iOS, Android, macOS)', () {
    late FixtureHost host;
    setUp(() => host = FixtureHost.create('flutter_host'));
    tearDown(() => host.dispose());

    test('passes every check with --strict, hashes included', () {
      final report = host.run(verify: true, strict: true);
      expect([
        for (final r in report.results)
          if (r.status != CheckStatus.ok) '$r',
      ], isEmpty);
      expect(report.results.map((r) => r.id), doctorChecks.keys);
      expect((report.exitCode, report.kind, report.platforms.join(',')), (0, 'flutter', 'android,ios,macos'));
      expect(report['natives']!.found, contains('match the manifest (v0.4.0)'));
      expect(report['native-output']!.found, contains('2 libraries of 2 builds match the manifest'));
      expect(report['one-ref']!.found, contains('git $_url at ${'1' * 40}'));
      expect(report['ios-min-os-phase']!.found, contains('the same as local_inference_flutter'));
      expect(report['macos-network-client']!.found, contains('sandboxed, with com.apple.security.network.client'));
    });

    test('without --verify-natives nothing is hashed: native-output is skipped and says why', () {
      final report = host.run();
      expect(report['native-output']!.status, CheckStatus.skipped);
      expect(report['native-output']!.found, contains('--verify-natives'));
      expect(report['natives']!.found, contains('not hashed'));
      expect(report.exitCode, 0);
    });

    test('the report as text and as JSON', () {
      final report = host.run(strict: true);
      final text = report.render();
      expect(text, startsWith('local_inference doctor '));
      expect(text, contains('a Flutter app (android, ios, macos)'));
      expect(text, contains('\nok       hooks-block '));
      expect(text, contains('20 checks: 19 ok, 0 warnings, 0 errors, 1 skipped. --strict: warnings fail.'));
      final json = report.toJson();
      expect(json['summary'], {'ok': 19, 'warning': 0, 'error': 0, 'skipped': 1});
      expect((json['results']! as List).first, {
        'id': 'hooks-block',
        'title': 'the llamadart hooks block',
        'status': 'ok',
        'found': 'pubspec.yaml: llamadart_native_runtimes: [llama_cpp]\nllamadart_native_path: natives/v0.4.0',
        'fix': null,
      });
    });
  });

  group('a good pure-Dart host', () {
    late FixtureHost host;
    setUp(() => host = FixtureHost.create('dart_host'));
    tearDown(() => host.dispose());

    test('passes; every platform check is skipped because it is pure Dart, and the downloads are hashed', () {
      final report = host.run(verify: true, strict: true);
      expect((report.exitCode, report.kind, report.platforms.isEmpty), (0, 'dart', true));
      for (final r in report.results) {
        if (r.id.startsWith('ios-') || r.id.startsWith('android-') || r.id.startsWith('macos-')) {
          expect((r.id, r.status, r.found.contains('a pure-Dart host')), (r.id, CheckStatus.skipped, true));
        } else {
          expect((r.id, r.status), (r.id, CheckStatus.ok), reason: r.found);
        }
      }
      expect(report['one-ref']!.found, contains('local_inference 0.1.0: hosted at https://pub.dev'));
      expect(report['sibling-ref']!.found, contains('local_inference: ^0.1.0'));
      expect(report['natives']!.found, contains('the hook downloads each bundle from GitHub'));
      expect(report['natives']!.found, contains('match the manifest (v0.4.0): macos-arm64 (2 files)'));
    });

    test('before pub get: the checks that need the lock say so', () {
      host.delete('pubspec.lock');
      host.delete('.dart_tool');
      final report = host.run();
      for (final id in ['pins', 'one-ref', 'runtimes']) {
        expect(report[id]!.status, CheckStatus.skipped);
        expect(report[id]!.found, contains('run flutter pub get (or dart pub get) first'));
      }
      expect(report.exitCode, 0);
    });
  });

  test('a workspace root: the platform checks point at its app, and hooks-block warns', () {
    final host = FixtureHost.create('flutter_host');
    addTearDown(host.dispose);
    host.replace('pubspec.yaml', 'publish_to: none\n', 'publish_to: none\nresolution: workspace\n');
    host.write(
      '../pubspec.yaml',
      'name: root\nenvironment:\n  sdk: ^3.12.0\nworkspace: [host]\nhooks:\n  user_defines:\n    llamadart:\n'
          '      llamadart_native_runtimes: [llama_cpp]\n',
    );
    final report = Doctor(
      p.dirname(host.dir),
      strict: true,
      environment: const {},
      manifest: fakeManifest,
      machineBundle: 'macos-arm64',
    ).run();
    expect(report.kind, 'workspace');
    expect(report.render(), contains(', a workspace root\n'));
    expect(report['hooks-block']!.status, CheckStatus.warning);
    expect(report['hooks-block']!.found, contains('this is a workspace root'));
    expect(report['hooks-block']!.fix, contains('dart run local_inference_flutter:doctor --strict <app folder>'));
    expect(report['ios-deployment-target']!.status, CheckStatus.skipped);
    expect(
      report['ios-deployment-target']!.found,
      contains('a workspace root: its apps have their own settings (host)'),
    );
    expect(report.exitCode, 1);
  });

  group('one broken host per failure class', () {
    for (final c in _cases) {
      test('${c.name}: ${c.check} ${c.status.name}', () {
        final host = FixtureHost.create(c.fixture);
        addTearDown(host.dispose);
        c.change(host);
        final report = host.run(verify: c.verify, environment: c.environment);
        final result = report[c.check]!;
        expect(result.status, c.status, reason: result.found);
        expect(result.found, contains(c.says));
        if (c.fixSays != null) expect(result.fix, contains(c.fixSays));
        if (c.status == CheckStatus.warning || c.status == CheckStatus.error) {
          expect(result.fix, isNotNull);
          expect(report.exitCode, c.status == CheckStatus.error ? 1 : 0);
          expect(host.run(verify: c.verify, strict: true, environment: c.environment).exitCode, 1);
        } else {
          expect(result.fix, isNull);
        }
      });
    }
  });
}
