/// Which models the phone can use, which are on disk, and the download of the missing ones.
///
/// A model counts as installed only after the downloaded file had the manifest's exact size and SHA-256
/// and was renamed from `<name>.part` to its final name. A GGUF entry's file must first start with the GGUF
/// header, so a web page served in its place is never hashed. The result is kept in `<root>/models/index.json`
/// with the file's size and modification time, so later launches trust the file without hashing 3 GB
/// again; a file whose size changed is deleted, one whose time changed is hashed again.
///
/// A download that failed keeps its partial data where the downloader can ([ModelDownloader.canResume]): trying
/// again resumes it, also after a relaunch, while the network rule it started with still holds (Wi-Fi only, or
/// mobile data the user agreed to; kept in `<root>/models/downloads.json`). Otherwise its data is discarded and the
/// download starts again under the current rule; mobile data the user agreed to for it stays allowed.
///
/// Files live under the root the host gives (Application Support on iOS, not Documents, which Finder file
/// sharing and backups see), in `models/<id>/`, excluded from iCloud backup.
///
/// The manifest comes from its hosting when it answers in time, otherwise from the copy in the app.
/// Before the first download the remote list is awaited (a few seconds at most); once a model is
/// installed the app starts on the bundled copy and swaps in the remote one when it arrives, unless a
/// download is under way. Only the remote list is trusted to say which leftover files and folders belong
/// to no model: the bundled copy may predate a newer model.
///
/// Pure Dart: [DeviceProbe] and [ModelDownloader] do the platform work, so tests drive it with fakes. It reports
/// codes and numbers, never sentences: local_inference_flutter's `ModelSetupStrings` and `LocalizedFormats` say them.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import '../util/change_source.dart';
import 'catalog.dart';
import 'device.dart';
import 'downloader.dart';
import 'http_downloader.dart';
import 'manifest.dart';
import 'manifest_fetch.dart';

/// Where a model is between not downloaded and ready (see [ModelStatus]).
enum ModelState { notDownloaded, queued, downloading, paused, waitingForWifi, verifying, ready, failed }

/// Why a download or its check failed.
enum ModelErrorCode {
  /// The file had another size or SHA-256 than the manifest's; it was deleted.
  integrity,

  /// The file is not a model at all: a GGUF entry's file without the GGUF header (a web page, for one), checked
  /// before its size and SHA-256; it was deleted. Also a downloader's [DownloadError.notAGgufFile].
  notAModelFile,

  /// The downloaded file was not where the downloader put it.
  fileMissing,

  /// The file could not be read or its SHA-256 computed; the file stays for the next attempt.
  cannotVerify,

  /// The checked file could not be renamed or recorded.
  cannotSave,

  /// The downloader did not start the download.
  cannotStart,

  /// The downloader could not continue a paused download.
  cannotResume,

  /// The download itself failed: [ModelError.download] says why.
  download,
}

/// Why a download or its check failed: a [code], with the downloader's reason for [ModelErrorCode.download] (and for
/// [ModelErrorCode.notAModelFile] when the downloader found it) and a technical [detail] where there is one.
@immutable
final class ModelError {
  const ModelError(this.code, {this.download, this.detail});

  final ModelErrorCode code;

  /// The downloader's reason, for [ModelErrorCode.download]; null when it gave none.
  final DownloadError? download;

  /// What the check found or the underlying error's text, for technical details; never shown as the reason.
  final String? detail;

  @override
  bool operator ==(Object other) =>
      other is ModelError && other.code == code && other.download == download && other.detail == detail;

  @override
  int get hashCode => Object.hash(code, download, detail);

  @override
  String toString() =>
      'ModelError(${code.name}${download == null ? '' : ', $download'}${detail == null ? '' : ': $detail'})';
}

/// Why a model should not be downloaded (or used) on this phone; [ModelManager.problemFor] checks them in the order
/// of the subclasses below.
@immutable
sealed class ModelProblem {
  const ModelProblem();
}

/// The manifest no longer offers the model and it is not installed.
final class NotOffered extends ModelProblem {
  const NotOffered();

  @override
  bool operator ==(Object other) => other is NotOffered;

  @override
  int get hashCode => (NotOffered).hashCode;

  @override
  String toString() => 'NotOffered()';
}

/// The phone has less RAM than the model needs.
final class NotEnoughRam extends ModelProblem {
  const NotEnoughRam(this.requiredMB);

  /// The manifest's `minPhysicalRamMB`.
  final int requiredMB;

  @override
  bool operator ==(Object other) => other is NotEnoughRam && other.requiredMB == requiredMB;

  @override
  int get hashCode => Object.hash(NotEnoughRam, requiredMB);

  @override
  String toString() => 'NotEnoughRam($requiredMB MB)';
}

/// Less memory is available to the app than the model needs.
final class NotEnoughMemory extends ModelProblem {
  const NotEnoughMemory(this.requiredMB, this.availableMB);

  /// The manifest's `minAvailableMemoryMB`.
  final int requiredMB;
  final int availableMB;

  @override
  bool operator ==(Object other) =>
      other is NotEnoughMemory && other.requiredMB == requiredMB && other.availableMB == availableMB;

  @override
  int get hashCode => Object.hash(NotEnoughMemory, requiredMB, availableMB);

  @override
  String toString() => 'NotEnoughMemory($requiredMB MB, available $availableMB MB)';
}

/// Less free space than the download needs.
final class NotEnoughDisk extends ModelProblem {
  const NotEnoughDisk(this.requiredMB, this.availableMB);

  /// The manifest's `minFreeDiskMB`.
  final int requiredMB;
  final int availableMB;

  @override
  bool operator ==(Object other) =>
      other is NotEnoughDisk && other.requiredMB == requiredMB && other.availableMB == availableMB;

  @override
  int get hashCode => Object.hash(NotEnoughDisk, requiredMB, availableMB);

  @override
  String toString() => 'NotEnoughDisk($requiredMB MB, available $availableMB MB)';
}

/// The host's `preflight` refused the model; [reason] is shown as it is.
final class HostRefused extends ModelProblem {
  const HostRefused(this.reason);

  final String reason;

  @override
  bool operator ==(Object other) => other is HostRefused && other.reason == reason;

  @override
  int get hashCode => Object.hash(HostRefused, reason);

  @override
  String toString() => 'HostRefused($reason)';
}

