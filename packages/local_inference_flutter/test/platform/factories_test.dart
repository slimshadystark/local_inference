// LocalInferenceFlutter's factories: the load options leave the micro-batch size to the engine (128 on iOS) and
// pick the CPU in a simulator; createModelManager wires the plugin probe and the platform's downloader;
// createAssistantController applies the platform defaults to an owned assistant; checkDeviceSupport applies the
// Android floor.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_inference/testing.dart';
import 'package:local_inference_flutter/local_inference_flutter.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const methods = MethodChannel('local_inference_flutter/device');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(methods, null);
    LocalInferenceDevice.resetCache();
  });

  void platformAnswers(Map<String, Object?> info) =>
      messenger.setMockMethodCallHandler(methods, (call) async => call.method == 'platform' ? info : null);

  test(
    'platformLoadOptions: microBatchSize stays null; the CPU in a simulator, the runtime\'s choice elsewhere',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      platformAnswers({
        'os': 'ios',
        'osVersion': '26.0',
        'abis': ['arm64'],
        'is64Bit': true,
        'isSimulator': true,
      });
      final simulator = await LocalInferenceFlutter.platformLoadOptions();
      expect((simulator.compute, simulator.microBatchSize), (ComputeBackend.cpu, null));

      LocalInferenceDevice.resetCache();
      platformAnswers({
        'os': 'ios',
        'osVersion': '26.0',
        'abis': ['arm64'],
        'is64Bit': true,
        'isSimulator': false,
      });
      final phone = await LocalInferenceFlutter.platformLoadOptions();
      expect(phone, const LoadOptions());
      expect(phone.microBatchSize, isNull);

      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      expect(await LocalInferenceFlutter.platformLoadOptions(), const LoadOptions());
      // Only phones use background_downloader: on macOS FileDownloader is not created.
      await LocalInferenceFlutter.installDownloaderStorage();
      expect(RetainingResumeStorage.installed, isNull);
    },
  );

  test(
    'platformDefaults: the load options of platformLoadOptions and a file store in the prefix-states folder',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      final tmp = Directory.systemTemp.createTempSync('factories_defaults_test');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final paths = LocalInferencePaths(
        modelsRoot: tmp.path,
        prefixStates: p.join(tmp.path, 'prefix_states'),
        downloadLocation: const ModelStorageLocation.applicationSupport(),
      );
      final (load, store) = await LocalInferenceFlutter.platformDefaults(paths: paths, maxPrefixStates: 2);
      expect(load, await LocalInferenceFlutter.platformLoadOptions());
      expect(load.microBatchSize, isNull);
      expect(store, isA<FilePrefixStateStore>());
      store as FilePrefixStateStore;
      expect((store.directory, store.maxEntries), (p.join(tmp.path, 'prefix_states'), 2));
    },
  );

  test('createModelManager: the plugin probe on the models volume, background downloads on phones', () async {
    final tmp = Directory.systemTemp.createTempSync('factories_test');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final paths = LocalInferencePaths(
      modelsRoot: tmp.path,
      prefixStates: p.join(tmp.path, 'prefix_states'),
      downloadLocation: ModelStorageLocation.absolute(tmp.path),
      androidTempDirectory: p.join(tmp.path, 'models', '.partial'),
    );
    final catalog = ModelCatalog.bundled(() async => testManifestJson());

    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final phone = await LocalInferenceFlutter.createModelManager(
      catalog: catalog,
      paths: paths,
      download: const BackgroundDownloadConfig(group: 'app_models'),
    );
    expect(phone.probe, isA<PluginDeviceProbe>().having((d) => d.volumePath, 'volumePath', tmp.path));
    final background = phone.downloader as BackgroundModelDownloader;
    expect(
      (background.location, background.config.group, background.androidTempDirectory),
      (ModelStorageLocation.absolute(tmp.path), 'app_models', p.join(tmp.path, 'models', '.partial')),
    );

    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final desktop = await LocalInferenceFlutter.createModelManager(catalog: catalog, paths: paths);
    expect(desktop.downloader, isA<HttpModelDownloader>());

    final downloader = FakeModelDownloader();
    final probe = FakeDeviceProbe();
    final given = await LocalInferenceFlutter.createModelManager(
      catalog: catalog,
      paths: paths,
      probe: probe,
      downloader: downloader,
      preflight: (entry, device) => entry.id == 'test-2b' ? const HostRefused('no') : null,
    );
    await given.init();
    await given.download('test-4b');
    expect(downloader.lastStart('test-4b')!.directory, p.join(tmp.path, 'models', 'test-4b'));
    expect(given.problemFor(given.entryFor('test-2b')!), const HostRefused('no'));
    await given.dispose();
    await phone.dispose();
    await desktop.dispose();
  });

  test('createAssistantController: the platform\'s load options and prefix store; an owned assistant', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    platformAnswers({
      'os': 'ios',
      'osVersion': '26.0',
      'abis': ['arm64'],
      'is64Bit': true,
      'isSimulator': true,
    });
    final tmp = Directory.systemTemp.createTempSync('factories_assistant_test');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final paths = LocalInferencePaths(
      modelsRoot: tmp.path,
      prefixStates: p.join(tmp.path, 'prefix_states'),
      downloadLocation: const ModelStorageLocation.applicationSupport(),
    );
    final engines = <ScriptedEngine>[];
    final controller = await LocalInferenceFlutter.createAssistantController(
      AssistantConfig.basic(systemPrompt: 'Hi.'),
      engine: () {
        final engine = ScriptedEngine(supportsStatePersistence: false);
        engines.add(engine);
        return engine;
      },
      paths: paths,
      maxPrefixStates: 2,
    );
    expect(controller.ownsAssistant, isTrue);
    expect(await controller.loadModel('m.gguf', identity: const ModelIdentity.fixed('m.gguf')), isTrue);
    final options = controller.assistant.state.info!.options;
    expect(
      (options.compute, options.microBatchSize),
      (ComputeBackend.cpu, null),
      reason: 'a simulator; 128 is core\'s',
    );
    await controller.dispose();
    expect(engines.single.disposes, 1, reason: 'the owned assistant freed its model');

    final given = await LocalInferenceFlutter.createAssistantController(
      AssistantConfig.basic(systemPrompt: 'Hi.'),
      load: const LoadOptions(contextTokens: 2048),
      prefixStore: InMemoryPrefixStateStore(),
      engine: () => ScriptedEngine(supportsStatePersistence: false),
    );
    expect(await given.loadModel('m.gguf', identity: const ModelIdentity.fixed('m.gguf')), isTrue);
    expect(given.assistant.state.info!.options.contextTokens, 2048);
    await given.dispose();
  });

  test('checkDeviceSupport: Android needs API 28, arm64-v8a and 64 bits; iOS and macOS pass; others do not', () async {
    Future<DeviceSupportProblem?> android(Map<String, Object?> info) async {
      LocalInferenceDevice.resetCache();
      platformAnswers({'os': 'android', 'osVersion': '14', ...info});
      return (await LocalInferenceFlutter.checkDeviceSupport()).problem;
    }

    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    expect(
      await android({
        'sdkInt': 27,
        'abis': ['arm64-v8a'],
        'is64Bit': true,
      }),
      DeviceSupportProblem.androidTooOld,
    );
    expect(
      await android({
        'sdkInt': 34,
        'abis': ['x86_64'],
        'is64Bit': true,
      }),
      DeviceSupportProblem.noArm64,
    );
    expect(
      await android({
        'sdkInt': 34,
        'abis': ['arm64-v8a'],
        'is64Bit': false,
      }),
      DeviceSupportProblem.not64Bit,
    );
    expect(
      await android({
        'sdkInt': 28,
        'abis': ['arm64-v8a', 'armeabi-v7a'],
        'is64Bit': true,
      }),
      isNull,
    );
    expect((await LocalInferenceFlutter.checkDeviceSupport()).platform!.androidSdkInt, 28);

    for (final platform in [TargetPlatform.iOS, TargetPlatform.macOS]) {
      debugDefaultTargetPlatformOverride = platform;
      expect((await LocalInferenceFlutter.checkDeviceSupport()).isSupported, isTrue);
    }
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    expect((await LocalInferenceFlutter.checkDeviceSupport()).problem, DeviceSupportProblem.unsupportedPlatform);
  });
}
