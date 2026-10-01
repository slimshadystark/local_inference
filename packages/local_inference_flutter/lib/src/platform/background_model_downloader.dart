/// The model download on phones, behind local_inference's [ModelDownloader].
///
/// [BackgroundModelDownloader] hands one plain DownloadTask per model to background_downloader:
/// a background URLSession on iOS, a user-initiated data transfer job on Android 14+ (WorkManager with
/// pause and resume every 9 minutes below that), so a 3 GB download survives the app going to the
/// background. Not a ParallelDownloadTask: chunks cannot use Android's user-initiated jobs and joining
/// them needs twice the file size on disk. The file lands as `<name>.part` in the manager's folder;
/// the manager checks it and gives it its final name.
///
/// Pausing and resuming need the server to announce byte ranges. Azure Blob Storage answers anonymous
/// requests with API version 2009-09-19 unless told otherwise, which sends no Accept-Ranges and an
/// unquoted ETag: iOS would then restart from byte 0 after a dropped connection and Android would refuse
/// to pause (and fail at WorkManager's 9-minute limit below Android 14). Every task names a recent
/// version; other hosts ignore the header.
///
/// Every task also asks for the file uncompressed. A CDN in front of an S3-compatible object store may gzip
/// an object stored as text/plain (the type such stores often give a .gguf) whenever the client accepts
/// gzip, which URLSession and Android do by default. The answer then has no Content-Length or Accept-Ranges
/// and only a weak ETag, while range requests get the strong one: no progress total, no pause, and resume
/// refused. With `Accept-Encoding: identity` such a CDN sends the stored bytes with their length and strong
/// ETag (`identity, gzip;q=0` was still compressed).
///
/// Android 14+ runs a user-initiated job (priority 0) only if it posts a notification within 10 s, which
/// background_downloader cannot do without POST_NOTIFICATIONS; below Android 14, and without that permission,
/// a task of priority 0 would be an expedited job, stopped after 2 minutes. So Android tasks get priority 0 only
/// from Android 14 with the permission granted, and 5 (a plain WorkManager job) otherwise ([userInitiatedFor]).
///
/// A failed download keeps its resume data when [RetainingResumeStorage] is FileDownloader's storage
/// (`LocalInferenceFlutter.installDownloaderStorage()`): [canResume] finds it, also after a relaunch, and [resume]
/// continues from it. [discard] deletes it with its temporary file, and [restore] reports such a download as failed
/// and deletes the temporary files in `models/.partial` that nothing refers to any more. The updates that arrive
/// between the creation of FileDownloader and this downloader's setup are held for it ([holdUpdates]).
///
/// A finished download is checked before it counts as complete ([BackgroundDownloadConfig.verifyContent]): a web
/// page, an answer other than 200 or 206, or a GGUF entry's file without the GGUF magic fails, and the file goes.
///
/// The tasks live in their own group with registered callbacks, so the app's own use of
/// FileDownloader().updates (a single-subscription stream) is not taken over.
///
/// Works on background_downloader 9.5.9 (Flutter 3.44) and 9.6: no TransferHint, which 9.5.9 lacks; the
/// priority and allowPause it would set are given directly. 9.6 tracks the connection (isConnected, isWiFi) and
/// requires Wi-Fi itself for a Wi-Fi-only task. 9.5.9 does neither: the plugin's `network` reading tells a missing
/// network from a missing Wi-Fi, and on Android, where 9.5.9 runs a Wi-Fi-only task on any unmetered network, this
/// downloader holds such a task back while the device is off Wi-Fi and pauses it when the connection leaves Wi-Fi
/// (both only while the app runs).
library;

import 'dart:async';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:local_inference/local_inference.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'device.dart';
import 'diagnostics.dart';
import 'download_config.dart';
import 'paths.dart';
import 'retaining_resume_storage.dart';

/// [ModelDownloader] on background_downloader, for iOS and Android (see the library comment).
final class BackgroundModelDownloader implements ModelDownloader {
  /// [location] names the folder the manager passes (Application Support, relative, by default);
  /// [androidTempDirectory] is where Android keeps a download in progress (default: `<location>/models/.partial`);
  /// [retainDirectory] where a failed download's resume data is kept (default: `<location>/models/.resume`).
  /// [storage] replaces [RetainingResumeStorage.installed] (tests); [device] answers the platform and the connection.
  BackgroundModelDownloader({
    this.location = const ModelStorageLocation.applicationSupport(),
    this.config = const BackgroundDownloadConfig(),
    FileDownloader? files,
    this.androidTempDirectory,
    this.retainDirectory,
    RetainingResumeStorage? storage,
    this.device = const LocalInferenceDevice(),
    @visibleForTesting DateTime Function()? now,
  }) : _injected = files,
       _storageOverride = storage,
       _now = now ?? DateTime.now;

