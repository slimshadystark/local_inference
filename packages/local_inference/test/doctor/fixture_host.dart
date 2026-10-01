// A fixture host of test/fixtures/doctor/ copied into a temporary folder, with what `pub get` and a build would have
// added: .dart_tool/package_config.json (llamadart and local_inference_flutter in fake folders), llamadart hook runs,
// and small fake native bundles (vendored for the Flutter host, the hook's download cache for the Dart host) with a
// manifest of their hashes.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:local_inference/doctor.dart';
import 'package:path/path.dart' as p;

/// The fake llama.cpp files of each bundle: archive and unpacked files.
const fakeBundles = {
  'macos-arm64': ['libllamadart.dylib'],
  'macos-x86_64': ['libllamadart.dylib'],
  'ios-arm64': ['libllamadart.dylib'],
  'ios-arm64-sim': ['libllamadart.dylib'],
  'android-arm64': ['libggml.so', 'libllamadart.so'],
  'android-x64': ['libggml.so', 'libllamadart.so'],
};

String fakeArchive(String bundle) => 'llamadart-native-$bundle-v0.4.0.tar.gz';

String _archiveBytes(String bundle) => 'the archive of $bundle\n';

String _libraryBytes(String bundle, String name) => 'the library $name of $bundle\n';

String _sha(String text) => crypto.sha256.convert(utf8.encode(text)).toString();

/// The manifest of [fakeBundles], in the format of tool/native/llamadart-native-v0.4.0.sha256.
final NativeManifest fakeManifest = NativeManifest.parse(
  [
    '# fake bundles of the doctor tests',
    for (final MapEntry(key: bundle, value: files) in fakeBundles.entries) ...[
      for (final name in files) '${_sha(_libraryBytes(bundle, name))}  $bundle/extracted/$name',
      '${_sha(_archiveBytes(bundle))}  $bundle/${fakeArchive(bundle)}',
    ],
    '${_sha('')}  extracted/target-bundle-not-vendored.so',
  ].join('\n'),
  tag: 'v0.4.0',
);

final class FixtureHost {
  FixtureHost._(this.base, this.dir);

  /// Copies test/fixtures/doctor/[fixture] (`flutter_host` or `dart_host`) and adds the resolution and build state.
  factory FixtureHost.create(String fixture) {
    final base = Directory.systemTemp.createTempSync('doctor_$fixture').resolveSymbolicLinksSync();
    final host = FixtureHost._(base, p.join(base, 'host'));
    _copy(p.join('test', 'fixtures', 'doctor', fixture), host.dir);
    final flutter = fixture == 'flutter_host';
    final packages = <String, String>{
      'llamadart': host.llamadartRoot,
      // The Flutter host takes the packages from git, the Dart host from pub.dev.
      'local_inference': flutter
          ? p.join(base, 'git', 'local_inference')
          : p.join(base, 'pub-cache', 'hosted', 'pub.dev', 'local_inference-0.1.0'),
      if (flutter) 'local_inference_flutter': host.flutterPackageRoot,
    };
    for (final root in packages.values) {
      Directory(root).createSync(recursive: true);
    }
    host.write(
      '.dart_tool/package_config.json',
      const JsonEncoder.withIndent('  ').convert({
        'configVersion': 2,
        'packages': [
          for (final MapEntry(key: name, value: root) in packages.entries)
            {'name': name, 'rootUri': Uri.directory(root).toString(), 'packageUri': 'lib/', 'languageVersion': '3.10'},
        ],
      }),
    );
    if (flutter) {
      final script = File(p.join(host.dir, 'ios', 'scripts', 'native_assets_min_os.sh'));
      File(p.join(host.flutterPackageRoot, 'tool', 'ios', 'native_assets_min_os.sh'))
        ..createSync(recursive: true)
        ..writeAsBytesSync(script.readAsBytesSync());
      for (final bundle in fakeBundles.keys) {
        host.writeBundle(p.join(host.dir, 'natives', 'v0.4.0', bundle), bundle);
      }
      host.write('natives/v0.4.0/extracted/target-bundle-not-vendored.so', '');
      host.addHookRun('aaaa000001', os: 'macos', arch: 'arm64');
      host.addHookRun('aaaa000002', os: 'ios', arch: 'arm64', iosSdk: 'iphoneos');
    } else {
      host.writeBundle(p.join(host.hookCache, 'macos-arm64'), 'macos-arm64');
      host.addHookRun('bbbb000001', os: 'macos', arch: 'arm64');
    }
    return host;
  }

  final String base;

  /// The host's folder.
  final String dir;

  String get llamadartRoot => p.join(base, 'pub-cache', 'hosted', 'pub.dev', 'llamadart-0.8.23');

