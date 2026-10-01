/// The iOS and macOS host settings a plugin cannot carry: deployment targets, entitlements, the ITMS-90208 build phase,
/// script sandboxing, the notification delegate, the photo-library strings and the app's privacy manifest.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'context.dart';
import 'natives.dart';
import 'report.dart';
import 'xcode.dart';
import 'xml.dart';

/// The app target of [platform]'s Xcode project, or the result that says why there is none.
({XcodeProject project, XcodeTarget target})? _app(
  DoctorContext c,
  String platform,
  Findings f,
  List<CheckResult> out,
) {
  final skip = c.skipPlatform(f, platform);
  if (skip != null) {
    out.add(skip);
    return null;
  }
  final project = c.xcodeProject(platform);
  if (project is! XcodeProject) {
    f.error('$project', 'flutter create --platforms $platform . recreates the platform folder');
    out.add(f.result());
    return null;
  }
  return (project: project, target: project.appTarget!);
}

/// Configuration names grouped by the value [value] gives each, in the target's order.
Map<String?, List<String>> _byValue(XcodeTarget target, String? Function(XcodeConfig config) value) {
  final groups = <String?, List<String>>{};
  for (final config in target.configs) {
    (groups[value(config)] ??= []).add(config.name);
  }
  return groups;
}

/// [path] as a build setting names it, relative to the project folder (`$(SRCROOT)/` and `${SRCROOT}/` allowed).
String _projectFile(XcodeProject project, String path) {
  final stripped = path.replaceFirst(RegExp(r'^\$[({](SRCROOT|PROJECT_DIR)[)}]/'), '');
  return p.normalize(p.isAbsolute(stripped) ? stripped : p.join(project.projectDir, stripped));
}

Object? _readPlist(String path) {
  try {
    return parsePlist(File(path).readAsStringSync());
  } on FormatException catch (e) {
    return e;
  } on FileSystemException catch (e) {
    return e;
  }
}

CheckResult _deploymentTarget(
  DoctorContext c, {
  required String platform,
  required String id,
  required String setting,
  required String minimum,
  required String podPlatform,
  required String why,
}) {
  final f = Findings(id, '$platform deployment target $minimum');
  final out = <CheckResult>[];
  final app = _app(c, platform, f, out);
  if (app == null) return out.single;
  final targetName = app.target.name;
  // The configurations by value and by where the value is set: the target, the project, or an .xcconfig file.
  final groups = <(String?, String?), List<String>>{};
  for (final config in app.target.configs) {
    final file = config.settingFile(setting);
    final origin = switch (config.settingSource(setting)) {
      null => null,
      _ when file != null => 'in ${c.host.show(file)}',
      'target' => 'on the $targetName target',
      _ => 'on the project',
    };
    (groups[(config.setting(setting), origin)] ??= []).add(config.name);
  }
  for (final MapEntry(key: (value, origin), value: configs) in groups.entries) {
    final where = '${configs.join(', ')}${origin == null ? '' : ' (set $origin)'}';
    final fix = origin != null && origin.startsWith('in ')
        ? 'set $setting = $minimum $origin (or delete it there and set it on the $targetName target)'
        : 'set $setting = $minimum on the $targetName target and the project (all configurations)';
    final order = value == null ? null : compareDottedVersions(value, minimum);
    if (value == null) {
      f.warning('$setting is not set for $where: Xcode then uses the SDK\'s own version', fix);
    } else if (order == null) {
      f.warning('$setting = $value for $where: not a version number the doctor can compare with $minimum', fix);
    } else if (order < 0) {
      f.error('$setting $value for $where: $why', fix);
    } else {
      f.ok('$setting $value for $where');
    }
  }
  final podfile = File(p.join(c.host.dir, platform, 'Podfile'));
  if (podfile.existsSync()) {
    final line = RegExp(
      '^\\s*platform\\s+:$podPlatform\\s*,\\s*["\']([0-9.]+)["\']',
      multiLine: true,
    ).firstMatch(podfile.readAsStringSync());
    final podFix = "write platform :$podPlatform, '$minimum' in $platform/Podfile";
    if (line == null) {
      f.ok(
        '$platform/Podfile has no platform :$podPlatform line: CocoaPods takes the $targetName target\'s deployment '
        'target',
      );
    } else if ((compareDottedVersions(line[1]!, minimum) ?? -1) < 0) {
      f.warning('$platform/Podfile: platform :$podPlatform, \'${line[1]}\'', podFix);
    } else {
      f.ok('$platform/Podfile: platform :$podPlatform, \'${line[1]}\'');
    }
  }
  return f.result();
}