  final ModelStorageLocation location;
  final BackgroundDownloadConfig config;
  final String? androidTempDirectory;
  final String? retainDirectory;
  final LocalInferenceDevice device;
  final FileDownloader? _injected;
  final RetainingResumeStorage? _storageOverride;
  final DateTime Function() _now;
  late final FileDownloader _files = _injected ?? FileDownloader();
  final _controller = StreamController<ModelDownloadUpdate>.broadcast();
  final _tasks = <String, DownloadTask>{};
  final _formats = <String, String>{};
  final _lastState = <String, ModelDownloadState>{};
  final _networkChecks = <String, Timer>{};
  Future<void>? _setUp;
  String? _partialDirectory;
  PlatformSupportInfo? _platform;
  bool _askedNotifications = false;

  /// Steps still running for a task (a content check), which the task's next updates wait for.
  final _pending = <String, Future<void>>{};

  /// The resume data [resume] handed back to background_downloader, until the task makes progress or ends.
  final _resumedFrom = <String, ResumeData>{};

  /// Wi-Fi-only tasks held back while the device is off Wi-Fi (background_downloader 9.5.9 on Android).
  final _held = <String, _Held>{};

  /// Tasks paused because the connection left Wi-Fi; their paused update becomes "waiting for Wi-Fi".
  final _pausingForWifi = <String>{};
  Timer? _wifiWatch;
  bool _checkingWifi = false;

  String get group => config.group;

  @override
  Stream<ModelDownloadUpdate> get updates => _controller.stream;

  /// The updates [holdUpdates] keeps, by FileDownloader and group.
  static final _early = Expando<Map<String, List<TaskUpdate>>>();

  /// The groups whose downloader set up, by FileDownloader: their callbacks are that downloader's.
  static final _setUpGroups = Expando<Set<String>>();

  /// Keeps the status and progress updates of [group]'s tasks until a downloader of [group] sets up, which handles
  /// them first, and has background_downloader record the group's tasks in its database from now on. Without it, an
  /// update that arrives between the creation of FileDownloader and that setup (iOS finishing or failing a download
  /// in a launch in the background, a notification's Cancel) reaches no callback and leaves the database behind.
  /// `LocalInferenceFlutter.installDownloaderStorage` calls it; a host that creates FileDownloader itself calls it
  /// right after. Once the group's downloader has set up it does nothing. [files] defaults to `FileDownloader()`.
  static void holdUpdates(String group, {FileDownloader? files}) {
    final downloader = files ?? FileDownloader();
    if (_setUpGroups[downloader]?.contains(group) ?? false) return;
    final held = (_early[downloader] ??= {}).putIfAbsent(group, () => []);
    downloader.registerCallbacks(
      group: group,
      taskStatusCallback: held.add,
      taskProgressCallback: (update) {
        // Of a task's progress since its last status only the latest counts.
        final last = held.lastIndexWhere((earlier) => earlier.task.taskId == update.task.taskId);
        if (last >= 0 && held[last] is TaskProgressUpdate) held.removeAt(last);
        held.add(update);
      },
    );
    // Not awaited: it waits for FileDownloader's storage, whose failure would never complete it. It applies before
    // any update, since FileDownloader handles updates only once that storage is ready.
    downloader.trackTasksInGroup(group, markDownloadedComplete: false).ignore();
  }

  /// Whether a download runs as a user-initiated data transfer job (priority 0): on iOS, its highest priority,
  /// always; on Android only from API 34 with the notification permission granted (such a job must post a
  /// notification; the plugin's manifest merges RUN_USER_INITIATED_JOBS). Elsewhere priority 5, so a task is never
  /// an expedited job, which Android stops after 2 minutes.
  @visibleForTesting
  static bool userInitiatedFor(PlatformSupportInfo platform, {required bool notificationsGranted}) =>
      switch (platform.os) {
        'android' => (platform.androidSdkInt ?? 0) >= 34 && notificationsGranted,
        _ => true,
      };

  /// The task for [entry], on [platform] ([userInitiatedFor] sets its priority).
  @visibleForTesting
  static DownloadTask buildTask(
    ModelEntry entry, {
    required String group,
    required BaseDirectory baseDirectory,
    required String directory,
    required String partFileName,
    required bool wifiOnly,
    required PlatformSupportInfo platform,
    required bool notificationsGranted,
    Map<String, String> headers = HttpModelDownloader.defaultHeaders,
    int retries = 3,
  }) => DownloadTask(
    taskId: entry.id,
    url: entry.url.toString(),
    headers: headers,
    filename: partFileName,
    directory: directory,
    baseDirectory: baseDirectory,
    group: group,
    updates: Updates.statusAndProgress,
    requiresWiFi: wifiOnly,
    retries: retries,
    allowPause: true,
    priority: userInitiatedFor(platform, notificationsGranted: notificationsGranted) ? 0 : 5,
    displayName: entry.displayName,
  );

