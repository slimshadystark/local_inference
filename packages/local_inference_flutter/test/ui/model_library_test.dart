// ModelLibrary: an installed model can be used and deleted after a confirmation,
// the Wi-Fi switch and the catalog's origin; nothing can be used or deleted while the chat loads or answers; free
// space is read again when it opens; forAssistant follows the chat's model; a tile builder replaces the cards.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_inference/testing.dart';
import 'package:local_inference_flutter/local_inference_flutter.dart';

import '../support/toy_chat.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('model_library_test'));
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<(ModelManager, FakeModelDownloader)> installed(WidgetTester tester, {FakeDeviceProbe? probe}) async {
    final downloader = FakeModelDownloader();
    final manager = ModelManager(
      root: () async => tmp.path,
      probe: probe ?? FakeDeviceProbe(),
      downloader: downloader,
      catalog: ModelCatalog.bundled(() async => testManifestJson()),
    );
    addTearDown(manager.dispose);
    await tester.runAsync(() async {
      await manager.init();
      await manager.download('test-4b');
      await Future<void>.delayed(Duration.zero);
      downloader.finish('test-4b', testModelBytes['test-4b']!);
      for (var i = 0; i < 500 && manager.statusOf('test-4b').state != ModelState.ready; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
    });
    return (manager, downloader);
  }

  Future<void> show(WidgetTester tester, Widget library) async {
    usePhoneSurface(tester);
    await tester.pumpWidget(
      app(
        LocalInferenceScope(
          strings: LocalInferenceStrings.italian,
          child: Scaffold(
            body: SingleChildScrollView(padding: const EdgeInsets.all(16), child: library),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('an installed model can be used and deleted; the Wi-Fi switch; where the list came from', (tester) async {
    final (manager, _) = await installed(tester);
    final used = <String>[];
    await show(tester, ModelLibrary(manager: manager, onUseModel: (model) => used.add(model.path)));
    expect(find.text('Modelli sul dispositivo'), findsOneWidget);
    expect(find.text('test-4b'), findsOneWidget);
    expect(find.text('Pronto'), findsOneWidget);
    expect(find.text('Consigliato'), findsOneWidget);
    expect(find.text('Non scaricato'), findsOneWidget);
    expect(find.text("Elenco modelli: incluso nell'app"), findsOneWidget);

    await tester.tap(find.byKey(LocalInferenceKeys.libraryUse('test-4b')));
    expect(used, [manager.pathOf('test-4b')]);

    await tester.tap(find.text('Scarica solo con Wi-Fi'));
    await pumpUntil(tester, () => !manager.wifiOnly, reason: 'switched off');

    await tester.tap(find.byKey(LocalInferenceKeys.libraryDelete('test-4b')));
    await tester.pumpAndSettle();
    expect(find.text('Elimino il modello?'), findsOneWidget);
    expect(find.text('Lo spazio torna libero subito.'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Elimina').last);
    final dir = Directory(manager.modelsDirectoryFor('test-4b'));
    await pumpUntil(tester, () => !dir.existsSync() && find.text('Pronto').evaluate().isEmpty, reason: 'deleted');
    await tester.pumpAndSettle();
    expect(find.text('Pronto'), findsNothing);
    expect(find.text('Nessuno'), findsOneWidget);
    expect(find.text('Scarica'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('locked while the chat loads a model: nothing can be used or deleted', (tester) async {
    final (manager, _) = await installed(tester);
    await show(tester, ModelLibrary(manager: manager, locked: true, onUseModel: (_) {}));
    expect(tester.widget<TextButton>(find.byKey(LocalInferenceKeys.libraryUse('test-4b'))).onPressed, isNull);
    expect(tester.widget<TextButton>(find.byKey(LocalInferenceKeys.libraryDelete('test-4b'))).onPressed, isNull);
  });

  testWidgets('it reads free space again when opened, so a download refused for space can start', (tester) async {
    final probe = FakeDeviceProbe(
      capabilities: const DeviceCapabilities(physicalMemoryMB: 7622, availableMemoryMB: 5960, freeDiskMB: 10),
    );
    final manager = ModelManager(
      root: () async => tmp.path,
      probe: probe,
      downloader: FakeModelDownloader(),
      catalog: ModelCatalog.bundled(() async => testManifestJson()),
    );
    addTearDown(manager.dispose);
    await tester.runAsync(manager.init);
    expect(manager.problemFor(manager.entries.first), isA<NotEnoughDisk>());
    probe.caps = const DeviceCapabilities(physicalMemoryMB: 7622, availableMemoryMB: 5960, freeDiskMB: 50000);
    await show(tester, ModelLibrary(manager: manager));
    await pumpUntil(tester, () => manager.capabilities.freeDiskMB == 50000, reason: 'read again');
    expect(find.textContaining('Spazio libero insufficiente'), findsNothing);
    expect(tester.widget<TextButton>(find.widgetWithText(TextButton, 'Scarica').first).onPressed, isNotNull);
  });

  testWidgets('forAssistant: the chat\'s model is in use and cannot be deleted; "Use" loads another', (tester) async {
    final (manager, downloader) = await installed(tester);
    final (controller, _) = await toyController(tester, load: false);
    await show(tester, ModelLibrary.forAssistant(controller, manager: manager));
    await tester.tap(find.byKey(LocalInferenceKeys.libraryUse('test-4b')));
    await pumpUntil(tester, () => controller.phase.value == AssistantPhase.ready, reason: 'loaded');
    expect(controller.assistant.state.modelPath, manager.pathOf('test-4b'));
    expect(find.text('In uso'), findsOneWidget);
    expect(tester.widget<TextButton>(find.byKey(LocalInferenceKeys.libraryDelete('test-4b'))).onPressed, isNull);
    expect(find.byKey(LocalInferenceKeys.libraryUse('test-4b')), findsOneWidget);
    expect(tester.widget<TextButton>(find.byKey(LocalInferenceKeys.libraryUse('test-4b'))).onPressed, isNull);
    downloader.calls.clear();
  });

  testWidgets('a tile builder replaces the cards and gets the actions', (tester) async {
    final (manager, _) = await installed(tester);
    final seen = <String, ModelTileActions>{};
    await show(
      tester,
      ModelLibrary(
        manager: manager,
        onUseModel: (_) {},
        builders: ModelSetupBuilders(
          tile: (context, tile) {
            seen[tile.entry.id] = tile.actions;
            return Text('tile ${tile.entry.id} ${tile.status.state.name}');
          },
        ),
      ),
    );
    expect(find.text('tile test-4b ready'), findsOneWidget);
    expect(find.text('tile test-2b notDownloaded'), findsOneWidget);
    expect(
      (seen['test-4b']!.use != null, seen['test-4b']!.delete != null, seen['test-4b']!.download),
      (true, true, null),
    );
    expect(seen['test-2b']!.download, isNotNull);
  });
}
