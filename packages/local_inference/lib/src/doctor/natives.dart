/// The llama.cpp native bundles of llamadart 0.8.23 (leehack/llamadart-native v0.4.0) and local_inference's SHA-256
/// manifest of them (tool/native/, embedded in native_manifest.g.dart).
library;

import 'dart:ffi' show Abi;
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:path/path.dart' as p;

import 'native_manifest.g.dart';

/// The manifest: the SHA-256 of every release archive and of every file it unpacks to, by path relative to the
/// folder `llamadart_native_path` points at (`<bundle>/<archive>`, `<bundle>/extracted/<file>`), plus the guard file
/// `extracted/target-bundle-not-vendored.so`.
final class NativeManifest {
  NativeManifest._(this.tag, this.sha256ByPath);

  /// Reads `shasum -a 256` lines (`<hex>  <path>`); `#` lines are comments. Throws [FormatException].
  factory NativeManifest.parse(String text, {required String tag}) {
    final entries = <String, String>{};
    for (final line in text.split('\n')) {
      if (line.trim().isEmpty || line.startsWith('#')) continue;
      final m = RegExp(r'^([0-9a-f]{64}) [ *](\S+)$').firstMatch(line.trimRight());
      if (m == null) throw FormatException('not a manifest line: $line');
      entries[m[2]!] = m[1]!;
    }
    return NativeManifest._(tag, Map.unmodifiable(entries));
  }

  /// tool/native/llamadart-native-v0.4.0.sha256.
  static final NativeManifest embedded = NativeManifest.parse(nativeManifestText, tag: nativeManifestTag);

  /// The release, such as `v0.4.0`.
  final String tag;
  final Map<String, String> sha256ByPath;

  /// The guard file of a vendored folder (tool/native/README.md, "The guard file").
  static const guardPath = 'extracted/target-bundle-not-vendored.so';

  /// The bundles the manifest covers, sorted.
  List<String> get bundles =>
      {for (final path in sha256ByPath.keys) path.split('/').first}.where((b) => b != 'extracted').toList()..sort();

  /// The release archive of [bundle]: `llamadart-native-<bundle>-<tag>.tar.gz`.
  String archiveName(String bundle) => 'llamadart-native-$bundle-$tag.tar.gz';

  /// The manifest paths of [bundle]'s files: its archive and everything under `extracted/`.
  Map<String, String> filesOf(String bundle) => {
    for (final MapEntry(:key, :value) in sha256ByPath.entries)
      if (key.startsWith('$bundle/')) key: value,
  };

  /// The SHA-256 of the unpacked file [name] of [bundle], or null.
  String? extractedSha256(String bundle, String name) => sha256ByPath['$bundle/extracted/$name'];
}

/// The bundle that builds for this computer run (`dart test`, `flutter test`, `dart run`): macos-arm64, linux-x64, …
String get thisMachineBundle => switch (Abi.current()) {
  Abi.macosArm64 => 'macos-arm64',
  Abi.macosX64 => 'macos-x86_64',
  Abi.linuxX64 => 'linux-x64',
  Abi.linuxArm64 => 'linux-arm64',
  Abi.windowsX64 => 'windows-x64',
  Abi.windowsArm64 => 'windows-arm64',
  final abi => '$abi',
};

/// The bundle a hook run built for, from its input's target (llamadart's resolveNativeBundleSpec); null for a target
/// with no llama.cpp bundle (32-bit Android, for instance).
String? bundleForTarget({required String? os, required String? architecture, String? iosSdk}) =>
    switch ((os, architecture)) {
      ('android', 'arm64') => 'android-arm64',
      ('android', 'x64') => 'android-x64',
      ('ios', 'arm64') => iosSdk == 'iphonesimulator' ? 'ios-arm64-sim' : 'ios-arm64',
      ('ios', 'x64') => 'ios-x86_64-sim',
      ('linux', 'arm64') => 'linux-arm64',
      ('linux', 'x64') => 'linux-x64',
      ('macos', 'arm64') => 'macos-arm64',
      ('macos', 'x64') => 'macos-x86_64',
      ('windows', 'arm64') => 'windows-arm64',
      ('windows', 'x64') => 'windows-x64',
      _ => null,
    };

/// The Android bundle of an ABI in `abiFilters`; null for an ABI llama.cpp has no bundle for.
String? androidBundleForAbi(String abi) => switch (abi) {
  'arm64-v8a' => 'android-arm64',
  'x86_64' => 'android-x64',
  _ => null,
};

/// The lowercase hex SHA-256 of the file at [path], read in 1 MiB chunks.
String sha256OfFile(String path) {
  final digest = _DigestSink();
  final input = crypto.sha256.startChunkedConversion(digest);
  final file = File(path).openSync();
  try {
    final buffer = Uint8List(1 << 20);
    while (true) {
      final n = file.readIntoSync(buffer);
      if (n == 0) break;
      input.add(Uint8List.sublistView(buffer, 0, n));
    }
  } finally {
    file.closeSync();
  }
  input.close();
  return digest.value!.toString();
}

final class _DigestSink implements Sink<crypto.Digest> {
  crypto.Digest? value;

  @override
  void add(crypto.Digest data) => value = data;

  @override
  void close() {}
}

/// What [verifyBundleFolder] found in one bundle folder.
final class BundleCheck {
  BundleCheck(this.bundle);

  final String bundle;

  /// Files that match the manifest.
  int matched = 0;

  /// Problems, one line each: a mismatch, a file the manifest does not list, a missing file, a symlink.
  final List<String> problems = [];
}

/// Checks the folder [bundleDir] of [bundle] (`<archive>` and `extracted/…`) against [manifest]: every file hashed,
/// every file the manifest lists present (the archive may be missing when [archiveOptional]), nothing else (`.DS_Store`
/// excepted: the hook bundles every library it finds) and no symlink.
BundleCheck verifyBundleFolder(
  NativeManifest manifest,
  String bundle,
  String bundleDir, {
  bool archiveOptional = false,
  String Function(String path) hash = sha256OfFile,
}) {
  final check = BundleCheck(bundle);
  final expected = manifest.filesOf(bundle);
  final seen = <String>{};
  for (final entity in Directory(bundleDir).listSync(recursive: true, followLinks: false)) {
    final relative = p.posix.joinAll(p.split(p.relative(entity.path, from: bundleDir)));
    if (p.basename(relative) == '.DS_Store') continue;
    final key = '$bundle/$relative';
    if (entity is Link) {
      check.problems.add('$key is a symlink');
      continue;
    }
    if (entity is! File) continue;
    seen.add(key);
    final want = expected[key];
    if (want == null) {
      check.problems.add('$key is not in the manifest');
      continue;
    }
    final got = hash(entity.path);
    if (got != want) {
      check.problems.add('$key: SHA-256 $got, the manifest says $want');
    } else {
      check.matched++;
    }
  }
  for (final key in expected.keys) {
    if (seen.contains(key)) continue;
    if (archiveOptional && key == '$bundle/${manifest.archiveName(bundle)}') continue;
    check.problems.add('$key is missing');
  }
  return check;
}
