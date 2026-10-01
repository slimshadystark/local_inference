/// What the plugin reports about the device: the platform, for the support check, and a diagnostics snapshot.
library;

import 'package:flutter/foundation.dart';

/// The device's heat, in the names iOS uses; Android's thermal status maps onto them.
enum ThermalState {
  nominal,
  fair,
  serious,
  critical,
  unknown;

  /// The state named [name]; [unknown] for anything else.
  static ThermalState parse(Object? name) => values.where((s) => s.name == name).firstOrNull ?? unknown;
}

/// Whether the device is charging, in the names iOS uses.
enum BatteryState {
  charging,
  full,
  unplugged,
  unknown;

  /// The state named [name]; [unknown] for anything else.
  static BatteryState parse(Object? name) => values.where((s) => s.name == name).firstOrNull ?? unknown;
}

/// The platform as the plugin reports it (`platform`), or as Dart can tell without it.
@immutable
final class PlatformSupportInfo {
  const PlatformSupportInfo({
    required this.os,
    required this.osVersion,
    required this.is64Bit,
    this.androidSdkInt,
    this.abis = const [],
    this.isSimulator = false,
  });

  /// Reads the keys `os`, `osVersion`, `sdkInt`, `abis`, `is64Bit` and `isSimulator`.
  factory PlatformSupportInfo.fromMap(Map<Object?, Object?> map) => PlatformSupportInfo(
    os: '${map['os'] ?? ''}',
    osVersion: '${map['osVersion'] ?? ''}',
    androidSdkInt: switch (map['sdkInt']) {
      final num n => n.toInt(),
      _ => null,
    },
    abis: [for (final abi in map['abis'] is List ? map['abis'] as List : const []) '$abi'],
    is64Bit: map['is64Bit'] == true,
    isSimulator: map['isSimulator'] == true,
  );

  /// "android", "ios", "macos", …
  final String os;
  final String osVersion;

  /// Android's API level; null elsewhere.
  final int? androidSdkInt;

  /// The ABIs the device runs, preferred first ("arm64-v8a", "x86_64"; "arm64" on Apple).
  final List<String> abis;
  final bool is64Bit;
  final bool isSimulator;

  @override
  bool operator ==(Object other) =>
      other is PlatformSupportInfo &&
      other.os == os &&
      other.osVersion == osVersion &&
      other.androidSdkInt == androidSdkInt &&
      listEquals(other.abis, abis) &&
      other.is64Bit == is64Bit &&
      other.isSimulator == isSimulator;

  @override
  int get hashCode => Object.hash(os, osVersion, androidSdkInt, Object.hashAll(abis), is64Bit, isSimulator);

  @override
  String toString() =>
      'PlatformSupportInfo($os $osVersion${androidSdkInt == null ? '' : ' API $androidSdkInt'}, ${abis.join('/')}, '
      '${is64Bit ? '64' : '32'}-bit${isSimulator ? ', simulator' : ''})';
}

/// The connection the device uses now (`network`): whether there is one, and whether it is the kind the Wi-Fi-only
/// rule accepts: Wi-Fi on Android (the transport background_downloader 9.6 asks for), Wi-Fi or wired Ethernet on
/// Apple devices (what iOS allows a task that may not use mobile data).
@immutable
final class NetworkState {
  const NetworkState({required this.connected, required this.wifi});

  /// Reads the keys `connected` and `wifi`.
  factory NetworkState.fromMap(Map<Object?, Object?> map) =>
      NetworkState(connected: map['connected'] == true, wifi: map['connected'] == true && map['wifi'] == true);

  /// A network with internet access.
  final bool connected;

  /// That network is Wi-Fi (see the class comment).
  final bool wifi;

  @override
  bool operator ==(Object other) => other is NetworkState && other.connected == connected && other.wifi == wifi;

  @override
  int get hashCode => Object.hash(connected, wifi);

  @override
  String toString() =>
      'NetworkState(${!connected
          ? 'offline'
          : wifi
          ? 'Wi-Fi'
          : 'not Wi-Fi'})';
}