  /// The same task as a WorkManager job, for a download paused as a user-initiated job whose
  /// notification permission was withdrawn since. Rebuilt from its JSON without transfer hints, which
  /// would make a task of an earlier build user-initiated again.
  @visibleForTesting
  static DownloadTask withoutUserInitiated(DownloadTask task) =>
      DownloadTask.fromJson({...task.toJson(), 'priority': 5}..remove('transferHints'));

  /// Where background_downloader writes the folder [directory] (absolute): relative to Application Support when
  /// [location] says so and the folder is inside it, else from the file system's root.
  @visibleForTesting
  static (BaseDirectory, String) taskDirectory(String directory, ModelStorageLocation location, String? support) {
    if (location is ApplicationSupportLocation && support != null && p.isWithin(support, directory)) {
      return (BaseDirectory.applicationSupport, p.relative(directory, from: support));
    }
    return (BaseDirectory.root, directory);
  }

  bool get _isAndroid => _platform?.os == 'android';

  bool get _isIos => _platform?.os == 'ios';

  /// The storage that keeps failed downloads' resume data, when FileDownloader adopted it.
  RetainingResumeStorage? get _keeper {
    final storage = _storageOverride ?? RetainingResumeStorage.installed;
    return storage != null && storage.adopted ? storage : null;
  }

  /// Callbacks, notifications and the global configuration, once, before the first task: on iOS the
  /// resource timeout can only be set before a task runs (the 4 h default is too short for 3 GB on a
  /// slow line).
  Future<void> _ensureSetUp() => _setUp ??= () async {
    _platform = await device.platform();
    final root = await _root();
    (_storageOverride ?? RetainingResumeStorage.installed)?.retain(
      group: group,
      directory: retainDirectory ?? p.join(root, 'models', '.resume'),
      // A copy is of no use without the system's temporary file it names, which no backup keeps.
      onWritten: _isIos ? device.excludeFromBackup : null,
    );
    _files.registerCallbacks(group: group, taskStatusCallback: _onStatus, taskProgressCallback: _onProgress);
    (_setUpGroups[_files] ??= {}).add(group);
    // What arrived before this setup (holdUpdates), in its order and before anything newer.
    for (final update in _early[_files]?.remove(group) ?? const <TaskUpdate>[]) {
      switch (update) {
        case TaskStatusUpdate():
          _onStatus(update);
        case TaskProgressUpdate():
          _onProgress(update);
      }
    }
    final notifications = config.resolvedNotifications;
    TaskNotification? notification(DownloadNotificationText? text) =>
        text == null ? null : TaskNotification(text.title, text.body);
    _files.configureNotificationForGroup(
      group,
      running: notification(notifications.running),
      paused: notification(notifications.paused),
      complete: notification(notifications.complete),
      error: notification(notifications.error),
      progressBar: notifications.progressBar,
    );
    // Android keeps the partial file in its own folder under models/: the no-backup folder, or the one the
    // host's backup rules leave out of cloud backup and transfers.
    final androidTemp = _isAndroid ? androidTempDirectory ?? p.join(root, 'models', '.partial') : null;
    _partialDirectory = androidTemp;
    // The host configures FileDownloader itself (BackgroundDownloadConfig.configureFileDownloader).
    if (!config.configureFileDownloader) return;
    final foreground = androidForegroundSetting(config.androidForeground);
    await _files.configure(
      globalConfig: [(Config.checkAvailableSpace, config.checkAvailableSpaceMB)],
      androidConfig: [
        (Config.useCacheDir, Config.never),
        if (androidTemp != null) (Config.tempFilePath, androidTemp),
        // background_downloader keeps this setting across launches: say it every time.
        if (foreground == null) (Config.runInForeground, Config.never),
        if (foreground != null && foreground.always) (Config.runInForeground, Config.always),
        if (foreground != null && !foreground.always) (Config.runInForegroundIfFileLargerThan, foreground.megabytes),
      ],
      iOSConfig: [
        (Config.resourceTimeout, config.iosResourceTimeout),
        (Config.excludeFromCloudBackup, Config.always),
        if (notifications.actionLabels != null) (Config.localize, notifications.actionLabels),
      ],
    );
  }();

  Future<String> _root() async => switch (location) {
    AbsoluteLocation(:final root) => root,
    ApplicationSupportLocation() => (await getApplicationSupportDirectory()).path,
  };

