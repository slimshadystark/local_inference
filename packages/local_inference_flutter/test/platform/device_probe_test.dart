// The 'local_inference_flutter/device' channel as Dart sees it (capabilities, SHA-256, backup flag, and the
// fallbacks where the native side is missing), the background_downloader task settings, the wait for a connection
// or for Wi-Fi, and the codes of its failures.
import 'dart:convert';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_inference_flutter/local_inference_flutter.dart';

import '../support/fake_files.dart';

/// A 4B entry of a manifest (a fine-tuned Qwen3.5 4B, Q5_K_M).
final ModelEntry _entry = ModelEntry(
  id: 'qwen3.5-4b-tuned-q5km',
  url: Uri.parse('https://example.com/models/qwen3.5-4b-tuned-Q5_K_M.gguf'),
  sizeBytes: 3074986592,
  sha256: '4b' * 32,
  displayName: 'Assistant 4B',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('local_inference_flutter/device');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('native answers: capabilities in MB, lowercase hash, backup flag with the path', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return switch (call.method) {
        'capabilities' => {'physicalMemoryMB': 7622, 'availableMemoryMB': 5960, 'freeDiskMB': 81234},
        'sha256' => 'ABCDEF',
        _ => null,
      };
    });
    const probe = PluginDeviceProbe();
    final caps = await probe.capabilities();
    expect((caps.physicalMemoryMB, caps.availableMemoryMB, caps.freeDiskMB), (7622, 5960, 81234));
    expect(await probe.sha256('/x/model.gguf.part'), 'abcdef');
    await probe.excludeFromBackup('/x/model.gguf');
    await const PluginDeviceProbe(volumePath: '/x/root').capabilities();
    expect(calls.map((c) => '${c.method} ${c.arguments}'), [
      'capabilities null',
      'sha256 {path: /x/model.gguf.part}',
      'excludeFromBackup {path: /x/model.gguf}',
      'capabilities {path: /x/root}',
    ]);

    messenger.setMockMethodCallHandler(channel, (call) async => {'physicalMemoryMB': 3700});
    final partial = await probe.capabilities();
    expect((partial.physicalMemoryMB, partial.availableMemoryMB, partial.freeDiskMB), (3700, null, null));
  });

  test('without the native side: unknown capabilities, SHA-256 in Dart, no backup flag', () async {
    final tmp = Directory.systemTemp.createTempSync('device_probe_test');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final bytes = utf8.encode('pretend weights' * 1000);
    final file = File('${tmp.path}/model.gguf')..writeAsBytesSync(bytes);
    const probe = PluginDeviceProbe();
    expect((await probe.capabilities()).isUnknown, isTrue);
    expect(await probe.sha256(file.path), '${crypto.sha256.convert(bytes)}');
    await probe.excludeFromBackup(file.path);
  });

  test(
    'download tasks ask for byte ranges and an uncompressed file; priority 0 only where a user-initiated job can run',
    () {
      const iPhone = PlatformSupportInfo(os: 'ios', osVersion: '26.0', is64Bit: true);
      PlatformSupportInfo android(int sdk) =>
          PlatformSupportInfo(os: 'android', osVersion: '$sdk', androidSdkInt: sdk, is64Bit: true);
      DownloadTask task(PlatformSupportInfo platform, {bool notifications = true}) =>
          BackgroundModelDownloader.buildTask(
            _entry,
            group: 'app_models',
            baseDirectory: BaseDirectory.applicationSupport,
            directory: 'models/${_entry.id}',
            partFileName: _entry.partFileName,
            wifiOnly: true,
            platform: platform,
            notificationsGranted: notifications,
          );

      final job = task(iPhone, notifications: false);
      expect(job.headers, {'x-ms-version': '2021-08-06', 'Accept-Encoding': 'identity'});
      expect((job.taskId, job.filename, job.url), (_entry.id, _entry.partFileName, _entry.url.toString()));
      expect((job.priority, job.allowPause, job.requiresWiFi), (0, true, true), reason: 'iOS stays at 0');
      expect(
        (job.directory, job.baseDirectory, job.group, job.retries),
        ('models/${_entry.id}', BaseDirectory.applicationSupport, 'app_models', 3),
      );
      expect(job.toJson()['transferHints'], isNull, reason: 'no TransferHint: 9.5.9 has none');

      expect(task(android(34)).priority, 0, reason: 'Android 14 with notifications: a user-initiated job');
      expect(task(android(36)).priority, 0);
      expect(task(android(34), notifications: false).priority, 5, reason: 'the job could not show its notification');
      expect(task(android(33)).priority, 5, reason: 'below Android 14 priority 0 is an expedited 2-minute job');
      expect(task(android(28)).priority, 5);
      expect(task(const PlatformSupportInfo(os: 'android', osVersion: '', is64Bit: true)).priority, 5);

      final work = task(android(33));
      expect(work.headers, job.headers);
      expect((work.priority, work.allowPause), (5, true));

      final demoted = BackgroundModelDownloader.withoutUserInitiated(job);
      expect((demoted.taskId, demoted.priority, demoted.allowPause, demoted.requiresWiFi), (job.taskId, 5, true, true));
      expect(demoted.headers, job.headers);
      // A task saved by the build that used transfer hints stays a WorkManager job once demoted.
      final hinted = DownloadTask.fromJson({
        ...job.toJson(),
        'transferHints': [0, 1],
      });
      expect(BackgroundModelDownloader.withoutUserInitiated(hinted).priority, 5);
      // resume() enqueues a copy: with the hints kept, 9.6's constructor would make it user-initiated again.
      expect(BackgroundModelDownloader.withoutUserInitiated(hinted).copyWith(retriesRemaining: 3).priority, 5);
      expect(demoted.copyWith(retriesRemaining: 3).priority, 5);
    },
  );

  test('a queued download says whether it waits for any connection or for Wi-Fi', () async {
    final files = FakeFiles()..connected = false;
    final root = (await Directory.systemTemp.createTemp('device_probe_test')).path;
    addTearDown(() => Directory(root).deleteSync(recursive: true));
    final downloader = BackgroundModelDownloader(
      files: files,
      location: ModelStorageLocation.absolute(root),
      config: const BackgroundDownloadConfig(networkCheckInterval: Duration(milliseconds: 5)),
    );
    final states = <ModelDownloadState>[];
    final subscription = downloader.updates.listen((u) => states.add(u.state));
    addTearDown(subscription.cancel);
    Future<void> reaches(ModelDownloadState state) async {
      for (var i = 0; i < 500 && (states.isEmpty || states.last != state); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      expect(states.last, state);
    }

    await downloader.start(
      _entry,
      directory: '$root/models/${_entry.id}',
      partFileName: _entry.partFileName,
      wifiOnly: true,
    );
    final task = files.enqueued.single;
    files.status!(TaskStatusUpdate(task, TaskStatus.enqueued));
    await reaches(ModelDownloadState.waitingForNetwork);
    files
      ..connected = true
      ..wifi = false;
    await reaches(ModelDownloadState.waitingForWifi);
    files.wifi = true;
    await reaches(ModelDownloadState.queued);
    files.status!(TaskStatusUpdate(task, TaskStatus.running));
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(states, [
      ModelDownloadState.queued,
      ModelDownloadState.waitingForNetwork,
      ModelDownloadState.waitingForWifi,
      ModelDownloadState.queued,
      ModelDownloadState.running,
    ]);
    await downloader.dispose();
  });

  test('download failures as codes', () {
    DownloadError error(TaskStatus status, [TaskException? e]) => BackgroundModelDownloader.errorFor(status, e);
    expect(error(TaskStatus.notFound).code, DownloadErrorCode.notFound);
    expect(
      error(TaskStatus.failed, TaskHttpException('Forbidden', 403)),
      const DownloadError(DownloadErrorCode.httpStatus, httpStatus: 403, detail: 'Forbidden'),
    );
    expect(error(TaskStatus.failed, TaskConnectionException('socket closed')).code, DownloadErrorCode.connection);
    expect(
      error(TaskStatus.failed, TaskFileSystemException('Insufficient space to store the file to be downloaded')).code,
      DownloadErrorCode.diskFull,
    );
    expect(error(TaskStatus.failed, TaskFileSystemException('rename failed')).code, DownloadErrorCode.fileSystem);
    expect(error(TaskStatus.failed, TaskResumeException('no resume data')).code, DownloadErrorCode.cannotResume);
    expect(error(TaskStatus.failed), const DownloadError(DownloadErrorCode.unknown));
  });
}
