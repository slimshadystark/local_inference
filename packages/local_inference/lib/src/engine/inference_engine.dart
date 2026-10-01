/// The L1 engine contract: a rendered prompt goes in, text comes out.
library;

import 'engine_info.dart';
import 'generation.dart';
import 'options.dart';

/// Creates an engine. One engine holds one model: another model means another engine.
typedef EngineFactory = InferenceEngine Function();

/// A local runtime behind one narrow surface. It renders nothing: prompts arrive rendered, and stop strings, grammar
/// and preserved tokens come in [GenerationOptions].
///
/// [load], [generate], [tokenize] and [countTokens], [saveState], [loadState] and [dispose] run one at a time, in call
/// order. After [dispose] every call throws [StateError].
abstract interface class InferenceEngine {
  /// Loads [modelPath]. Throws [StateError] while a model is loaded or loading, [ModelLoadException] when the runtime
  /// cannot load it. A model without a chat template loads ([EngineInfo.chatTemplate] is then null).
  Future<EngineInfo> load(String modelPath, [LoadOptions options = const LoadOptions()]);

  /// Whether a model is loaded and the engine is not disposed.
  bool get isLoaded;

  /// The loaded model; null before [load] completes and after [dispose].
  EngineInfo? get info;

  /// Counts the calls that change the context: [generate], [saveState] and [loadState] add 1 when called, before
  /// they return, whether they later run, fail or are cancelled. An unchanged value means the context still holds
  /// what the caller left there.
  int get contextEpoch;

  /// Queues a generation from the rendered [prompt] and returns its handle at once. A runtime failure, or no model
  /// loaded when its turn comes, fails the handle; only a call after [dispose] throws ([StateError]).
  Generation generate(String prompt, [GenerationOptions options = const GenerationOptions()]);

  /// The tokens of [text], special tokens added as [generate] adds them (the vocabulary decides about BOS).
  Future<List<int>> tokenize(String text);

  /// `(await tokenize(text)).length`.
  Future<int> countTokens(String text);

  /// Whether [saveState] and [loadState] work on this runtime.
  bool get supportsStatePersistence;

  /// Fills the context with exactly [promptPrefix], samples nothing, and writes the state to [path]. A recurrent
  /// state cannot be rewound, so the state ends at the prefix's last token. Failures throw [StateFileException].
  Future<SavedState> saveState(String path, String promptPrefix);

  /// Restores a state written by [saveState]; returns the tokens it holds. Failures throw [StateFileException].
  Future<int> loadState(String path);

  /// Frees the model. Queued generations complete as cancelled, other queued calls fail with [StateError], and a
  /// running generation is cancelled. Calling it again does nothing more.
  Future<void> dispose();
}
