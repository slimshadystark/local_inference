/// The Android host settings: minSdk, the ABIs the APK carries against the llama.cpp bundles, and the
/// foreground-service entries against the host's `AndroidForeground` choice.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'checks_natives.dart';
import 'context.dart';
import 'natives.dart';
import 'report.dart';
import 'xml.dart';

CheckResult? _gradle(DoctorContext c, Findings f) {
  final skip = c.skipPlatform(f, 'android');
  if (skip != null) return skip;
  if (c.gradlePath == null) {
    f.error('no android/app/build.gradle.kts or build.gradle', 'flutter create --platforms android . recreates it');
    return f.result();
  }
  return null;
}

/// `android-min-sdk`: minSdk is a number ≥ 28 (the plugin builds from 24; below 28 `checkDeviceSupport()` refuses the
/// assistant at run time).
CheckResult checkAndroidMinSdk(DoctorContext c) {
  final f = Findings('android-min-sdk', 'Android minSdk 28');
  final stop = _gradle(c, f);
  if (stop != null) return stop;
  final path = c.gradlePath!;
  final shown = c.host.show(path);
  const fix = 'set minSdk = 28 in defaultConfig of android/app/build.gradle.kts (minSdkVersion 28 in build.gradle)';
  const why = 'below API 28 checkDeviceSupport() refuses the assistant at run time, after the app is installed';
  final values = RegExp(
    r'\bminSdk(?:Version)?\s*(?:=\s*|\(\s*|\s+)([A-Za-z0-9_.]+)',
  ).allMatches(c.gradleText!).map((m) => m[1]!).toList();
  if (values.isEmpty) {
    f.warning('$shown sets no minSdk: Flutter\'s default (flutter.minSdkVersion, 24) applies; $why', fix);
  }
  for (final value in values) {
    final level = int.tryParse(value);
    if (level == null) {
      f.warning('$shown: minSdk = $value, not a number (flutter.minSdkVersion is 24); $why', fix);
    } else if (level < 28) {
      f.warning('$shown: minSdk = $level; $why', fix);
    } else {
      f.ok('$shown: minSdk = $level');
    }
  }
  return f.result();
}

/// `android-abi`: `abiFilters` keeps the ABIs llama.cpp has a library for (arm64-v8a, x86_64), and with vendored
/// natives each of them has its bundle.
CheckResult checkAndroidAbi(DoctorContext c) {
  final f = Findings('android-abi', 'Android ABIs and their llama.cpp bundles');
  final stop = _gradle(c, f);
  if (stop != null) return stop;
  final shown = c.host.show(c.gradlePath!);
  final filters = c.abiFilters;
  final vendored = c.host.nativePath;
  const filterFix = 'add ndk { abiFilters += listOf("arm64-v8a") } to defaultConfig (with "x86_64" too for emulators)';
  if (filters == null) {
    f.warning(
      '$shown has no abiFilters: the APK also carries armeabi-v7a, which has no llama.cpp library (such phones are '
      'refused at run time), and x86_64',
      filterFix,
    );
  } else {
    for (final statement in filters.unreadable) {
      f.warning(
        '$shown: the doctor cannot read the ABIs of "$statement" (it reads ABI names written as quoted strings)',
        'write the ABIs as quoted names, such as abiFilters += listOf("arm64-v8a"), or check by hand that they are '
            'arm64-v8a and x86_64 only${vendored == null ? '' : ', each with its bundle in ${c.host.show(vendored)}'}',
      );
    }
    for (final abi in filters.abis) {
      final bundle = androidBundleForAbi(abi);
      if (bundle == null) {
        f.warning('$shown: abiFilters has $abi, which has no llama.cpp library', filterFix);
      } else if (vendored != null && !Directory(p.join(vendored, bundle)).existsSync()) {
        f.error(
          '$shown: abiFilters has $abi, whose bundle $bundle is not in ${c.host.show(vendored)}: the build stops '
              'on the guard file',
          'fetch it with ${fetchScript(c)} --dest ${c.host.show(vendored)} $bundle',
        );
      } else {
        f.ok('$shown: abiFilters has $abi (bundle $bundle${vendored == null ? '' : ', vendored'})');
      }
    }
  }
  if (filters == null && vendored != null) {
    for (final bundle in const ['android-arm64', 'android-x64']) {
      if (!Directory(p.join(vendored, bundle)).existsSync()) {
        f.error(
          'without abiFilters the build also targets $bundle, which is not in ${c.host.show(vendored)}: it stops on '
          'the guard file',
          filterFix,
        );
      }
    }
  }
  return f.result();
}

/// An opt-in to a foreground-service download: `AndroidForeground.always()` or `.largerThan(…)`, also as a dot
/// shorthand passed to `androidForeground:` or given to a variable of type AndroidForeground.
final _optIn = RegExp(
  r'\bAndroidForeground\s*\.\s*(always|largerThan)\s*\(|'
  r'\bandroidForeground\s*:\s*(?:const\s+)?\.\s*(always|largerThan)\s*\(|'
  r'\bAndroidForeground\??\s+\w+\s*=\s*(?:const\s+)?\.\s*(always|largerThan)\s*\(',
);