  @override
  Future<void> start(
    ModelEntry entry, {
    required String directory,
    required String partFileName,
    required bool wifiOnly,
  }) async {
    await _ensureSetUp();
    final notificationsAllowed = await _notificationsAllowed();
    final support = location is ApplicationSupportLocation ? await _root() : null;
    final (base, folder) = taskDirectory(directory, location, support);
    final task = buildTask(
      entry,
      group: group,
      baseDirectory: base,
      directory: folder,
      partFileName: partFileName,
      wifiOnly: wifiOnly,
      platform: _platform!,
      notificationsGranted: notificationsAllowed,
      headers: {...HttpModelDownloader.defaultHeaders, ...config.headers},
      retries: config.retries,
    );
    final id = entry.id;
    _tasks[id] = task;
    _formats[id] = entry.format;
    _held.remove(id);
    _pausingForWifi.remove(id);
    _resumedFrom.remove(id);
    // A new download from the first byte: the data an earlier attempt kept is of no use.
    await _dropKept(id);
    if (!await _mayRun(task, resume: false)) return;
    if (!await _files.enqueue(task)) {
      _emit(
        ModelDownloadUpdate(
          id: id,
          state: ModelDownloadState.failed,
          error: const DownloadError(DownloadErrorCode.cannotStart),
        ),
      );
    }
  }

  @override
  Future<void> pause(String id) async {
    await _ensureSetUp();
    if (_held.containsKey(id)) return;
    final task = await _taskFor(id);
    if (task != null) await _files.pause(task);
  }

  /// Resumes a paused download from background_downloader's resume data, or a failed one from the data kept for it
  /// (with its retries renewed); starts it again when there is neither. A Wi-Fi-only task off Wi-Fi waits for it
  /// first (background_downloader 9.5.9 on Android).
  @override
  Future<void> resume(String id) async {
    await _ensureSetUp();
    if (_held.containsKey(id)) return;
    final task = await _taskFor(id) ?? await _keptTask(id);
    if (task == null) {
      _emit(
        ModelDownloadUpdate(
          id: id,
          state: ModelDownloadState.failed,
          error: const DownloadError(DownloadErrorCode.cannotResume),
        ),
      );
      return;
    }
    if (!await _mayRun(task, resume: true)) return;
    await _resume(task);
  }

  Future<void> _resume(DownloadTask task) async {
    final id = task.taskId;
    final userInitiated = userInitiatedFor(_platform!, notificationsGranted: await _notificationsAllowed());
    // Tasks compare equal by id, so the plugin resumes the paused data with this task's settings.
    final t = _withPriority(task, userInitiated: userInitiated);
    _tasks[id] = t;
    if (await _files.resume(t)) return;
    final keeper = _keeper;
    final kept = keeper == null ? null : await keeper.retained(id);
    final keptTask = kept?.task;
    if (keeper != null && kept != null && keptTask is DownloadTask) {
      final back = ResumeData(
        _withPriority(keptTask.copyWith(retriesRemaining: keptTask.retries), userInitiated: userInitiated),
        kept.data,
        kept.requiredStartByte,
        kept.eTag,
      );
      await keeper.restoreResumeData(back);
      _resumedFrom[id] = back;
      _tasks[id] = back.task as DownloadTask;
      if (await _files.resume(back.task as DownloadTask)) return;
      _resumedFrom.remove(id);
    }
    if (!await _files.enqueue(t.copyWith(retriesRemaining: t.retries))) {
      _emit(
        ModelDownloadUpdate(
          id: id,
          state: ModelDownloadState.failed,
          error: const DownloadError(DownloadErrorCode.cannotResume),
        ),
      );
    }
  }

  /// [task] as a WorkManager job when it may not be user-initiated any more (the permission was withdrawn).
  static DownloadTask _withPriority(DownloadTask task, {required bool userInitiated}) =>
      !userInitiated && task.priority < 5 ? withoutUserInitiated(task) : task;

  /// True when resume data was kept for [id] and, on Android, the temporary file it names still has the bytes it
  /// counts; false when FileDownloader was created without [RetainingResumeStorage].
  @override
  Future<bool> canResume(String id) async {
    await _ensureSetUp();
    final kept = await _keeper?.retained(id);
    if (kept == null) return false;
    if (!_isAndroid) return true;
    try {
      return await File(kept.tempFilepath).length() >= kept.requiredStartByte;
    } on FileSystemException {
      return false;
    }
  }

  /// Deletes the resume data kept for [id], the temporary file it names and the part file of the task.
  @override
  Future<void> discard(String id) async {
    await _ensureSetUp();
    final kept = await _keeper?.retained(id);
    await _dropKept(id);
    final task = await _taskFor(id) ?? _downloadTask(kept?.task);
    if (task != null) await _deleteFile(await task.filePath());
  }

  @override
  Future<void> cancel(String id) async {
    await _ensureSetUp();
    _pausingForWifi.remove(id);
    final held = _held.remove(id);
    // A held task that background_downloader never got (or not as a paused task) is canceled here.
    if (held != null && (!held.resume || await _files.taskForId(id) == null)) {
      await _dropKept(id);
      _emit(ModelDownloadUpdate(id: id, state: ModelDownloadState.canceled));
      return;
    }
    await _files.cancelTaskWithId(id);
  }

