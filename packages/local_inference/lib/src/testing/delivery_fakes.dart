/// Test doubles of model delivery: a downloader and a device probe driven by the test, and a small manifest whose
/// files a test can write.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:path/path.dart' as p;

import '../delivery/device.dart';
import '../delivery/downloader.dart';
import '../delivery/manifest.dart';

/// One call of [FakeModelDownloader.start].
final class FakeDownloadStart {
  const FakeDownloadStart(this.entry, {required this.directory, required this.partFileName, required this.wifiOnly});

  final ModelEntry entry;
  final String directory;
  final String partFileName;
  final bool wifiOnly;

  /// Where the downloader would write the file.
  String get path => p.join(directory, partFileName);
}

/// A downloader the test drives: it records every call and sends the updates the test [emit]s. [start] reports the
/// download queued, [pause] paused, [resume] running and [cancel] canceled (unless [echoCancel] is false), as a
/// background downloader does; [finish] writes the file and reports it complete. Like a downloader that keeps the
/// partial data of a failed download, [canResume] is true after a failed update of an id until it is started,
/// resumed, discarded, canceled or finished; [canResumeResult] fixes the answer instead.
final class FakeModelDownloader implements ModelDownloader {
  FakeModelDownloader({this.canResumeResult, this.echoCancel = true});

  final _controller = StreamController<ModelDownloadUpdate>.broadcast();

  /// Every call in order: `start <id> wifiOnly=<bool>`, `pause <id>`, `resume <id>`, `canResume <id>`,
  /// `discard <id>`, `cancel <id>`, `restore`.
  final List<String> calls = [];

  /// The [start] calls, in order.
  final List<FakeDownloadStart> started = [];

  /// The ids of the [pause], [resume], [cancel] and [discard] calls, in order.
  final List<String> paused = [], resumed = [], canceled = [], discarded = [];

  /// The updates [restore] sends, as downloads found running at launch would.
  final List<ModelDownloadUpdate> restored = [];

  /// The targets the last [restore] was given.
  List<DownloadTarget> restoredTargets = const [];

  /// What [canResume] answers; null: whether the id's download failed and its data is still kept (see the class).
  bool? canResumeResult;

  /// The ids whose partial data a real downloader would still keep: their last update was a failure.
  final Set<String> kept = {};

  /// Whether [cancel] reports the download canceled.
  bool echoCancel;

  /// Sends [update] to the listeners of [updates].
  void emit(ModelDownloadUpdate update) {
    if (update.state == ModelDownloadState.failed) kept.add(update.id);
    _controller.add(update);
  }

  /// The last [start] of [id], or null.
  FakeDownloadStart? lastStart(String id) => started.where((s) => s.entry.id == id).lastOrNull;

  /// Writes [bytes] where the last [start] of [id] put its part file, then reports the download complete.
  void finish(String id, List<int> bytes) {
    final start = lastStart(id) ?? (throw StateError('$id was never started'));
    File(start.path)
      ..createSync(recursive: true)
      ..writeAsBytesSync(bytes);
    kept.remove(id);
    emit(ModelDownloadUpdate(id: id, state: ModelDownloadState.complete));
  }

  @override
  Stream<ModelDownloadUpdate> get updates => _controller.stream;

  @override
  Future<void> start(
    ModelEntry entry, {
    required String directory,
    required String partFileName,
    required bool wifiOnly,
  }) async {
    calls.add('start ${entry.id} wifiOnly=$wifiOnly');
    started.add(FakeDownloadStart(entry, directory: directory, partFileName: partFileName, wifiOnly: wifiOnly));
    kept.remove(entry.id);
    emit(ModelDownloadUpdate(id: entry.id, state: ModelDownloadState.queued));
  }

  @override
  Future<void> pause(String id) async {
    calls.add('pause $id');
    paused.add(id);
    emit(ModelDownloadUpdate(id: id, state: ModelDownloadState.paused));
  }

  @override
  Future<void> resume(String id) async {
    calls.add('resume $id');
    resumed.add(id);
    kept.remove(id);
    emit(ModelDownloadUpdate(id: id, state: ModelDownloadState.running));
  }

  @override
  Future<bool> canResume(String id) async {
    calls.add('canResume $id');
    return canResumeResult ?? kept.contains(id);
  }

