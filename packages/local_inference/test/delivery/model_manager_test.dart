// ModelManager with a fake downloader and probe on a temporary folder: the download is verified (size,
// SHA-256) before it is renamed and recorded, a bad file is deleted, the index survives restarts only
// while size and time match, the reasons not to download, when the remote manifest is waited
// for, and which leftover files it lets the manager delete.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:local_inference/local_inference.dart';
import 'package:local_inference/testing.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/until.dart';

final List<int> bigBytes = testModelBytes['test-4b']!;
final List<int> smallBytes = testModelBytes['test-2b']!;

/// The requirements of a two-model manifest: a 4B and a 2B.
String twoModelManifest() => jsonEncode({
  'schemaVersion': 1,
  'manifestVersion': '2026-09-17',
  'models': [
    _entry(
      'qwen3.5-4b-tuned-q5km',
      'model-4b-Q5_K_M.gguf',
      3074986592,
      recommended: true,
      ram: 7000,
      available: 3800,
      disk: 3726,
    ),
    _entry(
      'qwen3.5-2b-tuned-q5km',
      'model-2b-Q5_K_M.gguf',
      1454787104,
      recommended: false,
      ram: 5500,
      available: 2000,
      disk: 2027,
    ),
  ],
});

Map<String, Object?> _entry(
  String id,
  String file,
  int size, {
  required bool recommended,
  required int ram,
  required int available,
  required int disk,
}) => {
  'id': id,
  'version': 1,
  'displayName': id,
  'params': id.contains('4b') ? '4B' : '2B',
  'quant': 'Q5_K_M',
  'format': 'gguf',
  'status': 'active',
  'recommended': recommended,
  'file': {'url': 'https://example.org/models/$file', 'sizeBytes': size, 'sha256': 'ab' * 32},
  'requirements': {'minPhysicalRamMB': ram, 'minAvailableMemoryMB': available, 'minFreeDiskMB': disk},
};

