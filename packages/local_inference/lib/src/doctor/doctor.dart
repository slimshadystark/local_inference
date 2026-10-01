/// The doctor: runs every check on a host and reports; the command line of `bin/doctor.dart`.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import '../version.dart';
import 'checks_android.dart';
import 'checks_apple.dart';
import 'checks_natives.dart';
import 'checks_pub.dart';
import 'context.dart';
import 'host.dart';
import 'natives.dart';
import 'report.dart';
import 'xcode.dart';

/// The checks, in report order, by id.
const Map<String, DoctorCheck> doctorChecks = {
  'hooks-block': checkHooksBlock,
  'pins': checkPins,
  'one-ref': checkOneRef,
  'sibling-ref': checkSiblingRef,
  'runtimes': checkRuntimes,
  'litert-lm': checkLiteRt,
  'natives': checkNatives,
  'native-output': checkNativeOutput,
  'ios-deployment-target': checkIosDeploymentTarget,
  'ios-memory-entitlement': checkIosMemoryEntitlement,
  'ios-min-os-phase': checkIosMinOsPhase,
  'ios-script-sandboxing': checkIosScriptSandboxing,
  'ios-notification-delegate': checkIosNotificationDelegate,
  'ios-photo-strings': checkIosPhotoStrings,
  'ios-privacy-manifest': checkIosPrivacyManifest,
  'android-min-sdk': checkAndroidMinSdk,
  'android-abi': checkAndroidAbi,
  'android-foreground': checkAndroidForeground,
  'macos-deployment-target': checkMacosDeploymentTarget,
  'macos-network-client': checkMacosNetworkClient,
};

/// Checks a host app or package against what the local_inference packages need. It reads files only: it runs no tool,
/// uses no network and changes nothing. (`dart run` runs the build hooks of the package that holds the doctor before
/// the doctor starts: see [doctorUsage].)
final class Doctor {
  Doctor(
    this.hostDir, {
    this.strict = false,
    this.verifyNatives = false,
    Map<String, String>? environment,
    NativeManifest? manifest,
    String? machineBundle,
  }) : environment = environment ?? Platform.environment,
       manifest = manifest ?? NativeManifest.embedded,
       machineBundle = machineBundle ?? thisMachineBundle;

  /// The host's folder (it holds its pubspec.yaml).
  final String hostDir;

  /// Whether warnings fail the run ([DoctorReport.exitCode]).
  final bool strict;

  /// Whether to hash the native libraries against [manifest].
  final bool verifyNatives;

  final Map<String, String> environment;
  final NativeManifest manifest;

  /// The llama.cpp bundle of this computer (its builds for `dart test`, `flutter test`, `dart run`).
  final String machineBundle;

  /// Runs every check; throws [FormatException] when [hostDir]'s pubspec.yaml is missing or cannot be read.
  DoctorReport run() {
    final host = HostProject.load(hostDir);
    final context = DoctorContext(
      host: host,
      environment: environment,
      manifest: manifest,
      machineBundle: machineBundle,
      verifyNatives: verifyNatives,
    );
    return DoctorReport(
      version: localInferenceVersion,
      host: host.dir,
      kind: host.isFlutter
          ? 'flutter'
          : host.isWorkspaceRoot
          ? 'workspace'
          : 'dart',
      platforms: host.platforms,
      strict: strict,
      verifyNatives: verifyNatives,
      results: [for (final MapEntry(key: id, value: check) in doctorChecks.entries) _run(id, check, context)],
    );
  }

  static CheckResult _run(String id, DoctorCheck check, DoctorContext context) {
    try {
      return check(context);
    } on Object catch (e) {
      // One unreadable file must not hide the other checks.
      return CheckResult(
        id: id,
        title: id,
        status: CheckStatus.error,
        found: 'the check could not run: $e',
        fix: 'fix what the message names, or report it with the host\'s files',
      );
    }
  }
}

/// The help text of the command line; [command] is how it was started.
String doctorUsage([String command = 'local_inference:doctor']) =>
    '''
Checks a host app or package against what the local_inference packages need: the hooks block, the pinned versions,
how the packages are listed, the llama.cpp bundles, and the iOS, Android and macOS settings a plugin cannot carry.
The doctor reads files only: it uses no network, and nothing changes unless --install-ios-script is given.

Usage: dart run $command [options] [host folder]

The host folder is the app or package to check (the default is the current folder). local_inference:doctor and
local_inference_flutter:doctor run the same checks.

dart run resolves the package it runs from and runs its build hooks before the doctor starts: llamadart's hook
builds for this computer (its bundle is vendored, or downloaded into the pub cache once) and, without the hooks
block, downloads LiteRT-LM too. So add the hooks block first. Where dart run fails before the doctor starts (the
pubspec does not resolve, a companion package, no bundle for this computer, no network), run the doctor from another
package that resolves local_inference, with the host folder as the argument.

Options:
  --json                 print the report as JSON
  --strict               warnings fail too
  --verify-natives       also hash the llama.cpp bundles (the vendored folder, or the hook's downloads in the pub
                         cache) and the libraries the host's builds bundled, against local_inference's manifest
  --install-ios-script   copy local_inference_flutter's tool/ios/native_assets_min_os.sh to ios/scripts/ and print
                         the build-phase steps; no check runs
  -h, --help             this text

Exit status: 0 when no check failed; 1 when a check found an error, or a warning with --strict; 2 for a usage error
(an unknown option, a folder without a readable pubspec.yaml, --install-ios-script without an ios/ folder).''';

