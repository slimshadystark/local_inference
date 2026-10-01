// BackgroundModelDownloader on a fake FileDownloader: background_downloader's status and progress callbacks become
// ModelDownloadUpdates with codes, a refused start or resume fails with its code, the folder is named relative to
// Application Support, and the group gets the configured notifications. Then, on fake status sequences: a failed
// download's resume data is kept and resumed, also after a relaunch, and discarded with its temporary file; orphaned
// temporary files are swept (D1); a finished download is checked before it counts as complete (D2); the Android
// priority and foreground setting (D4); the Wi-Fi rule on background_downloader 9.5.9 (D5). Runs on both
// background_downloader lines (9.5.9 on the Flutter 3.44 floor); FakeFiles(tracksConnection: false) is 9.5.9's
// FileDownloader, without isConnected and isWiFi.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_inference_flutter/local_inference_flutter.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import '../support/fake_files.dart';
import '../support/fake_path_provider.dart';
import '../support/memory_storage.dart';

final ModelEntry _entry = ModelEntry(
  id: 'm',
  url: Uri.parse('https://example.org/models/m-Q4_0.gguf'),
  sizeBytes: 1000,
  displayName: 'M',
);

const _iPhone = {
  'os': 'ios',
  'osVersion': '26.0',
  'abis': ['arm64'],
  'is64Bit': true,
};

Map<String, Object?> _android(int sdk) => {
  'os': 'android',
  'osVersion': '$sdk',
  'sdkInt': sdk,
  'abis': ['arm64-v8a'],
  'is64Bit': true,
};

