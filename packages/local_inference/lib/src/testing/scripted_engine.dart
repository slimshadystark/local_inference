/// A scripted [InferenceEngine] for tests: no model and no native code, the same queue and cancel rules as the real
/// engine.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import '../engine/engine_info.dart';
import '../engine/exceptions.dart';
import '../engine/generation.dart';
import '../engine/inference_engine.dart';
import '../engine/options.dart';
import '../engine/serial_queue.dart';
import 'qwen35_template.dart';

/// A generation found no output left in [ScriptedEngine.outputs]: the test script is too short.
final class ScriptExhausted extends Error {
  ScriptExhausted(this.message);

  /// Which generation found no output, and the end of its prompt.
  final String message;

  @override
  String toString() => 'ScriptExhausted: $message';
}

/// An engine that answers each generation with the next string of [outputs], in [chunkSize]-character deltas, and
/// records what it was asked.
///
/// Unlike a real engine it may be loaded again, also while loaded and after [dispose], so one instance can serve
/// several controllers or reloads. Otherwise it keeps the engine rules: operations run in call order, a cancel acts
/// as on a real engine, and [dispose] cancels the queued and running generations and fails the other queued calls;
/// until the next [load], every call throws [StateError]. Its figures are deterministic: prompt and prefill tokens
/// are `prompt.length ~/ 4`, decode tokens the number of deltas, times 0; [countTokens] is `text.length ~/ 4`.
/// [saveState] writes the prefix text itself to the file, [loadState] reads it back.
///
/// A generation with no output left fails with [ScriptExhausted], which is also reported to the zone of the
/// [generate] call: the test fails even when the code under test catches every error.
class ScriptedEngine implements InferenceEngine {
  ScriptedEngine({
    this.chatTemplate = qwen35ChatTemplate,
    Map<String, String> metadata = const {},
    this.chunkSize = 7,
    this.supportsStatePersistence = true,
  }) : assert(chunkSize > 0, 'chunkSize must be positive'),
       _metadata = metadata;

  /// The runtime a [ScriptedEngine] reports.
  static const RuntimeInfo runtime = RuntimeInfo(binding: 'scripted', bindingVersion: '1', native: 'none');

  /// The `tokenizer.chat_template` of the models it loads.
  final String chatTemplate;

  /// More GGUF metadata of the models it loads; it can replace `general.architecture` (`qwen35`) and the template.
  final Map<String, String> _metadata;

  /// Characters per text delta.
  final int chunkSize;

  @override
  final bool supportsStatePersistence;

  /// The raw outputs still to give, one per generation, consumed in order.
  final List<String> outputs = [];

  /// Every prompt received, in call order.
  final List<String> prompts = [];

  /// The options of every generation, in call order.
  final List<GenerationOptions> options = [];

  /// Calls of [saveState].
  int saves = 0;

  /// Calls of [loadState].
  int loads = 0;

  /// Calls of [dispose].
  int disposes = 0;

  /// While set and not completed, a generation waits for it before its first delta (a turn stays running). A cancel
  /// ends the wait.
  Completer<void>? gate;

  /// Thrown once by the next [loadState], wrapped in a [StateFileException].
  Object? failNextLoadState;

  /// `(n, error)`: the next generation fails with `error` after n deltas (after all of them when its output has
  /// fewer), as a runtime failure does: the handle gets a [GenerationException] whose cause is `error`.
  (int, Object)? throwAfterDeltas;

  SerialQueue _queue = SerialQueue();
  EngineInfo? _info;
  int _contextEpoch = 0;

  @override
  bool get isLoaded => _info != null;

  @override
  EngineInfo? get info => _info;

  @override
  int get contextEpoch => _contextEpoch;

  @override
  Future<EngineInfo> load(String modelPath, [LoadOptions options = const LoadOptions()]) {
    // A real engine stays disposed; this one starts a new queue.
    if (_queue.isClosed) _queue = SerialQueue();
    return _queue.run(() async {
      final file = File(modelPath);
      return _info = EngineInfo(
        modelPath: modelPath,
        modelBytes: file.existsSync() ? file.lengthSync() : 0,
        backend: 'scripted',
        gpuLayers: 0,
        contextTokens: options.contextTokens,
        loadMs: 0,
        options: options,
        metadata: {'tokenizer.chat_template': chatTemplate, 'general.architecture': 'qwen35', ..._metadata},
        runtime: runtime,
        addsBos: false,
      );
    });
  }