  String get flutterPackageRoot => p.join(base, 'git', 'local_inference_flutter');

  /// The hook's download cache in the fake llamadart package.
  String get hookCache => p.join(llamadartRoot, '.dart_tool', 'llamadart', 'native_bundles', 'v0.4.0');

  /// The Flutter host's vendored natives (its llamadart_native_path).
  String get vendored => p.join(dir, 'natives', 'v0.4.0');

  /// Runs the doctor on the host with the fake manifest, as on an Apple silicon Mac, in an empty environment.
  DoctorReport run({bool verify = false, bool strict = false, Map<String, String> environment = const {}}) => Doctor(
    dir,
    verifyNatives: verify,
    strict: strict,
    environment: environment,
    manifest: fakeManifest,
    machineBundle: 'macos-arm64',
  ).run();

  File file(String relative) => File(p.join(dir, relative));

  void write(String relative, String contents) => File(p.join(dir, relative))
    ..createSync(recursive: true)
    ..writeAsStringSync(contents);

  /// Replaces [from] with [to] in the host's file [relative]; fails when [from] is not there.
  void replace(String relative, Pattern from, String to) {
    final text = file(relative).readAsStringSync();
    final changed = text.replaceAll(from, to);
    if (changed == text) throw StateError('$relative does not contain $from');
    file(relative).writeAsStringSync(changed);
  }

  void delete(String relative) {
    final type = FileSystemEntity.typeSync(p.join(dir, relative));
    if (type == FileSystemEntityType.directory) {
      Directory(p.join(dir, relative)).deleteSync(recursive: true);
    } else {
      File(p.join(dir, relative)).deleteSync();
    }
  }

  /// Writes [bundle]'s fake archive and unpacked files into [folder].
  void writeBundle(String folder, String bundle) {
    File(p.join(folder, fakeArchive(bundle)))
      ..createSync(recursive: true)
      ..writeAsStringSync(_archiveBytes(bundle));
    for (final name in fakeBundles[bundle]!) {
      File(p.join(folder, 'extracted', name))
        ..createSync(recursive: true)
        ..writeAsStringSync(_libraryBytes(bundle, name));
    }
  }

  /// Records a llamadart hook run as the hooks runner does: its input (target, defines), log and output library.
  void addHookRun(
    String id, {
    required String os,
    required String arch,
    String? iosSdk,
    List<String> runtimes = const ['llama_cpp'],
    String? logged = 'llama_cpp',
  }) {
    final run = p.join(dir, '.dart_tool', 'hooks_runner', 'llamadart', id);
    final bundle = switch ((os, arch)) {
      ('ios', _) => iosSdk == 'iphonesimulator' ? 'ios-arm64-sim' : 'ios-arm64',
      ('macos', 'x64') => 'macos-x86_64',
      _ => '$os-$arch',
    };
    final library = fakeBundles[bundle]!.last;
    final output = p.join(dir, '.dart_tool', 'hooks_runner', 'shared', 'llamadart', 'build', id, 'llamadart_bin');
    File(p.join(output, library))
      ..createSync(recursive: true)
      ..writeAsStringSync(_libraryBytes(bundle, library));
    File(p.join(run, 'input.json'))
      ..createSync(recursive: true)
      ..writeAsStringSync(
        jsonEncode({
          'config': {
            'extensions': {
              'code_assets': {
                'target_os': os,
                'target_architecture': arch,
                if (iosSdk != null) 'ios': {'target_sdk': iosSdk, 'target_version': 13},
              },
            },
          },
          'package_root': llamadartRoot,
          'user_defines': {
            'workspace_pubspec': {
              'base_path': p.join(dir, 'pubspec.yaml'),
              'defines': {'llamadart_native_runtimes': runtimes},
            },
          },
        }),
      );
    File(p.join(run, 'output.json')).writeAsStringSync(
      jsonEncode({
        'assets': [
          {
            'encoding': {'file': p.join(output, library), 'id': 'package:llamadart/llamadart'},
            'type': 'code_assets/code',
          },
        ],
        'status': 'success',
      }),
    );
    File(p.join(run, 'stdout.txt')).writeAsStringSync(
      ['INFO: Hook Start: $bundle', if (logged != null) 'INFO: Selected native runtimes: $logged.', ''].join('\n\n'),
    );
  }

  void dispose() => Directory(base).deleteSync(recursive: true);

  static void _copy(String from, String to) {
    for (final entity in Directory(from).listSync(recursive: true)) {
      if (entity is! File) continue;
      final target = p.join(to, p.relative(entity.path, from: from));
      File(target).parent.createSync(recursive: true);
      entity.copySync(target);
    }
  }
}