/// A model's state with its numbers (progress, bytes, speed, time left) and, when it failed, why ([error] or
/// [problem]).
@immutable
final class ModelStatus {
  const ModelStatus({
    required this.state,
    this.progress = 0,
    this.bytesDone = 0,
    this.bytesTotal = 0,
    this.bytesPerSecond,
    this.timeRemaining,
    this.error,
    this.problem,
    this.waitingForNetwork = false,
  });

  static const notDownloaded = ModelStatus(state: ModelState.notDownloaded);

  final ModelState state;

  /// 0..1.
  final double progress;
  final int bytesDone;
  final int bytesTotal;

  /// The download's speed, when known.
  final double? bytesPerSecond;

  /// The time the download still needs, when known.
  final Duration? timeRemaining;

  /// Why [ModelState.failed], when the download or its check failed.
  final ModelError? error;

  /// Why [ModelState.failed], when the model was refused before any download ([ModelManager.problemFor]).
  final ModelProblem? problem;

  /// [ModelState.queued] with no connection at all, so neither Wi-Fi nor mobile data would help: the
  /// download starts when the phone is back online.
  final bool waitingForNetwork;

  /// A download is queued, running, paused, waiting or being checked.
  bool get isActive => const {
    ModelState.queued,
    ModelState.downloading,
    ModelState.paused,
    ModelState.waitingForWifi,
    ModelState.verifying,
  }.contains(state);

  @override
  bool operator ==(Object other) =>
      other is ModelStatus &&
      other.state == state &&
      other.progress == progress &&
      other.bytesDone == bytesDone &&
      other.bytesTotal == bytesTotal &&
      other.bytesPerSecond == bytesPerSecond &&
      other.timeRemaining == timeRemaining &&
      other.error == error &&
      other.problem == problem &&
      other.waitingForNetwork == waitingForNetwork;

  @override
  int get hashCode => Object.hash(
    state,
    progress,
    bytesDone,
    bytesTotal,
    bytesPerSecond,
    timeRemaining,
    error,
    problem,
    waitingForNetwork,
  );

  @override
  String toString() =>
      'ModelStatus(${state.name}${waitingForNetwork ? ' offline' : ''}, '
      '${(progress * 100).round()}%${(error ?? problem) == null ? '' : ', ${error ?? problem}'})';
}

/// A verified model on disk: the entry it was checked against, its file, size and SHA-256.
final class InstalledModel {
  const InstalledModel({required this.entry, required this.path, required this.sizeBytes, required this.sha256});
  final ModelEntry entry;
  final String path;
  final int sizeBytes;

  /// The SHA-256 the file had when it was checked (lowercase hex).
  final String sha256;
}

/// Why [ModelManager.install] did not end with the model ready: [error] or [problem], or neither when the download
/// was cancelled.
final class ModelInstallException implements Exception {
  const ModelInstallException(this.error, {required this.id, this.problem});

  final String id;
  final ModelError? error;
  final ModelProblem? problem;

  /// The download was cancelled (or the model deleted) before it was ready.
  bool get canceled => error == null && problem == null;

  @override
  String toString() => 'ModelInstallException($id: ${error ?? problem ?? 'canceled'})';
}

/// Which models this device can use, which are on disk, and the download of the missing ones (see the library
/// comment). Call [init] once at launch; listeners are told of every change.
final class ModelManager implements ChangeSource {
  /// [root] must return the absolute folder the models live under (`<root>/models/<id>/`). [preflight] is the
  /// host's own rule, asked last by [problemFor]. [settingsPath] defaults to `<root>/models/settings.json`.
  ModelManager({
    required Future<String> Function() root,
    required this.probe,
    required this.downloader,
    required this.catalog,
    ModelProblem? Function(ModelEntry entry, DeviceCapabilities device)? preflight,
    Future<String> Function()? settingsPath,
    DateTime Function()? now,
  }) : _modelsRoot = root,
       _preflight = preflight,
       _settingsPath = settingsPath,
       _now = now ?? DateTime.now;

  /// A manager for the folder [root] (CLI, desktop, server, tests): downloads run in the foreground on
  /// [HttpModelDownloader] and the probe is [DartDeviceProbe], unless given. [dispose] closes the downloader it
  /// created.
  factory ModelManager.forDirectory(
    String root, {
    required ModelCatalog catalog,
    ModelDownloader? downloader,
    DeviceProbe? probe,
  }) => ModelManager(
    root: () async => root,
    probe: probe ?? const DartDeviceProbe(),
    downloader: downloader ?? HttpModelDownloader(),
    catalog: catalog,
  ).._ownsDownloader = downloader == null;

  /// Memory, disk, hashing and the backup flag.
  final DeviceProbe probe;

  /// Runs the downloads.
  final ModelDownloader downloader;

  /// Where the manifest comes from.
  final ModelCatalog catalog;
  final Future<String> Function() _modelsRoot;
  final ModelProblem? Function(ModelEntry entry, DeviceCapabilities device)? _preflight;
  final Future<String> Function()? _settingsPath;
  final DateTime Function() _now;
  final _listeners = ChangeListeners();
  final _watchers = <StreamController<ModelStatus>>{};
  bool _ownsDownloader = false;

  late String _root;
  late String _settingsFile;
  late String _downloadsFile;
  ModelManifest? _manifest;
  CatalogOrigin _origin = CatalogOrigin.bundled;
  Object? _catalogError;
  DeviceCapabilities _capabilities = DeviceCapabilities.unknown;
  bool _wifiOnly = true;
  Future<void>? _init;
  bool _ready = false;
  bool _disposed = false;
  Object? _loadError;
  StreamSubscription<ModelDownloadUpdate>? _subscription;

  final _index = <String, _IndexRecord>{};
  final _status = <String, ModelStatus>{};
  final _verifying = <String>{};

  /// The [download] calls still starting, by id: a second call waits for the first.
  final _starting = <String, Completer<void>>{};
  final _canceled = <String>{};
  final _cancelRequested = <String, DateTime>{};

  /// Whether each download started Wi-Fi only; kept in `downloads.json` until the model is ready, canceled or
  /// deleted, so the rule holds after a relaunch.
  final _startedWifiOnly = <String, bool>{};

  /// Downloads the user let run on mobile data while Wi-Fi only was on; kept with [_startedWifiOnly].
  final _cellularConsent = <String>{};

  /// Retries that resumed kept data, by id, with their `allowCellular`: if the kept data turns out unusable
  /// ([DownloadErrorCode.cannotResume] before any progress), the download starts again.
  final _retrying = <String, bool>{};
  final _restarts = <String, Completer<void>>{};