  @override
  Generation generate(String prompt, [GenerationOptions options = const GenerationOptions()]) {
    _checkOpen();
    _contextEpoch++;
    prompts.add(prompt);
    this.options.add(options);
    final number = prompts.length;
    final zone = Zone.current;
    final generation = QueuedGeneration(maxTokens: options.sampling.maxTokens, emptyStats: () => _stats(prompt, 0));
    _queue.runGeneration(generation, () => _run(generation, prompt, number, zone));
    return generation;
  }

  Future<GenerationStats> _run(QueuedGeneration generation, String prompt, int number, Zone zone) async {
    final gate = this.gate;
    if (gate != null) {
      // A real engine stops before its first token when cancelled there.
      final cancelled = Completer<void>();
      generation.onCancel = cancelled.complete;
      await Future.any([gate.future, cancelled.future]);
      generation.onCancel = null;
    }
    if (generation.isCancelled) return _stats(prompt, 0);
    if (outputs.isEmpty) {
      final tail = prompt.length > 80 ? '…${prompt.substring(prompt.length - 80)}' : prompt;
      final error = ScriptExhausted(
        'generation $number found no output left in ScriptedEngine.outputs; its prompt ends ${jsonEncode(tail)}',
      );
      // The caller may catch every error (a chat turn shows a generic reply); the test must fail anyway.
      zone.handleUncaughtError(error, StackTrace.current);
      throw error;
    }
    final output = outputs.removeAt(0);
    final failure = throwAfterDeltas;
    throwAfterDeltas = null;
    var deltas = 0;
    for (var i = 0; i < output.length && !generation.isCancelled; i += chunkSize) {
      if (failure != null && deltas == failure.$1) break;
      generation.emit(output.substring(i, math.min(i + chunkSize, output.length)));
      deltas++;
      // One microtask per delta: the consumer sees each delta before the next and can cancel in between.
      await Future<void>.value();
    }
    if (failure != null && !generation.isCancelled) Error.throwWithStackTrace(failure.$2, StackTrace.current);
    return _stats(prompt, deltas);
  }

  static GenerationStats _stats(String prompt, int deltas) => GenerationStats(
    loadMs: 0,
    promptTokens: prompt.length ~/ 4,
    prefillTokens: prompt.length ~/ 4,
    prefillMs: 0,
    decodeTokens: deltas,
    decodeMs: 0,
    timeToFirstTokenMs: 0,
    totalMs: 0,
  );

  @override
  Future<List<int>> tokenize(String text) async {
    _checkOpen();
    return _queue.run(() async => List<int>.generate(text.length ~/ 4, (i) => i));
  }

  @override
  Future<int> countTokens(String text) async => (await tokenize(text)).length;

  @override
  Future<SavedState> saveState(String path, String promptPrefix) async {
    _checkOpen();
    _contextEpoch++;
    return _queue.run(() async {
      saves++;
      _checkPersistence();
      try {
        File(path).writeAsStringSync(promptPrefix);
      } catch (e) {
        throw StateFileException('cannot write $path', cause: e);
      }
      return SavedState(path: path, tokens: promptPrefix.length ~/ 4, bytes: promptPrefix.length, ms: 0);
    });
  }

  @override
  Future<int> loadState(String path) async {
    _checkOpen();
    _contextEpoch++;
    return _queue.run(() async {
      loads++;
      _checkPersistence();
      final failure = failNextLoadState;
      if (failure != null) {
        failNextLoadState = null;
        throw StateFileException('scripted loadState failure', cause: failure);
      }
      try {
        return File(path).readAsStringSync().length ~/ 4;
      } catch (e) {
        throw StateFileException('cannot read $path', cause: e);
      }
    });
  }

  void _checkPersistence() {
    if (!supportsStatePersistence) throw const StateFileException('this ScriptedEngine has no state persistence');
  }

  void _checkOpen() {
    if (_queue.isClosed) throw StateError('the engine is disposed');
  }

  /// Counts the call; then as on a real engine: queued generations end cancelled, other queued calls fail with
  /// [StateError], the running generation is cancelled. Completes once the running operation has finished.
  @override
  Future<void> dispose() {
    disposes++;
    _info = null;
    return _queue.close();
  }
}
