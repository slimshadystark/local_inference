/// What the model download needs from the platform: RAM and disk figures, a SHA-256 of a multi-GB file,
/// and the backup exclusion flag.
///
/// On phones local_inference_flutter's plugin answers (hashing 3 GB with CryptoKit or MessageDigest takes a
/// few seconds off the main thread, against about 30 s for package:crypto). [DartDeviceProbe] is the pure-Dart
/// probe: the figures are unknown, the hash runs in a background isolate and the backup flag is skipped.
library;

import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart' as crypto;

/// What the phone offers, as the native probe reports it (MB = 1024 * 1024 bytes); null when unknown.
final class DeviceCapabilities {
  const DeviceCapabilities({this.physicalMemoryMB, this.availableMemoryMB, this.freeDiskMB});

  static const unknown = DeviceCapabilities();

  final int? physicalMemoryMB;

  /// Memory the app may still use: iOS os_proc_available_memory (the per-process limit, raised by the
  /// increased-memory-limit entitlement), Android ActivityManager availMem.
  final int? availableMemoryMB;

  /// Space for important data on the volume holding the models.
  final int? freeDiskMB;

  bool get isUnknown => physicalMemoryMB == null && availableMemoryMB == null;

  /// Reads the keys `physicalMemoryMB`, `availableMemoryMB` and `freeDiskMB`; a missing, negative or non-numeric
  /// value is unknown.
  factory DeviceCapabilities.fromJson(Map<Object?, Object?>? json) {
    int? mb(String key) => switch (json?[key]) {
      final num n when n >= 0 => n.toInt(),
      _ => null,
    };
    return DeviceCapabilities(
      physicalMemoryMB: mb('physicalMemoryMB'),
      availableMemoryMB: mb('availableMemoryMB'),
      freeDiskMB: mb('freeDiskMB'),
    );
  }

  Map<String, Object?> toJson() => {
    'physicalMemoryMB': physicalMemoryMB,
    'availableMemoryMB': availableMemoryMB,
    'freeDiskMB': freeDiskMB,
  };

  @override
  bool operator ==(Object other) =>
      other is DeviceCapabilities &&
      other.physicalMemoryMB == physicalMemoryMB &&
      other.availableMemoryMB == availableMemoryMB &&
      other.freeDiskMB == freeDiskMB;

  @override
  int get hashCode => Object.hash(physicalMemoryMB, availableMemoryMB, freeDiskMB);

  @override
  String toString() =>
      'DeviceCapabilities(physical: $physicalMemoryMB MB, available: $availableMemoryMB MB, free disk: $freeDiskMB MB)';
}

/// The platform's part of model delivery: memory and disk figures, the SHA-256 of a model file and the backup flag.
/// [DartDeviceProbe] is the pure-Dart one; local_inference_flutter's `PluginDeviceProbe` asks the plugin.
abstract interface class DeviceProbe {
  /// Memory and free disk now; unknown figures are null.
  Future<DeviceCapabilities> capabilities();

  /// Lowercase hex SHA-256 of the file at [path].
  Future<String> sha256(String path);

  /// Keeps the file at [path] and its folder out of iCloud backups (no-op where backup rules do it).
  Future<void> excludeFromBackup(String path);
}

/// The probe of a pure-Dart host (CLI, server, tests): unknown capabilities, the hash in a background isolate, no
/// backup flag.
final class DartDeviceProbe implements DeviceProbe {
  const DartDeviceProbe();

  @override
  Future<DeviceCapabilities> capabilities() async => DeviceCapabilities.unknown;

  @override
  Future<String> sha256(String path) => Isolate.run(() => dartSha256(path));

  @override
  Future<void> excludeFromBackup(String path) async {}
}

/// SHA-256 with package:crypto, streaming; slow on multi-GB files, so run it in an isolate.
Future<String> dartSha256(String path) async => (await crypto.sha256.bind(File(path).openRead()).first).toString();