/// A snapshot of the conditions that change on-device speed (`diagnostics`): heat, battery saver, charging, memory
/// and, on Apple devices, the GPU's working set. [raw] keeps every key the plugin sent.
@immutable
final class DeviceDiagnostics {
  const DeviceDiagnostics({
    required this.raw,
    this.platform = '',
    this.osVersion = '',
    this.machine = '',
    this.isSimulator = false,
    this.thermal = ThermalState.unknown,
    this.androidThermalStatus,
    this.thermalHeadroom,
    this.lowPowerMode,
    this.lowMemory,
    this.battery = BatteryState.unknown,
    this.batteryPercent,
    this.physicalMemoryMB,
    this.availableMemoryMB,
    this.processAvailableMemoryMB,
    this.lowMemoryThresholdMB,
    this.processPssMB,
    this.metalRecommendedWorkingSetMB,
    this.metalCurrentAllocatedMB,
    this.gpu,
  });

  /// Reads the plugin's keys (`thermal_state`, `low_power_mode`, `battery`,
  /// `physical_memory_mb`, `process_available_memory_mb`, `metal_*`, and the newer ones).
  factory DeviceDiagnostics.fromMap(Map<Object?, Object?> map) {
    final raw = {for (final MapEntry(:key, :value) in map.entries) '$key': value};
    int? number(String key) => switch (raw[key]) {
      final num n => n.toInt(),
      _ => null,
    };
    bool? flag(String key) => switch (raw[key]) {
      final bool b => b,
      _ => null,
    };
    String? text(String key) => switch (raw[key]) {
      final String s => s,
      _ => null,
    };
    return DeviceDiagnostics(
      raw: Map.unmodifiable(raw),
      platform: text('platform') ?? '',
      osVersion: text('os_version') ?? text('ios') ?? text('android') ?? text('macos') ?? '',
      machine: text('machine') ?? '',
      isSimulator: flag('is_simulator') ?? false,
      thermal: ThermalState.parse(raw['thermal_state']),
      androidThermalStatus: number('android_thermal_status'),
      thermalHeadroom: switch (raw['thermal_headroom']) {
        final num n => n.toDouble(),
        _ => null,
      },
      lowPowerMode: flag('low_power_mode'),
      lowMemory: flag('low_memory'),
      battery: BatteryState.parse(raw['battery']),
      batteryPercent: number('battery_percent'),
      physicalMemoryMB: number('physical_memory_mb'),
      availableMemoryMB: number('available_memory_mb'),
      processAvailableMemoryMB: number('process_available_memory_mb'),
      lowMemoryThresholdMB: number('low_memory_threshold_mb'),
      processPssMB: number('process_pss_mb'),
      metalRecommendedWorkingSetMB: number('metal_recommended_working_set_mb'),
      metalCurrentAllocatedMB: number('metal_current_allocated_mb'),
      gpu: text('metal_device'),
    );
  }

  /// The keys of [toReportLine], in its order.
  static const reportKeys = [
    'machine',
    'ios',
    'android',
    'macos',
    'thermal_state',
    'low_power_mode',
    'battery',
    'physical_memory_mb',
    'process_available_memory_mb',
    'metal_device',
    'metal_recommended_working_set_mb',
    'metal_current_allocated_mb',
  ];

  final Map<String, Object?> raw;
  final String platform;
  final String osVersion;
  final String machine;
  final bool isSimulator;
  final ThermalState thermal;

  /// PowerManager's thermal status (Android 10+).
  final int? androidThermalStatus;

  /// PowerManager's forecast of the thermal headroom in 10 s (Android 11+); 1.0 is the throttling threshold.
  final double? thermalHeadroom;

  /// Low Power Mode on Apple devices, battery saver on Android.
  final bool? lowPowerMode;

  /// Android's low-memory flag.
  final bool? lowMemory;
  final BatteryState battery;
  final int? batteryPercent;
  final int? physicalMemoryMB;
  final int? availableMemoryMB;

  /// iOS os_proc_available_memory: what this process may still allocate.
  final int? processAvailableMemoryMB;
  final int? lowMemoryThresholdMB;
  final int? processPssMB;
  final int? metalRecommendedWorkingSetMB;
  final int? metalCurrentAllocatedMB;

  /// The Metal device's name on Apple devices.
  final String? gpu;

  /// A one-line report for logs: `key=value` for each of [reportKeys] the snapshot has, joined by ", ".
  String toReportLine() => [
    for (final key in reportKeys)
      if (raw.containsKey(key)) '$key=${raw[key]}',
  ].join(', ');

  @override
  String toString() => 'DeviceDiagnostics(${toReportLine()})';
}
