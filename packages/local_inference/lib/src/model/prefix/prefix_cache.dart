/// One saved prompt prefix of one engine: built once, restored whenever the context has moved away from it.
library;

import '../../engine/exceptions.dart';
import '../../engine/inference_engine.dart';
import 'model_identity.dart';
import 'prefix_key.dart';
import 'prefix_state_store.dart';

/// What [PrefixCache.prepare] did.
enum PrefixPreparation {
  /// The saved state was loaded.
  restored,

  /// The state was built (the prefix prefilled) and saved.
  built,

  /// The engine cannot save states (or the model does not need them): every call prefills in full.
  unsupported,
}

/// The saved state of one prompt prefix (system prompt and tool block) on [engine].
///
/// A recurrent model's context cannot be rewound to a shared prefix, so before each generation the prefix state is
/// restored, unless the context still holds it: [InferenceEngine.contextEpoch] has not moved since this cache's own
/// restore or build. Calls are not concurrent: await each before the next.
final class PrefixCache {
  PrefixCache({required this.engine, required this.model, required this.store});

  /// The engine whose context holds the prefix; loaded before [prepare].
  final InferenceEngine engine;

  /// The model file the states belong to.
  final ModelIdentity model;

  /// Where the states are kept.
  final PrefixStateStore store;

  PrefixKey? _key;
  String? _prefix;
  int? _epoch;

  /// The prefix of the last [prepare] that the engine supported; null before.
  String? get prefix => _prefix;

  /// Restores the saved state of [prefix], or builds it ([onBuild] first) when there is none or it fails to load (the
  /// file is then removed). Returns [PrefixPreparation.unsupported], and does nothing, when the engine cannot save
  /// states. Throws [StateError] when the engine has no model.
  Future<PrefixPreparation> prepare(String prefix, {void Function()? onBuild}) async {
    final info = engine.info;
    if (info == null) throw StateError('load a model before preparing a prefix');
    if (!engine.supportsStatePersistence) {
      _key = _prefix = _epoch = null;
      return PrefixPreparation.unsupported;
    }
    final key = PrefixKey.of(info, model, prefix);
    _key = key;
    _prefix = prefix;
    _epoch = null;
    if (await _load(key)) return PrefixPreparation.restored;
    onBuild?.call();
    await _build(key, prefix);
    return PrefixPreparation.built;
  }

  /// Before a generation: restores the prefix when [InferenceEngine.contextEpoch] moved since this cache's own
  /// restore or build (a missing state is built again, one that fails to load is removed and built again) and
  /// returns the time it took; zero when nothing was needed, before [prepare] and on an unsupported engine.
  Future<Duration> beforeGeneration() async {
    final key = _key;
    final prefix = _prefix;
    if (key == null || prefix == null || engine.contextEpoch == _epoch) return Duration.zero;
    final watch = Stopwatch()..start();
    if (!await _load(key)) await _build(key, prefix);
    return watch.elapsed;
  }

  /// Loads the state of [key]; false when there is none, or it failed to load and was removed.
  Future<bool> _load(PrefixKey key) async {
    final path = await store.find(key);
    if (path == null) return false;
    try {
      final loading = engine.loadState(path);
      final epoch = engine.contextEpoch;
      await loading;
      _epoch = epoch;
      return true;
    } on StateFileException {
      await store.remove(key);
      return false;
    }
  }

  Future<void> _build(PrefixKey key, String prefix) async {
    int? epoch;
    await store.put(key, (tempPath) async {
      final saving = engine.saveState(tempPath, prefix);
      epoch = engine.contextEpoch;
      await saving;
    });
    _epoch = epoch;
  }
}
