// The Listenable adapters of the model manager: ChangeSourceListenable forwards listeners unchanged (a rebuilt
// widget keeps its subscription), and ModelManagerWatcher fires each ValueListenable only when its value changes.
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_inference/testing.dart';
import 'package:local_inference_flutter/local_inference_flutter.dart';

class _Source implements ChangeSource {
  final listeners = <void Function()>[];

  @override
  void addListener(void Function() listener) => listeners.add(listener);

  @override
  void removeListener(void Function() listener) => listeners.remove(listener);

  void notify() {
    for (final listener in List.of(listeners)) {
      listener();
    }
  }
}

void main() {
  test('ChangeSourceListenable forwards the listener itself; two over one source are equal', () {
    final source = _Source();
    final listenable = ChangeSourceListenable(source);
    var calls = 0;
    void listener() => calls++;
    listenable.addListener(listener);
    expect(source.listeners.single, same(listener));
    source.notify();
    expect(calls, 1);
    ChangeSourceListenable(source).removeListener(listener);
    expect(source.listeners, isEmpty);
    expect(ChangeSourceListenable(source), ChangeSourceListenable(source));
    expect(ChangeSourceListenable(source).hashCode, ChangeSourceListenable(source).hashCode);
    expect(ChangeSourceListenable(source), isNot(ChangeSourceListenable(_Source())));
  });

  testWidgets('a ListenableBuilder over a new ChangeSourceListenable each build keeps one subscription', (
    tester,
  ) async {
    final source = _Source();
    var builds = 0;
    Widget app() => ListenableBuilder(
      listenable: ChangeSourceListenable(source),
      builder: (context, _) => Text('${builds++}', textDirection: TextDirection.ltr),
    );
    await tester.pumpWidget(app());
    await tester.pumpWidget(app());
    expect(source.listeners, hasLength(1));
    source.notify();
    await tester.pump();
    expect(builds, 3);
  });

  test('ModelManagerWatcher: ready, installed and each status notify only on a change of their own', () async {
    final tmp = Directory.systemTemp.createTempSync('adapters_test');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final downloader = FakeModelDownloader();
    final manager = ModelManager(
      root: () async => tmp.path,
      probe: FakeDeviceProbe(),
      downloader: downloader,
      catalog: ModelCatalog.bundled(() async => testManifestJson()),
    );
    final watcher = ModelManagerWatcher(manager);
    expect(watcher.ready.value, isFalse);
    expect(watcher.installed.value, isEmpty);
    final fired = <String>[];
    watcher.ready.addListener(() => fired.add('ready ${watcher.ready.value}'));
    watcher.installed.addListener(() => fired.add('installed ${watcher.installed.value.length}'));
    final big = watcher.status('test-4b');
    final small = watcher.status('test-2b');
    expect(identical(big, watcher.status('test-4b')), isTrue);
    big.addListener(() => fired.add('4b ${big.value.state.name}'));
    small.addListener(() => fired.add('2b ${small.value.state.name}'));
    var any = 0;
    watcher.listenable.addListener(() => any++);

    await manager.init();
    expect(fired, ['ready true']);
    await manager.download('test-4b');
    await Future<void>.delayed(Duration.zero);
    downloader.finish('test-4b', testModelBytes['test-4b']!);
    for (var i = 0; i < 200 && manager.statusOf('test-4b').state != ModelState.ready; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    expect(fired, ['ready true', '4b queued', '4b verifying', 'installed 1', '4b ready']);
    expect(watcher.installed.value.single.entry.id, 'test-4b');
    expect(small.value.state, ModelState.notDownloaded);
    expect(any, greaterThan(3));

    watcher.dispose();
    final before = fired.length;
    await manager.delete('test-4b');
    expect(fired, hasLength(before), reason: 'a disposed watcher no longer listens');
    await manager.dispose();
  });
}
