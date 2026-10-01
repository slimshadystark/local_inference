// The parts of background_downloader's FileDownloader that BackgroundModelDownloader uses, driven by the test. The
// signatures are those of 9.5.9 and 9.6.x alike; isConnected and isWiFi (9.6 only) answer through noSuchMethod.
import 'package:background_downloader/background_downloader.dart';

class FakeFiles implements FileDownloader {
  /// [tracksConnection] false: a FileDownloader without isConnected and isWiFi, as in 9.5.9.
  FakeFiles({this.tracksConnection = true});

  final bool tracksConnection;
  TaskStatusCallback? status;
  TaskProgressCallback? progress;
  final enqueued = <Task>[];
  final resumed = <Task>[];
  final paused = <Task>[];
  final canceled = <String>[];
  final notifications = <String, TaskNotification?>{};
  bool? progressBar;
  Object? globalConfig;
  Object? androidConfig;
  Object? iOSConfig;

  /// What [enqueue], [resume] and [pause] answer; [onResume], when set, answers [resume] instead (background_downloader
  /// resumes only a task whose resume data it holds).
  bool enqueueResult = true;
  bool resumeResult = true;
  bool pauseResult = true;
  Future<bool> Function(DownloadTask task)? onResume;

  /// What isConnected and isWiFi answer.
  bool connected = true;
  bool wifi = true;

  /// The tasks background_downloader holds (running, enqueued or paused): [allTasks] and [taskForId] answer from it.
  final active = <Task>[];

  /// Runs at each [allTasks], as iOS reports what it did while the app was closed once the session exists.
  void Function()? onAllTasks;

  /// The records of the tracked group, for [database].
  final records = <TaskRecord>[];
  var tracked = 0;

  /// The markDownloadedComplete of each [trackTasksInGroup] call.
  final trackedMarkingComplete = <bool>[];
  var resumedFromBackground = 0;
  var rescheduled = 0;

  @override
  FileDownloader registerCallbacks({
    String group = FileDownloader.defaultGroup,
    TaskStatusCallback? taskStatusCallback,
    TaskProgressCallback? taskProgressCallback,
    TaskNotificationTapCallback? taskNotificationTapCallback,
  }) {
    status = taskStatusCallback;
    progress = taskProgressCallback;
    return this;
  }

  @override
  FileDownloader configureNotificationForGroup(
    String group, {
    TaskNotification? running,
    TaskNotification? complete,
    TaskNotification? error,
    TaskNotification? paused,
    TaskNotification? canceled,
    bool progressBar = false,
    bool tapOpensFile = false,
    String groupNotificationId = '',
  }) {
    notifications
      ..['running'] = running
      ..['paused'] = paused
      ..['complete'] = complete
      ..['error'] = error;
    this.progressBar = progressBar;
    return this;
  }

  @override
  Future<List<(String, String)>> configure({
    dynamic globalConfig,
    dynamic androidConfig,
    dynamic iOSConfig,
    dynamic desktopConfig,
  }) async {
    this.globalConfig = globalConfig;
    this.androidConfig = androidConfig;
    this.iOSConfig = iOSConfig;
    return const [];
  }

  @override
  Future<bool> enqueue(Task task) async {
    enqueued.add(task);
    return enqueueResult;
  }

  @override
  Future<bool> resume(DownloadTask task) async {
    resumed.add(task);
    return await onResume?.call(task) ?? resumeResult;
  }

  @override
  Future<bool> pause(DownloadTask task) async {
    paused.add(task);
    return pauseResult;
  }

  @override
  Future<bool> cancelTaskWithId(String taskId) async {
    canceled.add(taskId);
    return true;
  }

  @override
  Future<Task?> taskForId(String taskId) async => active.where((task) => task.taskId == taskId).firstOrNull;

  @override
  Future<List<Task>> allTasks({
    String group = FileDownloader.defaultGroup,
    bool includeTasksWaitingToRetry = true,
    bool allGroups = false,
  }) async {
    onAllTasks?.call();
    return [
      for (final task in active)
        if (allGroups || task.group == group) task,
    ];
  }

  @override
  Future<FileDownloader> trackTasksInGroup(String group, {bool markDownloadedComplete = true}) async {
    tracked++;
    trackedMarkingComplete.add(markDownloadedComplete);
    return this;
  }

  @override
  Future<void> resumeFromBackground() async => resumedFromBackground++;

  @override
  Future<(List<Task>, List<Task>)> rescheduleKilledTasks() async {
    rescheduled++;
    return (<Task>[], <Task>[]);
  }

  @override
  Database get database => _FakeDatabase(records);

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (tracksConnection && invocation.isGetter && invocation.memberName == #isConnected) return connected;
    if (tracksConnection && invocation.isGetter && invocation.memberName == #isWiFi) return wifi;
    return super.noSuchMethod(invocation);
  }
}

class _FakeDatabase implements Database {
  _FakeDatabase(this.records);

  final List<TaskRecord> records;

  @override
  Future<TaskRecord?> recordForId(String taskId) async => records.where((r) => r.taskId == taskId).firstOrNull;

  @override
  Future<List<TaskRecord>> allRecords({String? group}) async => [
    for (final record in records)
      if (group == null || record.group == group) record,
  ];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
