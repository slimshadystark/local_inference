// HttpModelDownloader against a local HttpServer: the default headers and a headers provider, Range + If-Range on
// resume, 206 appended and 200 started again, web pages and bodies without the GGUF magic refused before anything is
// written, retries, 404, cancel, canResume and discard, and a part file an earlier process left (restore).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:local_inference/local_inference.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/until.dart';

final List<int> body = utf8.encode('GGUF${'weights ' * 20000}');
final int half = body.length ~/ 2;

/// A local server whose [handle] answers request number `n` (from 0); it records every request's headers.
final class TestServer {
  TestServer._(this._server, this.handle);

  static Future<TestServer> start(Future<void> Function(HttpRequest request, int n) handle) async {
    final server = TestServer._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0), handle);
    server._server.listen((request) {
      final n = server.requests.length;
      server.requests.add(request.headers);
      unawaited(handle(request, n).catchError((Object _) {}));
    });
    return server;
  }

  final HttpServer _server;
  final Future<void> Function(HttpRequest request, int n) handle;
  final List<HttpHeaders> requests = [];

  Uri get url => Uri.parse('http://127.0.0.1:${_server.port}/model-Q4_0.gguf');

  Future<void> close() => _server.close(force: true);
}

/// The whole file, with a strong ETag.
Future<void> whole(HttpRequest request, {String etag = '"v1"'}) async {
  request.response
    ..headers.set(HttpHeaders.etagHeader, etag)
    ..headers.contentType = ContentType.binary
    ..contentLength = body.length
    ..add(body);
  await request.response.close();
}

/// The part after the Range header's start, as a 206.
Future<void> rest(HttpRequest request) async {
  final start = int.parse(
    RegExp(r'bytes=(\d+)-').firstMatch(request.headers.value(HttpHeaders.rangeHeader)!)!.group(1)!,
  );
  request.response
    ..statusCode = HttpStatus.partialContent
    ..headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-${body.length - 1}/${body.length}')
    ..headers.contentType = ContentType.binary
    ..contentLength = body.length - start
    ..add(body.sublist(start));
  await request.response.close();
}

/// Headers for the whole file and the first half of the body, then the connection is cut.
Future<void> cutHalfway(HttpRequest request) async {
  final socket = await request.response.detachSocket(writeHeaders: false);
  socket.add(
    ascii.encode(
      'HTTP/1.1 200 OK\r\ncontent-length: ${body.length}\r\netag: "v1"\r\n'
      'content-type: application/octet-stream\r\n\r\n',
    ),
  );
  socket.add(body.sublist(0, half));
  await socket.flush();
  socket.destroy();
}

/// Headers and the first half of the body, then nothing until [release] completes (then the rest).
Future<void> Function(HttpRequest request) stallHalfway(Completer<void> release) => (request) async {
  request.response
    ..headers.set(HttpHeaders.etagHeader, '"v1"')
    ..contentLength = body.length
    ..add(body.sublist(0, half));
  await request.response.flush();
  await release.future;
  request.response.add(body.sublist(half));
  await request.response.close();
};