  /// Reattaches to the group's tasks, reports a failed download whose resume data was kept as failed, so a
  /// retry resumes it, and deletes the temporary files in `models/.partial` that no task needs any more, and kept
  /// data that can no longer resume. background_downloader keeps its own records, so [targets] are not needed.
  @override
  Future<void> restore({Iterable<DownloadTarget> targets = const []}) async {
    // Tracking marks a task complete (and reports it) when its file exists, e.g. when iOS finished the
    // download while the app was closed; resumeFromBackground delivers updates stored while suspended; the setup
    // handles those held since launch (holdUpdates). Those arrive through the callbacks and are newer than the
    // database, which is written after them.
    final reported = _lastState.keys.toSet();
    await _ensureSetUp();
    await _files.trackTasksInGroup(group);
    await _files.resumeFromBackground();
    try {
      // On iOS this creates the background session, so the system reports now the downloads it canceled when the
      // user force-quit the app (paused, with their resume data), before rescheduleKilledTasks takes them for
      // killed tasks and starts them again from the first byte.
      await _files.allTasks(allGroups: true);
    } catch (_) {
      // The records still tell.
    }
    for (final record in await _files.database.allRecords(group: group)) {
      final task = record.task;
      if (task is! DownloadTask) continue;
      final id = task.taskId;
      _tasks[id] = task;
      if (_lastState.containsKey(id) && !reported.contains(id)) continue;
      final ended = record.status == TaskStatus.failed || record.status == TaskStatus.notFound;
      final resumable = ended && await canResume(id);
      // On Android, data kept for a download whose temporary file is gone or short.
      if (ended && !resumable) await _dropKept(id);
      final state = switch (record.status) {
        TaskStatus.enqueued || TaskStatus.waitingToRetry => ModelDownloadState.queued,
        TaskStatus.running => ModelDownloadState.running,
        TaskStatus.paused => ModelDownloadState.paused,
        _ when resumable => ModelDownloadState.failed,
        _ => null,
      };
      if (state == null) continue;
      _emit(
        ModelDownloadUpdate(
          id: id,
          state: state,
          progress: record.progress >= 0 && record.progress <= 1 ? record.progress : null,
          expectedBytes: record.expectedFileSize > 0 ? record.expectedFileSize : null,
          error: state == ModelDownloadState.failed ? errorFor(record.status, record.exception) : null,
        ),
      );
      _checkNetworkLater(task, state);
    }
    await _sweepPartial();
    // Same delay as FileDownloader.start: re-enqueue tasks the OS dropped when the app was killed.
    Timer(const Duration(seconds: 5), () => _files.rescheduleKilledTasks().ignore());
  }

  /// Stops the network checks and closes [updates]. The tasks keep running in background_downloader.
  Future<void> dispose() async {
    for (final timer in _networkChecks.values) {
      timer.cancel();
    }
    _networkChecks.clear();
    _wifiWatch?.cancel();
    _wifiWatch = null;
    await _controller.close();
  }

  Future<DownloadTask?> _taskFor(String id) async {
    final known = _tasks[id];
    if (known != null) return known;
    final active = await _files.taskForId(id);
    if (active is DownloadTask) return _tasks[id] = active;
    final recorded = (await _files.database.recordForId(id))?.task;
    if (recorded is DownloadTask) return _tasks[id] = recorded;
    return null;
  }

  Future<DownloadTask?> _keptTask(String id) async => _downloadTask((await _keeper?.retained(id))?.task);

  static DownloadTask? _downloadTask(Task? task) => task is DownloadTask ? task : null;

  /// Deletes the resume data kept for [id] and, on Android, the temporary file it names.
  Future<void> _dropKept(String id) async {
    final keeper = _keeper;
    if (keeper == null) return;
    final kept = await keeper.retained(id);
    if (kept == null) return;
    if (_isAndroid && _isTemporaryFile(kept.tempFilepath)) await _deleteFile(kept.tempFilepath);
    await keeper.dropRetained(id);
  }

  /// Deletes the temporary files background_downloader left in `models/.partial` (Android): once no task of any
  /// group is active, each one that neither live nor kept resume data names and that nobody wrote for 10 minutes.
  /// The folder is background_downloader's temporary folder for every task of the app, hence the other groups too.
  Future<void> _sweepPartial() async {
    final folder = _partialDirectory;
    if (folder == null || !await Directory(folder).exists()) return;
    try {
      if ((await _files.allTasks(allGroups: true)).isNotEmpty) return;
      final named = <String>{};
      final keeper = _keeper;
      if (keeper != null) {
        for (final data in [...await keeper.retrieveAllResumeData(), ...await keeper.allRetained()]) {
          named.add(p.normalize(data.tempFilepath));
        }
      }
      final cutoff = _now().subtract(const Duration(minutes: 10));
      await for (final entity in Directory(folder).list()) {
        if (entity is! File || !_isTemporaryFile(entity.path) || named.contains(p.normalize(entity.path))) continue;
        if ((await entity.stat()).modified.isAfter(cutoff)) continue;
        await _deleteFile(entity.path);
      }
    } catch (_) {
      // Left for the next launch.
    }
  }

