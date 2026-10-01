/// background_downloader's storage, keeping the resume data of failed model downloads across launches.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// background_downloader's own store (LocalStore), which also keeps a copy of the resume data of the tasks of the
/// groups it [retain]s. background_downloader drops a task's resume data when the task ends (a final state, a failure
/// included) or when all of it is removed; this storage first copies it to `<directory>/<taskId>.json`, so a failed
/// model download can still resume, also after a relaunch. [retained] reads a copy, [dropRetained]
/// deletes it, [restoreResumeData] hands it back to background_downloader for `FileDownloader().resume(task)`.
///
/// It works only as FileDownloader's storage, which can be given on the very first `FileDownloader()` call alone:
/// [install] (LocalInferenceFlutter.installDownloaderStorage) makes that call, or a host that creates FileDownloader
/// itself passes a RetainingResumeStorage to it. It extends the concrete store, so methods that later 9.x versions
/// add are inherited.
class RetainingResumeStorage extends LocalStorePersistentStorage {
  RetainingResumeStorage();

  static RetainingResumeStorage? _installed;

  /// The storage FileDownloader adopted: the one [install] gave it, or one the host passed to its own first
  /// FileDownloader call; null otherwise (retention is off).
  static RetainingResumeStorage? get installed => _installed;

  /// Creates background_downloader's FileDownloader with a new RetainingResumeStorage, which must be the app's first
  /// FileDownloader call; true when FileDownloader adopted it (its initialize ran), also when it had adopted one
  /// before (an earlier call, or the host's own FileDownloader call). False when FileDownloader existed already with
  /// another storage: retention stays off. On platforms other than iOS and Android it does nothing and answers false:
  /// models download in the foreground there. [create] replaces the FileDownloader call and [storage] the new storage
  /// (tests).
  static Future<bool> install({
    @visibleForTesting FileDownloader Function(PersistentStorage storage)? create,
    @visibleForTesting RetainingResumeStorage? storage,
  }) async {
    if (_installed != null) return true;
    final mobile = defaultTargetPlatform == TargetPlatform.iOS || defaultTargetPlatform == TargetPlatform.android;
    if (create == null && !mobile) return false;
    storage ??= RetainingResumeStorage();
    try {
      (create ?? (store) => FileDownloader(persistentStorage: store))(storage);
    } on AssertionError {
      // Debug builds assert when FileDownloader existed already; release builds ignore the storage.
    }
    // FileDownloader initializes its storage while it is created; allow one turn in case that is deferred.
    if (!storage.adopted) await Future<void>.delayed(Duration.zero);
    if (!storage.adopted) return false;
    _installed = storage;
    return true;
  }

  /// Forgets the [installed] storage.
  @visibleForTesting
  static void resetInstalled() => _installed = null;

  final _directories = <String, String>{};

  /// What each directory's copies are handed to once written (see [retain]).
  final _written = <String, Future<void> Function(String path)>{};

  /// Resume data dropped before its group was [retain]ed (right after launch, before the downloader is set up), kept
  /// in memory until then.
  final _unclaimed = <String, ResumeData>{};
  var _adopted = false;
  Future<void> _queue = Future.value();

  /// Whether background_downloader adopted this storage: it called [initialize], which it does for the storage of
  /// FileDownloader alone.
  bool get adopted => _adopted;

  /// Keeps the resume data of [group]'s tasks in [directory] (a folder of its own) when background_downloader drops
  /// it, also what it dropped since launch, before this call. [onWritten] gets each copy's path once it is written
  /// (the downloader keeps it out of iCloud backup: without the system's temporary file it names, a restored copy
  /// could not resume).
  void retain({required String group, required String directory, Future<void> Function(String path)? onWritten}) {
    _directories[group] = directory;
    if (onWritten != null) _written[directory] = onWritten;
    final claimed = [
      for (final data in _unclaimed.values)
        if (data.task.group == group) data,
    ];
    if (claimed.isEmpty) return;
    for (final data in claimed) {
      _unclaimed.remove(data.taskId);
    }
    unawaited(
      _serial(() async {
        for (final data in claimed) {
          await _write(directory, data);
        }
      }).catchError((Object _) {}),
    );
  }