void main() {
  late Directory tmp;
  late String part;
  late List<ModelDownloadUpdate> updates;
  late HttpModelDownloader downloader;
  StreamSubscription<ModelDownloadUpdate>? subscription;
  TestServer? server;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('http_downloader_test');
    part = p.join(tmp.path, 'models', 'm', 'model-Q4_0.gguf.part');
    updates = [];
  });
  tearDown(() async {
    await subscription?.cancel();
    await downloader.close();
    await server?.close();
    server = null;
    tmp.deleteSync(recursive: true);
  });

  HttpModelDownloader make({FutureOr<Map<String, String>> Function(ModelEntry entry)? headers, int retries = 3}) {
    downloader = HttpModelDownloader(headers: headers, retries: retries, retryDelay: const Duration(milliseconds: 5));
    subscription = downloader.updates.listen(updates.add);
    return downloader;
  }

  ModelEntry entry() => ModelEntry(id: 'm', url: server!.url, sizeBytes: body.length);

  Future<void> start() =>
      downloader.start(entry(), directory: p.dirname(part), partFileName: 'model-Q4_0.gguf.part', wifiOnly: true);

  List<ModelDownloadState> states() => [for (final u in updates) u.state];

  bool ended() =>
      updates.isNotEmpty && const {ModelDownloadState.complete, ModelDownloadState.failed}.contains(updates.last.state);

  test(
    'downloads the whole file into a new folder with the default headers, reports progress, then complete',
    () async {
      server = await TestServer.start((request, n) => whole(request));
      make();
      await start();
      await until(ended);
      expect(states().first, ModelDownloadState.queued);
      expect(states().last, ModelDownloadState.complete);
      expect(states(), contains(ModelDownloadState.running));
      final running = updates.firstWhere((u) => u.state == ModelDownloadState.running);
      expect(running.expectedBytes, body.length);
      expect(running.progress, inInclusiveRange(0, 1));
      expect(File(part).readAsBytesSync(), body);
      final headers = server!.requests.single;
      expect(headers.value('x-ms-version'), '2021-08-06');
      expect(headers.value(HttpHeaders.acceptEncodingHeader), 'identity');
      expect(headers.value(HttpHeaders.rangeHeader), isNull);
    },
  );

  test('the headers provider adds to the default headers; a key it gives wins', () async {
    server = await TestServer.start((request, n) => whole(request));
    make(headers: (entry) async => {'Authorization': 'Bearer ${entry.id}', 'x-ms-version': '2025-01-05'});
    await start();
    await until(ended);
    expect(states().last, ModelDownloadState.complete);
    final headers = server!.requests.single;
    expect(headers.value(HttpHeaders.authorizationHeader), 'Bearer m');
    expect(headers.value('x-ms-version'), '2025-01-05');
    expect(headers.value(HttpHeaders.acceptEncodingHeader), 'identity', reason: 'the stored bytes, not gzip');
  });

  test('a dropped connection is retried with Range and If-Range on the strong ETag; the 206 is appended', () async {
    server = await TestServer.start((request, n) => n == 0 ? cutHalfway(request) : rest(request));
    make();
    await start();
    await until(ended);
    expect(states().last, ModelDownloadState.complete);
    expect(File(part).readAsBytesSync(), body);
    expect(server!.requests, hasLength(2));
    expect(server!.requests.last.value(HttpHeaders.rangeHeader), 'bytes=$half-');
    expect(server!.requests.last.value(HttpHeaders.ifRangeHeader), '"v1"');
  });

  test('pause keeps the part file; resume asks for the rest, and a 200 (the file changed) starts it again', () async {
    final release = Completer<void>();
    server = await TestServer.start(
      (request, n) => n == 0 ? stallHalfway(release)(request) : whole(request, etag: '"v2"'),
    );
    make();
    await start();
    await until(() => File(part).existsSync() && File(part).lengthSync() == half);
    await downloader.pause('m');
    await until(() => states().last == ModelDownloadState.paused);
    expect(await downloader.canResume('m'), isTrue);
    expect(File(part).lengthSync(), half);

    await downloader.resume('m');
    await until(ended);
    expect(states().last, ModelDownloadState.complete);
    expect(server!.requests.last.value(HttpHeaders.rangeHeader), 'bytes=$half-');
    expect(File(part).readAsBytesSync(), body, reason: 'the 200 body replaced the part file');
    release.complete();
  });

  test('a text/html answer, or a body that starts with <, fails as a web page before anything is written', () async {
    server = await TestServer.start((request, n) async {
      if (n < 2) {
        request.response
          ..headers.contentType = ContentType.html
          ..write(n == 0 ? '<html>login</html>' : 'Sign in required');
      } else {
        request.response
          ..headers.contentType = ContentType.binary
          ..write(' \n <!doctype html><html></html>');
      }
      await request.response.close();
    });
    make();
    final details = <String?>[];
    for (var i = 0; i < 3; i++) {
      updates.clear();
      await start();
      await until(ended);
      expect(states().last, ModelDownloadState.failed);
      expect(updates.last.error!.code, DownloadErrorCode.webPageInsteadOfFile);
      details.add(updates.last.error!.detail);
      expect(File(part).existsSync(), isFalse);
    }
    expect(details, ['Content-Type text/html', 'Content-Type text/html', 'the body starts with <']);
    expect(server!.requests, hasLength(3), reason: 'a web page is not retried');
  });

  test('a GGUF entry whose body lacks the GGUF magic fails as not a GGUF file, before anything is written', () async {
    server = await TestServer.start((request, n) async {
      request.response
        ..headers.contentType = ContentType.binary
        ..add([0x50, 0x4b, 0x03, 0x04, ...List.filled(100, 1)]);
      await request.response.close();
    });
    make();
    await start();
    await until(ended);
    expect(updates.last.error, DownloadError.notAGgufFile);
    expect(File(part).existsSync(), isFalse);
    expect(server!.requests, hasLength(1), reason: 'not retried');

    updates.clear();
    final other = ModelEntry(id: 'm', url: server!.url, sizeBytes: 104, format: 'bin');
    await downloader.start(other, directory: p.dirname(part), partFileName: 'model-Q4_0.gguf.part', wifiOnly: false);
    await until(ended);
    expect(states().last, ModelDownloadState.complete, reason: 'another format takes any body');
  });

  test('restore reports a part file an earlier process left as paused; its resume starts again when the file '
      'changed size', () async {
    server = await TestServer.start((request, n) async {
      if (n > 0) return whole(request);
      final start = int.parse(RegExp(r'bytes=(\d+)-').firstMatch(request.headers.value('range')!)!.group(1)!);
      request.response
        ..statusCode = HttpStatus.partialContent
        ..headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-${body.length}/${body.length + 1}')
        ..contentLength = body.length + 1 - start
        ..add([...body.sublist(start), 0]);
      await request.response.close();
    });
    File(part)
      ..createSync(recursive: true)
      ..writeAsBytesSync(body.sublist(0, half));
    final complete = p.join(tmp.path, 'models', 'c', 'c.gguf.part');
    File(complete)
      ..createSync(recursive: true)
      ..writeAsBytesSync(body);
    make();
    DownloadTarget target(String id, String path) => DownloadTarget(
      ModelEntry(id: id, url: server!.url, sizeBytes: body.length),
      directory: p.dirname(path),
      partFileName: p.basename(path),
    );
    await downloader.restore(
      targets: [
        target('m', part),
        target('c', complete),
        target('none', p.join(tmp.path, 'models', 'none', 'none.gguf.part')),
      ],
    );
    await until(() => updates.isNotEmpty);
    expect(updates.single.id, 'm', reason: 'a complete file is left to the manager, a missing one is nothing');
    expect(updates.single.state, ModelDownloadState.paused);
    expect(updates.single.progress, closeTo(0.5, 0.001));
    expect(updates.single.expectedBytes, body.length);
    expect((await downloader.canResume('m'), await downloader.canResume('c')), (true, false));

    await downloader.resume('m');
    await until(ended);
    expect(states().last, ModelDownloadState.complete);
    expect(File(part).readAsBytesSync(), body);
    expect(server!.requests.first.value(HttpHeaders.rangeHeader), 'bytes=$half-');
    expect(server!.requests.first.value(HttpHeaders.ifRangeHeader), isNull, reason: 'no validator survives');
    expect(server!.requests.last.value(HttpHeaders.rangeHeader), isNull, reason: 'another size: started again');
  });

  test('a 503 is retried; a 404 is notFound at once; retries run out on a server that keeps failing', () async {
    server = await TestServer.start((request, n) async {
      request.response.statusCode = n < 2 ? HttpStatus.serviceUnavailable : HttpStatus.ok;
      if (n >= 2) {
        await whole(request);
        return;
      }
      await request.response.close();
    });
    make();
    await start();
    await until(ended);
    expect(states().last, ModelDownloadState.complete);
    expect(server!.requests, hasLength(3));
    await server!.close();

    server = await TestServer.start((request, n) async {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
    });
    updates.clear();
    await start();
    await until(ended);
    expect(updates.last.error, const DownloadError(DownloadErrorCode.notFound, httpStatus: 404));
    expect(server!.requests, hasLength(1));
    await server!.close();

    server = await TestServer.start((request, n) async {
      request.response.statusCode = HttpStatus.badGateway;
      await request.response.close();
    });
    updates.clear();
    await start();
    await until(ended);
    expect(updates.last.error, const DownloadError(DownloadErrorCode.httpStatus, httpStatus: 502));
    expect(server!.requests, hasLength(4), reason: 'the first attempt and 3 retries');
  });

  test('cancel stops the transfer, deletes the part file and reports canceled; discard deletes a paused one', () async {
    final release = Completer<void>();
    server = await TestServer.start((request, n) => stallHalfway(release)(request));
    make();
    await start();
    await until(() => File(part).existsSync() && File(part).lengthSync() == half);
    await downloader.cancel('m');
    await until(() => states().last == ModelDownloadState.canceled);
    expect(File(part).existsSync(), isFalse);
    expect(await downloader.canResume('m'), isFalse);

    await start();
    await until(() => File(part).existsSync() && File(part).lengthSync() == half);
    await downloader.pause('m');
    await downloader.discard('m');
    expect(File(part).existsSync(), isFalse);
    expect(await downloader.canResume('m'), isFalse);
    release.complete();

    updates.clear();
    await downloader.resume('other');
    await until(() => updates.isNotEmpty);
    expect(updates.single.error!.code, DownloadErrorCode.cannotResume);
  });

  test('a part file already complete is done when the server refuses the range (416)', () async {
    final release = Completer<void>();
    server = await TestServer.start((request, n) async {
      if (n == 0) return stallHalfway(release)(request);
      request.response
        ..statusCode = HttpStatus.requestedRangeNotSatisfiable
        ..headers.set(HttpHeaders.contentRangeHeader, 'bytes */${body.length}');
      await request.response.close();
    });
    make();
    await start();
    await until(() => File(part).existsSync() && File(part).lengthSync() == half);
    await downloader.pause('m');
    File(part).writeAsBytesSync(body);
    await downloader.resume('m');
    await until(ended);
    expect(states().last, ModelDownloadState.complete);
    expect(File(part).readAsBytesSync(), body);
    release.complete();
  });
}