  /// Downloads that failed after [init], not the failures [ModelDownloader.restore] reported: a remote manifest that
  /// arrives meanwhile waits for the next launch ([_fetchRemote]).
  final _failedSinceInit = <String>{};

  /// Whether [init] has completed: the manifest, the index and the capabilities are read.
  bool get isReady => _ready;

  /// Why the last [init] failed (no manifest could be read), for the technical details; null once one succeeded.
  Object? get loadError => _loadError;

  /// The manifest in use; throws before [init] has completed.
  ModelManifest get manifest => _manifest ?? (throw StateError('ModelManager.init() has not completed'));

  /// Where [manifest] came from.
  CatalogOrigin get catalogOrigin => _origin;

  /// Why the remote manifest was not used, for the technical details: the error, or a short note.
  Object? get catalogError => _catalogError;

  /// The last reading of the device (see [refreshCapabilities]).
  DeviceCapabilities get capabilities => _capabilities;

  /// Every model of the manifest, in its order.
  List<ModelEntry> get entries => manifest.models;

  /// Active models this device's memory can run, best first ([ModelManifest.eligible]).
  List<ModelEntry> get eligible => manifest.eligible(_capabilities);

  /// The model to offer on this device ([ModelManifest.recommendedFor]).
  ModelEntry? get recommended => manifest.recommendedFor(_capabilities);

  /// Whether new downloads wait for Wi-Fi (the default; kept in the settings file).
  bool get wifiOnly => _wifiOnly;

  /// Verified models on disk, in manifest order; models no longer listed follow.
  List<InstalledModel> get installed {
    final ids = [
      for (final m in manifest.models)
        if (_index.containsKey(m.id)) m.id,
      for (final id in _index.keys)
        if (manifest.byId(id) == null) id,
    ];
    return [for (final id in ids) _installedModel(id)!];
  }

  /// The size of the verified models on disk.
  int get installedBytes => _index.values.fold(0, (sum, r) => sum + r.sizeBytes);

  /// `<root>/models`, which holds the index, the settings and a folder per model.
  String get modelsDirectory => p.join(_root, 'models');

  /// The folder of [id]'s files.
  String modelsDirectoryFor(String id) => p.join(_root, 'models', id);

  /// The verified file of [id], or null.
  String? pathOf(String id) => _index[id] == null ? null : _absolute(_index[id]!.path);

  /// The SHA-256 of the verified file of [id], or null.
  String? sha256Of(String id) => _index[id]?.sha256;

  /// The manifest's entry of [id], else the one an installed model was verified against.
  ModelEntry? entryFor(String id) => manifest.byId(id) ?? _index[id]?.entry;

  /// The status of [id]: its download or check (or how it failed), else ready when installed, else not downloaded.
  ModelStatus statusOf(String id) {
    final active = _status[id];
    if (active != null) return active;
    final record = _index[id];
    if (record != null) {
      return ModelStatus(
        state: ModelState.ready,
        progress: 1,
        bytesDone: record.sizeBytes,
        bytesTotal: record.sizeBytes,
      );
    }
    return ModelStatus.notDownloaded;
  }

  /// Why [entry] should not be downloaded (or used) on this phone; null when it can. The checks run in the order of
  /// [ModelProblem]'s subclasses: an installed model skips the disk check and the host's `preflight`.
  ModelProblem? problemFor(ModelEntry entry) {
    final device = _capabilities;
    if (!entry.isActive && !_index.containsKey(entry.id)) return const NotOffered();
    if (device.physicalMemoryMB != null && device.physicalMemoryMB! < entry.minPhysicalRamMB) {
      return NotEnoughRam(entry.minPhysicalRamMB);
    }
    if (device.availableMemoryMB != null && device.availableMemoryMB! < entry.minAvailableMemoryMB) {
      return NotEnoughMemory(entry.minAvailableMemoryMB, device.availableMemoryMB!);
    }
    if (_index.containsKey(entry.id)) return null;
    if (!entry.fitsDisk(device)) return NotEnoughDisk(entry.minFreeDiskMB, device.freeDiskMB!);
    return _preflight?.call(entry, device);
  }

  /// Reads the index and the manifest, reattaches to downloads and checks the files on disk. Concurrent calls share
  /// one attempt; after a failure the next call tries again.
  Future<void> init() => _init ??= _load().then<void>(
    (_) {},
    onError: (Object error, StackTrace stack) {
      _init = null;
      _loadError = error;
      _notify();
      Error.throwWithStackTrace(error, stack);
    },
  );

  Future<void> _load() async {
    _root = await _modelsRoot();
    await Directory(modelsDirectory).create(recursive: true);
    _settingsFile = await _settingsPath?.call() ?? p.join(modelsDirectory, 'settings.json');
    _downloadsFile = p.join(modelsDirectory, 'downloads.json');
    _loadSettings();
    _loadDownloads();
    _manifest = null;
    _origin = CatalogOrigin.bundled;
    _catalogError = null;
    _index.clear();
    final catalog = this.catalog;
    var deferRemote = false;
    switch (catalog) {
      case FixedCatalog(:final manifest):
        _manifest = manifest;
        _origin = CatalogOrigin.fixed;
        await _loadIndex();
      case BundledCatalog():
        // The bundled copy is the fallback; if it cannot be read (e.g. missing from the app's assets) the
        // remote one still lets the app work online.
        Object? bundledError;
        try {
          _manifest = ModelManifest.parse(await catalog.read());
        } catch (e) {
          bundledError = e;
        }
        // Index records carry the entry they were verified against, so the index does not need the manifest.
        await _loadIndex();
        final url = catalog.remote;
        deferRemote = _manifest != null && _index.isNotEmpty;
        if (url != null && !deferRemote) await _fetchRemote(catalog, url);
        if (_manifest == null) {
          throw StateError('no model manifest: bundled: $bundledError; remote: ${_catalogError ?? 'not configured'}');
        }
    }
    _capabilities = await _readCapabilities();
    await _subscription?.cancel();
    _subscription = downloader.updates.listen(_onUpdate);
    try {
      await downloader.restore(
        targets: [
          for (final entry in manifest.models)
            DownloadTarget(entry, directory: modelsDirectoryFor(entry.id), partFileName: entry.partFileName),
        ],
      );
    } catch (_) {
      // Nothing to reattach to; new downloads still work.
    }
    _ready = true;
    _loadError = null;
    _notify();
    _checkFilesOnDisk();
    if (catalog is BundledCatalog && catalog.remote != null && deferRemote) {
      unawaited(
        _fetchRemote(catalog, catalog.remote!, whenIdle: true).then((swapped) {
          if (!swapped) return;
          _checkFilesOnDisk();
          _notify();
        }),
      );
    }
  }