void main() {
  late Directory tmp;
  late FakeDeviceProbe probe;
  late FakeModelDownloader downloader;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('model_manager_test');
    probe = FakeDeviceProbe();
    downloader = FakeModelDownloader();
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  ModelManager manager({
    String? bundled,
    bool bundleMissing = false,
    Future<String?> Function(Uri url)? fetch,
    Duration fetchTimeout = const Duration(seconds: 2),
    FakeModelDownloader? using,
    DeviceProbe? probing,
  }) => ModelManager(
    root: () async => tmp.path,
    probe: probing ?? probe,
    downloader: using ?? downloader,
    catalog: ModelCatalog.bundled(
      () async =>
          bundleMissing ? throw const FileSystemException('Unable to load asset') : bundled ?? testManifestJson(),
      fetch: fetch,
      remote: fetch == null ? null : Uri.parse('https://example.org/models/manifest.json'),
      timeout: fetchTimeout,
    ),
    now: fixedClock(DateTime.utc(2026, 9, 17, 10)),
  );

  Future<ModelManager> downloaded() async {
    final models = manager();
    await models.init();
    await models.download('test-4b');
    downloader.finish('test-4b', bigBytes);
    await until(() => models.statusOf('test-4b').state == ModelState.ready);
    return models;
  }

  test('download, progress, completion: the verified file is renamed, excluded from backup and indexed', () async {
    final models = manager();
    await models.init();
    expect(downloader.calls, ['restore']);
    expect(models.catalogOrigin, CatalogOrigin.bundled);
    expect(models.recommended!.id, 'test-4b');
    expect(models.statusOf('test-4b').state, ModelState.notDownloaded);

    await Future.wait([models.download('test-4b'), models.download('test-4b')]);
    expect(downloader.calls, ['restore', 'start test-4b wifiOnly=true'], reason: 'a double tap starts one download');
    expect(downloader.lastStart('test-4b')!.directory, p.join(tmp.path, 'models', 'test-4b'));
    expect(downloader.lastStart('test-4b')!.partFileName, 'test-4b-Q5_K_M.gguf.part');
    await until(() => models.statusOf('test-4b').state == ModelState.queued);

    downloader.emit(
      ModelDownloadUpdate(
        id: 'test-4b',
        state: ModelDownloadState.running,
        progress: 0.5,
        expectedBytes: bigBytes.length,
        bytesPerSecond: 2.5e6,
        timeRemaining: const Duration(seconds: 90),
      ),
    );
    await until(() => models.statusOf('test-4b').state == ModelState.downloading);
    final running = models.statusOf('test-4b');
    expect(running.progress, 0.5);
    expect(running.bytesDone, bigBytes.length ~/ 2);
    expect(running.bytesTotal, bigBytes.length);
    expect(running.bytesPerSecond, 2.5e6);
    expect(running.timeRemaining, const Duration(seconds: 90));

    final states = <ModelState>[];
    models.addListener(() => states.add(models.statusOf('test-4b').state));
    downloader.finish('test-4b', bigBytes);
    await until(() => models.statusOf('test-4b').state == ModelState.ready);
    expect(states, contains(ModelState.verifying));

    final finalPath = p.join(tmp.path, 'models', 'test-4b', 'test-4b-Q5_K_M.gguf');
    expect(models.pathOf('test-4b'), finalPath);
    expect(File(finalPath).readAsBytesSync(), bigBytes);
    expect(File('$finalPath.part').existsSync(), isFalse);
    expect(probe.excluded, [finalPath]);
    expect(models.installed.single.entry.id, 'test-4b');
    expect(models.installed.single.sizeBytes, bigBytes.length);
    expect(models.installed.single.sha256, '${crypto.sha256.convert(bigBytes)}');
    expect(models.sha256Of('test-4b'), '${crypto.sha256.convert(bigBytes)}');
    expect(models.installedBytes, bigBytes.length);

    final index = jsonDecode(File(p.join(tmp.path, 'models', 'index.json')).readAsStringSync()) as Map;
    final record = index['test-4b'] as Map;
    expect(record['path'], p.join('models', 'test-4b', 'test-4b-Q5_K_M.gguf'));
    expect(record['sizeBytes'], bigBytes.length);
    expect(record['sha256'], '${crypto.sha256.convert(bigBytes)}');
    expect(record['verifiedAt'], '2026-09-17T10:00:00.000Z');
    // FileStat, as the manager reads it: before Dart 3.13, File.lastModified dropped the milliseconds on macOS.
    expect(record['fileModifiedMs'], File(finalPath).statSync().modified.millisecondsSinceEpoch);

    // A late duplicate completion does not hash again.
    final hashes = probe.hashed.length;
    downloader.emit(const ModelDownloadUpdate(id: 'test-4b', state: ModelDownloadState.complete));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(probe.hashed.length, hashes);
    expect(models.statusOf('test-4b').state, ModelState.ready);
    await models.dispose();
  });

  test('a SHA-256 or size mismatch deletes the part file and fails with the integrity code', () async {
    final models = manager();
    await models.init();
    final part = p.join(tmp.path, 'models', 'test-4b', 'test-4b-Q5_K_M.gguf.part');

    probe.hashOf = (_) async => '0' * 64;
    await models.download('test-4b');
    downloader.finish('test-4b', bigBytes);
    await until(() => models.statusOf('test-4b').state == ModelState.failed);
    expect(models.statusOf('test-4b').error!.code, ModelErrorCode.integrity);
    expect(models.statusOf('test-4b').error!.detail, startsWith('SHA-256 ${'0' * 64}, expected '));
    expect(File(part).existsSync(), isFalse);
    expect(models.pathOf('test-4b'), isNull);
    expect(File(p.join(tmp.path, 'models', 'index.json')).existsSync(), isFalse);

    probe.hashOf = null;
    await models.download('test-4b');
    expect(models.statusOf('test-4b').state, ModelState.queued);
    downloader.finish('test-4b', bigBytes.sublist(0, bigBytes.length - 1));
    await until(() => models.statusOf('test-4b').state == ModelState.failed);
    expect(
      models.statusOf('test-4b').error,
      ModelError(ModelErrorCode.integrity, detail: '${bigBytes.length - 1} bytes, expected ${bigBytes.length}'),
    );
    expect(File(part).existsSync(), isFalse);

    const connection = DownloadError(DownloadErrorCode.connection);
    downloader.emit(const ModelDownloadUpdate(id: 'test-4b', state: ModelDownloadState.failed, error: connection));
    await until(
      () => models.statusOf('test-4b').error == const ModelError(ModelErrorCode.download, download: connection),
    );
    await models.dispose();
  });

  test('delete removes the files and the index entry', () async {
    final models = await downloaded();
    final dir = Directory(models.modelsDirectoryFor('test-4b'));
    expect(dir.existsSync(), isTrue);
    await models.delete('test-4b');
    expect(dir.existsSync(), isFalse);
    expect(models.pathOf('test-4b'), isNull);
    expect(models.installed, isEmpty);
    expect(models.statusOf('test-4b').state, ModelState.notDownloaded);
    final index = jsonDecode(File(p.join(tmp.path, 'models', 'index.json')).readAsStringSync()) as Map;
    expect(index, isEmpty);
    await models.dispose();
  });

  test(
    'restart: the index is trusted while size and time match; a changed time is hashed again, a changed size deleted',
    () async {
      final first = await downloaded();
      final path = first.pathOf('test-4b')!;
      await first.dispose();

      probe.hashed.clear();
      final second = manager(using: FakeModelDownloader());
      await second.init();
      expect(second.statusOf('test-4b').state, ModelState.ready);
      expect(second.pathOf('test-4b'), path);
      expect(probe.hashed, isEmpty);
      await second.dispose();

      File(path).setLastModifiedSync(DateTime(2020));
      final third = manager(using: FakeModelDownloader());
      await third.init();
      expect(third.pathOf('test-4b'), isNull, reason: 'not installed until hashed again');
      await until(() => third.statusOf('test-4b').state == ModelState.ready);
      expect(probe.hashed, hasLength(1));
      expect(third.pathOf('test-4b'), path);
      await third.dispose();

      File(path).writeAsBytesSync([1, 2, 3], mode: FileMode.append);
      final fourth = manager(using: FakeModelDownloader());
      await fourth.init();
      expect(fourth.pathOf('test-4b'), isNull);
      expect(fourth.statusOf('test-4b').state, ModelState.notDownloaded);
      expect(File(path).existsSync(), isFalse);
      await fourth.dispose();
    },
  );

  test(
    'a download that finished while the app was closed is verified at launch; restored downloads show their state',
    () async {
      File(p.join(tmp.path, 'models', 'test-4b', 'test-4b-Q5_K_M.gguf.part'))
        ..createSync(recursive: true)
        ..writeAsBytesSync(bigBytes);
      downloader.restored.add(
        const ModelDownloadUpdate(id: 'test-2b', state: ModelDownloadState.paused, progress: 0.25),
      );
      final models = manager();
      await models.init();
      await until(() => models.statusOf('test-4b').state == ModelState.ready);
      await until(() => models.statusOf('test-2b').state == ModelState.paused);
      expect(models.statusOf('test-2b').progress, 0.25);

      await models.download('test-2b');
      expect(downloader.calls.last, 'resume test-2b');
      await until(() => models.statusOf('test-2b').state == ModelState.downloading);
      await models.dispose();
    },
  );

  test('pause, resume, cancel; late updates after a cancel are ignored', () async {
    final models = manager();
    await models.init();
    await models.download('test-2b');
    downloader.emit(const ModelDownloadUpdate(id: 'test-2b', state: ModelDownloadState.running, progress: 0.4));
    await until(() => models.statusOf('test-2b').state == ModelState.downloading);

    await models.pause('test-2b');
    await until(() => models.statusOf('test-2b').state == ModelState.paused);
    expect(models.statusOf('test-2b').progress, 0.4);
    await models.resume('test-2b');
    await until(() => models.statusOf('test-2b').state == ModelState.downloading);

    await models.cancel('test-2b');
    expect(models.statusOf('test-2b').state, ModelState.notDownloaded);
    downloader.emit(const ModelDownloadUpdate(id: 'test-2b', state: ModelDownloadState.running, progress: 0.41));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(models.statusOf('test-2b').state, ModelState.notDownloaded);
    expect(downloader.calls, [
      'restore',
      'start test-2b wifiOnly=true',
      'pause test-2b',
      'resume test-2b',
      'cancel test-2b',
    ]);

    // Cancel, start again at once, then the native cancel arrives late: the new download keeps its state.
    downloader.echoCancel = false;
    await models.download('test-2b');
    await models.cancel('test-2b');
    await models.download('test-2b');
    await until(() => models.statusOf('test-2b').state == ModelState.queued);
    downloader.emit(const ModelDownloadUpdate(id: 'test-2b', state: ModelDownloadState.canceled));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(models.statusOf('test-2b').state, ModelState.queued);
    // A cancel from the system notification clears it.
    downloader.emit(const ModelDownloadUpdate(id: 'test-2b', state: ModelDownloadState.canceled));
    await until(() => models.statusOf('test-2b').state == ModelState.notDownloaded);
    await models.dispose();
  });

  test('Wi-Fi only is persisted; mobile data restarts a download waiting for Wi-Fi', () async {
    final models = manager();
    await models.init();
    expect(models.wifiOnly, isTrue);
    await models.download('test-4b');
    downloader.emit(const ModelDownloadUpdate(id: 'test-4b', state: ModelDownloadState.waitingForWifi));
    await until(() => models.statusOf('test-4b').state == ModelState.waitingForWifi);
    await models.download('test-4b');
    expect(downloader.calls.last, 'start test-4b wifiOnly=true', reason: 'already queued');

    await models.download('test-4b', allowCellular: true);
    expect(downloader.calls.sublist(downloader.calls.length - 2), ['cancel test-4b', 'start test-4b wifiOnly=false']);
    await until(() => models.statusOf('test-4b').state == ModelState.queued);

    await models.setWifiOnly(false);
    await models.dispose();
    final again = manager(using: FakeModelDownloader());
    await again.init();
    expect(again.wifiOnly, isFalse);
    await again.dispose();
  });

  test('offline, a queued download says it waits for a connection, not for Wi-Fi', () async {
    final models = manager();
    await models.init();
    await models.download('test-4b');
    downloader.emit(const ModelDownloadUpdate(id: 'test-4b', state: ModelDownloadState.waitingForNetwork));
    await until(() => models.statusOf('test-4b').waitingForNetwork);
    expect(models.statusOf('test-4b').state, ModelState.queued);
    expect(models.statusOf('test-4b').isActive, isTrue);

    downloader.emit(const ModelDownloadUpdate(id: 'test-4b', state: ModelDownloadState.waitingForWifi));
    await until(() => models.statusOf('test-4b').state == ModelState.waitingForWifi);
    expect(models.statusOf('test-4b').waitingForNetwork, isFalse);

    downloader.emit(const ModelDownloadUpdate(id: 'test-4b', state: ModelDownloadState.waitingForNetwork));
    await until(() => models.statusOf('test-4b').waitingForNetwork);
    downloader.emit(const ModelDownloadUpdate(id: 'test-4b', state: ModelDownloadState.running, progress: 0.1));
    await until(() => models.statusOf('test-4b').state == ModelState.downloading);
    expect(models.statusOf('test-4b').waitingForNetwork, isFalse);
    await models.dispose();
  });

  test('problemFor gives the reason as a ModelProblem, and a refused download never starts', () async {
    final models = manager(bundled: twoModelManifest());
    await models.init();
    final big = models.entries.first;
    final small = models.entries.last;

    expect(models.problemFor(big), isNull);

    probe.caps = const DeviceCapabilities(physicalMemoryMB: 5731, availableMemoryMB: 3000, freeDiskMB: 50000);
    await models.refreshCapabilities();
    expect(models.problemFor(big), const NotEnoughRam(7000));
    expect(models.problemFor(small), isNull);
    expect(models.recommended, small);

    final fresh = manager(bundled: twoModelManifest(), using: FakeModelDownloader());
    probe.caps = const DeviceCapabilities(physicalMemoryMB: 7622, availableMemoryMB: 2000, freeDiskMB: 50000);
    await fresh.init();
    expect(fresh.problemFor(big), const NotEnoughMemory(3800, 2000));

    probe.caps = const DeviceCapabilities(physicalMemoryMB: 7622, availableMemoryMB: 5960, freeDiskMB: 1200);
    await models.refreshCapabilities();
    expect(models.capabilities.availableMemoryMB, 5960, reason: 'the highest reading is kept');
    expect(models.problemFor(big), const NotEnoughDisk(3726, 1200));
    await models.download(big.id);
    expect(downloader.started, isEmpty);
    expect(models.statusOf(big.id).state, ModelState.failed);
    expect(models.statusOf(big.id).problem, const NotEnoughDisk(3726, 1200));
    expect(models.statusOf(big.id).error, isNull);

    probe.caps = const DeviceCapabilities();
    final unknown = manager(bundled: twoModelManifest(), using: FakeModelDownloader());
    await unknown.init();
    expect(unknown.problemFor(big), isNull);
    expect(unknown.recommended!.id, big.id);
    for (final m in [models, fresh, unknown]) {
      await m.dispose();
    }
  });

  test('remote manifest: used when valid and in time, otherwise the bundled copy', () async {
    final remote = testManifestJson(manifestVersion: '2026-10-01', withSmall: false);

    final online = manager(fetch: (_) async => remote);
    await online.init();
    expect(online.catalogOrigin, CatalogOrigin.remote);
    expect(online.manifest.manifestVersion, '2026-10-01');
    expect(online.entries.map((e) => e.id), ['test-4b']);
    await online.dispose();

    final cases = <String, Future<String?> Function(Uri)>{
      'network error': (_) async => throw const SocketException('offline'),
      'no body': (_) async => null,
      'bad JSON': (_) async => '<html>404</html>',
      'bad manifest': (_) async => jsonEncode({'schemaVersion': 1, 'manifestVersion': 'x', 'models': []}),
      'too slow': (_) => Future<String?>.delayed(const Duration(seconds: 2), () => remote),
    };
    for (final MapEntry(key: name, value: fetch) in cases.entries) {
      final models = manager(
        fetch: fetch,
        fetchTimeout: const Duration(milliseconds: 50),
        using: FakeModelDownloader(),
      );
      await models.init();
      expect(models.catalogOrigin, CatalogOrigin.bundled, reason: name);
      expect(models.entries.map((e) => e.id), ['test-4b', 'test-2b'], reason: name);
      expect(models.catalogError, isNotNull, reason: name);
      await models.dispose();
    }
  });

  test(
    'with a model installed, launch does not wait for the remote manifest; it replaces the bundled one when idle',
    () async {
      await (await downloaded()).dispose();

      final answer = Completer<String?>();
      final later = manager(
        fetch: (_) => answer.future,
        fetchTimeout: const Duration(seconds: 5),
        using: FakeModelDownloader(),
      );
      final clock = Stopwatch()..start();
      await later.init();
      expect(clock.elapsed, lessThan(const Duration(seconds: 2)));
      expect(later.catalogOrigin, CatalogOrigin.bundled);
      expect(later.statusOf('test-4b').state, ModelState.ready);
      var notified = 0;
      later.addListener(() => notified++);
      answer.complete(testManifestJson(manifestVersion: '2026-10-01'));
      await until(() => later.catalogOrigin == CatalogOrigin.remote);
      expect(later.manifest.manifestVersion, '2026-10-01');
      expect(notified, greaterThan(0));
      await later.dispose();

      // A download set up from the bundled entry keeps it: the remote list waits for the next launch.
      final busyAnswer = Completer<String?>();
      final busy = manager(
        fetch: (_) => busyAnswer.future,
        fetchTimeout: const Duration(seconds: 5),
        using: FakeModelDownloader(),
      );
      await busy.init();
      await busy.download('test-2b');
      busyAnswer.complete(testManifestJson(manifestVersion: '2026-10-01'));
      await until(() => busy.catalogError != null);
      expect(busy.catalogOrigin, CatalogOrigin.bundled);
      expect(busy.statusOf('test-2b').state, ModelState.queued);
      await busy.dispose();

      // So does a failed download that can still resume its task.
      final failedAnswer = Completer<String?>();
      final failed = manager(
        fetch: (_) => failedAnswer.future,
        fetchTimeout: const Duration(seconds: 5),
        using: downloader,
      );
      await failed.init();
      await failed.download('test-2b');
      downloader.emit(const ModelDownloadUpdate(id: 'test-2b', state: ModelDownloadState.failed));
      await until(() => failed.statusOf('test-2b').state == ModelState.failed);
      failedAnswer.complete(testManifestJson(manifestVersion: '2026-10-01'));
      await until(() => failed.catalogError != null);
      expect(failed.catalogOrigin, CatalogOrigin.bundled);
      await failed.dispose();
    },
  );

  test(
    'the remote manifest lets launch delete files and folders it no longer names; the bundled copy does not',
    () async {
      final renamed = File(p.join(tmp.path, 'models', 'test-4b', 'test-4b-old-Q5_K_M.gguf'))
        ..createSync(recursive: true)
        ..writeAsBytesSync(bigBytes);
      final withdrawn = Directory(p.join(tmp.path, 'models', 'test-1b'));
      File(p.join(withdrawn.path, 'test-1b-Q5_K_M.gguf'))
        ..createSync(recursive: true)
        ..writeAsBytesSync(smallBytes);
      final androidPartial = File(p.join(tmp.path, 'models', '.partial', 'test-4b-Q5_K_M.gguf.part'))
        ..createSync(recursive: true)
        ..writeAsBytesSync([1, 2, 3]);

      final offline = manager(using: FakeModelDownloader());
      await offline.init();
      expect((renamed.existsSync(), withdrawn.existsSync()), (true, true));
      await offline.dispose();

      downloader.restored.add(
        const ModelDownloadUpdate(id: 'test-1b', state: ModelDownloadState.running, progress: 0.3),
      );
      final online = manager(fetch: (_) async => testManifestJson());
      await online.init();
      expect(online.catalogOrigin, CatalogOrigin.remote);
      expect(renamed.existsSync(), isFalse);
      expect(withdrawn.existsSync(), isFalse);
      expect(androidPartial.existsSync(), isTrue);
      await until(() => downloader.calls.contains('cancel test-1b'), reason: 'a withdrawn model stops downloading');
      await online.dispose();
    },
  );

  test('a model dropped from the manifest stays listed as installed until deleted', () async {
    final models = manager();
    await models.init();
    await models.download('test-2b');
    downloader.finish('test-2b', smallBytes);
    await until(() => models.statusOf('test-2b').state == ModelState.ready);
    await models.dispose();

    final later = manager(bundled: testManifestJson(withSmall: false), using: FakeModelDownloader());
    await later.init();
    expect(later.installed.single.entry.id, 'test-2b');
    expect(later.entryFor('test-2b')!.displayName, 'test-2b');
    await later.delete('test-2b');
    expect(later.installed, isEmpty);
    await later.dispose();
  });

  test('a model verified against an entry the host built stays installed after a relaunch, unhashed', () async {
    // The constructor's defaults (empty texts, no SHA-256) and a URL no published manifest may carry.
    final entry = ModelEntry(
      id: 'host',
      url: Uri.parse('http://127.0.0.1:8080/m/host.gguf'),
      sizeBytes: bigBytes.length,
    );
    ModelManager launch(FakeModelDownloader using) => ModelManager(
      root: () async => tmp.path,
      probe: probe,
      downloader: using,
      catalog: ModelCatalog.single(entry),
      now: fixedClock(DateTime.utc(2026, 9, 17, 10)),
    );
    final first = launch(downloader);
    await first.init();
    await first.download('host');
    downloader.finish('host', bigBytes);
    await until(() => first.statusOf('host').state == ModelState.ready);
    await first.dispose();
    expect(probe.hashed, hasLength(1));

    final again = launch(FakeModelDownloader());
    await again.init();
    expect(again.statusOf('host').state, ModelState.ready);
    expect(again.installed.single.entry, entry);
    expect(probe.hashed, hasLength(1), reason: 'the index vouches for the file: no check at each launch');
    await again.dispose();
  });

  test('pause acts only on a running download: a queued one has nothing to resume from', () async {
    final models = manager();
    await models.init();
    await models.download('test-4b');
    await until(() => models.statusOf('test-4b').state == ModelState.queued);
    await models.pause('test-4b');
    expect(downloader.calls, ['restore', 'start test-4b wifiOnly=true']);
    expect(models.statusOf('test-4b').state, ModelState.queued);
    await models.dispose();
  });

  test(
    'trying again after a network failure resumes; after a bad file or a changed Wi-Fi setting it starts over',
    () async {
      const connection = DownloadError(DownloadErrorCode.connection);
      final models = manager();
      await models.init();
      await models.download('test-4b');
      downloader.emit(const ModelDownloadUpdate(id: 'test-4b', state: ModelDownloadState.running, progress: 0.9));
      await until(() => models.statusOf('test-4b').state == ModelState.downloading);
      downloader.emit(const ModelDownloadUpdate(id: 'test-4b', state: ModelDownloadState.failed, error: connection));
      await until(() => models.statusOf('test-4b').state == ModelState.failed);
      await models.resume('test-4b');
      expect(downloader.calls.last, 'resume test-4b');
      await until(() => models.statusOf('test-4b').state == ModelState.downloading);

      downloader.finish('test-4b', bigBytes.sublist(1));
      await until(() => models.statusOf('test-4b').state == ModelState.failed);
      await models.download('test-4b');
      expect(downloader.calls.last, 'start test-4b wifiOnly=true', reason: 'the bad file is gone');

      downloader.emit(const ModelDownloadUpdate(id: 'test-4b', state: ModelDownloadState.failed));
      await until(() => models.statusOf('test-4b').state == ModelState.failed);
      await models.setWifiOnly(false);
      await models.download('test-4b');
      expect(downloader.calls.last, 'start test-4b wifiOnly=false', reason: 'the old task would still require Wi-Fi');
      await models.dispose();
    },
  );

  test('trying again after a mobile-data download failed resumes instead of starting over on Wi-Fi only', () async {
    const connection = DownloadError(DownloadErrorCode.connection);
    final models = manager();
    await models.init();
    await models.download('test-4b', allowCellular: true);
    downloader.emit(const ModelDownloadUpdate(id: 'test-4b', state: ModelDownloadState.running, progress: 0.6));
    await until(() => models.statusOf('test-4b').state == ModelState.downloading);
    downloader.emit(const ModelDownloadUpdate(id: 'test-4b', state: ModelDownloadState.failed, error: connection));
    await until(() => models.statusOf('test-4b').state == ModelState.failed);
    await models.download('test-4b');
    expect(downloader.calls, ['restore', 'start test-4b wifiOnly=false', 'canResume test-4b', 'resume test-4b']);

    // Started with Wi-Fi only off, which the user then turned on: no consent to mobile data, so it starts over.
    await models.setWifiOnly(false);
    await models.download('test-2b');
    downloader.emit(const ModelDownloadUpdate(id: 'test-2b', state: ModelDownloadState.failed));
    await until(() => models.statusOf('test-2b').state == ModelState.failed);
    await models.setWifiOnly(true);
    await models.download('test-2b');
    expect(downloader.calls.sublist(4), [
      'start test-2b wifiOnly=false',
      'canResume test-2b',
      'discard test-2b',
      'start test-2b wifiOnly=true',
    ]);
    await models.dispose();
  });

  test('a complete part file left by an earlier attempt is checked instead of downloaded again', () async {
    final models = manager();
    await models.init();
    final part = File(p.join(tmp.path, 'models', 'test-4b', 'test-4b-Q5_K_M.gguf.part'));

    // The check could not run (the native hash failed): the file stays for the retry.
    final flaky = manager(
      probing: FakeDeviceProbe(hashOf: (_) async => throw StateError('channel gone')),
      using: FakeModelDownloader(),
    );
    await flaky.init();
    part
      ..createSync(recursive: true)
      ..writeAsBytesSync(bigBytes);
    await flaky.download('test-4b');
    expect(
      flaky.statusOf('test-4b').error,
      const ModelError(ModelErrorCode.cannotVerify, detail: 'Bad state: channel gone'),
    );
    expect(part.existsSync(), isTrue);
    await flaky.dispose();

    await models.download('test-4b');
    expect(models.statusOf('test-4b').state, ModelState.ready);
    expect(downloader.calls, ['restore'], reason: 'no download started');
    expect(part.existsSync(), isFalse);
    await models.delete('test-4b');

    // A part file of another size is useless: deleted, and the download starts.
    part
      ..createSync(recursive: true)
      ..writeAsBytesSync(bigBytes.sublist(10));
    await models.download('test-4b');
    expect(part.existsSync(), isFalse);
    expect(downloader.calls.last, 'start test-4b wifiOnly=true');

    // A complete but corrupt one is deleted by the check, and the download starts.
    await models.cancel('test-4b');
    part
      ..createSync(recursive: true)
      ..writeAsBytesSync(List.of(bigBytes)..[0] ^= 1);
    await models.download('test-4b');
    expect(part.existsSync(), isFalse);
    expect(downloader.calls.last, 'start test-4b wifiOnly=true');
    await models.dispose();
  });

  test('a second copy completed after the model was installed is removed, now or at the next launch', () async {
    final models = await downloaded();
    final part = File(p.join(tmp.path, 'models', 'test-4b', 'test-4b-Q5_K_M.gguf.part'));
    downloader.finish('test-4b', bigBytes);
    await until(() => !part.existsSync());
    expect(models.statusOf('test-4b').state, ModelState.ready);
    await models.dispose();

    part.writeAsBytesSync(bigBytes);
    final later = manager(using: FakeModelDownloader());
    await later.init();
    expect(part.existsSync(), isFalse);
    expect(later.statusOf('test-4b').state, ModelState.ready);
    expect(File(later.pathOf('test-4b')!).existsSync(), isTrue);
    await later.dispose();
  });

  test('without the bundled manifest the remote one is used; with neither, init fails with loadError', () async {
    final online = manager(bundleMissing: true, fetch: (_) async => testManifestJson());
    await online.init();
    expect(online.catalogOrigin, CatalogOrigin.remote);
    expect(online.entries, hasLength(2));
    await online.dispose();

    final offline = manager(bundleMissing: true, fetch: (_) async => null, using: FakeModelDownloader());
    final notified = <Object?>[];
    offline.addListener(() => notified.add(offline.loadError));
    await expectLater(offline.init(), throwsStateError);
    expect(offline.isReady, isFalse);
    expect('${offline.loadError}', contains('no model manifest'));
    expect(notified, isNotEmpty);
    await offline.dispose();
  });
}
