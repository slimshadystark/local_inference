// The doctor's command line (runDoctor, bin/doctor.dart): options, the host folder (the current one by default), the
// exit status (0 passed, 1 an error or a warning with --strict, 2 a usage error), --json, --install-ios-script.
import 'dart:convert';
import 'dart:io';

import 'package:local_inference/doctor.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../bin/doctor.dart' as bin;
import 'fixture_host.dart';

void main() {
  late FixtureHost host;
  late StringBuffer out, err;
  setUp(() {
    host = FixtureHost.create('flutter_host');
    out = StringBuffer();
    err = StringBuffer();
  });
  tearDown(() => host.dispose());

  int doctor(List<String> args, {Map<String, String> environment = const {}}) => runDoctor(
    args,
    out: out,
    err: err,
    environment: environment,
    manifest: fakeManifest,
    machineBundle: 'macos-arm64',
  );

  test('a good host: exit 0, the text report; the current folder by default', () {
    expect(doctor([host.dir]), 0);
    expect(out.toString(), startsWith('local_inference doctor '));
    expect(out.toString(), contains('Exit status 0.'));
    expect(err.toString(), isEmpty);
    final here = StringBuffer();
    final code = IOOverrides.runZoned(
      () => runDoctor(
        const [],
        out: here,
        err: err,
        environment: const {},
        manifest: fakeManifest,
        machineBundle: 'macos-arm64',
      ),
      getCurrentDirectory: () => Directory(host.dir),
    );
    expect(code, 0);
    expect(here.toString(), contains(': ${host.dir}, a Flutter app'));
  });

  test('--json: the report as JSON, with the same results', () {
    expect(doctor(['--json', '--verify-natives', host.dir]), 0);
    final json = jsonDecode(out.toString()) as Map<String, Object?>;
    expect((json['tool'], json['format']), ('local_inference doctor', 1));
    expect((json['host'], json['kind'], json['verifyNatives'], json['exitCode']), (host.dir, 'flutter', true, 0));
    expect([for (final r in json['results']! as List) (r as Map)['id']], doctorChecks.keys);
    expect(json['summary'], {'ok': 20, 'warning': 0, 'error': 0, 'skipped': 0});
  });

  test('an error exits 1; a warning exits 0, and 1 with --strict', () {
    host.replace('ios/Runner/Runner.entitlements', 'increased-memory-limit', 'extended-virtual-addressing');
    expect(doctor([host.dir]), 1);
    expect(out.toString(), contains('error    ios-memory-entitlement'));
    expect(out.toString(), contains('fix: add the Increased Memory Limit capability'));
    host.replace('ios/Runner/Runner.entitlements', 'extended-virtual-addressing', 'increased-memory-limit');
    host.replace('android/app/build.gradle.kts', 'minSdk = 28', 'minSdk = 24');
    expect(doctor([host.dir]), 0);
    expect(doctor(['--strict', host.dir]), 1);
    expect(out.toString(), contains('--strict: warnings fail.'));
  });

  test('usage errors exit 2: an unknown option, two folders, a folder without pubspec.yaml', () {
    expect(doctor(['--nope', host.dir]), 2);
    expect(err.toString(), contains('unknown option --nope'));
    expect(err.toString(), contains('Usage: dart run local_inference:doctor'));
    expect(doctor([host.dir, host.dir]), 2);
    expect(doctor([p.join(host.dir, 'ios')]), 2);
    expect(err.toString(), contains('no pubspec.yaml in ${p.join(host.dir, 'ios')}'));
    expect(out.toString(), isEmpty);
  });

  test('a pubspec.yaml that is not valid YAML, or not a map, is a usage error with the reason', () {
    host.write('pubspec.yaml', 'name: bad\ndependencies:\n  foo: [\n');
    expect(doctor([host.dir]), 2);
    expect(err.toString(), contains('pubspec.yaml is not valid YAML'));
    expect(doctor(['--install-ios-script', host.dir]), 2);
    host.write('pubspec.yaml', '- a list\n');
    expect(doctor([host.dir]), 2);
    expect(err.toString(), contains('is not a YAML map'));
    expect(out.toString(), isEmpty);
  });

  test('--help names the command it runs as, the options and the exit status', () {
    expect(runDoctor(const ['--help'], out: out, err: err, command: 'local_inference_flutter:doctor'), 0);
    final help = out.toString();
    expect(help, contains('Usage: dart run local_inference_flutter:doctor [options] [host folder]'));
    for (final option in ['--json', '--strict', '--verify-natives', '--install-ios-script', '--help']) {
      expect(help, contains(option));
    }
    expect(help, contains('Exit status: 0 when no check failed; 1 when a check found an error'));
    expect(help, contains('dart run resolves the package it runs from and runs its build hooks'));
    expect(err.toString(), isEmpty);
  });

  test('--install-ios-script copies the packaged script and prints the build-phase steps', () {
    host.delete('ios/scripts');
    host.replace(
      'ios/Runner.xcodeproj/project.pbxproj',
      '7B1A0E5A2F6A000100C0FFEE /* Native Assets Minimum iOS */,',
      '',
    );
    expect(doctor(['--install-ios-script', host.dir]), 0);
    final script = host.file('ios/scripts/native_assets_min_os.sh');
    final packaged = File(p.join(host.flutterPackageRoot, 'tool', 'ios', 'native_assets_min_os.sh'));
    expect(script.readAsStringSync(), packaged.readAsStringSync());
    expect(out.toString(), contains('Copied ios/scripts/native_assets_min_os.sh'));
    expect(out.toString(), contains('Name it "Native Assets Minimum iOS"'));
    expect(out.toString(), contains(r'/bin/sh "$SRCROOT/scripts/native_assets_min_os.sh"'));
    expect(out.toString(), contains('Drag the phase below "Thin Binary"'));
    expect(out.toString(), isNot(contains('local_inference doctor 0')), reason: 'no check runs');

    // An older copy is replaced; with the phase in place there is nothing more to do.
    host
      ..write('ios/scripts/native_assets_min_os.sh', 'older')
      ..replace(
        'ios/Runner.xcodeproj/project.pbxproj',
        '3B06AD1E1E4923F5004D2608 /* Thin Binary */,',
        '3B06AD1E1E4923F5004D2608 /* Thin Binary */,\n'
            '\t\t\t\t7B1A0E5A2F6A000100C0FFEE /* Native Assets Minimum iOS */,',
      );
    out.clear();
    expect(doctor(['--install-ios-script', host.dir]), 0);
    expect(out.toString(), contains('Replaced an older ios/scripts/native_assets_min_os.sh'));
    expect(out.toString(), contains('The Runner target already runs it.'));
    expect(script.readAsStringSync(), packaged.readAsStringSync());
  });

  test('--install-ios-script leaves an equivalent phase of the host alone', () {
    host
      ..replace('ios/Runner.xcodeproj/project.pbxproj', 'native_assets_min_os.sh', 'fix_framework_min_os.sh')
      ..replace('ios/Runner.xcodeproj/project.pbxproj', 'Native Assets Minimum iOS', 'Fix Framework Min OS')
      ..write('ios/scripts/fix_framework_min_os.sh', '#!/bin/sh\n')
      ..delete('ios/scripts/native_assets_min_os.sh');
    expect(doctor(['--install-ios-script', host.dir]), 0);
    expect(out.toString(), contains('already has "Fix Framework Min OS"'));
    expect(out.toString(), contains('nothing to install'));
    expect(out.toString(), isNot(contains('Add the build phase')));
    expect(host.file('ios/scripts/native_assets_min_os.sh').existsSync(), isFalse);
    out.clear();
    expect(doctor(['--strict', host.dir]), 0, reason: 'the check accepts the phase');
  });

  test('--install-ios-script exits 2 without an ios/ folder or without local_inference_flutter', () {
    final dart = FixtureHost.create('dart_host');
    addTearDown(dart.dispose);
    expect(doctor(['--install-ios-script', dart.dir]), 2);
    expect(err.toString(), contains('has no ios/ folder'));
    host.delete('.dart_tool/package_config.json');
    expect(doctor(['--install-ios-script', host.dir]), 2);
    expect(err.toString(), contains('local_inference_flutter is not resolved'));
  });

  test('bin/doctor.dart runs it (dart run local_inference:doctor)', () {
    bin.main(const ['--help']);
    expect(exitCode, 0);
  });
}