/// `ios-deployment-target`: IPHONEOS_DEPLOYMENT_TARGET ≥ 16.4 in every configuration of the app target (and the
/// Podfile's platform, when there is one).
CheckResult checkIosDeploymentTarget(DoctorContext c) => _deploymentTarget(
  c,
  platform: 'ios',
  id: 'ios-deployment-target',
  setting: 'IPHONEOS_DEPLOYMENT_TARGET',
  minimum: '16.4',
  podPlatform: 'ios',
  why: 'llamadart\'s library needs iOS 16.4 (its minos), and local_inference_flutter\'s Package.swift says 16.4',
);

/// `macos-deployment-target`: MACOSX_DEPLOYMENT_TARGET ≥ 14.0 in every configuration of the app target.
CheckResult checkMacosDeploymentTarget(DoctorContext c) => _deploymentTarget(
  c,
  platform: 'macos',
  id: 'macos-deployment-target',
  setting: 'MACOSX_DEPLOYMENT_TARGET',
  minimum: '14.0',
  podPlatform: 'osx',
  why: 'local_inference_flutter\'s Package.swift and podspec need macOS 14.0',
);

/// The entitlements file of each configuration, grouped: path → configurations; configurations without one under
/// the key null.
Map<String?, List<String>> _entitlements(XcodeProject project, XcodeTarget target) => _byValue(target, (config) {
  final path = config.setting('CODE_SIGN_ENTITLEMENTS');
  return path == null || path.isEmpty ? null : _projectFile(project, path);
});

/// `ios-memory-entitlement`: each configuration's entitlements grant com.apple.developer.kernel.increased-memory-limit.
CheckResult checkIosMemoryEntitlement(DoctorContext c) {
  const key = 'com.apple.developer.kernel.increased-memory-limit';
  final f = Findings('ios-memory-entitlement', 'the increased-memory-limit entitlement');
  final out = <CheckResult>[];
  final app = _app(c, 'ios', f, out);
  if (app == null) return out.single;
  const fix =
      'add the Increased Memory Limit capability to the Runner target (Signing & Capabilities); it writes '
      '<key>$key</key><true/> into Runner/Runner.entitlements for every configuration';
  for (final MapEntry(key: path, value: configs) in _entitlements(app.project, app.target).entries) {
    final where = configs.join(', ');
    if (path == null) {
      f.error(
        'no CODE_SIGN_ENTITLEMENTS for $where: without the entitlement iOS stops the app when a model loads',
        fix,
      );
      continue;
    }
    final shown = c.host.show(path);
    final plist = _readPlist(path);
    if (plist is! Map) {
      f.error('$shown ($where) cannot be read: $plist', fix);
    } else if (plist[key] != true) {
      f.error('$shown ($where) does not grant $key: without it iOS stops the app when a model loads', fix);
    } else {
      f.ok('$shown ($where): $key');
    }
  }
  return f.result();
}

/// Whether [phase] is a Run Script phase that fixes the native-asset frameworks' MinimumOSVersion: ours (by name or
/// script), or a host's own script for the same fix, recognized by the common name `fix_framework_min_os.sh`.
bool fixesMinimumOs(XcodePhase phase) =>
    phase.isa == 'PBXShellScriptBuildPhase' &&
    (phase.name == 'Native Assets Minimum iOS' ||
        phase.shellScript.contains('native_assets_min_os.sh') ||
        phase.shellScript.contains('fix_framework_min_os.sh'));