  /// Uses the manifest at [url] when it answers within the catalog's timeout; true when it replaced the current
  /// one. With [whenIdle] it is left for a later launch while a download starts, runs, is checked or
  /// failed in the downloader since launch (its partial data may resume), since that download was set up from the
  /// current entry. A failure reported at launch does not hold it back: it would do so at every launch.
  Future<bool> _fetchRemote(BundledCatalog catalog, Uri url, {bool whenIdle = false}) async {
    try {
      final body = await (catalog.fetch ?? fetchManifest)(url).timeout(catalog.timeout);
      if (body == null) {
        _catalogError = 'no answer';
        return false;
      }
      final remote = ModelManifest.parse(body);
      if (_disposed) return false;
      bool busy(String id, ModelStatus s) =>
          s.isActive ||
          s.state == ModelState.failed && s.error?.code == ModelErrorCode.download && _failedSinceInit.contains(id);
      if (whenIdle && (_starting.isNotEmpty || _status.entries.any((e) => busy(e.key, e.value)))) {
        _catalogError = 'arrived during a download: kept for the next launch';
        return false;
      }
      final before = _manifest;
      _manifest = remote;
      _origin = CatalogOrigin.remote;
      _catalogError = null;
      _dropStaleKeptData(before, remote);
      return true;
    } catch (e) {
      _catalogError = e;
      return false;
    }
  }

  /// After [remote] replaced [before]: the data kept for a failed download whose file the remote list changed (URL,
  /// size or SHA-256) or withdrew could only resume the old file, so it goes; a withdrawn model's failure and rule go
  /// with it.
  void _dropStaleKeptData(ModelManifest? before, ModelManifest remote) {
    for (final MapEntry(key: id, value: status) in [..._status.entries]) {
      if (status.state != ModelState.failed) continue;
      final now = remote.byId(id);
      final then = before?.byId(id);
      final sameFile =
          now != null &&
          then != null &&
          now.url == then.url &&
          now.sizeBytes == then.sizeBytes &&
          now.sha256 == then.sha256;
      if (sameFile) continue;
      unawaited(_discard(id));
      if (now == null && !_index.containsKey(id)) {
        _status.remove(id);
        _forgetRule(id);
      }
    }
  }

  /// Reads RAM and disk again (disk changes; call before showing the size check). Available memory keeps
  /// the highest reading of this run, since a model loaded in the chat lowers it.
  Future<void> refreshCapabilities() async {
    final fresh = await _readCapabilities();
    final before = _capabilities.availableMemoryMB;
    final after = fresh.availableMemoryMB;
    _capabilities = DeviceCapabilities(
      physicalMemoryMB: fresh.physicalMemoryMB ?? _capabilities.physicalMemoryMB,
      availableMemoryMB: before == null || (after != null && after > before) ? after : before,
      freeDiskMB: fresh.freeDiskMB,
    );
    _notify();
  }

  /// Sets [wifiOnly] for the downloads started from now on, and saves it.
  Future<void> setWifiOnly(bool value) async {
    if (_wifiOnly == value) return;
    _wifiOnly = value;
    _notify();
    await _writeJson(_settingsFile, {'wifiOnly': value});
  }

  /// Downloads [id] and completes with the verified model; one already installed completes at once. [onProgress]
  /// gets the status now (unless it is an earlier attempt's failure) and every change. Throws
  /// [ModelInstallException] when this attempt fails, the model is refused ([problemFor]) or the download is
  /// cancelled; a model that is not in the manifest throws [ArgumentError].
  Future<InstalledModel> install(
    String id, {
    void Function(ModelStatus status)? onProgress,
    bool allowCellular = false,
  }) async {
    await init();
    final ready = _installedModel(id);
    if (ready != null) return ready;
    if (manifest.byId(id) == null) throw ArgumentError.value(id, 'id', 'not in the manifest');
    final result = Completer<InstalledModel>();
    var started = false;
    void settle(ModelStatus status) {
      if (!started || result.isCompleted) return;
      switch (status.state) {
        case ModelState.ready:
          result.complete(_installedModel(id)!);
        case ModelState.failed:
          result.completeError(ModelInstallException(status.error, id: id, problem: status.problem));
        case ModelState.notDownloaded when !_starting.containsKey(id):
          result.completeError(ModelInstallException(null, id: id));
        default:
          break;
      }
    }

    var first = true;
    final subscription = watch(id).listen(
      (status) {
        final stale = first && status.state == ModelState.failed;
        first = false;
        if (stale) return;
        onProgress?.call(status);
        settle(status);
      },
      onDone: () {
        if (!result.isCompleted) result.completeError(StateError('ModelManager was disposed during install($id)'));
      },
    );
    try {
      await download(id, allowCellular: allowCellular);
      started = true;
      settle(statusOf(id));
      return await result.future;
    } finally {
      await subscription.cancel();
    }
  }

  /// The status of [id] now, then each time it changes; the stream closes when the manager is disposed.
  Stream<ModelStatus> watch(String id) {
    late final StreamController<ModelStatus> controller;
    ModelStatus? last;
    void push() {
      final status = statusOf(id);
      if (status == last) return;
      last = status;
      controller.add(status);
    }

    controller = StreamController<ModelStatus>(
      onListen: () {
        if (_disposed) {
          unawaited(controller.close());
          return;
        }
        push();
        _listeners.add(push);
        _watchers.add(controller);
      },
      onCancel: () {
        _listeners.remove(push);
        _watchers.remove(controller);
      },
    );
    return controller.stream;
  }

  /// Starts (or resumes) the download of [id]. With [allowCellular] a download waiting for Wi-Fi starts
  /// again on any network. A failed download resumes where it stopped, also after a relaunch, when the
  /// downloader kept its data ([ModelDownloader.canResume]) and the network rule it started with still holds;
  /// otherwise its data is discarded and it starts again, on mobile data if the user agreed to that for it.
  /// Refused downloads end in [ModelState.failed] with [problemFor]'s problem. A call while another is starting
  /// [id] completes with that one, its options unused.
  Future<void> download(String id, {bool allowCellular = false}) async {
    await init();
    final entry = manifest.byId(id);
    if (entry == null) throw ArgumentError.value(id, 'id', 'not in the manifest');
    final starting = _starting[id];
    if (starting != null) return starting.future;
    final done = _starting[id] = Completer<void>();
    try {
      await _start(entry, allowCellular: allowCellular);
    } finally {
      _starting.remove(id);
      done.complete();
    }
  }

