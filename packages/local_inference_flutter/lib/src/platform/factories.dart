/// One-call setup of the platform pieces: the model manager, the load options, the device support check.
library;

import 'package:flutter/foundation.dart';
import 'package:local_inference/local_inference.dart';

import '../adapters/assistant_controller.dart';
import 'background_model_downloader.dart';
import 'device.dart';
import 'diagnostics.dart';
import 'download_config.dart';
import 'paths.dart';
import 'retaining_resume_storage.dart';

/// Why [LocalInferenceFlutter.checkDeviceSupport] refused the device.
enum DeviceSupportProblem {
  /// Android below API 28, the engine's validated floor.
  androidTooOld,

  /// No arm64-v8a ABI: the vendored engine is built for arm64 only.
  noArm64,

  /// A 32-bit process cannot map a multi-GB model.
  not64Bit,

  /// A platform the plugin does not support (Linux, Windows, web).
  unsupportedPlatform,
}

/// Whether the engine can run on this device.
@immutable
final class DeviceSupport {
  const DeviceSupport.supported({this.platform}) : problem = null;

  const DeviceSupport.unsupported(DeviceSupportProblem this.problem, {this.platform});

  /// Why not; null when supported.
  final DeviceSupportProblem? problem;

  /// What the plugin reported, when it was asked.
  final PlatformSupportInfo? platform;

  bool get isSupported => problem == null;

  @override
  String toString() => isSupported ? 'DeviceSupport.supported' : 'DeviceSupport.unsupported(${problem!.name})';
}

/// The one-call setup of the platform pieces: the model manager, the load options and the device check.
abstract final class LocalInferenceFlutter {
  /// Call first in `main()`, before anything creates background_downloader's FileDownloader: it creates it with a
  /// [RetainingResumeStorage], so a failed model download keeps its partial data and a retry resumes it, also after
  /// a relaunch. If FileDownloader already existed (the host or another plugin created it), that storage cannot be
  /// set: [BackgroundModelDownloader.canResume] then answers false and a retry starts again. It also holds the updates
  /// of [download]'s group until the model manager's downloader sets up ([BackgroundModelDownloader.holdUpdates]):
  /// pass the config [createModelManager] gets. It does nothing on platforms other than iOS and Android, where
  /// models download in the foreground.
  static Future<void> installDownloaderStorage({
    BackgroundDownloadConfig download = const BackgroundDownloadConfig(),
  }) async {
    if (defaultTargetPlatform != TargetPlatform.iOS && defaultTargetPlatform != TargetPlatform.android) return;
    await RetainingResumeStorage.install();
    BackgroundModelDownloader.holdUpdates(download.group);
  }

  /// The engine's load options for this device: the CPU in a simulator (no Metal there), the runtime's choice
  /// elsewhere. The micro-batch size stays null, so the engine applies its iOS default of 128.
  static Future<LoadOptions> platformLoadOptions({LocalInferenceDevice device = const LocalInferenceDevice()}) async {
    final simulator = switch (defaultTargetPlatform) {
      TargetPlatform.iOS || TargetPlatform.android => (await device.platform()).isSimulator,
      _ => false,
    };
    return LoadOptions(compute: simulator ? ComputeBackend.cpu : ComputeBackend.auto);
  }

  /// The engine's load options and a prefix-state store for this device: [platformLoadOptions], and a
  /// [FilePrefixStateStore] in [LocalInferencePaths.prefixStates] (the caches folder: the system may empty it, and a
  /// missing state is rebuilt) keeping the [maxPrefixStates] most recently used states. [paths] defaults to
  /// [LocalInferencePaths.resolve].
  static Future<(LoadOptions, PrefixStateStore)> platformDefaults({
    int maxPrefixStates = 3,
    LocalInferencePaths? paths,
    LocalInferenceDevice device = const LocalInferenceDevice(),
  }) async {
    final folders = paths ?? await LocalInferencePaths.resolve(device: device);
    return (
      await platformLoadOptions(device: device),
      FilePrefixStateStore(folders.prefixStates, maxEntries: maxPrefixStates),
    );
  }

