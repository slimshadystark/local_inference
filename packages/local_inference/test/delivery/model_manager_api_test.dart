// The ModelManager API added when delivery moved into the package: init retried after a failure, install and
// watch, forDirectory end to end over HTTP, every ModelProblem in its order, and the catalogs.
import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:local_inference/local_inference.dart';
import 'package:local_inference/testing.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/until.dart';

void main() {
  late Directory tmp;
  late FakeDeviceProbe probe;
  late FakeModelDownloader downloader;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('model_manager_api_test');
    probe = FakeDeviceProbe();
    downloader = FakeModelDownloader();
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  ModelManager manager({ModelCatalog? catalog, ModelProblem? Function(ModelEntry, DeviceCapabilities)? preflight}) =>
      ModelManager(
        root: () async => tmp.path,
        probe: probe,
        downloader: downloader,
        catalog: catalog ?? ModelCatalog.bundled(() async => testManifestJson()),
        preflight: preflight,
      );

  test('init can be tried again after a failure, and then clears loadError', () async {
    var bundled = false;
    var reads = 0;
    final models = manager(
      catalog: ModelCatalog.bundled(() async {
        reads++;
        return bundled ? testManifestJson() : throw const FileSystemException('Unable to load asset');
      }),
    );
    await expectLater(models.init(), throwsStateError);
    expect(models.isReady, isFalse);
    expect('${models.loadError}', contains('no model manifest'));
    await expectLater(models.init(), throwsStateError, reason: 'a new attempt, not the cached failure');
    expect(reads, 2);

    bundled = true;
    await Future.wait([models.init(), models.init()]);
    expect((models.isReady, models.loadError, reads), (true, null, 3), reason: 'concurrent calls share one attempt');
    await models.init();
    expect(reads, 3, reason: 'a successful init is not repeated');
    expect(downloader.calls, ['restore']);
    await models.dispose();
  });

  test(
    'install completes with the verified model and reports its progress; watch starts with the status now',
    () async {
      final models = manager();
      await models.init();
      final watched = <ModelState>[];
      final watching = models.watch('test-2b').listen((s) => watched.add(s.state));
      final seen = <ModelState>[];
      final install = models.install('test-2b', onProgress: (s) => seen.add(s.state));
      await until(() => downloader.lastStart('test-2b') != null);
      downloader.emit(const ModelDownloadUpdate(id: 'test-2b', state: ModelDownloadState.running, progress: 0.5));
      await until(() => models.statusOf('test-2b').state == ModelState.downloading);
      downloader.finish('test-2b', testModelBytes['test-2b']!);
      final installed = await install;
      expect(installed.entry.id, 'test-2b');
      expect(installed.path, p.join(tmp.path, 'models', 'test-2b', 'test-2b-Q5_K_M.gguf'));
      expect(installed.sha256, '${crypto.sha256.convert(testModelBytes['test-2b']!)}');
      expect(
        seen,
        containsAllInOrder([ModelState.queued, ModelState.downloading, ModelState.verifying, ModelState.ready]),
      );
      await until(() => watched.isNotEmpty && watched.last == ModelState.ready);
      expect(watched.first, ModelState.notDownloaded);
      expect(watched, containsAllInOrder([ModelState.queued, ModelState.downloading, ModelState.verifying]));

      final again = await models.install('test-2b');
      expect(
        (again.path, downloader.started.length),
        (installed.path, 1),
        reason: 'an installed model completes at once',
      );
      final late = await models.watch('test-2b').first;
      expect(late.state, ModelState.ready);
      await watching.cancel();
      await models.dispose();
    },
  );

  test('install throws ModelInstallException with the error, the problem, or canceled', () async {
    final models = manager();
    await models.init();

    probe.hashOf = (_) async => '0' * 64;
    final bad = expectLater(
      models.install('test-4b'),
      throwsA(
        isA<ModelInstallException>()
            .having((e) => e.error?.code, 'error code', ModelErrorCode.integrity)
            .having((e) => e.canceled, 'canceled', isFalse),
      ),
    );
    await until(() => downloader.lastStart('test-4b') != null);
    downloader.finish('test-4b', testModelBytes['test-4b']!);
    await bad;
    probe.hashOf = null;

    const failure = DownloadError(DownloadErrorCode.httpStatus, httpStatus: 503);
    final dropped = expectLater(
      models.install('test-2b'),
      throwsA(
        isA<ModelInstallException>().having(
          (e) => e.error,
          'error',
          const ModelError(ModelErrorCode.download, download: failure),
        ),
      ),
    );
    await until(() => downloader.lastStart('test-2b') != null);
    downloader.emit(const ModelDownloadUpdate(id: 'test-2b', state: ModelDownloadState.failed, error: failure));
    await dropped;

    final canceled = expectLater(
      models.install('test-4b'),
      throwsA(isA<ModelInstallException>().having((e) => e.canceled, 'canceled', isTrue)),
    );
    await until(() => models.statusOf('test-4b').state == ModelState.queued);
    await models.cancel('test-4b');
    await canceled;

    probe.caps = const DeviceCapabilities(physicalMemoryMB: 4000, availableMemoryMB: 3000, freeDiskMB: 50000);
    await expectLater(
      models.install('test-4b'),
      throwsA(isA<ModelInstallException>().having((e) => e.problem, 'problem', const NotEnoughRam(7000))),
    );
    await expectLater(models.install('nope'), throwsArgumentError);

    probe.caps = FakeDeviceProbe.defaultCapabilities;
    final pending = expectLater(models.install('test-2b'), throwsStateError, reason: 'dispose ends a pending install');
    await until(() => models.statusOf('test-2b').isActive);
    await models.dispose();
    await pending;
  });

  test('install during a retry that is still starting waits for it, not for the failure before it', () async {
    final slow = _SlowProbe(probe);
    final models = ModelManager(
      root: () async => tmp.path,
      probe: slow,
      downloader: downloader,
      catalog: ModelCatalog.bundled(() async => testManifestJson()),
    );
    await models.init();
    const failure = DownloadError(DownloadErrorCode.connection);
    final first = expectLater(models.install('test-2b'), throwsA(isA<ModelInstallException>()));
    await until(() => downloader.lastStart('test-2b') != null);
    downloader.emit(const ModelDownloadUpdate(id: 'test-2b', state: ModelDownloadState.failed, error: failure));
    await first;
    expect(models.statusOf('test-2b').error, const ModelError(ModelErrorCode.download, download: failure));

    // The retry waits on the probe, as it does on a phone (a channel round trip), while two installs join it.
    slow.hold();
    final retry = models.download('test-2b');
    final seen = <ModelState>[];
    final installs = [models.install('test-2b', onProgress: (s) => seen.add(s.state)), models.install('test-2b')];
    Object? stale;
    for (final install in installs) {
      unawaited(install.then<void>((_) {}, onError: (Object e) => stale = e));
    }
    await pumpEventQueue();
    expect(stale, isNull, reason: 'the failure before the retry is not its outcome');
    slow.release();
    await retry;
    expect(downloader.resumed, ['test-2b'], reason: 'the failed download resumes once');
    downloader.finish('test-2b', testModelBytes['test-2b']!);
    final installed = await Future.wait(installs);
    expect(installed.map((m) => m.entry.id), ['test-2b', 'test-2b']);
    expect(seen, isNot(contains(ModelState.failed)), reason: 'onProgress skips the failure before the retry');
    expect(seen, containsAllInOrder([ModelState.queued, ModelState.verifying, ModelState.ready]));
    await models.dispose();
  });

  test('every ModelProblem, in order; an installed model skips the disk check and the preflight', () async {
    final entries = [
      ModelEntry(
        id: 'gone',
        url: Uri.parse('https://example.org/gone.gguf'),
        sizeBytes: 10,
        availability: ModelAvailability.deprecated,
      ),
      ModelEntry(
        id: 'big',
        url: Uri.parse('https://example.org/big.gguf'),
        sizeBytes: 10,
        minPhysicalRamMB: 16000,
        minAvailableMemoryMB: 9000,
        minFreeDiskMB: 60000,
      ),
    ];
    final refused = <String>[];
    final models = manager(
      catalog: ModelCatalog.fixed(ModelManifest(models: entries)),
      preflight: (entry, device) {
        refused.add(entry.id);
        return const HostRefused('solo sui telefoni aziendali');
      },
    );
    await models.init();
    final gone = models.entryFor('gone')!;
    final big = models.entryFor('big')!;
    expect(models.problemFor(gone), const NotOffered());
    expect(models.problemFor(big), const NotEnoughRam(16000));
    probe.caps = const DeviceCapabilities(physicalMemoryMB: 16384, availableMemoryMB: 5960, freeDiskMB: 50000);
    await models.refreshCapabilities();
    expect(models.problemFor(big), const NotEnoughMemory(9000, 5960));
    probe.caps = const DeviceCapabilities(physicalMemoryMB: 16384, availableMemoryMB: 12000, freeDiskMB: 50000);
    await models.refreshCapabilities();
    expect(models.problemFor(big), const NotEnoughDisk(60000, 50000));
    expect(refused, isEmpty, reason: 'the preflight comes last');
    probe.caps = const DeviceCapabilities(physicalMemoryMB: 16384, availableMemoryMB: 12000, freeDiskMB: 70000);
    await models.refreshCapabilities();
    expect(models.problemFor(big), const HostRefused('solo sui telefoni aziendali'));
    expect(refused, ['big']);
    await models.download('big');
    expect(models.statusOf('big').problem, const HostRefused('solo sui telefoni aziendali'));
    expect(downloader.started, isEmpty);
    await models.dispose();

    // The same entry, installed: memory still counts, disk and preflight do not.
    File(p.join(tmp.path, 'models', 'big', 'big.gguf'))
      ..createSync(recursive: true)
      ..writeAsBytesSync([...'GGUF'.codeUnits, ...List.filled(6, 7)]);
    final later = manager(
      catalog: ModelCatalog.fixed(ModelManifest(models: entries)),
      preflight: (entry, device) => const HostRefused('no'),
    );
    probe.caps = const DeviceCapabilities(physicalMemoryMB: 16384, availableMemoryMB: 12000, freeDiskMB: 1);
    await later.init();
    await until(() => later.statusOf('big').state == ModelState.ready, reason: 'no sha256: checked by size alone');
    expect(later.problemFor(big), isNull);
    probe.caps = const DeviceCapabilities(physicalMemoryMB: 8000, availableMemoryMB: 12000, freeDiskMB: 1);
    await later.refreshCapabilities();
    expect(later.problemFor(big), const NotEnoughRam(16000));
    await later.dispose();
  });

  test('catalogs: fixed and single are used as given; bundled fetches the remote copy with fetchManifest', () async {
    final entry = ModelEntry(id: 'one', url: Uri.parse('https://example.org/one.gguf'), sizeBytes: 10);
    final single = manager(catalog: ModelCatalog.single(entry));
    await single.init();
    expect(single.catalogOrigin, CatalogOrigin.fixed);
    expect(single.entries, [entry]);
    expect(single.catalogError, isNull);
    await single.dispose();

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final cacheControl = <String?>[];
    server.listen((request) async {
      cacheControl.add(request.headers.value(HttpHeaders.cacheControlHeader));
      request.response.write(testManifestJson(manifestVersion: 'remote', withSmall: false));
      await request.response.close();
    });
    addTearDown(() => server.close(force: true));
    final bundled = manager(
      catalog: ModelCatalog.bundled(
        () async => testManifestJson(),
        remote: Uri.parse('http://127.0.0.1:${server.port}/manifest.json'),
      ),
    );
    await bundled.init();
    expect((bundled.catalogOrigin, bundled.manifest.manifestVersion), (CatalogOrigin.remote, 'remote'));
    expect(cacheControl, ['no-cache']);
    await bundled.dispose();
  });

  test('forDirectory: DartDeviceProbe and HttpModelDownloader download, check and install a model', () async {
    final bytes = testModelBytes['test-4b']!;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response
        ..headers.contentType = ContentType.binary
        ..contentLength = bytes.length
        ..add(bytes);
      await request.response.close();
    });
    addTearDown(() => server.close(force: true));
    final entry = ModelEntry(
      id: 'http',
      url: Uri.parse('http://127.0.0.1:${server.port}/files/http-Q4_0.gguf'),
      sizeBytes: bytes.length,
      sha256: '${crypto.sha256.convert(bytes)}',
    );
    final models = ModelManager.forDirectory(tmp.path, catalog: ModelCatalog.single(entry));
    expect(models.probe, isA<DartDeviceProbe>());
    expect(models.downloader, isA<HttpModelDownloader>());
    final installed = await models.install('http');
    expect(installed.path, p.join(tmp.path, 'models', 'http', 'http-Q4_0.gguf'));
    expect(File(installed.path).readAsBytesSync(), bytes);
    expect(models.capabilities.isUnknown, isTrue);
    await models.dispose();
    await expectLater(
      (models.downloader as HttpModelDownloader).start(entry, directory: tmp.path, partFileName: 'x', wifiOnly: false),
      throwsStateError,
      reason: 'dispose closed the downloader it created',
    );
  });
}

/// [FakeDeviceProbe] whose capabilities wait while [hold] is on, like a platform channel that is slow to answer.
final class _SlowProbe implements DeviceProbe {
  _SlowProbe(this.inner);

  final FakeDeviceProbe inner;
  Completer<void>? _held;

  void hold() => _held = Completer<void>();

  void release() {
    _held?.complete();
    _held = null;
  }

  @override
  Future<DeviceCapabilities> capabilities() async {
    await _held?.future;
    return inner.capabilities();
  }

  @override
  Future<String> sha256(String path) => inner.sha256(path);

  @override
  Future<void> excludeFromBackup(String path) => inner.excludeFromBackup(path);
}