  /// FileDownloader calls it for its own storage alone, so this storage is the app's ([installed]).
  @override
  Future<void> initialize() {
    _adopted = true;
    _installed ??= this;
    return initializeStore();
  }

  /// LocalStore's own initialization.
  @protected
  @visibleForTesting
  Future<void> initializeStore() => super.initialize();

  /// Copies the resume data of the retained groups' tasks (the task [taskId], or all when null), then removes it
  /// from background_downloader's store.
  @override
  Future<void> removeResumeData(String? taskId) => _serial(() async {
    try {
      await _retain(taskId);
    } catch (_) {
      // Best effort: without the copy, a retry starts again.
    }
    await removeStoredResumeData(taskId);
  });

  /// LocalStore's own removal.
  @protected
  @visibleForTesting
  Future<void> removeStoredResumeData(String? taskId) => super.removeResumeData(taskId);

  /// The resume data kept for [taskId], or null; read after any copy under way.
  Future<ResumeData?> retained(String taskId) => _serial(() async {
    for (final directory in _directories.values.toSet()) {
      final kept = await _read(File(_path(directory, taskId)));
      if (kept != null) return kept;
    }
    return null;
  });

  /// Every copy kept for the retained groups.
  Future<List<ResumeData>> allRetained() => _serial(() async {
    final all = <ResumeData>[];
    for (final directory in _directories.values.toSet()) {
      final folder = Directory(directory);
      if (!await folder.exists()) continue;
      await for (final entity in folder.list()) {
        if (entity is! File || !entity.path.endsWith('.json')) continue;
        final kept = await _read(entity);
        if (kept != null) all.add(kept);
      }
    }
    return all;
  });

  /// Deletes the copy kept for [taskId], after any copy under way.
  Future<void> dropRetained(String taskId) => _serial(() async {
    _unclaimed.remove(taskId);
    for (final directory in _directories.values.toSet()) {
      try {
        await File(_path(directory, taskId)).delete();
      } on FileSystemException {
        continue;
      }
    }
  });

  /// Stores [data] as background_downloader's resume data again, after any removal under way, so that
  /// `FileDownloader().resume(task)` continues from it.
  Future<void> restoreResumeData(ResumeData data) => _serial(() => storeResumeData(data));

  Future<void> _retain(String? taskId) async {
    final data = taskId == null ? await retrieveAllResumeData() : [?await retrieveResumeData(taskId)];
    for (final resume in data) {
      final directory = _directories[resume.task.group];
      if (directory == null) {
        _unclaimed[resume.taskId] = resume;
      } else {
        await _write(directory, resume);
      }
    }
  }

  Future<void> _write(String directory, ResumeData resume) async {
    final file = File(_path(directory, resume.taskId));
    await file.parent.create(recursive: true);
    // A temporary file, then a rename: a crash never leaves half a copy.
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode(resume.toJson()), flush: true);
    await tmp.rename(file.path);
    try {
      await _written[directory]?.call(file.path);
    } catch (_) {
      // Best effort: the copy is written.
    }
  }

  static Future<ResumeData?> _read(File file) async {
    try {
      return ResumeData.fromJson(jsonDecode(await file.readAsString()) as Map<String, dynamic>);
    } catch (_) {
      // Missing, or not a copy this storage wrote.
      return null;
    }
  }

  static String _path(String directory, String taskId) =>
      p.join(directory, '${taskId.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')}.json');

  /// Runs [operation] after the ones before it: a copy completes before the copy is read, dropped or replaced.
  Future<T> _serial<T>(Future<T> Function() operation) {
    final result = _queue.then((_) => operation());
    _queue = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }
}