  Future<void> _start(ModelEntry entry, {required bool allowCellular}) async {
    final id = entry.id;
    final state = statusOf(id).state;
    switch (state) {
      case ModelState.ready || ModelState.verifying || ModelState.downloading:
        return;
      case ModelState.paused:
        return await resume(id);
      case ModelState.queued || ModelState.waitingForWifi:
        if (!allowCellular || _startedWifiOnly[id] == false) return;
        await _cancelForRestart(id);
        return _startFresh(entry, allowCellular: allowCellular);
      case ModelState.notDownloaded || ModelState.failed:
        break;
    }
    if (await _checkCompletePart(entry)) return;
    if (state == ModelState.failed) {
      // A download the user let run on mobile data keeps that consent when it is tried again.
      final cellular = allowCellular || _startedWifiOnly[id] == false && _cellularConsent.contains(id);
      // The partial data the downloader kept, in this process or an earlier one, resumes under the rule the
      // download started with; otherwise it goes.
      if (await _canResume(id) && _networkRuleHolds(id, allowCellular: allowCellular)) {
        return _resumeKept(entry, allowCellular: cellular);
      }
      await _discard(id);
      return _startFresh(entry, allowCellular: cellular, partChecked: true);
    }
    await _startFresh(entry, allowCellular: allowCellular, partChecked: true);
  }

  /// A complete part file left by an earlier attempt (e.g. the check could not run) is checked instead of
  /// downloading gigabytes again. True when that settled the download: the model is ready, or the file stays for
  /// the next attempt.
  Future<bool> _checkCompletePart(ModelEntry entry) async {
    final part = File(_partPath(entry));
    if (!await part.exists() || await part.length() != entry.sizeBytes) return false;
    _canceled.remove(entry.id);
    await _verify(entry, part.path);
    return _index.containsKey(entry.id) || await part.exists();
  }

  /// Starts [entry] from the first byte under the current Wi-Fi rule, which is kept for a later retry.
  Future<void> _startFresh(ModelEntry entry, {required bool allowCellular, bool partChecked = false}) async {
    final id = entry.id;
    if (!partChecked && await _checkCompletePart(entry)) return;
    // A part file of another size is useless.
    await _deleteQuietly(File(_partPath(entry)));
    await refreshCapabilities();
    final problem = problemFor(entry);
    if (problem != null) return _fail(id, problem: problem);
    _canceled.remove(id);
    _retrying.remove(id);
    final wifiOnly = _wifiOnly && !allowCellular;
    _startedWifiOnly[id] = wifiOnly;
    if (_wifiOnly && allowCellular) {
      _cellularConsent.add(id);
    } else {
      _cellularConsent.remove(id);
    }
    _saveRules();
    await Directory(modelsDirectoryFor(id)).create(recursive: true);
    _setStatus(id, ModelStatus(state: ModelState.queued, bytesTotal: entry.sizeBytes));
    try {
      await downloader.start(
        entry,
        directory: modelsDirectoryFor(id),
        partFileName: entry.partFileName,
        wifiOnly: wifiOnly,
      );
    } catch (e) {
      _fail(id, error: ModelError(ModelErrorCode.cannotStart, detail: '$e'));
    }
  }

  /// Resumes the data the downloader kept for [entry]. If the downloader cannot, or reports the data unusable
  /// ([DownloadErrorCode.cannotResume] before any progress, see [_onUpdate]), the download starts again.
  Future<void> _resumeKept(ModelEntry entry, {required bool allowCellular}) async {
    final id = entry.id;
    await refreshCapabilities();
    final problem = problemFor(entry);
    if (problem != null) return _fail(id, problem: problem);
    _canceled.remove(id);
    _setStatus(id, ModelStatus(state: ModelState.queued, bytesTotal: entry.sizeBytes));
    _retrying[id] = allowCellular;
    try {
      await downloader.resume(id);
    } catch (_) {
      _retrying.remove(id);
      await _discard(id);
      await _startFresh(entry, allowCellular: allowCellular);
    }
  }

  /// The kept data of [entry] could not be resumed after all: it goes, and the download starts again.
  Future<void> _restartAfterFailedResume(ModelEntry entry, {required bool allowCellular}) async {
    final id = entry.id;
    if (_disposed) return;
    final done = _starting[id] = Completer<void>();
    try {
      await _discard(id);
      if (_canceled.contains(id) || _index.containsKey(id)) return;
      await _startFresh(entry, allowCellular: allowCellular);
    } finally {
      _starting.remove(id);
      done.complete();
    }
  }

  Future<bool> _canResume(String id) async {
    try {
      return await downloader.canResume(id);
    } catch (_) {
      return false;
    }
  }

  Future<void> _discard(String id) async {
    try {
      await downloader.discard(id);
    } catch (_) {
      // Best effort: a later start deletes the part file; the downloader sweeps its own leftovers.
    }
  }

  /// Pauses a running download. A queued one has no data to resume from yet (iOS would fail it), so
  /// it can only be cancelled.
  Future<void> pause(String id) async {
    if (statusOf(id).state == ModelState.downloading) await downloader.pause(id);
  }

  /// Resumes a paused download; a failed or missing one goes through [download] (which resumes kept data when it
  /// can). A paused download the downloader cannot resume fails with [ModelErrorCode.cannotResume].
  Future<void> resume(String id) async {
    final status = statusOf(id);
    switch (status.state) {
      case ModelState.notDownloaded || ModelState.failed:
        if (!_starting.containsKey(id)) return download(id);
      case ModelState.paused:
        _canceled.remove(id);
        _setStatus(id, _copy(status, state: ModelState.queued));
        try {
          await downloader.resume(id);
        } catch (e) {
          _fail(id, error: ModelError(ModelErrorCode.cannotResume, detail: '$e'));
        }
      default:
        return;
    }
  }

