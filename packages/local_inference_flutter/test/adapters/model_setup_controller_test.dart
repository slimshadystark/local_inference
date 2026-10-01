// ModelSetupController and pickSetupEntry: which model the first launch offers, the stages, the automatic load (at
// init, and when models go from none to some, never after an unload on purpose), the refresh when the app returns,
// the model picker's choice and the download analytics.
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_inference/testing.dart';
import 'package:local_inference_flutter/local_inference_flutter.dart';

import '../support/toy_chat.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('model_setup_controller_test'));
  tearDown(() => tmp.deleteSync(recursive: true));

  (ModelManager, FakeModelDownloader, FakeDeviceProbe) manager({DeviceCapabilities? caps, ModelCatalog? catalog}) {
    final downloader = FakeModelDownloader();
    final probe = FakeDeviceProbe(capabilities: caps ?? FakeDeviceProbe.defaultCapabilities);
    final models = ModelManager(
      root: () async => tmp.path,
      probe: probe,
      downloader: downloader,
      catalog: catalog ?? ModelCatalog.bundled(() async => testManifestJson()),
    );
    addTearDown(models.dispose);
    return (models, downloader, probe);
  }

  Future<void> until(bool Function() done, {String reason = ''}) async {
    for (var i = 0; i < 500 && !done(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    expect(done(), isTrue, reason: reason);
  }

  AssistantController assistant() {
    final controller = AssistantController.owning(
      Assistant(
        toyConfig(),
        engine: () => ScriptedEngine(supportsStatePersistence: false),
        prefixStore: InMemoryPrefixStateStore(),
      ),
    );
    addTearDown(controller.dispose);
    return controller;
  }

  Future<void> install(ModelManager models, FakeModelDownloader downloader, String id) async {
    await models.download(id);
    await Future<void>.delayed(Duration.zero);
    downloader.finish(id, testModelBytes[id]!);
    await until(() => models.statusOf(id).state == ModelState.ready, reason: '$id installed');
  }

  group('pickSetupEntry', () {
    test('the recommended model; the least demanding when none fits; the one chosen', () async {
      final (models, _, _) = manager();
      await models.init();
      expect(pickSetupEntry(models, null)?.id, 'test-4b');
      expect(pickSetupEntry(models, 'test-2b')?.id, 'test-2b');

      final (small, _, _) = manager(
        caps: const DeviceCapabilities(physicalMemoryMB: 3700, availableMemoryMB: 2900, freeDiskMB: 50000),
      );
      await small.init();
      expect(small.recommended, isNull);
      expect(pickSetupEntry(small, null)?.id, 'test-2b', reason: 'the least demanding one');
    });

    test('a download under way comes first, then a failed one, then the one chosen', () async {
      final (models, downloader, _) = manager();
      await models.init();
      await models.download('test-2b');
      expect(pickSetupEntry(models, null)?.id, 'test-2b', reason: 'a second download would start otherwise');
      expect(pickSetupEntry(models, 'test-4b')?.id, 'test-2b');
      downloader.emit(
        const ModelDownloadUpdate(
          id: 'test-2b',
          state: ModelDownloadState.failed,
          error: DownloadError(DownloadErrorCode.connection),
        ),
      );
      await until(() => models.statusOf('test-2b').state == ModelState.failed);
      expect(pickSetupEntry(models, null)?.id, 'test-2b', reason: 'its view offers Retry');
      await models.download('test-4b');
      expect(pickSetupEntry(models, null)?.id, 'test-4b', reason: 'downloading before failed');
      expect(pickSetupEntry(models, 'test-2b')?.id, 'test-2b', reason: 'the chosen one, failed, before another');
    });
  });

  test('stages: starting, consent, downloading, loading the model, ready', () async {
    final (models, downloader, _) = manager();
    final chat = assistant();
    final setup = ModelSetupController(manager: models, assistant: chat);
    addTearDown(setup.dispose);
    expect(setup.stage, SetupStage.starting);
    final init = setup.init();
    expect(setup.init(), same(init), reason: 'idempotent');
    await init;
    expect(setup.stage, SetupStage.consent);
    expect(setup.entry?.id, 'test-4b');
    expect(setup.alternatives.map((e) => e.id), ['test-2b']);
    expect(setup.problem, isNull);

    await setup.download();
    expect(setup.stage, SetupStage.downloading);
    final stages = <SetupStage>[];
    setup.addListener(() => stages.add(setup.stage));
    downloader.finish('test-4b', testModelBytes['test-4b']!);
    await until(() => chat.phase.value == AssistantPhase.ready, reason: 'the verified model loads by itself');
    expect(stages, containsAllInOrder([SetupStage.loadingModel, SetupStage.ready]));
    expect(chat.assistant.state.modelPath, models.pathOf('test-4b'));
  });

  test('a model list that cannot be read: catalogUnavailable, and retry starts the manager again', () async {
    var fail = true;
    final (models, _, _) = manager(
      catalog: ModelCatalog.bundled(
        () async => fail ? throw const FileSystemException('no asset') : testManifestJson(),
      ),
    );
    final setup = ModelSetupController(manager: models, assistant: assistant());
    addTearDown(setup.dispose);
    await setup.init();
    expect(setup.stage, SetupStage.catalogUnavailable);
    fail = false;
    await setup.retry();
    expect(setup.stage, SetupStage.consent);
  });

  test('no model offered, with a manager or without one', () async {
    final (models, _, _) = manager(catalog: ModelCatalog.fixed(const ModelManifest(models: [])));
    final setup = ModelSetupController(manager: models, assistant: assistant());
    addTearDown(setup.dispose);
    await setup.init();
    expect(setup.stage, SetupStage.noneOffered);

    final bare = ModelSetupController(assistant: assistant());
    addTearDown(bare.dispose);
    await bare.init();
    expect(bare.stage, SetupStage.noneOffered);
  });

  test('the automatic load: an installed model at init, the first candidate the host gives', () async {
    final (models, downloader, _) = manager();
    await models.init();
    await install(models, downloader, 'test-2b');
    final chat = assistant();
    final setup = ModelSetupController(manager: models, assistant: chat);
    addTearDown(setup.dispose);
    await setup.init();
    await until(() => chat.phase.value == AssistantPhase.ready);
    expect(chat.assistant.state.modelPath, models.pathOf('test-2b'));
    expect(setup.stage, SetupStage.ready);

    final found = assistant();
    final host = ModelSetupController(
      assistant: found,
      candidates: (installed) => [const ModelCandidate(path: 'found.gguf'), ...installed.map(ModelCandidate.installed)],
    );
    addTearDown(host.dispose);
    await host.init();
    await until(() => found.phase.value == AssistantPhase.ready);
    expect(found.assistant.state.modelPath, 'found.gguf');
  });

  test('a model unloaded on purpose is not loaded again by a later change of the manager', () async {
    final (models, downloader, _) = manager();
    final chat = assistant();
    final setup = ModelSetupController(manager: models, assistant: chat);
    addTearDown(setup.dispose);
    await setup.init();
    await setup.download();
    downloader.finish('test-4b', testModelBytes['test-4b']!);
    await until(() => chat.phase.value == AssistantPhase.ready);

    expect(await chat.unloadModel(), isTrue);
    await models.setWifiOnly(false);
    await models.download('test-2b');
    downloader.finish('test-2b', testModelBytes['test-2b']!);
    await until(() => models.statusOf('test-2b').state == ModelState.ready);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(chat.phase.value, AssistantPhase.noModel);
    expect(chat.assistant.state.modelPath, isNull);
    expect(setup.stage, SetupStage.modelAvailable, reason: 'models are there; nothing loads one by itself');
    await setup.refresh();
    expect(chat.phase.value, AssistantPhase.ready, reason: 'a refresh asks explicitly');
  });

  test('autoLoad off: modelAvailable until a refresh loads the first candidate', () async {
    final chat = assistant();
    final model = File('${tmp.path}/found.gguf')..writeAsStringSync('x');
    final setup = ModelSetupController(
      assistant: chat,
      autoLoad: false,
      candidates: (_) => [ModelCandidate(path: model.path)],
    );
    addTearDown(setup.dispose);
    await setup.init();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(chat.phase.value, AssistantPhase.noModel);
    expect(setup.stage, SetupStage.modelAvailable);
    await setup.refresh();
    expect(chat.assistant.state.modelPath, model.path);
    expect(setup.stage, SetupStage.ready);
  });

  test('a failed load is ready for the setup: the chat shows the failure and its Retry', () async {
    final chat = AssistantController.owning(
      Assistant(
        toyConfig(),
        engine: () => ScriptedEngine(chatTemplate: '', supportsStatePersistence: false),
        prefixStore: InMemoryPrefixStateStore(),
      ),
    );
    addTearDown(chat.dispose);
    final model = File('${tmp.path}/refused.gguf')..writeAsStringSync('x');
    final setup = ModelSetupController(
      assistant: chat,
      candidates: (_) => [ModelCandidate(path: model.path)],
    );
    addTearDown(setup.dispose);
    await setup.init();
    await until(() => chat.phase.value == AssistantPhase.failed);
    expect(setup.stage, SetupStage.ready);
  });

  test('retryLoad: the last model when one was loaded, even with a setup attached', () async {
    final chat = assistant();
    final first = File('${tmp.path}/first.gguf')..writeAsStringSync('x');
    final other = File('${tmp.path}/other.gguf')..writeAsStringSync('x');
    final setup = ModelSetupController(
      assistant: chat,
      candidates: (_) => [ModelCandidate(path: other.path)],
    );
    addTearDown(setup.dispose);
    expect(await chat.loadModel(first.path), isTrue);
    await setup.init();
    expect(chat.assistant.state.modelPath, first.path, reason: 'a loaded model is not replaced at init');
    expect(await chat.retryLoad(), isTrue);
    expect(chat.assistant.state.modelPath, first.path, reason: 'the last model, not the setup\'s candidate');
  });

  test('back in the foreground, free space is read again, so a refused download can start', () async {
    final (models, _, probe) = manager(
      caps: const DeviceCapabilities(physicalMemoryMB: 7622, availableMemoryMB: 5960, freeDiskMB: 10),
    );
    final setup = ModelSetupController(manager: models, assistant: assistant());
    addTearDown(setup.dispose);
    await setup.init();
    expect(setup.problem, isA<NotEnoughDisk>());
    probe.caps = const DeviceCapabilities(physicalMemoryMB: 7622, availableMemoryMB: 5960, freeDiskMB: 50000);
    final binding = TestWidgetsFlutterBinding.instance;
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await until(() => setup.problem == null, reason: 'read again');
  });

  test('choosing another model drops the partial data of a failed one', () async {
    final (models, downloader, _) = manager();
    final setup = ModelSetupController(manager: models, assistant: assistant());
    addTearDown(setup.dispose);
    await setup.init();
    await setup.download();
    downloader.emit(
      const ModelDownloadUpdate(
        id: 'test-4b',
        state: ModelDownloadState.failed,
        error: DownloadError(DownloadErrorCode.connection),
      ),
    );
    await until(() => setup.status?.state == ModelState.failed);
    expect(setup.stage, SetupStage.consent);
    await setup.choose('test-2b');
    await until(() => downloader.calls.contains('discard test-4b'), reason: 'the failed download is dropped');
    expect(models.statusOf('test-4b').state, ModelState.notDownloaded);
    expect(setup.entry?.id, 'test-2b');
    expect(setup.chosenId, 'test-2b');
  });

  test('download analytics: started, finished; failed with its code', () async {
    final (models, downloader, _) = manager();
    final setup = ModelSetupController(manager: models, assistant: assistant(), autoLoad: false);
    addTearDown(setup.dispose);
    final events = <ChatAnalyticsEvent>[];
    setup.analytics.listen(events.add);
    await setup.init();
    await setup.download();
    downloader.finish('test-4b', testModelBytes['test-4b']!);
    await until(() => models.statusOf('test-4b').state == ModelState.ready);
    await setup.choose('test-2b');
    await setup.download();
    downloader.emit(
      const ModelDownloadUpdate(
        id: 'test-2b',
        state: ModelDownloadState.failed,
        error: DownloadError(DownloadErrorCode.diskFull),
      ),
    );
    await until(() => models.statusOf('test-2b').state == ModelState.failed);
    await pumpEventQueue();
    expect(events.map((e) => e.runtimeType), [
      ModelDownloadStartedEvent,
      ModelDownloadFinishedEvent,
      ModelDownloadStartedEvent,
      ModelDownloadFailedEvent,
    ]);
    expect((events.last as ModelDownloadFailedEvent).code, 'diskFull');
  });
}