  /// background_downloader names its temporary files `com.bbflight.background_downloader<number>`.
  static bool _isTemporaryFile(String path) => p.basename(path).startsWith('com.bbflight.background_downloader');

  static Future<void> _deleteFile(String path) async {
    try {
      await File(path).delete();
    } on FileSystemException {
      return;
    }
  }

  /// Whether download notifications may be shown, asking once per run. Checked on every start and
  /// resume, since the user can change it in the system settings meanwhile.
  Future<bool> _notificationsAllowed() async {
    if (!(_isAndroid || _isIos)) return true;
    try {
      var status = await _files.permissions.status(PermissionType.notifications);
      if (status != PermissionStatus.granted && !_askedNotifications) {
        _askedNotifications = true;
        status = await _files.permissions.request(PermissionType.notifications);
      }
      return status == PermissionStatus.granted;
    } catch (_) {
      return false;
    }
  }

  void _onStatus(TaskStatusUpdate update) {
    final task = update.task;
    final id = task.taskId;
    if (task is DownloadTask) _tasks[id] = task;
    if (update.status == TaskStatus.paused && task is DownloadTask && _pausingForWifi.remove(id)) {
      // Paused here because the connection left Wi-Fi: it waits for Wi-Fi, then resumes.
      _held[id] = _Held(task, resume: true);
      _inOrder(id, () => _emit(ModelDownloadUpdate(id: id, state: ModelDownloadState.waitingForWifi)));
      _watchWifi();
      return;
    }
    ResumeData? handedBack;
    if (update.status.isFinalState) {
      _pausingForWifi.remove(id);
      handedBack = _resumedFrom.remove(id);
      // A download that finished or was canceled needs no kept data (background_downloader has just copied its
      // resume data into the storage, which runs this after that copy).
      if (update.status == TaskStatus.complete || update.status == TaskStatus.canceled) {
        final keeper = _keeper;
        if (keeper != null) unawaited(keeper.dropRetained(id));
      }
    }
    final state = switch (update.status) {
      TaskStatus.enqueued || TaskStatus.waitingToRetry => ModelDownloadState.queued,
      TaskStatus.running => ModelDownloadState.running,
      TaskStatus.paused => ModelDownloadState.paused,
      TaskStatus.complete => ModelDownloadState.complete,
      TaskStatus.notFound || TaskStatus.failed => ModelDownloadState.failed,
      TaskStatus.canceled => ModelDownloadState.canceled,
    };
    if (state == ModelDownloadState.complete && config.verifyContent && task is DownloadTask) {
      _inOrder(id, () async => _emit(await _checkContent(update, task)));
    } else if (state == ModelDownloadState.failed && handedBack != null && _isIos) {
      final back = handedBack;
      _inOrder(id, () async => _emit(await _failureOfKeptResume(update, back)));
    } else {
      _inOrder(
        id,
        () => _emit(
          ModelDownloadUpdate(
            id: id,
            state: state,
            error: state == ModelDownloadState.failed ? errorFor(update.status, update.exception) : null,
          ),
        ),
      );
    }
    _checkNetworkLater(task, state);
    if (state == ModelDownloadState.running && task.requiresWiFi && _guardsWifi) _watchWifi();
  }

  /// The verdict on a finished download: a `text/html` answer or a status other than 200 or 206 is a web page; a
  /// GGUF entry's file that starts with `<` is one too, and one without the GGUF magic is no model. Such a file is
  /// deleted; anything else is complete (the manager still checks size and SHA-256).
  Future<ModelDownloadUpdate> _checkContent(TaskStatusUpdate update, DownloadTask task) async {
    final id = task.taskId;
    ModelDownloadUpdate failed(DownloadError error) =>
        ModelDownloadUpdate(id: id, state: ModelDownloadState.failed, error: error);
    final path = await task.filePath();
    final type = update.mimeType?.toLowerCase();
    final status = update.responseStatusCode;
    final html = type != null && type.startsWith('text/html');
    if (html || status != null && status != 200 && status != 206) {
      await _deleteFile(path);
      return failed(
        DownloadError(
          DownloadErrorCode.webPageInsteadOfFile,
          httpStatus: status,
          detail: html ? 'Content-Type $type' : 'HTTP $status',
        ),
      );
    }
    if ((_formats[id] ?? (task.filename.contains('.gguf') ? 'gguf' : '')) == 'gguf') {
      final head = await _head(path);
      final content = head == null ? DownloadedContent.gguf : DownloadedContent.of(head);
      if (content != DownloadedContent.gguf) {
        await _deleteFile(path);
        return failed(
          content == DownloadedContent.webPage
              ? DownloadError(
                  DownloadErrorCode.webPageInsteadOfFile,
                  httpStatus: status,
                  detail: 'the file starts with <',
                )
              : DownloadError.notAGgufFile,
        );
      }
    }
    return ModelDownloadUpdate(id: id, state: ModelDownloadState.complete);
  }