/// Runs the doctor for the command line [args] and returns the exit status (see [doctorUsage]). The report goes to
/// [out] (stdout by default), usage errors to [err] (stderr). [environment], [manifest] and [machineBundle] replace
/// the process environment, the embedded manifest and this computer's bundle (for tests).
int runDoctor(
  List<String> args, {
  StringSink? out,
  StringSink? err,
  Map<String, String>? environment,
  NativeManifest? manifest,
  String? machineBundle,
  String command = 'local_inference:doctor',
}) {
  final output = out ?? stdout;
  final errors = err ?? stderr;
  var json = false, strict = false, verify = false, install = false;
  final folders = <String>[];
  for (final arg in args) {
    switch (arg) {
      case '--json':
        json = true;
      case '--strict':
        strict = true;
      case '--verify-natives':
        verify = true;
      case '--install-ios-script':
        install = true;
      case '-h' || '--help':
        output.writeln(doctorUsage(command));
        return 0;
      default:
        if (arg.startsWith('-')) {
          errors.writeln('doctor: unknown option $arg\n\n${doctorUsage(command)}');
          return 2;
        }
        folders.add(arg);
    }
  }
  if (folders.length > 1) {
    errors.writeln('doctor: one host folder at most, got ${folders.join(' ')}\n\n${doctorUsage(command)}');
    return 2;
  }
  final dir = p.normalize(p.absolute(folders.isEmpty ? Directory.current.path : folders.single));
  if (!File(p.join(dir, 'pubspec.yaml')).existsSync()) {
    errors.writeln(
      'doctor: no pubspec.yaml in $dir: run the doctor in the host app or package, or name its folder '
      '(dart run $command --help)',
    );
    return 2;
  }
  final HostProject host;
  try {
    host = HostProject.load(dir);
  } on FormatException catch (e) {
    errors.writeln('doctor: ${e.message}');
    return 2;
  } on FileSystemException catch (e) {
    errors.writeln('doctor: cannot read ${e.path ?? p.join(dir, 'pubspec.yaml')}: ${e.message}');
    return 2;
  }
  if (install) return installIosScript(host, out: output, err: errors, command: command);
  final report = Doctor(
    dir,
    strict: strict,
    verifyNatives: verify,
    environment: environment,
    manifest: manifest,
    machineBundle: machineBundle,
  ).run();
  output.write(json ? '${report.toJsonText()}\n' : report.render());
  return report.exitCode;
}

/// `--install-ios-script`: copies local_inference_flutter's tool/ios/native_assets_min_os.sh to the host's
/// ios/scripts/ and prints how to add the build phase. Returns 0, or 2 when there is no ios/ folder or
/// local_inference_flutter is not resolved.
int installIosScript(HostProject host, {required StringSink out, required StringSink err, required String command}) {
  final ios = p.join(host.dir, 'ios');
  if (!Directory(ios).existsSync()) {
    err.writeln('doctor: --install-ios-script: ${host.dir} has no ios/ folder');
    return 2;
  }
  final pbxproj = XcodeProject.find(ios);
  var phases = const <XcodePhase>[];
  if (pbxproj != null) {
    try {
      phases = XcodeProject.read(pbxproj).appTarget?.phases ?? const [];
    } on FormatException {
      // The steps below still apply; the check reports the unreadable project.
    } on FileSystemException {
      // As above.
    }
  }
  final runsOurs = phases.any((ph) => ph.shellScript.contains('native_assets_min_os.sh'));
  final equivalent = phases.where(fixesMinimumOs).map((ph) => '"${ph.name}"').toList();
  if (!runsOurs && equivalent.isNotEmpty) {
    out.writeln(
      'The app target already has ${equivalent.join(', ')}, which sets the frameworks\' MinimumOSVersion: nothing to '
      'install (a second phase would do the same work). Run dart run $command --strict to check it.',
    );
    return 0;
  }
  final package = host.packageRoot('local_inference_flutter');
  final source = package == null ? null : p.join(package, 'tool', 'ios', 'native_assets_min_os.sh');
  if (source == null || !File(source).existsSync()) {
    err.writeln(
      'doctor: --install-ios-script: local_inference_flutter is not resolved in ${host.dir} (depend on it, then '
      'flutter pub get)',
    );
    return 2;
  }
  final target = p.join(ios, 'scripts', 'native_assets_min_os.sh');
  final before = File(target).existsSync() ? File(target).readAsBytesSync() : null;
  final bytes = File(source).readAsBytesSync();
  final same = before != null && before.length == bytes.length && _equal(before, bytes);
  if (same) {
    out.writeln('${host.show(target)} is already the same as $source.');
  } else {
    File(target)
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(bytes);
    out.writeln('${before == null ? 'Copied' : 'Replaced an older'} ${host.show(target)} (from $source).');
  }
  if (runsOurs) {
    out.writeln('The Runner target already runs it. Run dart run $command --strict to check the rest.');
    return 0;
  }
  out.writeln('''
Add the build phase in Xcode (open ios/Runner.xcworkspace), on the Runner target:
  1. Build Phases > + > New Run Script Phase.
  2. Name it "Native Assets Minimum iOS".
  3. Script: /bin/sh "\$SRCROOT/scripts/native_assets_min_os.sh"
  4. Uncheck "Based on dependency analysis".
  5. Drag the phase below "Thin Binary".
  6. Build Settings > User Script Sandboxing (ENABLE_USER_SCRIPT_SANDBOXING): No, for all configurations.
Then run dart run $command --strict.''');
  return 0;
}

bool _equal(List<int> a, List<int> b) {
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