/// `ios-min-os-phase`: a Run Script phase after "Thin Binary" fixes the MinimumOSVersion Flutter writes into the
/// native-asset frameworks (ITMS-90208); it runs on every build, its script exists, and a copy of ours equals the
/// packaged one.
CheckResult checkIosMinOsPhase(DoctorContext c) {
  final f = Findings('ios-min-os-phase', 'the "Native Assets Minimum iOS" build phase');
  final out = <CheckResult>[];
  final app = _app(c, 'ios', f, out);
  if (app == null) return out.single;
  final phases = app.target.phases;
  const install =
      'dart run local_inference_flutter:doctor --install-ios-script copies the script to ios/scripts/ and prints '
      'the steps';
  final thin = phases.indexWhere((ph) => ph.name == 'Thin Binary' || ph.shellScript.contains('embed_and_thin'));
  final fixes = [
    for (var i = 0; i < phases.length; i++)
      if (fixesMinimumOs(phases[i])) i,
  ];
  if (fixes.isEmpty) {
    f.error(
      'the ${app.target.name} target has no phase that sets the native-asset frameworks\' MinimumOSVersion: App Store '
      'Connect rejects the upload (ITMS-90208)',
      install,
    );
    return f.result();
  }
  if (fixes.length > 1) {
    f.warning(
      '${fixes.length} phases fix MinimumOSVersion: ${fixes.map((i) => '"${phases[i].name}"').join(', ')}',
      'keep one of them',
    );
  }
  for (final i in fixes) {
    final phase = phases[i];
    final name = '"${phase.name}"';
    if (thin < 0) {
      f.warning('no "Thin Binary" phase to run $name after', 'keep the phase after the phase that embeds Flutter');
    } else if (i < thin) {
      f.error(
        '$name runs before "Thin Binary", which embeds the frameworks it must fix',
        'drag $name below "Thin Binary" in the ${app.target.name} target\'s Build Phases',
      );
    } else {
      f.ok('$name runs after "Thin Binary"');
    }
    if (!phase.alwaysOutOfDate) {
      f.warning(
        '$name runs only when its inputs change ("Based on dependency analysis" is on)',
        'uncheck "Based on dependency analysis" on $name',
      );
    }
    final script = RegExp(
      r'''(?:\$\{?(?:SRCROOT|PROJECT_DIR)\}?|\$\((?:SRCROOT|PROJECT_DIR)\))/([^"'\s]+\.sh)''',
    ).firstMatch(phase.shellScript);
    if (script == null) {
      if (phase.shellScript.contains('MinimumOSVersion')) {
        f.ok('$name is an inline script that sets MinimumOSVersion (not compared with the packaged one)');
      } else {
        f.warning('$name runs no script the doctor recognizes', install);
      }
      continue;
    }
    final file = p.normalize(p.join(app.project.projectDir, script[1]));
    final shown = c.host.show(file);
    if (!File(file).existsSync()) {
      f.error('$name runs $shown, which does not exist', install);
      continue;
    }
    if (p.basename(file) != 'native_assets_min_os.sh') {
      f.ok('$name runs $shown (an equivalent script of the host)');
      continue;
    }
    final packagedRoot = c.host.packageRoot('local_inference_flutter');
    final packaged = packagedRoot == null ? null : p.join(packagedRoot, 'tool', 'ios', 'native_assets_min_os.sh');
    if (packaged == null || !File(packaged).existsSync()) {
      f.ok('$name runs $shown (local_inference_flutter is not resolved: not compared with its copy)');
    } else if (sha256OfFile(file) != sha256OfFile(packaged)) {
      f.warning(
        '$shown differs from local_inference_flutter\'s tool/ios/native_assets_min_os.sh (an older copy?)',
        'dart run local_inference_flutter:doctor --install-ios-script replaces it with the packaged one',
      );
    } else {
      f.ok('$name runs $shown, the same as local_inference_flutter\'s tool/ios/native_assets_min_os.sh');
    }
  }
  return f.result();
}

/// `ios-script-sandboxing`: ENABLE_USER_SCRIPT_SANDBOXING is not YES (the phase edits and signs frameworks again).
CheckResult checkIosScriptSandboxing(DoctorContext c) {
  final f = Findings('ios-script-sandboxing', 'user script sandboxing off');
  final out = <CheckResult>[];
  final app = _app(c, 'ios', f, out);
  if (app == null) return out.single;
  const setting = 'ENABLE_USER_SCRIPT_SANDBOXING';
  for (final MapEntry(key: value, value: configs) in _byValue(
    app.target,
    (config) => config.setting(setting),
  ).entries) {
    final where = configs.join(', ');
    if (value == 'YES') {
      f.error(
        '$setting = YES for $where: the "Native Assets Minimum iOS" phase cannot edit and sign the frameworks',
        'set $setting = NO (Build Settings › User Script Sandboxing: No) on the ${app.target.name} target',
      );
    } else {
      f.ok(value == null ? '$setting is not set for $where (Xcode\'s default, NO)' : '$setting = $value for $where');
    }
  }
  return f.result();
}