  /// An [AssistantController] that owns a new [Assistant] with [config], on this device's defaults: [load] defaults
  /// to [platformLoadOptions] (the CPU in a simulator; the micro-batch size left to the engine, 128 on iOS),
  /// [prefixStore] to a [FilePrefixStateStore] of [maxPrefixStates] states in the caches folder
  /// ([LocalInferencePaths.prefixStates]). [engine] makes each model's engine (default: llama.cpp through llamadart).
  /// Disposing the controller disposes the assistant and its model.
  static Future<AssistantController> createAssistantController(
    AssistantConfig config, {
    LoadOptions? load,
    EngineFactory? engine,
    PrefixStateStore? prefixStore,
    int maxPrefixStates = 3,
    LocalInferencePaths? paths,
    LocalInferenceDevice device = const LocalInferenceDevice(),
    DateTime Function()? wallClock,
  }) async {
    final options = load ?? await platformLoadOptions(device: device);
    final store =
        prefixStore ??
        FilePrefixStateStore(
          (paths ?? await LocalInferencePaths.resolve(device: device)).prefixStates,
          maxEntries: maxPrefixStates,
        );
    return AssistantController.owning(
      Assistant(config, engine: engine ?? LlamadartEngine.new, load: options, prefixStore: store, wallClock: wallClock),
    );
  }

  /// A [ModelManager] for this platform: [paths] (default: [LocalInferencePaths.resolve]), the plugin's
  /// [PluginDeviceProbe] measuring the models' volume, and background_downloader on iOS and Android
  /// ([BackgroundModelDownloader] with [download]) or a foreground [HttpModelDownloader] elsewhere. [probe] and
  /// [downloader] replace those (tests). [ModelManager.dispose] leaves that [HttpModelDownloader] running: a desktop
  /// host that stops downloading calls its `close()`.
  static Future<ModelManager> createModelManager({
    required ModelCatalog catalog,
    LocalInferencePaths? paths,
    BackgroundDownloadConfig download = const BackgroundDownloadConfig(),
    ModelProblem? Function(ModelEntry entry, DeviceCapabilities device)? preflight,
    DeviceProbe? probe,
    ModelDownloader? downloader,
  }) async {
    final where = paths ?? await LocalInferencePaths.resolve();
    final mobile = defaultTargetPlatform == TargetPlatform.iOS || defaultTargetPlatform == TargetPlatform.android;
    return ModelManager(
      root: () async => where.modelsRoot,
      probe: probe ?? PluginDeviceProbe(volumePath: where.modelsRoot),
      downloader:
          downloader ??
          (mobile
              ? BackgroundModelDownloader(
                  location: where.downloadLocation,
                  config: download,
                  androidTempDirectory: where.androidTempDirectory,
                )
              : HttpModelDownloader(headers: (_) => download.headers, retries: download.retries)),
      catalog: catalog,
      preflight: preflight,
    );
  }

  /// Whether the engine can run here: Android needs API 28, the arm64-v8a ABI and a 64-bit process; iOS and macOS
  /// are supported; other platforms are not.
  static Future<DeviceSupport> checkDeviceSupport({LocalInferenceDevice device = const LocalInferenceDevice()}) async {
    switch (defaultTargetPlatform) {
      case TargetPlatform.iOS || TargetPlatform.macOS:
        return const DeviceSupport.supported();
      case TargetPlatform.android:
        final info = await device.platform();
        if ((info.androidSdkInt ?? 0) < 28) {
          return DeviceSupport.unsupported(DeviceSupportProblem.androidTooOld, platform: info);
        }
        if (!info.abis.contains('arm64-v8a')) {
          return DeviceSupport.unsupported(DeviceSupportProblem.noArm64, platform: info);
        }
        if (!info.is64Bit) return DeviceSupport.unsupported(DeviceSupportProblem.not64Bit, platform: info);
        return DeviceSupport.supported(platform: info);
      default:
        return const DeviceSupport.unsupported(DeviceSupportProblem.unsupportedPlatform);
    }
  }
}
