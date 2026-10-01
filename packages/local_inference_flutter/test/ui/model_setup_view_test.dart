// The chat's first-launch setup: consent, download,
// the verified model loading by itself; phones below every model; failed, restored and mobile-data downloads and
// their Retry; a model list that cannot be read; free space read again on return; the model picker.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_inference/testing.dart';
import 'package:local_inference_flutter/local_inference_flutter.dart';

import '../support/toy_chat.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('model_setup_view_test'));
  tearDown(() => tmp.deleteSync(recursive: true));

  (ModelManager, FakeModelDownloader) manager({FakeDeviceProbe? probe, ModelCatalog? catalog}) {
    final downloader = FakeModelDownloader();
    final models = ModelManager(
      root: () async => tmp.path,
      probe: probe ?? FakeDeviceProbe(),
      downloader: downloader,
      catalog: catalog ?? ModelCatalog.bundled(() async => testManifestJson()),
    );
    addTearDown(models.dispose);
    return (models, downloader);
  }

  Future<(AssistantController, ModelSetupController)> open(WidgetTester tester, ModelManager models) async {
    usePhoneSurface(tester);
    final (controller, _) = await toyController(tester, load: false);
    final setup = ModelSetupController(manager: models, assistant: controller);
    addTearDown(setup.dispose);
    await tester.pumpWidget(
      app(
        LocalInferenceScope(
          strings: LocalInferenceStrings.italian,
          child: ChatPage(controller: controller, setup: setup, assistantName: 'Ada'),
        ),
      ),
    );
    return (controller, setup);
  }

  bool shows(String text) => find.textContaining(text).evaluate().isNotEmpty;

  ButtonStyleButton buttonWith(WidgetTester tester, String label) => tester.widget<ButtonStyleButton>(
    find.ancestor(of: find.text(label), matching: find.byWidgetPredicate((w) => w is ButtonStyleButton)).first,
  );

  Future<void> tapText(WidgetTester tester, String text) async {
    await tester.ensureVisible(find.text(text));
    await tester.pump();
    await tester.tap(find.text(text));
  }

  testWidgets('first launch without a model: consent, download, then the verified model loads', (tester) async {
    final (models, downloader) = manager();
    final (controller, _) = await open(tester, models);
    await pumpUntil(tester, () => shows('Avvia la sperimentazione di Ada'), reason: 'the consent');
    await tapText(tester, 'Scarica e prova');
    await pumpUntil(tester, () => downloader.lastStart('test-4b') != null, reason: 'download started');
    expect(find.textContaining("Scarico l'assistente"), findsOneWidget);

    downloader.finish('test-4b', testModelBytes['test-4b']!);
    await pumpUntil(tester, () => controller.phase.value == AssistantPhase.ready, reason: 'the model loads by itself');
    expect(controller.assistant.state.modelPath, models.pathOf('test-4b'));
    expect(find.text(LocalInferenceStrings.italian.chat.composerHint), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a phone below every model: the consent says why, with the button off', (tester) async {
    final (models, _) = manager(
      probe: FakeDeviceProbe(
        capabilities: const DeviceCapabilities(physicalMemoryMB: 3700, availableMemoryMB: 2900, freeDiskMB: 50000),
      ),
    );
    await open(tester, models);
    await pumpUntil(tester, () => shows('Avvia la sperimentazione di'));
    expect(find.text('test-2b'), findsOneWidget, reason: 'the least demanding model');
    expect(find.textContaining('Serve un telefono con almeno 6 GB'), findsOneWidget);
    expect(buttonWith(tester, 'Scarica e prova').onPressed, isNull);
    expect(find.text('Nessun modello sul dispositivo'), findsNothing);
  });

  testWidgets('a failed download can be tried again from the first screen', (tester) async {
    final (models, downloader) = manager();
    final (controller, _) = await open(tester, models);
    await pumpUntil(tester, () => shows('Scarica e prova'));
    await tapText(tester, 'Scarica e prova');
    await pumpUntil(tester, () => downloader.lastStart('test-4b') != null, reason: 'download started');
    downloader.emit(
      const ModelDownloadUpdate(
        id: 'test-4b',
        state: ModelDownloadState.failed,
        error: DownloadError(DownloadErrorCode.connection),
      ),
    );
    await pumpUntil(tester, () => shows('Riprova'), reason: 'retry offered');
    expect(find.text('Connessione interrotta: riprova.'), findsOneWidget);
    expect(buttonWith(tester, 'Riprova').onPressed, isNotNull);
    await tapText(tester, 'Riprova');
    await pumpUntil(tester, () => downloader.calls.last == 'resume test-4b', reason: 'resumed where it stopped');

    downloader.finish('test-4b', testModelBytes['test-4b']!);
    await pumpUntil(tester, () => controller.phase.value == AssistantPhase.ready, reason: 'loaded');
  });

  testWidgets('a download the user let use mobile data starts again on mobile data from Riprova', (tester) async {
    final (models, downloader) = manager();
    downloader.canResumeResult = false;
    await open(tester, models);
    await pumpUntil(tester, () => shows('Scarica e prova'));
    await tapText(tester, 'Scarica e prova');
    await pumpUntil(tester, () => downloader.calls.last == 'start test-4b wifiOnly=true', reason: 'Wi-Fi only');

    downloader.emit(const ModelDownloadUpdate(id: 'test-4b', state: ModelDownloadState.waitingForWifi));
    await pumpUntil(tester, () => shows('Usa la rete mobile'), reason: 'waits for Wi-Fi');
    await tester.tap(find.text('Usa la rete mobile'));
    await pumpUntil(tester, () => shows('Sei su rete mobile'), reason: 'asks first');
    await tester.tap(find.text('Scarica'));
    await pumpUntil(tester, () => downloader.calls.last == 'start test-4b wifiOnly=false', reason: 'on mobile data');

    downloader.emit(
      const ModelDownloadUpdate(
        id: 'test-4b',
        state: ModelDownloadState.failed,
        error: DownloadError(DownloadErrorCode.connection),
      ),
    );
    await pumpUntil(tester, () => shows('Riprova'), reason: 'retry offered');
    final before = downloader.calls.length;
    await tapText(tester, 'Riprova');
    await pumpUntil(tester, () => downloader.calls.length == before + 3, reason: 'started again');
    expect(downloader.calls.sublist(before), ['canResume test-4b', 'discard test-4b', 'start test-4b wifiOnly=false']);
  });

  testWidgets('a download restored at launch is shown, not the consent for another model; its failure offers Riprova', (
    tester,
  ) async {
    final (models, downloader) = manager();
    downloader.restored.add(const ModelDownloadUpdate(id: 'test-2b', state: ModelDownloadState.running, progress: 0.3));
    await open(tester, models);
    await pumpUntil(tester, () => shows("Scarico l'assistente…"), reason: 'progress shown');
    expect(find.text('test-2b'), findsOneWidget);
    expect(find.textContaining('Avvia la sperimentazione di'), findsNothing);

    downloader.emit(
      const ModelDownloadUpdate(
        id: 'test-2b',
        state: ModelDownloadState.failed,
        error: DownloadError(DownloadErrorCode.connection),
      ),
    );
    await pumpUntil(tester, () => shows('Riprova'), reason: 'retry offered');
    expect(find.text('test-2b'), findsOneWidget);
    await tapText(tester, 'Riprova');
    await pumpUntil(tester, () => downloader.calls.last == 'resume test-2b', reason: 'resumed where it stopped');
  });

  testWidgets('a restored download that fails with no data kept starts that model again on Riprova', (tester) async {
    final (models, downloader) = manager();
    downloader
      ..canResumeResult = false
      ..restored.add(const ModelDownloadUpdate(id: 'test-2b', state: ModelDownloadState.running, progress: 0.3));
    await open(tester, models);
    await pumpUntil(tester, () => shows("Scarico l'assistente…"), reason: 'progress shown');
    downloader.emit(
      const ModelDownloadUpdate(
        id: 'test-2b',
        state: ModelDownloadState.failed,
        error: DownloadError(DownloadErrorCode.connection),
      ),
    );
    await pumpUntil(tester, () => shows('Riprova'), reason: 'retry offered');
    await tapText(tester, 'Riprova');
    await pumpUntil(tester, () => downloader.calls.last.startsWith('start test-2b'), reason: 'the same model again');
    expect(downloader.calls.sublist(downloader.calls.length - 3, downloader.calls.length - 1), [
      'canResume test-2b',
      'discard test-2b',
    ]);
  });

  testWidgets('a model list that cannot be read: a panel with Riprova, not a spinner', (tester) async {
    var fail = true;
    final (models, _) = manager(
      catalog: ModelCatalog.bundled(
        () async => fail ? throw const FileSystemException('no asset') : testManifestJson(),
      ),
    );
    await open(tester, models);
    await pumpUntil(tester, () => shows('Elenco modelli non disponibile.'), reason: 'the failure is shown');
    fail = false;
    await tapText(tester, 'Riprova');
    await pumpUntil(tester, () => shows('Avvia la sperimentazione di Ada'), reason: 'read on retry');
  });

  testWidgets('space freed while the app was in the background turns the download button on', (tester) async {
    final probe = FakeDeviceProbe(
      capabilities: const DeviceCapabilities(physicalMemoryMB: 7622, availableMemoryMB: 5960, freeDiskMB: 10),
    );
    final (models, _) = manager(probe: probe);
    await open(tester, models);
    await pumpUntil(tester, () => shows('Spazio libero insufficiente'));
    expect(buttonWith(tester, 'Scarica e prova').onPressed, isNull);

    probe.caps = const DeviceCapabilities(physicalMemoryMB: 7622, availableMemoryMB: 5960, freeDiskMB: 50000);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await pumpUntil(tester, () => !shows('Spazio libero insufficiente'), reason: 'free space read again');
    expect(buttonWith(tester, 'Scarica e prova').onPressed, isNotNull);
  });

  testWidgets('"choose another model": the picker lists the models; the choice becomes the consent\'s', (tester) async {
    final (models, _) = manager();
    await open(tester, models);
    await pumpUntil(tester, () => shows('Scegli un altro modello'));
    await tapText(tester, 'Scegli un altro modello');
    await pumpUntil(tester, () => find.byKey(LocalInferenceKeys.pickerEntry('test-2b')).evaluate().isNotEmpty);
    await tester.pumpAndSettle();
    expect(find.textContaining('consigliato per questo telefono'), findsOneWidget);
    await tester.tap(find.byKey(LocalInferenceKeys.pickerEntry('test-2b')));
    await tester.pumpAndSettle();
    expect(find.text('test-2b'), findsOneWidget);
    expect(find.text('test-4b'), findsNothing);
  });

  group('a model is there but not loaded', () {
    const en = LocalInferenceStrings.english;

    Future<AssistantController> chat(
      WidgetTester tester,
      ModelSetupController Function(AssistantController controller, String model) setup, {
      bool inScope = false,
    }) async {
      usePhoneSurface(tester);
      final (controller, _) = await toyController(tester, load: false);
      final model = File('${tmp.path}/toy.gguf')..writeAsStringSync('x');
      final made = setup(controller, model.path);
      addTearDown(made.dispose);
      await tester.pumpWidget(
        app(
          inScope
              ? LocalInferenceScope(
                  assistant: controller,
                  setup: made,
                  child: const ChatPage(assistantName: 'Acme'),
                )
              : ChatPage(controller: controller, setup: made, assistantName: 'Acme'),
        ),
      );
      await tester.pump();
      return controller;
    }

    Future<void> load(WidgetTester tester, AssistantController controller) async {
      expect(find.text(en.chat.notLoadedTitle), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNothing, reason: 'nothing is loading');
      await tester.tap(find.byKey(LocalInferenceKeys.loadModel));
      await pumpUntil(tester, () => controller.phase.value == AssistantPhase.ready, reason: 'loaded');
      expect(find.text(en.chat.composerHint), findsOneWidget, reason: 'the conversation');
    }

    testWidgets('autoLoad off: "Load" instead of an endless "Preparing"', (tester) async {
      final controller = await chat(
        tester,
        (controller, model) => ModelSetupController(
          assistant: controller,
          autoLoad: false,
          candidates: (_) => [ModelCandidate(path: model)],
        ),
      );
      expect(controller.phase.value, AssistantPhase.noModel);
      await load(tester, controller);
    });

    testWidgets('a model unloaded on purpose: "Load" brings it back', (tester) async {
      final controller = await chat(
        tester,
        (controller, model) => ModelSetupController(
          assistant: controller,
          candidates: (_) => [ModelCandidate(path: model)],
        ),
      );
      await pumpUntil(tester, () => controller.phase.value == AssistantPhase.ready, reason: 'loaded by itself');
      await tester.runAsync(controller.unloadModel);
      await tester.pump();
      await load(tester, controller);
    });

    testWidgets("a setup without the chat's assistant (it only downloads): its model can be loaded", (tester) async {
      final controller = await chat(
        tester,
        (controller, model) => ModelSetupController(candidates: (_) => [ModelCandidate(path: model)]),
        inScope: true,
      );
      expect(find.text('Acme'), findsOneWidget);
      await load(tester, controller);
    });
  });

  testWidgets("the setup's panels go through the chat's statusPanel builder", (tester) async {
    usePhoneSurface(tester);
    final kinds = <ChatPanelKind>[];
    Future<void> show(ModelSetupController setup, AssistantController controller) async {
      addTearDown(setup.dispose);
      await tester.pumpWidget(
        app(
          ChatPage(
            controller: controller,
            setup: setup,
            builders: ChatBuilders(
              statusPanel: (context, slot) {
                kinds.add(slot.kind);
                return Column(
                  children: [
                    Text('custom ${slot.kind.name}'),
                    Expanded(child: slot.buildDefault()),
                  ],
                );
              },
            ),
          ),
        ),
      );
      await tester.pump();
    }

    // The manager is starting.
    final (controller, _) = await toyController(tester, load: false);
    final hold = Completer<String>();
    final starting = ModelManager(
      root: () => hold.future,
      probe: FakeDeviceProbe(),
      downloader: FakeModelDownloader(),
      catalog: ModelCatalog.bundled(() async => testManifestJson()),
    );
    addTearDown(starting.dispose);
    await show(ModelSetupController(manager: starting, assistant: controller), controller);
    expect(find.text('custom preparing'), findsOneWidget);

    // The model list cannot be read; no model is offered.
    final (unreadable, _) = manager(
      catalog: ModelCatalog.bundled(() async => throw const FileSystemException('no asset')),
    );
    await show(ModelSetupController(manager: unreadable, assistant: controller), controller);
    await pumpUntil(tester, () => kinds.contains(ChatPanelKind.catalogUnavailable));
    final (empty, _) = manager(catalog: ModelCatalog.fixed(const ModelManifest(models: [])));
    await show(ModelSetupController(manager: empty, assistant: controller), controller);
    await pumpUntil(tester, () => kinds.contains(ChatPanelKind.noneOffered));

    // A model that nothing loads by itself.
    final model = File('${tmp.path}/toy.gguf')..writeAsStringSync('x');
    await show(
      ModelSetupController(
        assistant: controller,
        autoLoad: false,
        candidates: (_) => [ModelCandidate(path: model.path)],
      ),
      controller,
    );
    expect(find.text('custom modelAvailable'), findsOneWidget);
    hold.complete(tmp.path);
  });

  testWidgets('standalone, autoLoad off: "Load" loads the model and the setup is ready', (tester) async {
    usePhoneSurface(tester);
    final (controller, _) = await toyController(tester, load: false);
    final model = File('${tmp.path}/toy.gguf')..writeAsStringSync('x');
    final setup = ModelSetupController(
      assistant: controller,
      autoLoad: false,
      candidates: (_) => [ModelCandidate(path: model.path)],
    );
    addTearDown(setup.dispose);
    var ready = 0;
    await tester.pumpWidget(
      app(
        Scaffold(
          body: ModelSetupView(controller: setup, onReady: () => ready++),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(LocalInferenceKeys.loadModel));
    await pumpUntil(tester, () => ready == 1, reason: 'loaded');
    expect(controller.phase.value, AssistantPhase.ready);
  });

  testWidgets('standalone: onReady runs once the model is installed, without a chat', (tester) async {
    usePhoneSurface(tester);
    final (models, downloader) = manager();
    final setup = ModelSetupController(manager: models);
    addTearDown(setup.dispose);
    var ready = 0;
    await tester.pumpWidget(
      app(
        Scaffold(
          body: ModelSetupView(controller: setup, assistantName: 'Helper', onReady: () => ready++),
        ),
      ),
    );
    await pumpUntil(tester, () => shows('Start trying Helper'), reason: 'English consent');
    await tapText(tester, 'Download and try');
    await pumpUntil(tester, () => downloader.lastStart('test-4b') != null);
    downloader.finish('test-4b', testModelBytes['test-4b']!);
    await pumpUntil(tester, () => ready == 1, reason: 'installed');
    expect(setup.stage, SetupStage.ready);
  });
}