/// `ios-notification-delegate`: an AppDelegate makes the app UNUserNotificationCenter's delegate, so the download
/// notifications (background_downloader) reach the app.
CheckResult checkIosNotificationDelegate(DoctorContext c) {
  final f = Findings('ios-notification-delegate', 'the notification center delegate');
  final out = <CheckResult>[];
  final skip = c.skipPlatform(f, 'ios');
  if (skip != null) return skip;
  if (!c.host.resolves('background_downloader')) {
    return f.skipped('background_downloader is not in the host\'s packages: no download notifications');
  }
  final app = _app(c, 'ios', f, out);
  if (app == null) return out.single;
  final pattern = RegExp(
    r'UNUserNotificationCenter\s*\.\s*current\s*\(\s*\)\s*\.\s*delegate\s*=|'
    r'\[\s*UNUserNotificationCenter\s+currentNotificationCenter\s*\]\s*\.\s*delegate\s*=|'
    r'UNUserNotificationCenter\s*\.\s*currentNotificationCenter\s*\.\s*delegate\s*=',
  );
  final sources = [
    for (final entity in Directory(p.join(c.host.dir, 'ios')).listSync(recursive: true, followLinks: false))
      if (entity is File &&
          RegExp(r'\.(swift|m|mm)$').hasMatch(entity.path) &&
          !p
              .split(p.relative(entity.path, from: c.host.dir))
              .any((s) => s == 'Pods' || s == 'Flutter' || s == '.symlinks'))
        entity,
  ];
  final setting = sources
      .where((file) => pattern.hasMatch(stripComments(file.readAsStringSync())))
      .map((f) => c.host.show(f.path));
  if (setting.isEmpty) {
    f.warning(
      'no source in ios/ sets UNUserNotificationCenter\'s delegate: the download notifications and their buttons do '
          'not reach the app',
      'in AppDelegate.swift: import UserNotifications, then UNUserNotificationCenter.current().delegate = self before '
          'super.application(...didFinishLaunchingWithOptions:); an SDK that owns the delegate must forward to '
          'FlutterAppDelegate',
    );
  } else {
    f.ok('${setting.join(', ')} sets UNUserNotificationCenter\'s delegate');
  }
  return f.result();
}

/// `ios-photo-strings`: the app's Info.plist has the photo-library strings background_downloader's linked APIs need
/// for an App Store upload, or background_downloader is built without those APIs: through Swift Package Manager with
/// the BYPASS variables set (in every build environment), or through CocoaPods with the BYPASS flags in the Podfile.
CheckResult checkIosPhotoStrings(DoctorContext c) {
  const keys = ['NSPhotoLibraryUsageDescription', 'NSPhotoLibraryAddUsageDescription'];
  const bypass = ['BYPASS_PERMISSION_IOSADDTOPHOTOLIBRARY', 'BYPASS_PERMISSION_IOSCHANGEPHOTOLIBRARY'];
  final f = Findings('ios-photo-strings', 'the photo-library strings');
  final out = <CheckResult>[];
  final skip = c.skipPlatform(f, 'ios');
  if (skip != null) return skip;
  if (!c.host.resolves('background_downloader')) {
    return f.skipped('background_downloader is not in the host\'s packages');
  }
  final app = _app(c, 'ios', f, out);
  if (app == null) return out.single;
  // A plugin built through CocoaPods is in Podfile.lock. Its podspec ignores the BYPASS variables (only
  // background_downloader's Package.swift reads them); the Podfile passes the flags instead (its doc/permissions.md).
  final podLock = File(p.join(c.host.dir, 'ios', 'Podfile.lock'));
  final viaPods = podLock.existsSync() && podLock.readAsStringSync().contains('background_downloader');
  final podfile = File(p.join(c.host.dir, 'ios', 'Podfile'));
  // Without Ruby comments (a # that does not open an interpolation).
  final podfileText = podfile.existsSync()
      ? podfile.readAsStringSync().replaceAllMapped(RegExp(r'(^|\s)#(?!\{)[^\n]*', multiLine: true), (m) => m[1]!)
      : '';
  final bypassed = viaPods
      ? bypass.every((name) => RegExp('-D\\s*$name\\b').hasMatch(podfileText))
      : bypass.every((name) => c.environment[name] == '1');
  final how = viaPods
      ? 'the Podfile passes ${bypass.map((b) => '-D $b').join(' and ')} to background_downloader (CocoaPods)'
      : '${bypass.join(' and ')} are set here; they must be set in every build environment (Xcode, CI)';
  final bypassFix = viaPods
      ? 'or, since background_downloader is built through CocoaPods (ios/Podfile.lock), add '
            '${bypass.map((b) => "config.build_settings['OTHER_SWIFT_FLAGS'] << '-D $b'").join(' and ')} for its '
            'target in the Podfile\'s post_install (background_downloader\'s doc/permissions.md)'
      : 'or set ${bypass.join('=1 and ')}=1 in every build environment';
  final podsNote = viaPods ? ' (the BYPASS variables do nothing for a CocoaPods build)' : '';
  final plists = _byValue(app.target, (config) {
    final path = config.setting('INFOPLIST_FILE');
    return _projectFile(app.project, path == null || path.isEmpty ? 'Runner/Info.plist' : path);
  });
  for (final MapEntry(key: path, value: configs) in plists.entries) {
    final shown = c.host.show(path!);
    final plist = _readPlist(path);
    final missing = plist is Map
        ? [
            for (final key in keys)
              if (plist[key] is! String || (plist[key] as String).trim().isEmpty) key,
          ]
        : keys;
    if (missing.isEmpty) {
      f.ok('$shown (${configs.join(', ')}): ${keys.join(', ')}');
    } else if (bypassed) {
      f.ok('$shown lacks ${missing.join(', ')}, but $how');
    } else {
      f.warning(
        '$shown lacks ${missing.join(' and ')}: background_downloader links the photo-library APIs, and App Store '
            'Connect rejects an upload without these strings$podsNote',
        'add ${keys.join(' and ')} to $shown (they are never shown), $bypassFix',
      );
    }
  }
  return f.result();
}