  /// Stops the download of [id] and deletes its partial data (a failed download's kept data too); a check under way
  /// is left to finish.
  Future<void> cancel(String id) async {
    final status = _status[id];
    if (status == null || status.state == ModelState.verifying) return;
    _canceled.add(id);
    _retrying.remove(id);
    _status.remove(id);
    _notify();
    if (status.state == ModelState.failed) {
      await _discard(id);
    } else {
      _cancelRequested[id] = _now();
      try {
        await downloader.cancel(id);
      } catch (_) {
        // Already gone on the native side.
      }
    }
    final entry = entryFor(id);
    if (entry != null) await _deleteQuietly(File(_partPath(entry)));
    _forgetRule(id);
  }

  /// Removes the model's files and its index entry, cancelling a download in progress.
  Future<void> delete(String id) async {
    if (_status[id]?.state == ModelState.verifying) return;
    if (_status.containsKey(id)) await cancel(id);
    _forgetRule(id);
    final record = _index.remove(id);
    if (record != null) {
      await _deleteQuietly(File(_absolute(record.path)));
      await _writeIndex();
    }
    final dir = Directory(modelsDirectoryFor(id));
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } on FileSystemException {
      // Best effort: whatever is left is not referenced by the index.
    }
    _status.remove(id);
    _notify();
  }

  @override
  void addListener(void Function() listener) => _listeners.add(listener);

  @override
  void removeListener(void Function() listener) => _listeners.remove(listener);

  /// Stops listening to the downloader, drops the listeners and closes the [watch] streams; closes the downloader
  /// only when [ModelManager.forDirectory] created it. Downloads keep running in a background downloader.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _listeners.clear();
    for (final watcher in List.of(_watchers)) {
      unawaited(watcher.close());
    }
    _watchers.clear();
    await _subscription?.cancel();
    final downloader = this.downloader;
    if (_ownsDownloader && downloader is HttpModelDownloader) await downloader.close();
  }

  /// Verification and file checks can finish after [dispose].
  void _notify() {
    if (!_disposed) _listeners.notify();
  }

  void _onUpdate(ModelDownloadUpdate update) {
    final id = update.id;
    final entry = manifest.byId(id);
    if (entry == null) {
      // A model withdrawn from the remote list: gigabytes nobody could install, in a download, in the data kept for
      // a retry nobody can make, and a rule nobody needs.
      const inFlight = {
        ModelDownloadState.queued,
        ModelDownloadState.running,
        ModelDownloadState.paused,
        ModelDownloadState.waitingForWifi,
        ModelDownloadState.waitingForNetwork,
      };
      if (_origin == CatalogOrigin.remote && !_index.containsKey(id)) {
        if (inFlight.contains(update.state) && !_cancelRequested.containsKey(id)) {
          _cancelRequested[id] = _now();
          unawaited(downloader.cancel(id).catchError((Object _) {}));
        }
        if (update.state == ModelDownloadState.failed) unawaited(_discard(id));
        _forgetRule(id);
      }
      return;
    }
    if (_verifying.contains(id)) return;
    if (_index.containsKey(id)) {
      // A second download that completed after the model was installed (e.g. a task rescheduled at
      // launch) leaves gigabytes nobody refers to; so does one that failed with its data kept.
      if (update.state == ModelDownloadState.complete) unawaited(_deleteQuietly(File(_partPath(entry))));
      if (update.state == ModelDownloadState.failed) unawaited(_discard(id));
      return;
    }
    if (update.state == ModelDownloadState.canceled) {
      final restart = _restarts[id];
      if (restart != null && !restart.isCompleted) return restart.complete();
      // The echo of our own cancel may arrive after the user started the download again.
      final requested = _cancelRequested.remove(id);
      if (requested != null && _now().difference(requested) < const Duration(seconds: 10)) return;
      if (_status.remove(id) != null) _notify();
      return;
    }
    if (_canceled.contains(id)) return;
    final previous = _status[id] ?? ModelStatus(state: ModelState.queued, bytesTotal: entry.sizeBytes);
    switch (update.state) {
      case ModelDownloadState.queued:
        _setStatus(
          id,
          _copy(previous, state: ModelState.queued, progress: update.progress, expectedBytes: update.expectedBytes),
        );
      case ModelDownloadState.waitingForWifi:
        _setStatus(id, _copy(previous, state: ModelState.waitingForWifi, progress: update.progress));
      case ModelDownloadState.waitingForNetwork:
        _setStatus(id, _copy(previous, state: ModelState.queued, progress: update.progress, waitingForNetwork: true));
      case ModelDownloadState.paused:
        _setStatus(id, _copy(previous, state: ModelState.paused, progress: update.progress, clearRates: true));
      case ModelDownloadState.running:
        // A reading replaces the last one only when the update carries progress and knows it.
        final carriesProgress = update.progress != null;
        // Progress: the kept data was usable.
        if (carriesProgress) _retrying.remove(id);
        final speed = update.bytesPerSecond;
        final remaining = update.timeRemaining;
        _setStatus(
          id,
          _copy(
            previous,
            state: ModelState.downloading,
            progress: update.progress,
            expectedBytes: update.expectedBytes,
            bytesPerSecond: carriesProgress && speed != null && speed > 0 ? speed : null,
            timeRemaining: carriesProgress && remaining != null && remaining > Duration.zero ? remaining : null,
          ),
        );
      case ModelDownloadState.failed:
        final error = update.error;
        final allowCellular = _retrying.remove(id);
        if (allowCellular != null && error?.code == DownloadErrorCode.cannotResume && !_starting.containsKey(id)) {
          // The data kept for a retry turned out unusable (e.g. iOS removed its temporary file): start again.
          unawaited(_restartAfterFailedResume(entry, allowCellular: allowCellular));
          return;
        }
        // Updates that restore() reports arrive before init completes.
        if (_ready) _failedSinceInit.add(id);
        _fail(
          id,
          error: error?.code == DownloadErrorCode.unknown && error?.detail == DownloadError.notAGgufFile.detail
              ? ModelError(ModelErrorCode.notAModelFile, download: error)
              : ModelError(ModelErrorCode.download, download: error),
        );
      case ModelDownloadState.complete:
        _retrying.remove(id);
        unawaited(_verify(entry, _partPath(entry)));
      case ModelDownloadState.canceled:
        break;
    }
  }

  /// The GGUF header of a GGUF entry's file, then size, then SHA-256, then the atomic rename and the index. A
  /// mismatch deletes the file: a file that is no model (a web page) fails as [ModelErrorCode.notAModelFile] before it
  /// is hashed, one of another size or SHA-256 as [ModelErrorCode.integrity]. An entry without a SHA-256 (built by
  /// the host) is checked by size alone.
  Future<void> _verify(ModelEntry entry, String source) async {
    final id = entry.id;
    if (!_verifying.add(id)) return;
    _setStatus(
      id,
      ModelStatus(state: ModelState.verifying, progress: 1, bytesDone: entry.sizeBytes, bytesTotal: entry.sizeBytes),
    );
    try {
      final file = File(source);
      if (!await file.exists()) return _fail(id, error: ModelError(ModelErrorCode.fileMissing, detail: source));
      if (entry.format == 'gguf') {
        final List<int> head;
        try {
          head = await _head(file);
        } on FileSystemException catch (e) {
          return _fail(id, error: ModelError(ModelErrorCode.cannotVerify, detail: '$e'));
        }
        final content = DownloadedContent.of(head);
        if (content != DownloadedContent.gguf) {
          await _deleteQuietly(file);
          final what = content == DownloadedContent.webPage ? 'a web page' : 'no GGUF header';
          return _fail(id, error: ModelError(ModelErrorCode.notAModelFile, detail: what));
        }
      }
      final length = await file.length();
      if (length != entry.sizeBytes) {
        await _deleteQuietly(file);
        return _fail(
          id,
          error: ModelError(ModelErrorCode.integrity, detail: '$length bytes, expected ${entry.sizeBytes}'),
        );
      }
      final String digest;
      try {
        digest = (await probe.sha256(source)).toLowerCase();
      } catch (e) {
        return _fail(id, error: ModelError(ModelErrorCode.cannotVerify, detail: '$e'));
      }
      if (entry.sha256 != null && digest != entry.sha256) {
        await _deleteQuietly(file);
        return _fail(
          id,
          error: ModelError(ModelErrorCode.integrity, detail: 'SHA-256 $digest, expected ${entry.sha256}'),
        );
      }
      final target = _finalPath(entry);
      final placed = source == target ? file : await file.rename(target);
      try {
        await probe.excludeFromBackup(target);
      } catch (_) {
        // The Android backup rules and the downloader's own iOS flag still apply.
      }
      final stat = await placed.stat();
      _index[id] = _IndexRecord(
        path: p.relative(target, from: _root),
        sizeBytes: length,
        sha256: digest,
        verifiedAt: _now().toUtc(),
        fileModifiedMs: stat.modified.millisecondsSinceEpoch,
        entry: entry,
      );
      await _writeIndex();
      _status.remove(id);
      _notify();
      _forgetRule(id);
    } on FileSystemException catch (e) {
      _fail(id, error: ModelError(ModelErrorCode.cannotSave, detail: '$e'));
    } finally {
      _verifying.remove(id);
    }
  }

  /// The first bytes of [file], enough for the GGUF header or a web page's first tag.
  static Future<List<int>> _head(File file) async {
    final raf = await file.open();
    try {
      return await raf.read(64);
    } finally {
      await raf.close();
    }
  }

  /// Files the index does not vouch for: a full-size part file (the download finished while the app was
  /// closed or during a check) or final file (its time changed) is checked again; other sizes are deleted.
  /// Next to an installed model every other file goes. With the remote list, files under names it no
  /// longer uses and folders of models it no longer lists (a download that finished after the model was
  /// renamed or withdrawn) are deleted too.
  void _checkFilesOnDisk() {
    if (_disposed) return;
    final authoritative = _origin == CatalogOrigin.remote;
    for (final entry in manifest.models) {
      try {
        final dir = Directory(modelsDirectoryFor(entry.id));
        final record = _index[entry.id];
        if (record != null) {
          if (!dir.existsSync()) continue;
          for (final file in dir.listSync().whereType<File>()) {
            if (!p.equals(file.path, _absolute(record.path))) file.deleteSync();
          }
          continue;
        }
        if (_status[entry.id] != null) continue;
        if (authoritative && dir.existsSync()) {
          final keep = {_partPath(entry), _finalPath(entry)};
          for (final file in dir.listSync().whereType<File>()) {
            if (!keep.any((path) => p.equals(path, file.path))) file.deleteSync();
          }
        }
        for (final path in [_partPath(entry), _finalPath(entry)]) {
          final file = File(path);
          if (!file.existsSync()) continue;
          if (file.lengthSync() == entry.sizeBytes) {
            unawaited(_verify(entry, path));
            break;
          }
          file.deleteSync();
        }
      } on FileSystemException {
        // Left for the next launch; nothing refers to these files.
      }
    }
    if (!authoritative) return;
    try {
      for (final dir in Directory(modelsDirectory).listSync().whereType<Directory>()) {
        final id = p.basename(dir.path);
        // Hidden folders are not models: '.partial' holds Android's downloads in progress.
        if (id.startsWith('.') || manifest.byId(id) != null || _index.containsKey(id) || _status.containsKey(id)) {
          continue;
        }
        dir.deleteSync(recursive: true);
      }
    } on FileSystemException {
      // Left for the next launch.
    }
  }

  /// Whether a failed download may resume with its task's network rule, kept across launches: one that needs Wi-Fi
  /// while Wi-Fi only still applies, or one on mobile data the user agreed to or that Wi-Fi only no longer forbids.
  /// Otherwise it starts over under the current rule. A download with no recorded rule (started by an earlier
  /// version) resumes: its task keeps the rule it was started with.
  bool _networkRuleHolds(String id, {required bool allowCellular}) => switch (_startedWifiOnly[id]) {
    true => _wifiOnly && !allowCellular,
    false => !_wifiOnly || allowCellular || _cellularConsent.contains(id),
    null => true,
  };

  Future<void> _cancelForRestart(String id) async {
    final done = Completer<void>();
    _restarts[id] = done;
    try {
      try {
        await downloader.cancel(id);
      } catch (_) {
        // Already gone on the native side: nothing will echo the cancel.
        done.complete();
      }
      await done.future.timeout(const Duration(seconds: 3), onTimeout: () {});
    } finally {
      _restarts.remove(id);
      _status.remove(id);
    }
  }

  Future<DeviceCapabilities> _readCapabilities() async {
    try {
      return await probe.capabilities();
    } catch (_) {
      return DeviceCapabilities.unknown;
    }
  }

  /// Loads the index, keeping only records whose file still has the recorded size and time.
  Future<void> _loadIndex() async {
    final file = File(p.join(modelsDirectory, 'index.json'));
    if (!await file.exists()) return;
    Object? decoded;
    try {
      decoded = jsonDecode(await file.readAsString());
    } on FormatException {
      decoded = null;
    }
    var changed = decoded is! Map;
    for (final MapEntry(:key, :value) in (decoded is Map ? decoded : const {}).entries) {
      final record = _IndexRecord.tryParse(value);
      final stat = record == null ? null : await File(_absolute(record.path)).stat();
      if (record != null &&
          stat!.type == FileSystemEntityType.file &&
          stat.size == record.sizeBytes &&
          stat.modified.millisecondsSinceEpoch == record.fileModifiedMs) {
        _index['$key'] = record;
      } else {
        changed = true;
      }
    }
    if (changed) await _writeIndex();
  }

  Future<void> _writeIndex() =>
      _writeJson(p.join(modelsDirectory, 'index.json'), {for (final e in _index.entries) e.key: e.value.toJson()});

  void _loadSettings() {
    try {
      final decoded = jsonDecode(File(_settingsFile).readAsStringSync());
      if (decoded is Map && decoded['wifiOnly'] is bool) _wifiOnly = decoded['wifiOnly'] as bool;
    } catch (_) {
      _wifiOnly = true;
    }
  }

  /// Reads the network rule of each download not yet ready: `{"<id>": {"wifiOnly": bool, "cellularConsent": bool}}`.
  void _loadDownloads() {
    _startedWifiOnly.clear();
    _cellularConsent.clear();
    try {
      final decoded = jsonDecode(File(_downloadsFile).readAsStringSync());
      if (decoded is! Map) return;
      for (final MapEntry(:key, :value) in decoded.entries) {
        if (value is! Map || value['wifiOnly'] is! bool) continue;
        _startedWifiOnly['$key'] = value['wifiOnly'] as bool;
        if (value['cellularConsent'] == true) _cellularConsent.add('$key');
      }
    } catch (_) {
      // No file (nothing downloading) or a damaged one: the rules are unknown.
    }
  }

  /// Saves the rules of [_startedWifiOnly] and [_cellularConsent], or deletes the file when there are none. The file
  /// is small and written synchronously, so writes never overlap (and work in a test's fake-async zone).
  void _saveRules() {
    final file = File(_downloadsFile);
    try {
      if (_startedWifiOnly.isEmpty) {
        if (file.existsSync()) file.deleteSync();
        return;
      }
      final json = {
        for (final MapEntry(:key, :value) in _startedWifiOnly.entries)
          key: {'wifiOnly': value, 'cellularConsent': _cellularConsent.contains(key)},
      };
      final tmp = File('${file.path}.tmp')..writeAsStringSync(jsonEncode(json), flush: true);
      tmp.renameSync(file.path);
    } on FileSystemException {
      // The rule is then unknown after a relaunch, and a retry resumes (see _networkRuleHolds).
    }
  }

  /// Drops the network rule of [id]: its download is ready, canceled or deleted.
  void _forgetRule(String id) {
    final had = _startedWifiOnly.remove(id) != null;
    if (_cellularConsent.remove(id) || had) _saveRules();
  }

  /// Write to a temporary file and rename, so a crash never leaves half a JSON file.
  static Future<void> _writeJson(String path, Object json) async {
    final tmp = File('$path.tmp');
    await tmp.parent.create(recursive: true);
    await tmp.writeAsString(jsonEncode(json), flush: true);
    await tmp.rename(path);
  }

  static Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      return;
    }
  }

  String _partPath(ModelEntry entry) => p.join(modelsDirectoryFor(entry.id), entry.partFileName);

  String _finalPath(ModelEntry entry) => p.join(modelsDirectoryFor(entry.id), entry.fileName);

  String _absolute(String path) => p.isAbsolute(path) ? path : p.join(_root, path);

  InstalledModel? _installedModel(String id) {
    final record = _index[id];
    if (record == null) return null;
    return InstalledModel(
      entry: _manifest?.byId(id) ?? record.entry,
      path: _absolute(record.path),
      sizeBytes: record.sizeBytes,
      sha256: record.sha256,
    );
  }

  void _setStatus(String id, ModelStatus status) {
    _status[id] = status;
    _notify();
  }

  void _fail(String id, {ModelError? error, ModelProblem? problem}) {
    final entry = entryFor(id);
    _setStatus(
      id,
      ModelStatus(state: ModelState.failed, bytesTotal: entry?.sizeBytes ?? 0, error: error, problem: problem),
    );
  }

  static ModelStatus _copy(
    ModelStatus s, {
    required ModelState state,
    double? progress,
    int? expectedBytes,
    double? bytesPerSecond,
    Duration? timeRemaining,
    bool clearRates = false,
    bool waitingForNetwork = false,
  }) {
    final total = expectedBytes ?? s.bytesTotal;
    final fraction = (progress ?? s.progress).clamp(0.0, 1.0);
    return ModelStatus(
      state: state,
      progress: fraction,
      bytesDone: (fraction * total).round(),
      bytesTotal: total,
      bytesPerSecond: clearRates ? null : bytesPerSecond ?? s.bytesPerSecond,
      timeRemaining: clearRates ? null : timeRemaining ?? s.timeRemaining,
      waitingForNetwork: waitingForNetwork,
    );
  }
}

