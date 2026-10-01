/// The first-launch model setup as a controller: which model to offer, its download, and loading it once it is there.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:local_inference/local_inference.dart';

import 'analytics.dart';
import 'assistant_controller.dart';
import 'pick_setup_entry.dart';

/// Where the model setup is.
enum SetupStage {
  /// The model manager is starting (reading its catalog and its files).
  starting,

  /// The model list could not be read; retry.
  catalogUnavailable,

  /// No model is offered (none in the catalog, or no manager and no model file).
  noneOffered,

  /// A model can be downloaded: ask the user first (its size, whether this device can run it).
  consent,

  /// The model downloads (queued, running, paused, waiting for Wi-Fi, being checked).
  downloading,

  /// A model file is there, no model is loaded, and nothing loads one by itself: [ModelSetupController.autoLoad] is
  /// off, or the model was unloaded on purpose. [ModelSetupController.refresh] loads it (the views offer "Load").
  modelAvailable,

  /// The assistant loads a model.
  loadingModel,

  /// The setup's part is done: a model was loaded (a failed load too: the chat shows the failure and "Retry"), or,
  /// without an assistant, one is installed.
  ready,
}

/// A model file the setup can load: a verified download, or a file the host found.
@immutable
final class ModelCandidate {
  const ModelCandidate({required this.path, this.label, this.sizeBytes, this.entry});

  /// A model the manager verified.
  ModelCandidate.installed(InstalledModel model)
    : this(path: model.path, label: model.entry.displayName, sizeBytes: model.sizeBytes, entry: model.entry);

  final String path;

  /// The name to show; null uses the file name.
  final String? label;
  final int? sizeBytes;

  /// The catalog entry of a downloaded model; null for a file the host found.
  final ModelEntry? entry;

  @override
  bool operator ==(Object other) =>
      other is ModelCandidate &&
      other.path == path &&
      other.label == label &&
      other.sizeBytes == sizeBytes &&
      other.entry == entry;

  @override
  int get hashCode => Object.hash(path, label, sizeBytes, entry);

  @override
  String toString() => 'ModelCandidate($path)';
}

/// The models the setup can load, the preferred first, from the manager's verified models ([installed]; empty
/// without a manager). Called at every change of the manager, so it must be cheap.
typedef SetupCandidates = List<ModelCandidate> Function(List<InstalledModel> installed);

List<ModelCandidate> _installedOnly(List<InstalledModel> installed) => [
  for (final model in installed) ModelCandidate.installed(model),
];

/// The first-launch setup of a chat: it offers a model to download ([pickSetupEntry]), follows its download and loads
/// the first candidate when one appears.
///
/// The automatic load happens at [init] (after the manager's own init, so a loaded model does not lower its memory
/// reading), and when the candidates go from none to some while no model is loaded: a model unloaded on purpose
/// (to free memory for something else) is not loaded again by a later change of the manager
/// ([SetupStage.modelAvailable]: the chat offers "Load", which calls [refresh]). When the app comes back
/// to the foreground it reads the device's free space and memory again, so a download refused for space can start.
final class ModelSetupController extends ChangeNotifier {
  ModelSetupController({
    this.manager,
    this.assistant,
    SetupCandidates? candidates,
    this.autoLoad = true,
    this.refreshOnResume = true,
    this.pick = pickSetupEntry,
  }) : _candidatesOf = candidates ?? _installedOnly {
    manager?.addListener(_onManager);
    assistant?.phase.addListener(_onPhase);
    assistant?.retryFallback = _fallback;
  }

  /// Downloads models; null when the host only has files of its own (the candidates).
  final ModelManager? manager;

  /// The chat that loads the model; null for a setup that only downloads.
  final AssistantController? assistant;

  /// Whether a candidate loads by itself (see the class comment).
  final bool autoLoad;

  /// Whether the device's free space and memory are read again when the app returns to the foreground.
  final bool refreshOnResume;

  /// Chooses the model the setup is about ([pickSetupEntry]).
  final SetupEntryPicker pick;

