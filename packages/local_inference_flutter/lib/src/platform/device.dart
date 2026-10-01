/// The device, through the plugin: platform, capabilities, SHA-256, backup flag, the no-backup folder, the
/// connection, diagnostics and thermal changes. Every call falls back when the plugin is missing (Linux, Windows,
/// tests).
library;

import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:local_inference/local_inference.dart';

import 'device_channel.dart';
import 'diagnostics.dart';

/// The plugin's device calls. Hashing 3 GB natively (CryptoKit, MessageDigest) takes a few seconds off the main
/// thread, against about 30 s for package:crypto. Call it from the root isolate (a background isolate needs
/// `BackgroundIsolateBinaryMessenger.ensureInitialized`).
final class LocalInferenceDevice {
  const LocalInferenceDevice();

  static PlatformSupportInfo? _platform;

  /// Forgets the cached [platform] answer.
  @visibleForTesting
  static void resetCache() => _platform = null;

  /// The OS, its version, the Android API level, the ABIs, 64-bit and simulator; asked once, then cached. Without
  /// the plugin: what Dart can tell (the ABI of this process, no API level).
  Future<PlatformSupportInfo> platform() async {
    final cached = _platform;
    if (cached != null) return cached;
    final answer = await DeviceChannel.call<Map<Object?, Object?>>('platform');
    final value = answer.value;
    return _platform = value != null
        ? PlatformSupportInfo.fromMap(value)
        : PlatformSupportInfo(
            os: Platform.operatingSystem,
            osVersion: Platform.operatingSystemVersion,
            abis: [Abi.current().toString().split('_').last],
            is64Bit: Abi.current().toString().contains('64'),
          );
  }

  /// Memory and free disk in MB; free disk is measured on the volume of [volumePath] (default: Application Support
  /// on Apple devices, the app's files folder on Android). Unknown without the plugin.
  Future<DeviceCapabilities> capabilities({String? volumePath}) async {
    final answer = await DeviceChannel.call<Map<Object?, Object?>>(
      'capabilities',
      volumePath == null ? null : {'path': volumePath},
    );
    return answer.available ? DeviceCapabilities.fromJson(answer.value) : DeviceCapabilities.unknown;
  }

  /// Lowercase hex SHA-256 of the file at [path]; in a background isolate without the plugin.
  Future<String> sha256(String path) async {
    final answer = await DeviceChannel.call<String>('sha256', {'path': path});
    if (!answer.available) return const DartDeviceProbe().sha256(path);
    final hex = answer.value;
    if (hex == null) throw StateError('sha256 returned nothing for $path');
    return hex.toLowerCase();
  }

  /// Keeps the file at [path] and its folder out of iCloud and Time Machine backups; nothing on Android (models go
  /// to the no-backup folder) and without the plugin.
  Future<void> excludeFromBackup(String path) async {
    await DeviceChannel.call<void>('excludeFromBackup', {'path': path});
  }

  /// Android's noBackupFilesDir; null elsewhere and without the plugin.
  Future<String?> noBackupDirectory() async => (await DeviceChannel.call<String>('noBackupDirectory')).value;

  /// The connection in use ([NetworkState]); null without the plugin, or before it has a reading.
  Future<NetworkState?> network() async {
    final value = (await DeviceChannel.call<Map<Object?, Object?>>('network')).value;
    return value == null ? null : NetworkState.fromMap(value);
  }

  /// A diagnostics snapshot; null without the plugin.
  Future<DeviceDiagnostics?> diagnostics() async {
    final value = (await DeviceChannel.call<Map<Object?, Object?>>('diagnostics')).value;
    return value == null ? null : DeviceDiagnostics.fromMap(value);
  }

  /// The thermal state now, then every change (Android 10+, iOS, macOS); nothing on the other platforms. A state the
  /// native side reports twice in a row (Android's listener repeats the current one) arrives once.
  Stream<ThermalState> thermalStateChanges() => switch (defaultTargetPlatform) {
    TargetPlatform.android ||
    TargetPlatform.iOS ||
    TargetPlatform.macOS => DeviceChannel.thermalStates().map(ThermalState.parse).distinct(),
    _ => const Stream.empty(),
  };
}

/// The core [DeviceProbe] on the plugin. [volumePath] is the models root, so free space is read on its volume.
final class PluginDeviceProbe implements DeviceProbe {
  const PluginDeviceProbe({this.device = const LocalInferenceDevice(), this.volumePath});

  final LocalInferenceDevice device;
  final String? volumePath;

  @override
  Future<DeviceCapabilities> capabilities() => device.capabilities(volumePath: volumePath);

  @override
  Future<String> sha256(String path) => device.sha256(path);

  @override
  Future<void> excludeFromBackup(String path) => device.excludeFromBackup(path);
}