  @override
  Future<void> discard(String id) async {
    calls.add('discard $id');
    discarded.add(id);
    kept.remove(id);
  }

  @override
  Future<void> cancel(String id) async {
    calls.add('cancel $id');
    canceled.add(id);
    kept.remove(id);
    if (echoCancel) emit(ModelDownloadUpdate(id: id, state: ModelDownloadState.canceled));
  }

  @override
  Future<void> restore({Iterable<DownloadTarget> targets = const []}) async {
    calls.add('restore');
    restoredTargets = List.unmodifiable(targets);
    restored.forEach(emit);
  }
}

/// A device probe the test sets: [caps] is what [capabilities] reports; [sha256] answers from [hashes] (by path),
/// else from [hashOf], else with the file's real SHA-256; the paths it was asked to hash or exclude are recorded.
final class FakeDeviceProbe implements DeviceProbe {
  FakeDeviceProbe({DeviceCapabilities capabilities = defaultCapabilities, this.hashes, this.hashOf})
    : caps = capabilities;

  /// An 8 GB phone (7622 MB reported), 5960 MB available to the app, 50 GB free.
  static const defaultCapabilities = DeviceCapabilities(
    physicalMemoryMB: 7622,
    availableMemoryMB: 5960,
    freeDiskMB: 50000,
  );

  /// What [capabilities] reports; tests change it between readings.
  DeviceCapabilities caps;

  /// Fixed answers of [sha256], by path.
  Map<String, String>? hashes;

  /// The answer of [sha256] for a path [hashes] does not name; it may throw.
  Future<String> Function(String path)? hashOf;

  /// The paths [sha256] was asked for, in order.
  final List<String> hashed = [];

  /// The paths [excludeFromBackup] was asked for, in order.
  final List<String> excluded = [];

  @override
  Future<DeviceCapabilities> capabilities() async => caps;

  @override
  Future<String> sha256(String path) async {
    hashed.add(path);
    final fixed = hashes?[path];
    if (fixed != null) return fixed;
    final hashOf = this.hashOf;
    if (hashOf != null) return hashOf(path);
    return dartSha256(path);
  }

  @override
  Future<void> excludeFromBackup(String path) async => excluded.add(path);
}

/// The model files of [testManifestJson], by id: `test-4b` (960 bytes) and `test-2b` (480 bytes).
final Map<String, List<int>> testModelBytes = Map.unmodifiable({
  'test-4b': List<int>.unmodifiable(utf8.encode('GGUF pretend 4B weights ' * 40)),
  'test-2b': List<int>.unmodifiable(utf8.encode('GGUF pretend 2B weights ' * 20)),
});

/// A schema-1 manifest of two small models whose files are [testModelBytes]: `test-4b` (recommended, 7000 MB of RAM,
/// 3800 available) and, with [withSmall], `test-2b` (5500 and 2000). Each needs 100 MB of free disk; the display
/// name is the id.
String testManifestJson({bool withSmall = true, String manifestVersion = '2026-09-17'}) => jsonEncode({
  'schemaVersion': 1,
  'manifestVersion': manifestVersion,
  'models': [
    _testEntry('test-4b', 'test-4b-Q5_K_M.gguf', recommended: true, ram: 7000, available: 3800),
    if (withSmall) _testEntry('test-2b', 'test-2b-Q5_K_M.gguf', recommended: false, ram: 5500, available: 2000),
  ],
});

Map<String, Object?> _testEntry(
  String id,
  String file, {
  required bool recommended,
  required int ram,
  required int available,
}) {
  final bytes = testModelBytes[id]!;
  return {
    'id': id,
    'version': 1,
    'displayName': id,
    'params': id.endsWith('4b') ? '4B' : '2B',
    'quant': 'Q5_K_M',
    'format': 'gguf',
    'status': 'active',
    'recommended': recommended,
    'file': {
      'url': 'https://example.org/models/$file',
      'sizeBytes': bytes.length,
      'sha256': '${crypto.sha256.convert(bytes)}',
    },
    'requirements': {'minPhysicalRamMB': ram, 'minAvailableMemoryMB': available, 'minFreeDiskMB': 100},
  };
}