  /// The first bytes of the file at [path]; null when it cannot be read (the manager reports a missing file).
  static Future<List<int>?> _head(String path) async {
    try {
      final file = await File(path).open();
      try {
        return await file.read(64);
      } finally {
        await file.close();
      }
    } on FileSystemException {
      return null;
    }
  }

  /// A download that [resume] continued from kept data failed on iOS. With no new resume data (the storage kept
  /// exactly what was handed back), iOS could not use the old data (its temporary file is gone): the copy goes, and
  /// the failure is [DownloadErrorCode.cannotResume], after which the manager starts the download again.
  Future<ModelDownloadUpdate> _failureOfKeptResume(TaskStatusUpdate update, ResumeData handedBack) async {
    final id = update.task.taskId;
    final keeper = _keeper;
    final kept = keeper == null ? null : await keeper.retained(id);
    if (keeper != null && (kept == null || kept == handedBack)) {
      await keeper.dropRetained(id);
      return ModelDownloadUpdate(
        id: id,
        state: ModelDownloadState.failed,
        error: DownloadError(DownloadErrorCode.cannotResume, detail: update.exception?.description),
      );
    }
    return ModelDownloadUpdate(
      id: id,
      state: ModelDownloadState.failed,
      error: errorFor(update.status, update.exception),
    );
  }

  /// Runs [step] for the task [id] after the steps still pending for it, so its updates keep their order.
  void _inOrder(String id, FutureOr<void> Function() step) {
    final before = _pending[id];
    final result = before == null ? step() : before.then((_) => step());
    if (result is! Future<void>) return;
    late final Future<void> guarded;
    guarded = result.catchError((Object _) {}).whenComplete(() {
      if (identical(_pending[id], guarded)) _pending.remove(id);
    });
    _pending[id] = guarded;
  }

  /// A queued task waits for a connection (for Wi-Fi when Wi-Fi-only). The connectivity reading settles
  /// a moment after launch and can change while the task waits, so it is checked every
  /// network check interval until the task leaves the queue.
  void _checkNetworkLater(Task task, ModelDownloadState state) {
    _networkChecks.remove(task.taskId)?.cancel();
    if (state != ModelDownloadState.queued) return;
    const waiting = {
      ModelDownloadState.queued,
      ModelDownloadState.waitingForWifi,
      ModelDownloadState.waitingForNetwork,
    };
    _networkChecks[task.taskId] = Timer.periodic(config.networkCheckInterval, (timer) async {
      if (!waiting.contains(_lastState[task.taskId])) {
        timer.cancel();
        if (identical(_networkChecks[task.taskId], timer)) _networkChecks.remove(task.taskId);
        return;
      }
      final connection = await _connection();
      final last = _lastState[task.taskId];
      if (connection == null || !timer.isActive || !waiting.contains(last)) return;
      final next = !connection.connected
          ? ModelDownloadState.waitingForNetwork
          : task.requiresWiFi && !connection.wifi
          ? ModelDownloadState.waitingForWifi
          : ModelDownloadState.queued;
      if (next != last) _emit(ModelDownloadUpdate(id: task.taskId, state: next));
    });
  }

  /// The connection as background_downloader tracks it (9.6: FileDownloader.isConnected and isWiFi, fed by
  /// connectivity_plus); null on 9.5.9, which has neither.
  ({bool connected, bool wifi})? _trackedConnection() {
    final dynamic files = _files;
    try {
      return (connected: files.isConnected as bool, wifi: files.isWiFi as bool);
    } on NoSuchMethodError {
      return null;
    }
  }

  /// The connection: background_downloader's reading, else the plugin's (`network`); null when neither knows.
  Future<({bool connected, bool wifi})?> _connection() async {
    final tracked = _trackedConnection();
    if (tracked != null) return tracked;
    final state = await device.network();
    return state == null ? null : (connected: state.connected, wifi: state.wifi);
  }

  /// Whether this downloader keeps the Wi-Fi-only rule itself: on background_downloader 9.5.9 on Android, which
  /// runs a Wi-Fi-only task on any unmetered network. 9.6 requires Wi-Fi itself; iOS never lets such a task use
  /// mobile data.
  bool get _guardsWifi => _isAndroid && _trackedConnection() == null;

  /// Whether [task] may run now. A Wi-Fi-only task off Wi-Fi is held back (see [_guardsWifi]), reported as waiting,
  /// and started or resumed once the device is on Wi-Fi again.
  Future<bool> _mayRun(DownloadTask task, {required bool resume}) async {
    if (!task.requiresWiFi || !_guardsWifi) return true;
    final connection = await _connection();
    if (connection == null || connection.wifi) return true;
    _held[task.taskId] = _Held(task, resume: resume);
    _emit(
      ModelDownloadUpdate(
        id: task.taskId,
        state: connection.connected ? ModelDownloadState.waitingForWifi : ModelDownloadState.waitingForNetwork,
      ),
    );
    _watchWifi();
    return false;
  }