  final SetupCandidates _candidatesOf;
  List<ModelCandidate> _candidates = const [];
  String? _chosenId;
  Future<void>? _initialized;
  AppLifecycleListener? _lifecycle;
  final Map<String, DateTime> _downloadStarts = {};
  final StreamController<ChatAnalyticsEvent> _analytics = StreamController.broadcast();
  bool _disposed = false;

  /// The model files that can be loaded now, the preferred first.
  List<ModelCandidate> get candidates => _candidates;

  /// The model the user chose in the model picker; null until then.
  String? get chosenId => _chosenId;

  /// Download events for analytics (started, finished, failed).
  Stream<ChatAnalyticsEvent> get analytics => _analytics.stream;

  /// The model the setup is about; null before the manager is ready or when none is offered.
  ModelEntry? get entry {
    final manager = this.manager;
    if (manager == null || !manager.isReady) return null;
    return pick(manager, _chosenId);
  }

  /// The download status of [entry].
  ModelStatus? get status => switch (entry) {
    final entry? => manager!.statusOf(entry.id),
    null => null,
  };

  /// Why [entry] cannot be downloaded or used on this device; null when it can.
  ModelProblem? get problem => switch (entry) {
    final entry? => manager!.problemFor(entry),
    null => null,
  };

  /// The other models the user can choose instead of [entry].
  List<ModelEntry> get alternatives {
    final current = entry;
    if (current == null) return const [];
    return [
      for (final other in manager!.entries)
        if (other.id != current.id && other.isActive) other,
    ];
  }

  /// Where the setup is; see [SetupStage].
  SetupStage get stage {
    final phase = assistant?.phase.value;
    if (phase == AssistantPhase.loading || phase == AssistantPhase.preparing) return SetupStage.loadingModel;
    if (phase == AssistantPhase.ready || phase == AssistantPhase.busy || phase == AssistantPhase.failed) {
      return SetupStage.ready;
    }
    // No model loaded. The automatic load starts at once (the phase is loading by the time anyone looks), so a
    // candidate here waits for a refresh.
    if (_candidates.isNotEmpty) return assistant == null ? SetupStage.ready : SetupStage.modelAvailable;
    final manager = this.manager;
    if (manager == null) return SetupStage.noneOffered;
    if (!manager.isReady) return manager.loadError != null ? SetupStage.catalogUnavailable : SetupStage.starting;
    final entry = this.entry;
    if (entry == null) return SetupStage.noneOffered;
    final status = manager.statusOf(entry.id);
    if (status.isActive) return SetupStage.downloading;
    if (status.state == ModelState.ready) return assistant == null ? SetupStage.ready : SetupStage.modelAvailable;
    return SetupStage.consent;
  }

  /// Starts the manager (its failure shows as [SetupStage.catalogUnavailable]), then looks for candidates and loads
  /// the first. Every call returns the same future; the setup views call it.
  Future<void> init() => _initialized ??= _initialize();

  Future<void> _initialize() async {
    final manager = this.manager;
    if (manager != null && refreshOnResume) _lifecycle = AppLifecycleListener(onResume: _onResume);
    if (manager != null) {
      try {
        await manager.init();
      } on Object {
        // Shown by the stage (catalogUnavailable) through manager.loadError.
      }
    }
    if (_disposed) return;
    unawaited(_refresh(autoLoad: true));
    notifyListeners();
  }

  /// Looks for candidates again and, with [load], loads the first when no model is loaded (the "Refresh" of a panel
  /// with no model); this asks explicitly, so it loads also when [autoLoad] is off.
  Future<void> refresh({bool load = true}) async {
    final loading = _refresh(autoLoad: load, explicit: true);
    notifyListeners();
    await loading;
  }

  /// Downloads [entry] ([ModelManager.download]); throws when the download cannot start.
  Future<void> download({bool allowCellular = false}) async {
    final entry = this.entry;
    if (entry == null) return;
    await manager!.download(entry.id, allowCellular: allowCellular);
    _downloadStarts[entry.id] = DateTime.now();
    _track(ModelDownloadStartedEvent(modelId: entry.id));
  }

  Future<void> pause() async {
    if (entry case final entry?) await manager!.pause(entry.id);
  }