/// An `androidForeground:` argument, and the values the doctor can classify.
final _argument = RegExp(r'\bandroidForeground\s*:\s*');
final _known = RegExp(r'^(?:const\s+)?(?:AndroidForeground\s*)?\.\s*(?:always|largerThan|never)\s*\(');

/// The opt-ins in the app's Dart code, and the `androidForeground:` arguments the doctor cannot classify (a variable,
/// a call), each as `file:line (what)`.
({List<String> optIns, List<String> unclear}) _foregroundChoices(DoctorContext c) {
  final optIns = <String>[], unclear = <String>[];
  for (final file in c.host.dartSources) {
    final String text;
    try {
      text = stripComments(file.readAsStringSync());
    } on FileSystemException {
      continue;
    }
    String where(int offset) => '${c.host.show(file.path)}:${'\n'.allMatches(text.substring(0, offset)).length + 1}';
    for (final m in _optIn.allMatches(text)) {
      optIns.add('${where(m.start)} (AndroidForeground.${m[1] ?? m[2] ?? m[3]})');
    }
    for (final m in _argument.allMatches(text)) {
      final rest = text.substring(m.end);
      if (!_known.hasMatch(rest)) {
        unclear.add('${where(m.start)} (androidForeground: ${RegExp(r'^[^,)\n]*').firstMatch(rest)![0]!.trim()})');
      }
    }
  }
  return (optIns: optIns, unclear: unclear);
}

/// `android-foreground`: the manifest's dataSync foreground-service entries agree with the host's AndroidForeground
/// choice (opted in with `.always()` or `.largerThan(…)` in the app's code: the entries are needed; not opted in: they
/// would ask for a Play declaration the app does not need).
CheckResult checkAndroidForeground(DoctorContext c) {
  const service = 'androidx.work.impl.foreground.SystemForegroundService';
  const permission = 'android.permission.FOREGROUND_SERVICE_DATA_SYNC';
  final f = Findings('android-foreground', 'foreground-service entries and AndroidForeground');
  final skip = c.skipPlatform(f, 'android');
  if (skip != null) return skip;
  if (!c.host.resolves('background_downloader')) {
    return f.skipped('background_downloader is not in the host\'s packages: no background download');
  }
  final (:optIns, :unclear) = _foregroundChoices(c);
  final manifestPath = p.join(c.host.dir, 'android', 'app', 'src', 'main', 'AndroidManifest.xml');
  final shown = c.host.show(manifestPath);
  if (!File(manifestPath).existsSync()) {
    f.error('no $shown', 'flutter create --platforms android . recreates it');
    return f.result();
  }
  final XmlElement manifest;
  try {
    manifest = parseXml(File(manifestPath).readAsStringSync());
  } on FormatException catch (e) {
    f.error('$shown cannot be read: ${e.message}', 'fix the XML of $shown');
    return f.result();
  }
  final elements = manifest.descendants.toList();
  final hasPermission = elements.any((e) => e.name == 'uses-permission' && e.attributes['android:name'] == permission);
  final typed = elements.any(
    (e) =>
        e.name == 'service' &&
        e.attributes['android:name'] == service &&
        (e.attributes['android:foregroundServiceType'] ?? '').split('|').contains('dataSync'),
  );
  if (optIns.isNotEmpty) {
    final missing = [
      if (!hasPermission) '<uses-permission android:name="$permission"/>',
      if (!typed) '<service android:name="$service" android:foregroundServiceType="dataSync" tools:node="merge"/>',
    ];
    if (missing.isEmpty) {
      f.ok(
        '${optIns.join(', ')} opts in, and $shown declares $permission and the dataSync type (declare it in the Play '
        'Console too)',
      );
    } else {
      f.error(
        '${optIns.join(', ')} opts in to a foreground-service download, but $shown lacks ${missing.join(' and ')}: '
            'Android 14 stops a foreground service without its type',
        'add ${missing.join(' and ')} to $shown (xmlns:tools on <manifest>), and declare the dataSync use in the Play '
            'Console',
      );
    }
  } else if (unclear.isNotEmpty) {
    f.warning(
      '${unclear.join(', ')}: the doctor cannot tell whether this opts in to a foreground-service download, so it '
          'cannot check ${hasPermission || typed ? 'that' : 'whether'} $shown needs its dataSync entries',
      'with an opt-in (AndroidForeground.always() or .largerThan(…)), $shown needs <uses-permission '
          'android:name="$permission"/> and <service android:name="$service" android:foregroundServiceType="dataSync" '
          'tools:node="merge"/>; without one it needs neither',
    );
  } else if (hasPermission || typed) {
    f.warning(
      '$shown declares a dataSync foreground service, but the app\'s code opts in nowhere (AndroidForeground.never() '
          'is the default): Google Play asks for a declaration of that use',
      'remove $permission and the dataSync type from $shown, or opt in with AndroidForeground.largerThan(…)',
    );
  } else {
    f.ok('no AndroidForeground opt-in in the app\'s code and no dataSync entries in $shown (the default: never)');
  }
  return f.result();
}
