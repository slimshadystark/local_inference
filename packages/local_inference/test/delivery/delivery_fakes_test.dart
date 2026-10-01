// The delivery doubles of package:local_inference/testing.dart: the test manifest and its files, the fake
// downloader's records and the fake probe's answers.
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:local_inference/local_inference.dart';
import 'package:local_inference/testing.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('testManifestJson parses; each entry names the size and SHA-256 of its testModelBytes', () {
    final manifest = ModelManifest.parse(testManifestJson());
    expect(manifest.models.map((m) => m.id), ['test-4b', 'test-2b']);
    for (final entry in manifest.models) {
      final bytes = testModelBytes[entry.id]!;
      expect((entry.sizeBytes, entry.sha256), (bytes.length, '${crypto.sha256.convert(bytes)}'));
    }
    final small = ModelManifest.parse(testManifestJson(withSmall: false, manifestVersion: 'v2'));
    expect((small.models.length, small.manifestVersion), (1, 'v2'));
    expect(fixedClock(DateTime.utc(2026))(), DateTime.utc(2026));
  });

  test('FakeModelDownloader records the calls and answers like a background downloader', () async {
    final tmp = Directory.systemTemp.createTempSync('delivery_fakes_test');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final entry = ModelManifest.parse(testManifestJson()).models.first;
    final downloader = FakeModelDownloader(canResumeResult: true, echoCancel: false)
      ..restored.add(const ModelDownloadUpdate(id: 'old', state: ModelDownloadState.paused));
    final states = <String>[];
    final subscription = downloader.updates.listen((u) => states.add('${u.id} ${u.state.name}'));
    addTearDown(subscription.cancel);
    await downloader.restore();
    await downloader.start(entry, directory: tmp.path, partFileName: entry.partFileName, wifiOnly: false);
    await downloader.pause('test-4b');
    await downloader.resume('test-4b');
    expect(await downloader.canResume('test-4b'), isTrue);
    await downloader.discard('test-4b');
    await downloader.cancel('test-4b');
    downloader.finish('test-4b', [1, 2, 3]);
    await Future<void>.delayed(Duration.zero);
    expect(downloader.calls, [
      'restore',
      'start test-4b wifiOnly=false',
      'pause test-4b',
      'resume test-4b',
      'canResume test-4b',
      'discard test-4b',
      'cancel test-4b',
    ]);
    for (final ids in [downloader.paused, downloader.resumed, downloader.discarded, downloader.canceled]) {
      expect(ids, ['test-4b']);
    }
    expect(states, ['old paused', 'test-4b queued', 'test-4b paused', 'test-4b running', 'test-4b complete']);
    expect(File(p.join(tmp.path, entry.partFileName)).readAsBytesSync(), [1, 2, 3]);
    expect(downloader.lastStart('test-4b')!.path, p.join(tmp.path, entry.partFileName));
  });

  test('FakeModelDownloader keeps the data of a failed download until it starts, resumes, goes or finishes', () async {
    final tmp = Directory.systemTemp.createTempSync('delivery_fakes_test');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final entry = ModelManifest.parse(testManifestJson()).models.first;
    final downloader = FakeModelDownloader();
    const failed = ModelDownloadUpdate(id: 'test-4b', state: ModelDownloadState.failed);
    final target = DownloadTarget(entry, directory: tmp.path, partFileName: entry.partFileName);
    await downloader.restore(targets: [target]);
    expect(downloader.restoredTargets, [target]);
    expect(target.path, p.join(tmp.path, entry.partFileName));
    expect(await downloader.canResume('test-4b'), isFalse);
    for (final Future<void> Function() ends in [
      () => downloader.start(entry, directory: tmp.path, partFileName: entry.partFileName, wifiOnly: true),
      () => downloader.resume('test-4b'),
      () => downloader.discard('test-4b'),
      () => downloader.cancel('test-4b'),
      () async => downloader.finish('test-4b', [1]),
    ]) {
      downloader.emit(failed);
      expect(await downloader.canResume('test-4b'), isTrue);
      await ends();
      expect(await downloader.canResume('test-4b'), isFalse);
    }
    downloader
      ..emit(failed)
      ..canResumeResult = false;
    expect(await downloader.canResume('test-4b'), isFalse, reason: 'a fixed answer wins');
  });

  test('FakeDeviceProbe: settable capabilities, fixed or computed hashes, recorded paths', () async {
    final tmp = Directory.systemTemp.createTempSync('delivery_fakes_test');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final file = File(p.join(tmp.path, 'm.gguf'))..writeAsBytesSync([7, 7, 7]);
    final probe = FakeDeviceProbe(hashes: {'/fixed': 'f' * 64});
    expect(await probe.capabilities(), FakeDeviceProbe.defaultCapabilities);
    probe.caps = DeviceCapabilities.unknown;
    expect(await probe.capabilities(), DeviceCapabilities.unknown);
    expect(await probe.sha256('/fixed'), 'f' * 64);
    expect(await probe.sha256(file.path), '${crypto.sha256.convert([7, 7, 7])}');
    probe.hashOf = (path) async => 'computed';
    expect(await probe.sha256(file.path), 'computed');
    await probe.excludeFromBackup(file.path);
    expect(probe.hashed, ['/fixed', file.path, file.path]);
    expect(probe.excluded, [file.path]);
  });
}