final List<int> _gguf = [...utf8.encode('GGUF'), 3, 0, 0, 0, ...List.filled(40, 7)];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const methods = MethodChannel('local_inference_flutter/device');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory root;
  late FakeFiles files;
  late BackgroundModelDownloader downloader;
  late List<ModelDownloadUpdate> updates;
  final extra = <BackgroundModelDownloader>[];

  /// What the plugin answers: the platform, and the connection (`network`); null leaves the method unanswered.
  Map<String, Object?>? platform;
  Map<String, Object?>? network;

  /// Every call the plugin got.
  final deviceCalls = <MethodCall>[];

  setUp(() {
    root = Directory.systemTemp.createTempSync('background_model_downloader_test');
    files = FakeFiles();
    platform = null;
    network = null;
    deviceCalls.clear();
    messenger.setMockMethodCallHandler(methods, (call) async {
      deviceCalls.add(call);
      final answer = switch (call.method) {
        'platform' => platform,
        'network' => network,
        _ => null,
      };
      if (answer == null) throw MissingPluginException();
      return answer;
    });
    downloader = BackgroundModelDownloader(
      files: files,
      location: ModelStorageLocation.absolute(root.path),
      config: const BackgroundDownloadConfig(
        group: 'app_models',
        notifications: DownloadNotifications(
          running: DownloadNotificationText('Scarico Ada', '{progress}'),
          complete: DownloadNotificationText('Ada scaricato', "Apri l'app per iniziare."),
          actionLabels: {'Cancel': 'Annulla'},
        ),
      ),
    );
    updates = [];
    downloader.updates.listen(updates.add);
  });
  tearDown(() async {
    await downloader.dispose();
    for (final other in extra) {
      await other.dispose();
    }
    extra.clear();
    messenger.setMockMethodCallHandler(methods, null);
    LocalInferenceDevice.resetCache();
    // A storage a test initialized became the app's (RetainingResumeStorage.installed).
    RetainingResumeStorage.resetInstalled();
    root.deleteSync(recursive: true);
  });

  /// Another downloader on [on] (default: a new FakeFiles), whose updates go to [into] (default: [updates]).
  BackgroundModelDownloader make({
    FakeFiles? on,
    RetainingResumeStorage? storage,
    BackgroundDownloadConfig config = const BackgroundDownloadConfig(group: 'app_models'),
    List<ModelDownloadUpdate>? into,
    DateTime Function()? now,
  }) {
    final made = BackgroundModelDownloader(
      files: on ?? FakeFiles(),
      location: ModelStorageLocation.absolute(root.path),
      config: config,
      storage: storage,
      now: now,
    );
    made.updates.listen((into ?? updates).add);
    extra.add(made);
    return made;
  }

  Future<DownloadTask> started([BackgroundModelDownloader? on, FakeFiles? fake, bool wifiOnly = false]) async {
    await (on ?? downloader).start(
      _entry,
      directory: p.join(root.path, 'models', 'm'),
      partFileName: 'm.part',
      wifiOnly: wifiOnly,
    );
    return (fake ?? files).enqueued.last as DownloadTask;
  }

  Future<void> until(bool Function() condition, {String? reason}) async {
    for (var i = 0; i < 500 && !condition(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    expect(condition(), isTrue, reason: reason);
  }

  /// The state of the last update delivered so far.
  ModelDownloadState? lastState([List<ModelDownloadUpdate>? of]) => (of ?? updates).lastOrNull?.state;

  Future<List<ModelDownloadUpdate>> delivered([int? count]) async {
    if (count != null) await until(() => updates.length >= count);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    return updates;
  }

  /// background_downloader's order for a final state: it drops the task's resume data (the storage copies it
  /// first), then reports the status.
  void finalState(FakeFiles on, TaskStatusUpdate update, [RetainingResumeStorage? storage]) {
    unawaited(storage?.removeResumeData(update.task.taskId));
    on.status!(update);
  }

  group('basic behavior', () {
    test('status and progress callbacks become updates, failures with their codes', () async {
      final task = await started();
      expect(
        (task.baseDirectory, task.directory, task.filename, task.group),
        (BaseDirectory.root, p.join(root.path, 'models', 'm').substring(1), 'm.part', 'app_models'),
      );
      files.status!(TaskStatusUpdate(task, TaskStatus.running));
      files.progress!(TaskProgressUpdate(task, 0.25, 1000, 2.5, const Duration(seconds: 30)));
      files.progress!(TaskProgressUpdate(task, 1.0));
      files.progress!(TaskProgressUpdate(task, -1.0));
      files.status!(TaskStatusUpdate(task, TaskStatus.paused));
      files.status!(TaskStatusUpdate(task, TaskStatus.failed, TaskHttpException('Service Unavailable', 503)));
      files.status!(TaskStatusUpdate(task, TaskStatus.notFound));
      files.status!(TaskStatusUpdate(task, TaskStatus.complete));
      files.status!(TaskStatusUpdate(task, TaskStatus.canceled));
      final got = await delivered(7);
      expect(got.map((u) => u.state), [
        ModelDownloadState.running,
        ModelDownloadState.running,
        ModelDownloadState.paused,
        ModelDownloadState.failed,
        ModelDownloadState.failed,
        ModelDownloadState.complete,
        ModelDownloadState.canceled,
      ], reason: 'a complete waits for its check; what follows waits for it');
      final progress = got[1];
      expect(
        (progress.progress, progress.expectedBytes, progress.bytesPerSecond, progress.timeRemaining),
        (0.25, 1000, 2.5e6, const Duration(seconds: 30)),
      );
      expect(
        got[3].error,
        const DownloadError(DownloadErrorCode.httpStatus, httpStatus: 503, detail: 'Service Unavailable'),
      );
      expect(got[4].error!.code, DownloadErrorCode.notFound);
      expect(got.where((u) => u.state != ModelDownloadState.failed).every((u) => u.error == null), isTrue);
    });

    test('a start the plugin refuses fails as cannotStart; a resume it cannot do fails as cannotResume', () async {
      files.enqueueResult = false;
      await started();
      expect((await delivered()).single.error, const DownloadError(DownloadErrorCode.cannotStart));

      updates.clear();
      files
        ..resumeResult = false
        ..enqueueResult = false;
      await downloader.resume('m');
      expect((await delivered()).single.error, const DownloadError(DownloadErrorCode.cannotResume));
      expect(files.resumed.single.taskId, 'm');
      expect(
        files.enqueued.last.retriesRemaining,
        files.enqueued.last.retries,
        reason: 'enqueued again, retries reset',
      );

      updates.clear();
      files.resumeResult = true;
      await downloader.resume('m');
      expect(await delivered(), isEmpty, reason: 'resumed: the plugin reports the rest');

      await downloader.resume('unknown');
      expect((await delivered()).single.error, const DownloadError(DownloadErrorCode.cannotResume));
      expect(await downloader.canResume('m'), isFalse, reason: 'no storage keeps resume data');
      await downloader.cancel('m');
      expect(files.canceled, ['m']);
    });

    test('discard deletes the part file of the task', () async {
      final task = await started();
      final part = File(await task.filePath())..createSync(recursive: true);
      await downloader.discard('m');
      expect(part.existsSync(), isFalse);
      await downloader.discard('unknown');
    });

    test(
      'the group gets the configured notifications; iOS the timeout, the backup flag and the button words',
      () async {
        await started();
        expect(files.notifications['running']!.title, 'Scarico Ada');
        expect(files.notifications['running']!.body, '{progress}');
        expect(files.notifications['complete']!.title, 'Ada scaricato');
        expect((files.notifications['paused'], files.notifications['error'], files.progressBar), (null, null, true));
        expect(files.globalConfig, [(Config.checkAvailableSpace, 500)]);
        expect(files.iOSConfig, [
          (Config.resourceTimeout, const Duration(hours: 24)),
          (Config.excludeFromCloudBackup, Config.always),
          (Config.localize, const {'Cancel': 'Annulla'}),
        ]);
        expect(files.androidConfig, [
          (Config.useCacheDir, Config.never),
          (Config.runInForeground, Config.never),
        ], reason: 'no foreground service by default, said every time: the setting outlives the app');
      },
    );

    test('the folder is named relative to Application Support when it is inside it', () {
      const support = '/var/mobile/Containers/Data/Application/X/Library/Application Support';
      expect(
        BackgroundModelDownloader.taskDirectory(
          '$support/models/m',
          const ModelStorageLocation.applicationSupport(),
          support,
        ),
        (BaseDirectory.applicationSupport, 'models/m'),
      );
      expect(
        BackgroundModelDownloader.taskDirectory(
          '/elsewhere/models/m',
          const ModelStorageLocation.applicationSupport(),
          support,
        ),
        (BaseDirectory.root, '/elsewhere/models/m'),
      );
      expect(
        BackgroundModelDownloader.taskDirectory(
          '$support/models/m',
          const ModelStorageLocation.absolute('/x'),
          support,
        ),
        (BaseDirectory.root, '$support/models/m'),
      );
    });

    test(
      'in Application Support a task names its folder relative to it, so it survives the iOS container moving',
      () async {
        final original = PathProviderPlatform.instance;
        addTearDown(() => PathProviderPlatform.instance = original);
        final support = p.join(root.path, 'Application Support');
        PathProviderPlatform.instance = FakePathProvider(support, p.join(root.path, 'Caches'));
        final ios = BackgroundModelDownloader(
          files: files,
          config: const BackgroundDownloadConfig(group: 'app_models'),
        );
        await ios.start(_entry, directory: p.join(support, 'models', 'm'), partFileName: 'm.part', wifiOnly: false);
        final task = files.enqueued.single as DownloadTask;
        expect(
          (task.baseDirectory, task.directory, task.filename),
          (BaseDirectory.applicationSupport, 'models/m', 'm.part'),
        );
        await ios.dispose();
      },
    );

    test('the configured headers are added to the default ones', () async {
      final authorized = make(
        on: files,
        config: const BackgroundDownloadConfig(headers: {'Authorization': 'Bearer t'}),
      );
      await authorized.start(_entry, directory: root.path, partFileName: 'x.part', wifiOnly: false);
      expect(files.enqueued.single.headers, {
        'x-ms-version': '2021-08-06',
        'Accept-Encoding': 'identity',
        'Authorization': 'Bearer t',
      });
    });

    test('without isConnected, isWiFi and the plugin, a queued download stays queued', () async {
      final plain = FakeFiles(tracksConnection: false);
      final states = <ModelDownloadUpdate>[];
      final older = make(
        on: plain,
        config: const BackgroundDownloadConfig(networkCheckInterval: Duration(milliseconds: 5)),
        into: states,
      );
      await older.start(_entry, directory: root.path, partFileName: 'x.part', wifiOnly: true);
      plain.status!(TaskStatusUpdate(plain.enqueued.single, TaskStatus.enqueued));
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(states.map((u) => u.state), [ModelDownloadState.queued]);
    });
  });

  group('D1: resume data kept across launches', () {
    late MemoryStorage storage;
    setUp(() {
      storage = MemoryStorage();
      unawaited(storage.initialize());
    });
    String kept(String id) => p.join(root.path, 'models', '.resume', '$id.json');

    /// Until the storage copied [id]'s resume data and background_downloader's copy is gone.
    Future<void> keptOnly(String id) => until(() => File(kept(id)).existsSync() && !storage.live.containsKey(id));

    test('a failed download keeps its resume data; after a relaunch it is reported and resumed with retries '
        'renewed (iOS)', () async {
      platform = _iPhone;
      final first = make(on: files, storage: storage);
      final task = await started(first);
      storage.live['m'] = ResumeData(task.copyWith(retriesRemaining: 0), 'resume data from URLSession');
      finalState(files, TaskStatusUpdate(task, TaskStatus.failed, TaskConnectionException('offline')), storage);
      await until(() => updates.any((u) => u.state == ModelDownloadState.failed));
      expect(updates.last.error, const DownloadError(DownloadErrorCode.connection, detail: 'offline'));
      await keptOnly('m');
      expect(await first.canResume('m'), isTrue);
      expect(
        [
          for (final call in deviceCalls)
            if (call.method == 'excludeFromBackup') (call.arguments as Map)['path'],
        ],
        [kept('m')],
        reason: 'no backup keeps the temporary file the copy names',
      );

      // A relaunch: the database still has the failed task.
      final again = FakeFiles()
        ..records.add(TaskRecord(task, TaskStatus.failed, 0.4, 1000, TaskConnectionException('offline')))
        ..onResume = (task) async => storage.live.containsKey(task.taskId);
      final relaunched = <ModelDownloadUpdate>[];
      final second = make(on: again, storage: storage, into: relaunched);
      await second.restore();
      expect(relaunched.single.state, ModelDownloadState.failed);
      expect(relaunched.single.error, const DownloadError(DownloadErrorCode.connection, detail: 'offline'));
      expect(await second.canResume('m'), isTrue);
      await second.resume('m');
      expect(again.resumed, hasLength(2), reason: 'no paused data, then the kept data handed back');
      final back = again.resumed.last as DownloadTask;
      expect((back.retriesRemaining, back.retries), (3, 3));
      expect(storage.live['m']!.data, 'resume data from URLSession');
      expect(again.enqueued, isEmpty, reason: 'resumed, not started again');
    });

    test('on Android the kept data resumes only while its temporary file has the bytes it counts', () async {
      platform = _android(34);
      final first = make(on: files, storage: storage);
      final task = await started(first);
      final temp = File(p.join(root.path, 'models', '.partial', 'com.bbflight.background_downloader42'))
        ..createSync(recursive: true)
        ..writeAsBytesSync(List.filled(100, 1));
      storage.live['m'] = ResumeData(task, temp.path, 100, '"etag"');
      finalState(files, TaskStatusUpdate(task, TaskStatus.failed, TaskConnectionException('reset')), storage);
      await keptOnly('m');
      expect(await first.canResume('m'), isTrue);
      expect(
        deviceCalls.where((call) => call.method == 'excludeFromBackup'),
        isEmpty,
        reason: 'Android keeps the models in its no-backup folder',
      );
      temp.writeAsBytesSync(List.filled(50, 1));
      expect(await first.canResume('m'), isFalse, reason: 'fewer bytes than the resume data counts');
      temp.deleteSync();
      expect(await first.canResume('m'), isFalse);

      temp.writeAsBytesSync(List.filled(100, 1));
      final part = File(await task.filePath())..createSync(recursive: true);
      await first.discard('m');
      expect((File(kept('m')).existsSync(), temp.existsSync(), part.existsSync()), (false, false, false));
      expect(await first.canResume('m'), isFalse);
    });

    test('a resume of kept data that fails: iOS with no new data drops it as cannotResume; new data stays', () async {
      platform = _iPhone;
      final ios = make(on: files, storage: storage);
      files.onResume = (task) async => storage.live.containsKey(task.taskId);
      final task = await started(ios);
      storage.live['m'] = ResumeData(task, 'old data');
      finalState(files, TaskStatusUpdate(task, TaskStatus.failed, TaskConnectionException('offline')), storage);
      await keptOnly('m');
      await ios.resume('m');
      final count = updates.length;
      // iOS refuses the old data: the task fails at once, and no new resume data came.
      finalState(files, TaskStatusUpdate(task, TaskStatus.failed, TaskException('cannot open the file')), storage);
      await until(() => updates.length > count);
      expect(updates.last.error, const DownloadError(DownloadErrorCode.cannotResume, detail: 'cannot open the file'));
      await until(() => !File(kept('m')).existsSync());
      expect(await ios.canResume('m'), isFalse);

      // With some progress and new data after the resume, the failure is an ordinary one and the new data stays.
      storage.live['m'] = ResumeData(task, 'old data');
      finalState(files, TaskStatusUpdate(task, TaskStatus.failed, TaskConnectionException('offline')), storage);
      await keptOnly('m');
      await ios.resume('m');
      files.progress!(TaskProgressUpdate(task, 0.5));
      storage.live['m'] = ResumeData(task, 'new data');
      finalState(files, TaskStatusUpdate(task, TaskStatus.failed, TaskConnectionException('offline')), storage);
      await until(() => updates.last.state == ModelDownloadState.failed && updates.last.error!.detail == 'offline');
      expect((await storage.retained('m'))!.data, 'new data');

      // Android reports what failed: a resume the server refuses is cannotResume.
      final android = BackgroundModelDownloader.errorFor(TaskStatus.failed, TaskResumeException('ETag changed'));
      expect(android, const DownloadError(DownloadErrorCode.cannotResume, detail: 'ETag changed'));
    });

    test('iOS: a kept resume that fails before any progress but with new resume data fails as it is', () async {
      platform = _iPhone;
      final ios = make(on: files, storage: storage);
      files.onResume = (task) async => storage.live.containsKey(task.taskId);
      final task = await started(ios);
      storage.live['m'] = ResumeData(task, 'old data');
      finalState(files, TaskStatusUpdate(task, TaskStatus.failed, TaskConnectionException('offline')), storage);
      await keptOnly('m');
      await ios.resume('m');
      final count = updates.length;
      storage.live['m'] = ResumeData(task, 'new data');
      finalState(files, TaskStatusUpdate(task, TaskStatus.failed, TaskConnectionException('offline')), storage);
      await until(() => updates.length > count);
      expect(updates.last.error, const DownloadError(DownloadErrorCode.connection, detail: 'offline'));
      expect((await storage.retained('m'))!.data, 'new data');
    });

    test('iOS: a kept resume that made progress keeps its data when it fails, with no new data', () async {
      platform = _iPhone;
      final ios = make(on: files, storage: storage);
      files.onResume = (task) async => storage.live.containsKey(task.taskId);
      final task = await started(ios);
      storage.live['m'] = ResumeData(task, 'old data');
      finalState(files, TaskStatusUpdate(task, TaskStatus.failed, TaskConnectionException('offline')), storage);
      await keptOnly('m');
      await ios.resume('m');
      files.progress!(TaskProgressUpdate(task, 0.5));
      final count = updates.length;
      finalState(files, TaskStatusUpdate(task, TaskStatus.failed, TaskConnectionException('offline')), storage);
      await until(() => updates.length > count && updates.last.state == ModelDownloadState.failed);
      expect(updates.last.error, const DownloadError(DownloadErrorCode.connection, detail: 'offline'));
      expect((await storage.retained('m'))!.data, 'old data', reason: 'the data was usable: not cannotResume');
    });

    test('Android: kept data of a user-initiated task resumes as a plain job without notifications', () async {
      platform = _android(34);
      final android = make(on: files, storage: storage);
      final task = (await started(android)).copyWith(priority: 0);
      final temp = File(p.join(root.path, 'models', '.partial', 'com.bbflight.background_downloader9'))
        ..createSync(recursive: true)
        ..writeAsBytesSync(List.filled(100, 1));
      storage.live['m'] = ResumeData(task, temp.path, 100, '"etag"');
      finalState(files, TaskStatusUpdate(task, TaskStatus.failed, TaskConnectionException('reset')), storage);
      await keptOnly('m');
      files.onResume = (task) async => storage.live.containsKey(task.taskId);
      await android.resume('m');
      expect((files.resumed.last as DownloadTask).priority, 5, reason: 'notifications are not granted here');
      expect(storage.live['m']!.task.priority, 5);
    });

    test('restore drops data kept for a download that can no longer resume from it (Android)', () async {
      platform = _android(34);
      final first = make(on: files, storage: storage);
      final task = await started(first);
      final temp = File(p.join(root.path, 'models', '.partial', 'com.bbflight.background_downloader7'))
        ..createSync(recursive: true)
        ..writeAsBytesSync(List.filled(40, 1));
      storage.live['m'] = ResumeData(task, temp.path, 100, '"etag"');
      finalState(files, TaskStatusUpdate(task, TaskStatus.failed, TaskConnectionException('reset')), storage);
      await keptOnly('m');

      final again = FakeFiles()
        ..records.add(TaskRecord(task, TaskStatus.failed, 0.4, 1000, TaskConnectionException('reset')));
      final relaunched = <ModelDownloadUpdate>[];
      await make(on: again, storage: storage, into: relaunched).restore();
      expect(relaunched, isEmpty, reason: 'fewer bytes than the kept data counts: nothing to resume');
      expect((File(kept('m')).existsSync(), temp.existsSync()), (false, false));
    });

    test('a storage the host passed to its own first FileDownloader call keeps the data as well', () async {
      platform = _iPhone;
      RetainingResumeStorage.resetInstalled();
      final hosts = MemoryStorage();
      // FileDownloader(persistentStorage: RetainingResumeStorage()) in the host initializes it.
      await hosts.initialize();
      expect(RetainingResumeStorage.installed, same(hosts));
      expect(await RetainingResumeStorage.install(create: (_) => throw StateError('not called')), isTrue);
      final plain = make(on: files);
      final task = await started(plain);
      hosts.live['m'] = ResumeData(task, 'data');
      finalState(files, TaskStatusUpdate(task, TaskStatus.failed, TaskConnectionException('offline')), hosts);
      await until(() => File(kept('m')).existsSync());
      expect(await plain.canResume('m'), isTrue);
    });

    test('the copy goes when the download completes or is canceled, and when it starts again', () async {
      platform = _iPhone;
      final ios = make(on: files, storage: storage, config: const BackgroundDownloadConfig(verifyContent: false));
      final task = await started(ios);
      Future<void> fail() async {
        storage.live['m'] = ResumeData(task, 'data');
        finalState(files, TaskStatusUpdate(task, TaskStatus.failed), storage);
        await keptOnly('m');
      }

      await fail();
      finalState(files, TaskStatusUpdate(task, TaskStatus.complete), storage);
      await until(() => !File(kept('m')).existsSync(), reason: 'complete');
      await fail();
      finalState(files, TaskStatusUpdate(task, TaskStatus.canceled), storage);
      await until(() => !File(kept('m')).existsSync(), reason: 'canceled');
      await fail();
      await started(ios);
      expect(File(kept('m')).existsSync(), isFalse, reason: 'a new start from the first byte');
    });

    test('removing all resume data keeps a copy of the retained groups\' only', () async {
      final ours = Directory(p.join(root.path, 'ours'));
      storage.retain(group: 'app_models', directory: ours.path);
      DownloadTask task(String id, String group) =>
          DownloadTask(taskId: id, url: 'https://example.org/$id', group: group);
      storage.live
        ..['a'] = ResumeData(task('a', 'app_models'), 'a data')
        ..['b'] = ResumeData(task('b', 'other'), 'b data');
      await storage.removeResumeData(null);
      expect(storage.live, isEmpty);
      expect(storage.removed, [null]);
      expect([for (final data in await storage.allRetained()) data.taskId], ['a']);
      expect((await storage.retained('a'))!.data, 'a data');
      expect(await storage.retained('b'), isNull);
      await storage.dropRetained('a');
      expect(await storage.retained('a'), isNull);

      // Dropped right after launch, before the downloader retained its group: copied once it does.
      final early = MemoryStorage();
      early.live['c'] = ResumeData(task('c', 'app_models'), 'c data');
      await early.removeResumeData('c');
      expect(await early.retained('c'), isNull);
      early.retain(group: 'app_models', directory: p.join(root.path, 'early'));
      expect((await early.retained('c'))!.data, 'c data');
    });

    test('without the storage FileDownloader adopted, nothing is kept and canResume is false', () async {
      platform = _iPhone;
      final unadopted = MemoryStorage();
      final plain = make(on: files, storage: unadopted);
      final task = await started(plain);
      unadopted.live['m'] = ResumeData(task, 'data');
      finalState(files, TaskStatusUpdate(task, TaskStatus.failed), unadopted);
      await until(() => updates.isNotEmpty);
      expect(await plain.canResume('m'), isFalse);
    });

    test('install makes the storage FileDownloader\'s, once; not when FileDownloader existed already', () async {
      RetainingResumeStorage.resetInstalled();
      addTearDown(RetainingResumeStorage.resetInstalled);
      expect(await RetainingResumeStorage.install(create: (_) => throw AssertionError('exists')), isFalse);
      expect(await RetainingResumeStorage.install(create: (_) => FakeFiles()), isFalse, reason: 'never initialized');
      expect(RetainingResumeStorage.installed, isNull);
      final adopted = MemoryStorage();
      FileDownloader create(PersistentStorage storage) {
        unawaited(storage.initialize());
        return FakeFiles();
      }

      expect(await RetainingResumeStorage.install(create: create, storage: adopted), isTrue);
      expect(RetainingResumeStorage.installed, same(adopted));
      expect(await RetainingResumeStorage.install(create: (_) => throw StateError('not called')), isTrue);
    });

    test('restore sweeps temporary files no task needs any more, once no task is active', () async {
      platform = _android(34);
      final now = DateTime(2026, 9, 30, 12);
      final old = now.subtract(const Duration(minutes: 11));
      final partial = Directory(p.join(root.path, 'models', '.partial'))..createSync(recursive: true);
      File temp(String name, DateTime modified) => File(p.join(partial.path, name))
        ..writeAsBytesSync([1])
        ..setLastModifiedSync(modified);
      final orphan = temp('com.bbflight.background_downloader1', old);
      final recent = temp('com.bbflight.background_downloader2', now.subtract(const Duration(minutes: 2)));
      final keptTemp = temp('com.bbflight.background_downloader3', old);
      final liveTemp = temp('com.bbflight.background_downloader4', old);
      final other = temp('notes.txt', old);
      final task = DownloadTask(taskId: 'm', url: 'https://example.org/m.gguf', group: 'app_models');
      storage.retain(group: 'app_models', directory: p.join(root.path, 'models', '.resume'));
      storage.live['m'] = ResumeData(task, keptTemp.path, 1);
      await storage.removeResumeData('m');
      storage.live['p'] = ResumeData(task.copyWith(taskId: 'p'), liveTemp.path, 1);

      final busy = FakeFiles()..active.add(DownloadTask(taskId: 'x', url: 'https://example.org/x', group: 'host'));
      await make(on: busy, storage: storage, now: () => now).restore();
      expect(orphan.existsSync(), isTrue, reason: 'another group\'s task may still write there');

      await make(on: FakeFiles(), storage: storage, now: () => now).restore();
      expect(
        (orphan.existsSync(), recent.existsSync(), keptTemp.existsSync(), liveTemp.existsSync(), other.existsSync()),
        (false, true, true, true, true),
      );
    });

    test(
      'restore reports running, paused and queued tasks as before, and a failure with nothing kept not at all',
      () async {
        final again = FakeFiles();
        DownloadTask task(String id) => DownloadTask(
          taskId: id,
          url: 'https://example.org/$id.gguf',
          filename: '$id.gguf.part',
          group: 'app_models',
        );
        again.records.addAll([
          TaskRecord(task('a'), TaskStatus.running, 0.5, 1000),
          TaskRecord(task('b'), TaskStatus.paused, 0.25, 1000),
          TaskRecord(task('c'), TaskStatus.enqueued, 0, -1),
          TaskRecord(task('d'), TaskStatus.failed, -1, 1000, TaskConnectionException('offline')),
          TaskRecord(task('e'), TaskStatus.complete, 1, 1000),
        ]);
        final restored = <ModelDownloadUpdate>[];
        await make(on: again, storage: storage, into: restored).restore();
        expect(
          [for (final u in restored) '${u.id} ${u.state.name} ${u.progress}'],
          ['a running 0.5', 'b paused 0.25', 'c queued 0.0'],
        );
        expect((again.tracked, again.resumedFromBackground), (1, 1));
      },
    );

    test('updates that arrive before the downloader sets up are held for it, in order, over the database', () async {
      platform = _iPhone;
      final early = FakeFiles();
      BackgroundModelDownloader.holdUpdates('app_models', files: early);
      expect(early.trackedMarkingComplete, [false], reason: 'the database follows the group from launch');
      final task = DownloadTask(
        taskId: 'm',
        url: 'https://example.org/m.gguf',
        filename: 'm.gguf.part',
        group: 'app_models',
      );
      // A launch in the background: the updates come before the model manager exists.
      early.records.add(TaskRecord(task, TaskStatus.running, 0.5, 1000));
      early.status!(TaskStatusUpdate(task, TaskStatus.running));
      early.progress!(TaskProgressUpdate(task, 0.6));
      early.progress!(TaskProgressUpdate(task, 0.7));
      early.status!(TaskStatusUpdate(task, TaskStatus.canceled));
      final restored = <ModelDownloadUpdate>[];
      await make(on: early, into: restored).restore();
      expect(
        [for (final u in restored) '${u.state.name} ${u.progress}'],
        ['running null', 'running 0.7', 'canceled null'],
        reason: 'the latest progress only; nothing after the cancel',
      );
      expect(early.trackedMarkingComplete, [false, true]);

      // Too late to hold anything: the downloader's callbacks stay.
      BackgroundModelDownloader.holdUpdates('app_models', files: early);
      early.status!(TaskStatusUpdate(task, TaskStatus.enqueued));
      await until(() => restored.last.state == ModelDownloadState.queued);
    });

    test('iOS: a download the user force-quit is reported paused before its running record is read', () async {
      platform = _iPhone;
      final relaunched = FakeFiles();
      final task = DownloadTask(
        taskId: 'm',
        url: 'https://example.org/m.gguf',
        filename: 'm.gguf.part',
        group: 'app_models',
      );
      relaunched.records.add(TaskRecord(task, TaskStatus.running, 0.4, 1000));
      // The background session, once created, reports the system's cancel of a force-quit as a pause.
      relaunched.onAllTasks = () => relaunched.status!(TaskStatusUpdate(task, TaskStatus.paused));
      final restored = <ModelDownloadUpdate>[];
      await make(on: relaunched, into: restored).restore();
      expect([for (final u in restored) u.state], [ModelDownloadState.paused], reason: 'not the stale running');
    });
  });

  group('D2: a finished download is checked before it counts', () {
    Future<ModelDownloadUpdate> finish(
      List<int> bytes, {
      String? mimeType,
      int? status,
      BackgroundModelDownloader? on,
    }) async {
      final task = await started(on);
      final file = File(await task.filePath())
        ..createSync(recursive: true)
        ..writeAsBytesSync(bytes);
      final count = updates.length;
      files.status!(TaskStatusUpdate(task, TaskStatus.complete, null, null, null, status, mimeType));
      await until(() => updates.length > count);
      final update = updates.last;
      expect(file.existsSync(), update.state == ModelDownloadState.complete, reason: 'a refused file is deleted');
      return update;
    }

    test('a web page, an answer other than 200 or 206, or no GGUF magic fails; a GGUF file is complete', () async {
      expect(
        (await finish(_gguf, mimeType: 'text/html', status: 200)).error,
        const DownloadError(DownloadErrorCode.webPageInsteadOfFile, httpStatus: 200, detail: 'Content-Type text/html'),
      );
      expect(
        (await finish(_gguf, mimeType: 'application/octet-stream', status: 203)).error,
        const DownloadError(DownloadErrorCode.webPageInsteadOfFile, httpStatus: 203, detail: 'HTTP 203'),
      );
      expect(
        (await finish(utf8.encode(' \n<!DOCTYPE html><html>'), mimeType: 'text/plain', status: 200)).error,
        const DownloadError(DownloadErrorCode.webPageInsteadOfFile, httpStatus: 200, detail: 'the file starts with <'),
      );
      expect((await finish([0x50, 0x4b, 3, 4, 5, 6], status: 200)).error, DownloadError.notAGgufFile);
      // An S3-compatible store may serve a .gguf as text/plain; a resumed task ends with 206.
      expect((await finish(_gguf, mimeType: 'text/plain', status: 200)).state, ModelDownloadState.complete);
      expect((await finish(_gguf, status: 206)).state, ModelDownloadState.complete);
      // Found complete at launch (no answer recorded): the file decides.
      expect((await finish(_gguf)).state, ModelDownloadState.complete);
    });

    test('with verifyContent off, a finished download is complete as reported', () async {
      final unchecked = make(on: files, config: const BackgroundDownloadConfig(verifyContent: false));
      expect(
        (await finish(utf8.encode('<html>'), mimeType: 'text/html', status: 200, on: unchecked)).state,
        ModelDownloadState.complete,
      );
    });
  });

  group('D4: Android priority and foreground service', () {
    test('Android tasks are user-initiated jobs only from API 34 with notifications; iOS ones always', () async {
      Future<int> priority(Map<String, Object?> info) async {
        LocalInferenceDevice.resetCache();
        platform = info;
        final fake = FakeFiles();
        final made = make(on: fake);
        await made.start(_entry, directory: root.path, partFileName: 'x.part', wifiOnly: false);
        return fake.enqueued.single.priority;
      }

      expect(await priority(_iPhone), 0);
      expect(await priority(_android(34)), 5, reason: 'the notification permission is not granted here');
      expect(await priority(_android(33)), 5);
      expect(await priority(_android(28)), 5);
    });

    test('a foreground service only when the host opts in', () async {
      Future<Object?> androidConfig(AndroidForeground foreground) async {
        final fake = FakeFiles();
        final opted = make(
          on: fake,
          config: BackgroundDownloadConfig(androidForeground: foreground),
        );
        await opted.start(_entry, directory: root.path, partFileName: 'x.part', wifiOnly: false);
        return fake.androidConfig;
      }

      expect(await androidConfig(const AndroidForeground.never()), [
        (Config.useCacheDir, Config.never),
        (Config.runInForeground, Config.never),
      ]);
      expect(await androidConfig(const AndroidForeground.always()), [
        (Config.useCacheDir, Config.never),
        (Config.runInForeground, Config.always),
      ]);
      expect(await androidConfig(const AndroidForeground.largerThan(100)), [
        (Config.useCacheDir, Config.never),
        (Config.runInForegroundIfFileLargerThan, 100),
      ]);
      platform = _android(34);
      LocalInferenceDevice.resetCache();
      expect(await androidConfig(const AndroidForeground.never()), [
        (Config.useCacheDir, Config.never),
        (Config.tempFilePath, p.join(root.path, 'models', '.partial')),
        (Config.runInForeground, Config.never),
      ]);
    });
  });

  test('a host that configures FileDownloader itself gets no app-wide configuration from the downloader', () async {
    platform = _android(34);
    final fake = FakeFiles();
    await make(
      on: fake,
      config: const BackgroundDownloadConfig(configureFileDownloader: false),
    ).start(_entry, directory: root.path, partFileName: 'x.part', wifiOnly: false);
    expect((fake.globalConfig, fake.androidConfig, fake.iOSConfig), (null, null, null));
    expect(fake.enqueued, hasLength(1));
    expect(fake.notifications.containsKey('running'), isTrue, reason: "the group's own notifications stay");
  });

  group('D5: the Wi-Fi rule on background_downloader 9.5.9', () {
    const fast = BackgroundDownloadConfig(group: 'app_models', networkCheckInterval: Duration(milliseconds: 5));
    const cellular = {'connected': true, 'wifi': false};
    const offline = {'connected': false, 'wifi': false};
    const wifi = {'connected': true, 'wifi': true};

    test('on Android a Wi-Fi-only download off Wi-Fi waits, and starts once on Wi-Fi', () async {
      platform = _android(34);
      network = cellular;
      final older = FakeFiles(tracksConnection: false);
      final guarded = make(on: older, config: fast);
      await guarded.start(_entry, directory: root.path, partFileName: 'x.part', wifiOnly: true);
      expect(older.enqueued, isEmpty, reason: '9.5.9 would run it on an unmetered mobile network');
      await until(() => lastState() == ModelDownloadState.waitingForWifi);
      network = offline;
      await until(() => lastState() == ModelDownloadState.waitingForNetwork);
      network = wifi;
      await until(() => older.enqueued.length == 1);
      await until(() => lastState() == ModelDownloadState.queued);

      // Not Wi-Fi only: it starts at once.
      network = cellular;
      await guarded.start(_entry, directory: root.path, partFileName: 'x.part', wifiOnly: false);
      expect(older.enqueued, hasLength(2));
    });

    test(
      'on Android a running Wi-Fi-only download pauses when the connection leaves Wi-Fi, and goes on with it',
      () async {
        platform = _android(34);
        network = wifi;
        final older = FakeFiles(tracksConnection: false);
        final guarded = make(on: older, config: fast);
        await guarded.start(_entry, directory: root.path, partFileName: 'x.part', wifiOnly: true);
        final task = older.enqueued.single as DownloadTask;
        older.status!(TaskStatusUpdate(task, TaskStatus.running));
        older.progress!(TaskProgressUpdate(task, 0.3));
        network = cellular;
        await until(() => older.paused.length == 1, reason: 'paused on leaving Wi-Fi');
        older.status!(TaskStatusUpdate(task, TaskStatus.paused));
        await until(() => lastState() == ModelDownloadState.waitingForWifi, reason: 'waits, not paused');
        network = wifi;
        await until(() => older.resumed.length == 1, reason: 'resumed on Wi-Fi');
        await until(() => lastState() == ModelDownloadState.queued);
      },
    );

    test(
      'on Android a Wi-Fi-only download found running after a relaunch pauses when the connection leaves Wi-Fi',
      () async {
        platform = _android(34);
        network = wifi;
        final older = FakeFiles(tracksConnection: false);
        final task = DownloadTask(
          taskId: 'm',
          url: 'https://example.org/m.gguf',
          filename: 'm.gguf.part',
          group: 'app_models',
          requiresWiFi: true,
        );
        older.records.add(TaskRecord(task, TaskStatus.running, 0.4, 1000));
        await make(on: older, config: fast).restore();
        // After a relaunch the plugin sends progress, not a new running status.
        older.progress!(TaskProgressUpdate(task, 0.45));
        network = cellular;
        older.progress!(TaskProgressUpdate(task, 0.5));
        await until(() => older.paused.length == 1, reason: 'paused on leaving Wi-Fi');
      },
    );

    test('on Android a resume off Wi-Fi waits too; canceling a wait reports canceled', () async {
      platform = _android(34);
      network = cellular;
      final older = FakeFiles(tracksConnection: false);
      final guarded = make(on: older, config: fast);
      await guarded.start(_entry, directory: root.path, partFileName: 'x.part', wifiOnly: true);
      await guarded.cancel('m');
      await until(() => lastState() == ModelDownloadState.canceled);
      expect(older.canceled, isEmpty, reason: 'background_downloader never had it');

      network = wifi;
      await guarded.start(_entry, directory: root.path, partFileName: 'x.part', wifiOnly: true);
      final task = older.enqueued.single as DownloadTask;
      older.active.add(task);
      older.status!(TaskStatusUpdate(task, TaskStatus.paused));
      network = cellular;
      await guarded.resume('m');
      expect(older.resumed, isEmpty);
      await until(() => lastState() == ModelDownloadState.waitingForWifi);
      await guarded.cancel('m');
      expect(older.canceled, ['m'], reason: 'the paused task is background_downloader\'s to cancel');
    });

    test('9.6, and iOS, keep the Wi-Fi rule themselves: the task is handed over at once', () async {
      network = cellular;
      platform = _android(34);
      final newer = FakeFiles()..wifi = false;
      await make(on: newer, config: fast).start(_entry, directory: root.path, partFileName: 'x.part', wifiOnly: true);
      expect(newer.enqueued, hasLength(1), reason: '9.6 requires Wi-Fi itself');

      LocalInferenceDevice.resetCache();
      platform = _iPhone;
      final older = FakeFiles(tracksConnection: false);
      await make(on: older, config: fast).start(_entry, directory: root.path, partFileName: 'x.part', wifiOnly: true);
      expect(older.enqueued, hasLength(1), reason: 'iOS never lets it use mobile data');
    });

    test('on 9.5.9 the plugin tells a download waiting for Wi-Fi from one waiting for a network', () async {
      platform = _iPhone;
      network = cellular;
      final older = FakeFiles(tracksConnection: false);
      final states = <ModelDownloadUpdate>[];
      final ios = make(on: older, config: fast, into: states);
      await ios.start(_entry, directory: root.path, partFileName: 'x.part', wifiOnly: true);
      older.status!(TaskStatusUpdate(older.enqueued.single, TaskStatus.enqueued));
      await until(() => lastState(states) == ModelDownloadState.waitingForWifi);
      network = offline;
      await until(() => lastState(states) == ModelDownloadState.waitingForNetwork);
      network = wifi;
      await until(() => lastState(states) == ModelDownloadState.queued);
    });
  });
}
