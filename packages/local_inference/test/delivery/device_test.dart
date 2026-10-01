// DeviceCapabilities from a plugin's map, the pure-Dart probe, and fetchManifest against a local server.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:local_inference/local_inference.dart';
import 'package:test/test.dart';

void main() {
  test('DeviceCapabilities.fromJson keeps non-negative numbers; anything else is unknown', () {
    final caps = DeviceCapabilities.fromJson({'physicalMemoryMB': 7622.0, 'availableMemoryMB': -1, 'freeDiskMB': 'x'});
    expect(caps, const DeviceCapabilities(physicalMemoryMB: 7622));
    expect(caps.isUnknown, isFalse);
    expect(DeviceCapabilities.fromJson(null), DeviceCapabilities.unknown);
    expect(DeviceCapabilities.unknown.isUnknown, isTrue);
    expect(const DeviceCapabilities(freeDiskMB: 10).isUnknown, isTrue, reason: 'only memory decides');
    const full = DeviceCapabilities(physicalMemoryMB: 1, availableMemoryMB: 2, freeDiskMB: 3);
    expect(DeviceCapabilities.fromJson(full.toJson()), full);
    expect('$full', 'DeviceCapabilities(physical: 1 MB, available: 2 MB, free disk: 3 MB)');
  });

  test('DartDeviceProbe: unknown capabilities, the SHA-256 in an isolate, no backup flag', () async {
    final tmp = Directory.systemTemp.createTempSync('device_test');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final bytes = utf8.encode('pretend weights' * 1000);
    final file = File('${tmp.path}/model.gguf')..writeAsBytesSync(bytes);
    const probe = DartDeviceProbe();
    expect(await probe.capabilities(), DeviceCapabilities.unknown);
    expect(await probe.sha256(file.path), '${crypto.sha256.convert(bytes)}');
    await probe.excludeFromBackup(file.path);
    await expectLater(probe.sha256('${tmp.path}/missing.gguf'), throwsA(isA<FileSystemException>()));
  });

  test('fetchManifest: the body of a 200 with no-cache; null for another status, a large body or no server', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final seen = <String?>[];
    server.listen((request) async {
      seen.add(request.headers.value(HttpHeaders.cacheControlHeader));
      switch (request.uri.path) {
        case '/ok.json':
          request.response.write('{"città": "Valmontana"}');
        case '/big.json':
          request.response.add(List.filled(2000, 0x20));
        default:
          request.response.statusCode = HttpStatus.notFound;
      }
      await request.response.close();
    });
    Uri url(String path) => Uri.parse('http://127.0.0.1:${server.port}$path');
    expect(await fetchManifest(url('/ok.json')), '{"città": "Valmontana"}');
    expect(await fetchManifest(url('/missing.json')), isNull);
    expect(await fetchManifest(url('/big.json'), maxBytes: 1000), isNull);
    expect(await fetchManifest(url('/big.json')), hasLength(2000));
    expect(seen, everyElement('no-cache'));

    final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = closed.port;
    await closed.close();
    expect(await fetchManifest(Uri.parse('http://127.0.0.1:$port/manifest.json')), isNull);
  });
}
