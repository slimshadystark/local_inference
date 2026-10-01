// The plugin's channels through LocalInferenceDevice, on a mocked binary messenger: platform (cached, and the Dart
// fallback), the no-backup folder, the connection, the diagnostics snapshot and its report line, the thermal events,
// and the native errors.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_inference_flutter/local_inference_flutter.dart';

/// An iPhone 16 Pro Max as the plugin reports it, every key included.
const Map<String, Object?> iphoneSnapshot = {
  'machine': 'iPhone17,2',
  'ios': '26.0',
  'thermal_state': 'fair',
  'low_power_mode': false,
  'battery': 'unplugged',
  'physical_memory_mb': 7622,
  'process_available_memory_mb': 5960,
  'metal_device': 'Apple A18 Pro GPU',
  'metal_recommended_working_set_mb': 5461,
  'metal_current_allocated_mb': 12,
  'platform': 'ios',
  'os_version': '26.0',
  'is_simulator': false,
  'battery_percent': 81,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const methods = MethodChannel('local_inference_flutter/device');
  const thermal = EventChannel('local_inference_flutter/thermal');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const device = LocalInferenceDevice();
  tearDown(() {
    messenger.setMockMethodCallHandler(methods, null);
    messenger.setMockStreamHandler(thermal, null);
    LocalInferenceDevice.resetCache();
  });

  test('platform: read once from the plugin, then cached; without it, what Dart can tell', () async {
    var calls = 0;
    messenger.setMockMethodCallHandler(methods, (call) async {
      calls++;
      return {
        'apiVersion': 1,
        'os': 'android',
        'osVersion': '14',
        'sdkInt': 34,
        'abis': ['arm64-v8a', 'armeabi-v7a'],
        'is64Bit': true,
        'isSimulator': false,
      };
    });
    final info = await device.platform();
    expect(
      info,
      const PlatformSupportInfo(
        os: 'android',
        osVersion: '14',
        androidSdkInt: 34,
        abis: ['arm64-v8a', 'armeabi-v7a'],
        is64Bit: true,
      ),
    );
    await device.platform();
    expect(calls, 1);

    LocalInferenceDevice.resetCache();
    messenger.setMockMethodCallHandler(methods, null);
    final fallback = await device.platform();
    expect((fallback.androidSdkInt, fallback.isSimulator, fallback.is64Bit), (null, false, true));
    expect(fallback.abis, hasLength(1));
  });

  test('noBackupDirectory, and nothing without the plugin or where the platform has none', () async {
    messenger.setMockMethodCallHandler(methods, (call) async => call.method == 'noBackupDirectory' ? '/data/nb' : null);
    expect(await device.noBackupDirectory(), '/data/nb');
    messenger.setMockMethodCallHandler(methods, (call) async => null);
    expect(await device.noBackupDirectory(), isNull);
    messenger.setMockMethodCallHandler(methods, null);
    expect(await device.noBackupDirectory(), isNull);
  });

  test('network: the connection and whether it is Wi-Fi; nothing without the plugin or before a reading', () async {
    Map<String, Object?>? answer = {'connected': true, 'wifi': false};
    messenger.setMockMethodCallHandler(methods, (call) async => call.method == 'network' ? answer : null);
    expect(await device.network(), const NetworkState(connected: true, wifi: false));
    answer = {'connected': true, 'wifi': true};
    expect(await device.network(), const NetworkState(connected: true, wifi: true));
    answer = {'connected': false, 'wifi': true};
    expect(await device.network(), const NetworkState(connected: false, wifi: false), reason: 'Wi-Fi needs a link');
    expect('${await device.network()}', 'NetworkState(offline)');
    answer = null;
    expect(await device.network(), isNull, reason: 'no reading yet');
    messenger.setMockMethodCallHandler(methods, null);
    expect(await device.network(), isNull);
  });

  test('diagnostics: typed fields, every raw key, and the report line in its key order', () async {
    messenger.setMockMethodCallHandler(methods, (call) async => call.method == 'diagnostics' ? iphoneSnapshot : null);
    final snapshot = (await device.diagnostics())!;
    expect(
      (snapshot.platform, snapshot.osVersion, snapshot.machine, snapshot.isSimulator),
      ('ios', '26.0', 'iPhone17,2', false),
    );
    expect(
      (snapshot.thermal, snapshot.battery, snapshot.batteryPercent, snapshot.lowPowerMode),
      (ThermalState.fair, BatteryState.unplugged, 81, false),
    );
    expect(
      (snapshot.physicalMemoryMB, snapshot.processAvailableMemoryMB, snapshot.gpu),
      (7622, 5960, 'Apple A18 Pro GPU'),
    );
    expect((snapshot.metalRecommendedWorkingSetMB, snapshot.metalCurrentAllocatedMB), (5461, 12));
    expect(snapshot.raw, iphoneSnapshot);
    expect(
      snapshot.toReportLine(),
      'machine=iPhone17,2, ios=26.0, thermal_state=fair, low_power_mode=false, battery=unplugged, '
      'physical_memory_mb=7622, process_available_memory_mb=5960, metal_device=Apple A18 Pro GPU, '
      'metal_recommended_working_set_mb=5461, metal_current_allocated_mb=12',
    );

    final android = DeviceDiagnostics.fromMap({
      'platform': 'android',
      'android': '14',
      'thermal_state': 'serious',
      'android_thermal_status': 3,
      'thermal_headroom': 0.97,
      'low_memory': true,
      'battery': 'charging',
    });
    expect(
      (android.osVersion, android.thermal, android.androidThermalStatus, android.thermalHeadroom, android.lowMemory),
      ('14', ThermalState.serious, 3, 0.97, true),
    );
    expect(android.toReportLine(), 'android=14, thermal_state=serious, battery=charging');
    expect(DeviceDiagnostics.fromMap({'thermal_state': 'molten'}).thermal, ThermalState.unknown);

    messenger.setMockMethodCallHandler(methods, null);
    expect(await device.diagnostics(), isNull);
  });

  test('thermal state changes arrive as ThermalState, a repeated state once', () async {
    messenger.setMockStreamHandler(
      thermal,
      MockStreamHandler.inline(
        onListen: (arguments, events) {
          events
            ..success('nominal')
            ..success('nominal')
            ..success('critical')
            ..success('nominal')
            ..endOfStream();
        },
      ),
    );
    expect(await device.thermalStateChanges().toList(), [
      ThermalState.nominal,
      ThermalState.critical,
      ThermalState.nominal,
    ]);
  });

  test('native failures are PlatformExceptions; a hash that comes back empty is a StateError', () async {
    messenger.setMockMethodCallHandler(methods, (call) async {
      throw PlatformException(code: call.method == 'sha256' ? 'sha256_failed' : 'exclude_failed', message: 'io');
    });
    await expectLater(
      device.sha256('/x'),
      throwsA(isA<PlatformException>().having((e) => e.code, 'code', 'sha256_failed')),
    );
    await expectLater(
      device.excludeFromBackup('/x'),
      throwsA(isA<PlatformException>().having((e) => e.code, 'code', 'exclude_failed')),
    );
    messenger.setMockMethodCallHandler(methods, (call) async => null);
    await expectLater(device.sha256('/x'), throwsStateError);
  });
}