  Future<void> resume() async {
    if (entry case final entry?) await manager!.resume(entry.id);
  }

  Future<void> cancel() async {
    if (entry case final entry?) await manager!.cancel(entry.id);
  }

  /// Makes [id] the model the setup is about (the model picker). The partial data of a failed model is dropped: it
  /// is gigabytes nobody will resume.
  Future<void> choose(String id) async {
    final manager = this.manager;
    if (manager == null || !manager.isReady) return;
    final current = entry;
    if (current != null && current.id != id && manager.statusOf(current.id).state == ModelState.failed) {
      unawaited(manager.cancel(current.id));
    }
    _chosenId = id;
    notifyListeners();
  }

  /// Tries again: the manager's start when the model list could not be read, else a failed download.
  Future<void> retry() async {
    final manager = this.manager;
    if (manager != null && !manager.isReady) {
      try {
        await manager.init();
      } on Object {
        // Still unavailable.
      }
      if (_disposed) return;
      await refresh();
      return;
    }
    if (status?.state == ModelState.failed) await download();
  }

  /// Reads the candidates; with [autoLoad] loads the first when no model is loaded (only when the controller's
  /// [ModelSetupController.autoLoad] is on, unless the user asked: [explicit]). Returns the load, if any.
  Future<bool>? _refresh({required bool autoLoad, bool explicit = false}) {
    final manager = this.manager;
    final installed = manager != null && manager.isReady ? manager.installed : const <InstalledModel>[];
    _candidates = List.unmodifiable(_candidatesOf(installed));
    final assistant = this.assistant;
    if (!autoLoad || (!explicit && !this.autoLoad) || assistant == null || _candidates.isEmpty) return null;
    if (assistant.assistant.state.modelPath != null) return null;
    return assistant.loadModel(_candidates.first.path);
  }

  /// What `AssistantController.retryLoad` does when no model was loaded yet.
  Future<bool> _fallback() async {
    final loading = _refresh(autoLoad: true, explicit: true);
    notifyListeners();
    return await loading ?? false;
  }

  void _onManager() {
    if (_disposed) return;
    final before = _candidates.length;
    final state = assistant?.assistant.state;
    // Only when models appear: a model unloaded on purpose is not loaded again by a later change.
    unawaited(
      _refresh(
        autoLoad: before == 0 && state != null && state.modelPath == null && state.phase == AssistantPhase.noModel,
      ),
    );
    _trackDownloads();
    notifyListeners();
  }

  void _onPhase() {
    if (!_disposed) notifyListeners();
  }

  void _onResume() {
    final manager = this.manager;
    if (_disposed || manager == null || !manager.isReady) return;
    if (assistant != null && assistant!.phase.value != AssistantPhase.noModel) return;
    unawaited(manager.refreshCapabilities().catchError((Object _) {}));
  }

  void _trackDownloads() {
    final manager = this.manager;
    if (manager == null || !manager.isReady || _downloadStarts.isEmpty) return;
    for (final MapEntry(key: id, value: started) in _downloadStarts.entries.toList()) {
      final status = manager.statusOf(id);
      if (status.state == ModelState.ready) {
        _downloadStarts.remove(id);
        _track(ModelDownloadFinishedEvent(modelId: id, duration: DateTime.now().difference(started)));
      } else if (status.state == ModelState.failed) {
        _downloadStarts.remove(id);
        final error = status.error;
        final code =
            error?.download?.code.name ?? error?.code.name ?? status.problem?.runtimeType.toString() ?? 'unknown';
        _track(ModelDownloadFailedEvent(modelId: id, code: code));
      }
    }
  }

  void _track(ChatAnalyticsEvent event) {
    if (!_analytics.isClosed) _analytics.add(event);
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    manager?.removeListener(_onManager);
    final assistant = this.assistant;
    if (assistant != null) {
      assistant.phase.removeListener(_onPhase);
      if (assistant.retryFallback == _fallback) assistant.retryFallback = null;
    }
    _lifecycle?.dispose();
    unawaited(_analytics.close());
    super.dispose();
  }
}
