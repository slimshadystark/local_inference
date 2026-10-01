// Resuming in ModelManager: a failed download resumes the data the downloader kept, also after a relaunch, while the
// network rule it started with holds (kept in downloads.json), and starts again otherwise or when the kept data turns
// out unusable; a file without the GGUF header is not a model and is never hashed; every failure has a code and,
// where there is one, a detail.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:local_inference/local_inference.dart';
import 'package:local_inference/testing.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/until.dart';

final List<int> bigBytes = testModelBytes['test-4b']!;
const connection = DownloadError(DownloadErrorCode.connection);

ModelDownloadUpdate failedUpdate(String id, [DownloadError? error = connection]) =>
    ModelDownloadUpdate(id: id, state: ModelDownloadState.failed, error: error);

/// The test manifest with the file of [id] at another URL.
String movedFile(String id) {
  final manifest = jsonDecode(testManifestJson()) as Map<String, dynamic>;
  for (final model in manifest['models'] as List) {
    if (model['id'] == id) model['file']['url'] = 'https://example.org/models/v2/$id-Q5_K_M.gguf';
  }
  return jsonEncode(manifest);
}

void main() {
  late Directory tmp;
  late FakeDeviceProbe probe;
  late FakeModelDownloader downloader;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('resume_test');
    probe = FakeDeviceProbe();
    downloader = FakeModelDownloader();
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  ModelManager manager({ModelDownloader? using, Future<String?> Function(Uri url)? fetch}) => ModelManager(
    root: () async => tmp.path,
    probe: probe,
    downloader: using ?? downloader,
    catalog: ModelCatalog.bundled(
      () async => testManifestJson(),
      remote: fetch == null ? null : Uri.parse('https://example.org/models/manifest.json'),
      fetch: fetch,
    ),
  );

  File downloadsFile() => File(p.join(tmp.path, 'models', 'downloads.json'));
  Object? rules() => downloadsFile().existsSync() ? jsonDecode(downloadsFile().readAsStringSync()) : null;
  String part(String id) => p.join(tmp.path, 'models', id, '$id-Q5_K_M.gguf.part');

  test('a web page or a file without the GGUF header fails as notAModelFile before it is hashed', () async {
    final models = manager();
    await models.init();
    await models.download('test-4b');
    downloader.finish('test-4b', utf8.encode(' \n<!doctype html><html><body>Sign in</body></html>'));
    await until(() => models.statusOf('test-4b').state == ModelState.failed);
    expect(models.statusOf('test-4b').error, const ModelError(ModelErrorCode.notAModelFile, detail: 'a web page'));
    expect(File(part('test-4b')).existsSync(), isFalse);

    await models.download('test-4b');
    downloader.finish('test-4b', List.filled(bigBytes.length, 0x41));
    await until(() => models.statusOf('test-4b').state == ModelState.failed);
    expect(models.statusOf('test-4b').error, const ModelError(ModelErrorCode.notAModelFile, detail: 'no GGUF header'));
    expect(File(part('test-4b')).existsSync(), isFalse);
    expect(probe.hashed, isEmpty, reason: 'never a hash of a web page');

    // The downloader's own verdict on a file that is no model.
    await models.download('test-4b');
    downloader.emit(failedUpdate('test-4b', DownloadError.notAGgufFile));
    await until(() => models.statusOf('test-4b').state == ModelState.failed);
    expect(
      models.statusOf('test-4b').error,
      const ModelError(ModelErrorCode.notAModelFile, download: DownloadError.notAGgufFile),
    );
    await models.dispose();
  });

  test('restore is told where each model of the manifest would be written', () async {
    final models = manager();
    await models.init();
    expect(downloader.restoredTargets, [
      for (final entry in models.entries)
        DownloadTarget(
          entry,
          directory: p.join(tmp.path, 'models', entry.id),
          partFileName: '${entry.id}-Q5_K_M.gguf.part',
        ),
    ]);
    await models.dispose();
  });

  test('after a relaunch, trying again resumes the kept data while the rule the download started with holds', () async {
    final first = manager();
    await first.init();
    await first.download('test-4b');
    await first.download('test-2b', allowCellular: true);
    expect(rules(), {
      'test-4b': {'wifiOnly': true, 'cellularConsent': false},
      'test-2b': {'wifiOnly': false, 'cellularConsent': true},
    });
    downloader
      ..emit(failedUpdate('test-4b'))
      ..emit(failedUpdate('test-2b'));
    await until(() => first.statusOf('test-2b').state == ModelState.failed);
    await first.dispose();

    // The downloader reports the failed downloads whose data it kept.
    final relaunched = FakeModelDownloader()..restored.addAll([failedUpdate('test-4b'), failedUpdate('test-2b')]);
    final again = manager(using: relaunched);
    await again.init();
    await until(() => again.statusOf('test-2b').state == ModelState.failed);
    expect(again.statusOf('test-4b').error, const ModelError(ModelErrorCode.download, download: connection));
    await again.download('test-4b');
    await again.download('test-2b');
    expect(relaunched.calls, ['restore', 'canResume test-4b', 'resume test-4b', 'canResume test-2b', 'resume test-2b']);
    expect(again.statusOf('test-4b').state, ModelState.downloading);
    await again.dispose();
  });

  test('after a relaunch, a download whose rule no longer holds starts again under the current rule', () async {
    final first = manager();
    await first.init();
    await first.download('test-4b');
    downloader.emit(failedUpdate('test-4b'));
    await until(() => first.statusOf('test-4b').state == ModelState.failed);
    await first.setWifiOnly(false);
    await first.dispose();

    final relaunched = FakeModelDownloader()..restored.add(failedUpdate('test-4b'));
    final again = manager(using: relaunched);
    await again.init();
    await until(() => again.statusOf('test-4b').state == ModelState.failed);
    await again.download('test-4b');
    expect(relaunched.calls, ['restore', 'canResume test-4b', 'discard test-4b', 'start test-4b wifiOnly=false']);
    expect(rules(), {
      'test-4b': {'wifiOnly': false, 'cellularConsent': false},
    });
    await again.dispose();
  });

  test('a failed download whose rule was never recorded (an earlier version started it) resumes', () async {
    final relaunched = FakeModelDownloader()..restored.add(failedUpdate('test-4b'));
    final models = manager(using: relaunched);
    await models.init();
    await until(() => models.statusOf('test-4b').state == ModelState.failed);
    expect(rules(), isNull);
    await models.download('test-4b');
    expect(relaunched.calls, ['restore', 'canResume test-4b', 'resume test-4b']);
    await models.dispose();
  });

  test('a download on mobile data the user agreed to keeps that consent when it is tried again', () async {
    final models = manager();
    await models.init();
    await models.download('test-4b');
    downloader.emit(const ModelDownloadUpdate(id: 'test-4b', state: ModelDownloadState.waitingForWifi));
    await until(() => models.statusOf('test-4b').state == ModelState.waitingForWifi);
    await models.download('test-4b', allowCellular: true);
    expect(downloader.calls.last, 'start test-4b wifiOnly=false');

    // Nothing kept (an error status, or a failure before the first byte): it starts again on mobile data.
    downloader
      ..canResumeResult = false
      ..emit(failedUpdate('test-4b', const DownloadError(DownloadErrorCode.httpStatus, httpStatus: 503)));
    await until(() => models.statusOf('test-4b').state == ModelState.failed);
    await models.download('test-4b');
    expect(downloader.calls.sublist(downloader.calls.length - 3), [
      'canResume test-4b',
      'discard test-4b',
      'start test-4b wifiOnly=false',
    ]);
    expect(rules(), {
      'test-4b': {'wifiOnly': false, 'cellularConsent': true},
    });

    // Kept data that turns out unusable: the automatic restart keeps the consent too.
    downloader.canResumeResult = null;
    downloader.emit(failedUpdate('test-4b'));
    await until(() => models.statusOf('test-4b').state == ModelState.failed);
    await models.download('test-4b');
    expect(downloader.calls.last, 'resume test-4b');
    downloader.emit(failedUpdate('test-4b', const DownloadError(DownloadErrorCode.cannotResume)));
    await until(() => downloader.calls.last == 'start test-4b wifiOnly=false', reason: 'restarted on mobile data');
    await models.dispose();
  });

  test('a rule is kept only until the model is ready, canceled or deleted', () async {
    final models = manager();
    await models.init();
    await models.download('test-4b');
    await models.download('test-2b');
    expect((rules()! as Map).keys, ['test-4b', 'test-2b']);
    downloader.finish('test-4b', bigBytes);
    await until(() => models.statusOf('test-4b').state == ModelState.ready);
    await until(() => (rules()! as Map).keys.single == 'test-2b');
    await models.cancel('test-2b');
    expect(downloadsFile().existsSync(), isFalse);

    await models.download('test-2b');
    downloader.emit(failedUpdate('test-2b'));
    await until(() => models.statusOf('test-2b').state == ModelState.failed);
    await models.delete('test-2b');
    expect(downloadsFile().existsSync(), isFalse);
    expect(downloader.calls.last, 'discard test-2b', reason: 'the kept data of a failed download goes too');

    downloadsFile().writeAsStringSync('not json');
    final damaged = manager(using: FakeModelDownloader());
    await damaged.init();
    await damaged.dispose();
    await models.dispose();
  });

  test('with a model installed, a failure reported at launch does not keep the remote manifest out', () async {
    final first = manager();
    await first.init();
    await first.download('test-4b');
    downloader.finish('test-4b', bigBytes);
    await until(() => first.statusOf('test-4b').state == ModelState.ready);
    await first.download('test-2b');
    downloader.emit(failedUpdate('test-2b'));
    await until(() => first.statusOf('test-2b').state == ModelState.failed);
    await first.dispose();

    final answer = Completer<String?>();
    final relaunched = FakeModelDownloader()..restored.add(failedUpdate('test-2b'));
    final again = manager(using: relaunched, fetch: (_) => answer.future);
    await again.init();
    expect((again.catalogOrigin, again.statusOf('test-2b').state), (CatalogOrigin.bundled, ModelState.failed));
    answer.complete(testManifestJson(manifestVersion: '2026-10-01'));
    await until(() => again.catalogOrigin == CatalogOrigin.remote, reason: 'not held back at every launch');
    expect(again.manifest.manifestVersion, '2026-10-01');
    await again.download('test-2b');
    expect(relaunched.calls, ['restore', 'canResume test-2b', 'resume test-2b']);
    await again.dispose();
  });

  test('a remote list that moves the file of a failed download discards the data kept for the old file', () async {
    final first = manager();
    await first.init();
    await first.download('test-4b');
    downloader.finish('test-4b', bigBytes);
    await until(() => first.statusOf('test-4b').state == ModelState.ready);
    await first.download('test-2b');
    downloader.emit(failedUpdate('test-2b'));
    await until(() => first.statusOf('test-2b').state == ModelState.failed);
    await first.dispose();

    final relaunched = FakeModelDownloader()..restored.add(failedUpdate('test-2b'));
    final again = manager(using: relaunched, fetch: (_) async => movedFile('test-2b'));
    await again.init();
    await until(() => again.catalogOrigin == CatalogOrigin.remote);
    await until(() => relaunched.calls.contains('discard test-2b'), reason: 'it could only resume the old file');
    await again.download('test-2b');
    expect(relaunched.calls.sublist(relaunched.calls.length - 3), [
      'canResume test-2b',
      'discard test-2b',
      'start test-2b wifiOnly=true',
    ]);
    expect('${relaunched.lastStart('test-2b')!.entry.url}', 'https://example.org/models/v2/test-2b-Q5_K_M.gguf');
    await again.dispose();

    // A later list withdraws it: its failure, its data and its rule go.
    final withdrawing = FakeModelDownloader()..restored.add(failedUpdate('test-2b'));
    final later = manager(using: withdrawing, fetch: (_) async => testManifestJson(withSmall: false));
    await later.init();
    expect(later.statusOf('test-2b').state, ModelState.failed, reason: 'the bundled list still has it');
    await until(() => later.catalogOrigin == CatalogOrigin.remote);
    await until(() => withdrawing.calls.contains('discard test-2b'));
    expect(later.statusOf('test-2b').state, ModelState.notDownloaded);
    expect(downloadsFile().existsSync(), isFalse);
    await later.dispose();
  });

  test('with the remote list, the kept data and the rule of a model it withdrew go', () async {
    final first = manager();
    await first.init();
    await first.download('test-2b');
    downloader.emit(failedUpdate('test-2b'));
    await until(() => first.statusOf('test-2b').state == ModelState.failed);
    await first.dispose();
    expect((rules()! as Map).keys, ['test-2b']);

    final relaunched = FakeModelDownloader()..restored.add(failedUpdate('test-2b'));
    final online = manager(using: relaunched, fetch: (_) async => testManifestJson(withSmall: false));
    await online.init();
    expect(online.catalogOrigin, CatalogOrigin.remote);
    await until(() => relaunched.calls.contains('discard test-2b'));
    expect(downloadsFile().existsSync(), isFalse);
    await online.dispose();
  });

  test('without kept data a failed download is discarded and starts again; cancel discards it too', () async {
    final models = manager();
    await models.init();
    await models.download('test-4b');
    downloader
      ..emit(failedUpdate('test-4b'))
      ..canResumeResult = false;
    await until(() => models.statusOf('test-4b').state == ModelState.failed);
    await models.download('test-4b');
    expect(downloader.calls.sublist(2), ['canResume test-4b', 'discard test-4b', 'start test-4b wifiOnly=true']);

    downloader.emit(failedUpdate('test-4b'));
    await until(() => models.statusOf('test-4b').state == ModelState.failed);
    await models.cancel('test-4b');
    expect(downloader.calls.last, 'discard test-4b');
    expect(models.statusOf('test-4b').state, ModelState.notDownloaded);
    await models.dispose();
  });

  test('a retry whose kept data turns out unusable starts again; after some progress the failure shows', () async {
    final models = manager();
    await models.init();
    await models.download('test-4b');
    downloader.emit(failedUpdate('test-4b'));
    await until(() => models.statusOf('test-4b').state == ModelState.failed);
    await models.download('test-4b');
    expect(downloader.calls.last, 'resume test-4b');
    downloader.emit(failedUpdate('test-4b', const DownloadError(DownloadErrorCode.cannotResume, detail: 'gone')));
    await until(() => downloader.calls.last == 'start test-4b wifiOnly=true', reason: 'resume, or else restart');
    expect(downloader.calls.sublist(2), [
      'canResume test-4b',
      'resume test-4b',
      'discard test-4b',
      'start test-4b wifiOnly=true',
    ]);
    expect(models.statusOf('test-4b').state, ModelState.queued);

    downloader.emit(failedUpdate('test-4b'));
    await until(() => models.statusOf('test-4b').state == ModelState.failed);
    await models.download('test-4b');
    downloader.emit(const ModelDownloadUpdate(id: 'test-4b', state: ModelDownloadState.running, progress: 0.5));
    const cannotResume = DownloadError(DownloadErrorCode.cannotResume);
    downloader.emit(failedUpdate('test-4b', cannotResume));
    await until(() => models.statusOf('test-4b').state == ModelState.failed);
    expect(models.statusOf('test-4b').error, const ModelError(ModelErrorCode.download, download: cannotResume));
    expect(downloader.calls.last, 'resume test-4b', reason: 'the data was usable: no restart');
    await models.dispose();
  });

  test('a resume the downloader refuses: kept data starts again, a paused download fails as cannotResume', () async {
    final refusing = _RefusingResume(downloader);
    final models = manager(using: refusing);
    await models.init();
    await models.download('test-4b');
    downloader.emit(failedUpdate('test-4b'));
    await until(() => models.statusOf('test-4b').state == ModelState.failed);
    await models.download('test-4b');
    expect(downloader.calls.sublist(2), ['canResume test-4b', 'discard test-4b', 'start test-4b wifiOnly=true']);

    downloader.emit(const ModelDownloadUpdate(id: 'test-4b', state: ModelDownloadState.paused, progress: 0.3));
    await until(() => models.statusOf('test-4b').state == ModelState.paused);
    await models.resume('test-4b');
    expect(
      models.statusOf('test-4b').error,
      const ModelError(ModelErrorCode.cannotResume, detail: 'Bad state: the task is gone'),
    );
    await models.dispose();
  });

  test('an installed model whose download fails again has the kept data discarded', () async {
    final models = manager();
    await models.init();
    await models.download('test-4b');
    downloader.finish('test-4b', bigBytes);
    await until(() => models.statusOf('test-4b').state == ModelState.ready);
    downloader.emit(failedUpdate('test-4b'));
    await until(() => downloader.calls.last == 'discard test-4b');
    expect(models.statusOf('test-4b').state, ModelState.ready);
    await models.dispose();
  });

  test('forDirectory across launches: the part file an earlier process left resumes with a Range request', () async {
    final bytes = testModelBytes['test-4b']!;
    final half = bytes.length ~/ 2;
    final ranges = <String?>[];
    final ifRanges = <String?>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final range = request.headers.value(HttpHeaders.rangeHeader);
      ranges.add(range);
      ifRanges.add(request.headers.value(HttpHeaders.ifRangeHeader));
      final start = int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range ?? 'bytes=0-')!.group(1)!);
      request.response
        ..statusCode = start > 0 ? HttpStatus.partialContent : HttpStatus.ok
        ..headers.contentType = ContentType.binary;
      if (start > 0) {
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-${bytes.length - 1}/${bytes.length}',
        );
      }
      request.response
        ..contentLength = bytes.length - start
        ..add(bytes.sublist(start));
      await request.response.close();
    });
    addTearDown(() => server.close(force: true));
    final test = ModelManifest.parse(testManifestJson()).models;
    final local = ModelEntry(
      id: 'test-4b',
      url: Uri.parse('http://127.0.0.1:${server.port}/models/test-4b-Q5_K_M.gguf'),
      sizeBytes: bytes.length,
      sha256: test.first.sha256,
    );
    final catalog = ModelCatalog.fixed(ModelManifest(models: [local, test.last]));
    File(part('test-4b'))
      ..createSync(recursive: true)
      ..writeAsBytesSync(bytes.sublist(0, half));

    final models = ModelManager.forDirectory(tmp.path, catalog: catalog);
    await models.init();
    await until(() => models.statusOf('test-4b').state == ModelState.paused);
    expect(models.statusOf('test-4b').progress, closeTo(0.5, 0.01));
    expect(await models.downloader.canResume('test-4b'), isTrue);
    final installed = await models.install('test-4b');
    expect(File(installed.path).readAsBytesSync(), bytes);
    expect(ranges, ['bytes=$half-']);
    expect(ifRanges, [null], reason: 'the last validator died with the earlier process');
    await models.dispose();

    // Another launch: an installed model is not restored; a part file can be discarded.
    File(part('test-2b'))
      ..createSync(recursive: true)
      ..writeAsBytesSync([...'GGUF'.codeUnits, 1, 2]);
    final later = ModelManager.forDirectory(tmp.path, catalog: catalog);
    await later.init();
    // At once: the index keeps the host-built entry (an http URL, empty texts), so the file is not checked again.
    expect(later.statusOf('test-4b').state, ModelState.ready);
    await until(() => later.statusOf('test-2b').state == ModelState.paused);
    expect(later.statusOf('test-4b').state, ModelState.ready);
    await later.downloader.discard('test-2b');
    expect(File(part('test-2b')).existsSync(), isFalse);
    expect(await later.downloader.canResume('test-2b'), isFalse);
    await later.dispose();
  });

  test('ModelError and DownloadedContent', () {
    expect(
      const ModelError(ModelErrorCode.cannotSave, detail: 'x'),
      isNot(const ModelError(ModelErrorCode.cannotSave)),
    );
    expect('${const ModelError(ModelErrorCode.cannotSave, detail: 'x')}', 'ModelError(cannotSave: x)');
    expect(DownloadedContent.of(utf8.encode('GGUF\x03\x00')), DownloadedContent.gguf);
    expect(DownloadedContent.of(utf8.encode(' \r\n\t<html>')), DownloadedContent.webPage);
    expect(DownloadedContent.of(utf8.encode('<?xml')), DownloadedContent.webPage);
    expect(DownloadedContent.of(utf8.encode('GGU')), DownloadedContent.other);
    expect(DownloadedContent.of(utf8.encode(' GGUF')), DownloadedContent.other);
    expect(DownloadedContent.of(const []), DownloadedContent.other);
    expect(DownloadError.notAGgufFile, const DownloadError(DownloadErrorCode.unknown, detail: 'not a GGUF file'));
  });
}

/// A downloader whose resume throws, as a native call that fails does.
final class _RefusingResume implements ModelDownloader {
  _RefusingResume(this.inner);

  final FakeModelDownloader inner;

  @override
  Future<void> resume(String id) async => throw StateError('the task is gone');

  @override
  Future<void> start(
    ModelEntry entry, {
    required String directory,
    required String partFileName,
    required bool wifiOnly,
  }) => inner.start(entry, directory: directory, partFileName: partFileName, wifiOnly: wifiOnly);

  @override
  Future<void> pause(String id) => inner.pause(id);

  @override
  Future<bool> canResume(String id) => inner.canResume(id);

  @override
  Future<void> discard(String id) => inner.discard(id);

  @override
  Future<void> cancel(String id) => inner.cancel(id);

  @override
  Stream<ModelDownloadUpdate> get updates => inner.updates;

  @override
  Future<void> restore({Iterable<DownloadTarget> targets = const []}) => inner.restore(targets: targets);
}