  void _watchWifi() => _wifiWatch ??= Timer.periodic(config.networkCheckInterval, (_) => unawaited(_checkWifi()));

  /// While tasks are held or Wi-Fi-only tasks run (background_downloader 9.5.9 on Android): on Wi-Fi the held
  /// ones start or resume; off Wi-Fi the running ones pause, and the held ones say what they wait for.
  Future<void> _checkWifi() async {
    if (_checkingWifi) return;
    _checkingWifi = true;
    try {
      final running = [
        for (final MapEntry(key: id, value: task) in _tasks.entries)
          if (task.requiresWiFi && _lastState[id] == ModelDownloadState.running && !_pausingForWifi.contains(id)) task,
      ];
      if (_held.isEmpty && running.isEmpty) {
        _wifiWatch?.cancel();
        _wifiWatch = null;
        return;
      }
      final connection = await _connection();
      if (connection == null) return;
      if (connection.wifi) {
        for (final id in [..._held.keys]) {
          final held = _held.remove(id);
          if (held != null) await _release(held);
        }
        return;
      }
      final waiting = connection.connected ? ModelDownloadState.waitingForWifi : ModelDownloadState.waitingForNetwork;
      for (final id in _held.keys) {
        if (_lastState[id] != waiting) _emit(ModelDownloadUpdate(id: id, state: waiting));
      }
      for (final task in running) {
        _pausingForWifi.add(task.taskId);
        if (!await _files.pause(task)) _pausingForWifi.remove(task.taskId);
      }
    } finally {
      _checkingWifi = false;
    }
  }

  /// Starts or resumes a task that waited for Wi-Fi.
  Future<void> _release(_Held held) async {
    final task = held.task;
    _emit(ModelDownloadUpdate(id: task.taskId, state: ModelDownloadState.queued));
    if (held.resume) return _resume(task);
    if (!await _files.enqueue(task)) {
      _emit(
        ModelDownloadUpdate(
          id: task.taskId,
          state: ModelDownloadState.failed,
          error: const DownloadError(DownloadErrorCode.cannotStart),
        ),
      );
    }
  }

  void _onProgress(TaskProgressUpdate update) {
    // Negative values and 1.0 mirror status changes, which arrive as status updates.
    if (update.progress < 0 || update.progress >= 1) return;
    final task = update.task;
    final id = task.taskId;
    if (task is DownloadTask) _tasks.putIfAbsent(id, () => task);
    // Progress: data handed back for a resume was usable.
    _resumedFrom.remove(id);
    // A download found running after a relaunch sends progress, not a new running status.
    if (task.requiresWiFi && _wifiWatch == null && _guardsWifi) _watchWifi();
    _inOrder(
      id,
      () => _emit(
        ModelDownloadUpdate(
          id: id,
          state: ModelDownloadState.running,
          progress: update.progress,
          expectedBytes: update.hasExpectedFileSize && update.expectedFileSize > 0 ? update.expectedFileSize : null,
          // background_downloader measures MB/s.
          bytesPerSecond: update.hasNetworkSpeed ? update.networkSpeed * 1e6 : null,
          timeRemaining: update.hasTimeRemaining ? update.timeRemaining : null,
        ),
      ),
    );
  }

  void _emit(ModelDownloadUpdate update) {
    _lastState[update.id] = update.state;
    if (!_controller.isClosed) _controller.add(update);
  }

  /// Why a task failed, as a code: the status and exception background_downloader reports.
  static DownloadError errorFor(TaskStatus status, TaskException? exception) {
    if (status == TaskStatus.notFound) return const DownloadError(DownloadErrorCode.notFound, httpStatus: 404);
    return switch (exception) {
      TaskHttpException(:final httpResponseCode, :final description) => DownloadError(
        DownloadErrorCode.httpStatus,
        httpStatus: httpResponseCode,
        detail: description,
      ),
      TaskConnectionException(:final description) => DownloadError(DownloadErrorCode.connection, detail: description),
      TaskFileSystemException(:final description) when description.toLowerCase().contains('space') => DownloadError(
        DownloadErrorCode.diskFull,
        detail: description,
      ),
      TaskFileSystemException(:final description) => DownloadError(DownloadErrorCode.fileSystem, detail: description),
      TaskResumeException(:final description) => DownloadError(DownloadErrorCode.cannotResume, detail: description),
      null => const DownloadError(DownloadErrorCode.unknown),
      _ => DownloadError(DownloadErrorCode.unknown, detail: exception.description),
    };
  }
}

/// A Wi-Fi-only task held back off Wi-Fi: [resume] when it has data to continue from (paused, or kept after a
/// failure), else it starts from the first byte.
final class _Held {
  const _Held(this.task, {required this.resume});

  final DownloadTask task;
  final bool resume;
}