/// `ios-privacy-manifest`: the app target bundles a PrivacyInfo.xcprivacy that declares FileTimestamp C617.1
/// (llamadart.framework calls stat and fstat).
CheckResult checkIosPrivacyManifest(DoctorContext c) {
  final f = Findings('ios-privacy-manifest', 'FileTimestamp C617.1 in the app privacy manifest');
  final out = <CheckResult>[];
  final app = _app(c, 'ios', f, out);
  if (app == null) return out.single;
  const fix =
      'declare NSPrivacyAccessedAPICategoryFileTimestamp with the reason C617.1 in ios/Runner/PrivacyInfo.xcprivacy '
      '(NSPrivacyAccessedAPITypes), and keep the file in the Runner target\'s Copy Bundle Resources';
  final manifests = {
    for (final phase in app.target.phases)
      if (phase.isa == 'PBXResourcesBuildPhase')
        for (final path in phase.filePaths)
          if (p.basename(path) == 'PrivacyInfo.xcprivacy') path,
  };
  if (manifests.isEmpty) {
    final onDisk = p.join(c.host.dir, 'ios', 'Runner', 'PrivacyInfo.xcprivacy');
    f.error(
      File(onDisk).existsSync()
          ? '${c.host.show(onDisk)} is not in the ${app.target.name} target\'s Copy Bundle Resources: the app ships '
                'without it'
          : 'the ${app.target.name} target bundles no PrivacyInfo.xcprivacy: App Store Connect requires the reason for '
                'llamadart.framework\'s stat and fstat calls',
      fix,
    );
    return f.result();
  }
  for (final path in manifests) {
    final shown = c.host.show(path);
    final plist = _readPlist(path);
    final types = plist is Map ? plist['NSPrivacyAccessedAPITypes'] : null;
    final declared =
        types is List &&
        types.any(
          (t) =>
              t is Map &&
              t['NSPrivacyAccessedAPIType'] == 'NSPrivacyAccessedAPICategoryFileTimestamp' &&
              t['NSPrivacyAccessedAPITypeReasons'] is List &&
              (t['NSPrivacyAccessedAPITypeReasons'] as List).contains('C617.1'),
        );
    if (plist is! Map) {
      f.error('$shown cannot be read: $plist', fix);
    } else if (!declared) {
      f.error(
        '$shown does not declare FileTimestamp C617.1: llamadart.framework calls stat and fstat, and App Store Connect '
        'rejects the upload without the reason',
        fix,
      );
    } else {
      f.ok('$shown declares FileTimestamp C617.1');
    }
  }
  return f.result();
}

/// `macos-network-client`: a sandboxed configuration has the network.client entitlement the download needs.
CheckResult checkMacosNetworkClient(DoctorContext c) {
  const sandbox = 'com.apple.security.app-sandbox';
  const client = 'com.apple.security.network.client';
  final f = Findings('macos-network-client', 'network access when sandboxed');
  final out = <CheckResult>[];
  final app = _app(c, 'macos', f, out);
  if (app == null) return out.single;
  for (final MapEntry(key: path, value: configs) in _entitlements(app.project, app.target).entries) {
    final where = configs.join(', ');
    if (path == null) {
      f.ok('no entitlements for $where: not sandboxed');
      continue;
    }
    final shown = c.host.show(path);
    final plist = _readPlist(path);
    if (plist is! Map) {
      f.error('$shown ($where) cannot be read: $plist', 'fix the property list $shown');
    } else if (plist[sandbox] == true && plist[client] != true) {
      f.error(
        '$shown ($where): the App Sandbox is on without $client, so the model download fails',
        'add <key>$client</key><true/> to $shown',
      );
    } else {
      f.ok(
        plist[sandbox] == true
            ? '$shown ($where): sandboxed, with $client'
            : '$shown ($where): not sandboxed (with the App Sandbox on, add $client)',
      );
    }
  }
  return f.result();
}