class _IndexRecord {
  const _IndexRecord({
    required this.path,
    required this.sizeBytes,
    required this.sha256,
    required this.verifiedAt,
    required this.fileModifiedMs,
    required this.entry,
  });

  /// Relative to the models root: the iOS container path changes when the app is reinstalled or updated.
  final String path;
  final int sizeBytes;
  final String sha256;
  final DateTime verifiedAt;
  final int fileModifiedMs;

  /// The manifest entry the file was verified against, so a model later dropped from the manifest can
  /// still be shown and deleted.
  final ModelEntry entry;

  static _IndexRecord? tryParse(Object? json) {
    if (json is! Map) return null;
    try {
      return _IndexRecord(
        path: json['path'] as String,
        sizeBytes: json['sizeBytes'] as int,
        sha256: json['sha256'] as String,
        verifiedAt: DateTime.parse(json['verifiedAt'] as String),
        fileModifiedMs: json['fileModifiedMs'] as int,
        entry: ModelEntry.fromIndexJson(json['entry']),
      );
    } catch (_) {
      return null;
    }
  }

  Map<String, Object?> toJson() => {
    'path': path,
    'sizeBytes': sizeBytes,
    'sha256': sha256,
    'verifiedAt': verifiedAt.toIso8601String(),
    'fileModifiedMs': fileModifiedMs,
    'entry': entry.toJson(),
  };
}
