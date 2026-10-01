/// [InferenceEngine] on llamadart 0.8.23 (llama.cpp v0.4.0). With llamadart_families.dart, the only file of
/// local_inference that imports llamadart.
///
/// Prompts arrive rendered and go to `LlamaEngine.generate` (raw prompt), not to `create(tools: ...)`: llamadart's
/// `ToolDefinition` cannot carry `anyOf`, `additionalProperties`, `minimum`/`maximum` or a schema's key order, so its
/// rendering would not be the text a model was trained on. The raw path still has GBNF (eager or lazy), streaming,
/// cancel, perf counters and state save/load.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:llamadart/llamadart.dart' as ll;
import 'package:meta/meta.dart';

import '../engine/engine_info.dart';
import '../engine/exceptions.dart';
import '../engine/generation.dart';
import '../engine/inference_engine.dart';
import '../engine/options.dart';
import '../engine/serial_queue.dart';

/// The llama.cpp engine.
///
/// Logging is process-global in llamadart: each [load] points it at this engine's level and [log].
final class LlamadartEngine implements InferenceEngine {
  LlamadartEngine({
    EngineLogLevel logLevel = EngineLogLevel.warn,
    void Function(String line)? log,
    RuntimeInfo runtime = defaultRuntime,
  }) : this._(ll.LlamaEngine(ll.LlamaBackend()), logLevel, log, runtime, Platform.isIOS);

  /// An engine over [backend] instead of the native one, to test the adapter without a model.
  @visibleForTesting
  LlamadartEngine.withBackend(
    ll.LlamaBackend backend, {
    EngineLogLevel logLevel = EngineLogLevel.warn,
    void Function(String line)? log,
    RuntimeInfo runtime = defaultRuntime,
    bool? isIOS,
  }) : this._(ll.LlamaEngine(backend), logLevel, log, runtime, isIOS ?? Platform.isIOS);

  LlamadartEngine._(this._native, this._logLevel, void Function(String line)? log, this.runtime, this._isIOS)
    : _log = log ?? stderr.writeln;

  /// llamadart 0.8.23 on the llama.cpp bundles of llamadart-native v0.4.0. The native tag cannot be read at runtime
  /// (llamadart hook/build.dart:17), so it is pinned with the exact llamadart version.
  static const RuntimeInfo defaultRuntime = RuntimeInfo(
    binding: 'llamadart',
    bindingVersion: '0.8.23',
    native: 'llama.cpp v0.4.0',
  );

  /// What [saveState] fills the context with: the prompt decode only (maxTokens 0). A sampled token would advance a
  /// recurrent (Gated DeltaNet) state past the prefix, and such a state cannot be rewound.
  static const ll.GenerationParams _prefixFillParams = ll.GenerationParams(
    maxTokens: 0,
    temp: 0,
    reusePromptPrefix: true,
  );

  final ll.LlamaEngine _native;
  final EngineLogLevel _logLevel;
  final void Function(String line) _log;
  final bool _isIOS;

  /// What [EngineInfo.runtime] reports.
  final RuntimeInfo runtime;
  final SerialQueue _queue = SerialQueue();

  EngineInfo? _info;
  bool _loading = false;
  Future<void>? _disposed;
  int _loadMs = 0;
  int _contextEpoch = 0;

  /// The llamadart engine underneath. Unstable: it bypasses the queue and the options mapping.
  @experimental
  ll.LlamaEngine get native => _native;

  /// The llamadart parameters of a generation with [options]. Every field [GenerationOptions] does not cover keeps
  /// llamadart's default.
  @visibleForTesting
  static ll.GenerationParams paramsFor(GenerationOptions options) {
    final sampling = options.sampling;
    final grammar = options.grammar;
    return ll.GenerationParams(
      maxTokens: sampling.maxTokens,
      temp: sampling.temperature,
      topK: sampling.topK,
      topP: sampling.topP,
      minP: sampling.minP,
      penalty: sampling.repeatPenalty,
      presencePenalty: sampling.presencePenalty,
      seed: sampling.seed,
      stopSequences: options.stop,
      grammar: grammar?.gbnf,
      grammarLazy: grammar?.isLazy ?? false,
      grammarTriggers: [for (final trigger in grammar?.triggers ?? const <GrammarTrigger>[]) _trigger(trigger)],
      preservedTokens: options.preservedTokens,
      reusePromptPrefix: options.reusePromptPrefix,
      streamBatchTokenThreshold: options.streamChunkTokens,
    );
  }

  static ll.GenerationGrammarTrigger _trigger(GrammarTrigger trigger) => switch (trigger) {
    GrammarWordTrigger(:final word) => ll.GenerationGrammarTrigger(type: 0, value: word),
    GrammarTokenTrigger(:final id, :final text) => ll.GenerationGrammarTrigger(type: 1, value: text, token: id),
    GrammarPatternTrigger(:final regex) => ll.GenerationGrammarTrigger(type: 2, value: regex),
    GrammarPatternFullTrigger(:final regex) => ll.GenerationGrammarTrigger(type: 3, value: regex),
  };

  /// The llamadart parameters of a load with [options] on iOS ([isIOS]) or elsewhere.
  @visibleForTesting
  static ll.ModelParams modelParamsFor(LoadOptions options, {required bool isIOS}) {
    final gpuLayers = options.gpuLayers;
    final threads = options.threads ?? 0;
    return ll.ModelParams(
      contextSize: options.contextTokens,
      gpuLayers: gpuLayers == null || gpuLayers < 0 ? ll.ModelParams.maxGpuLayers : gpuLayers,
      numberOfThreads: threads,
      numberOfThreadsBatch: threads,
      // n_ubatch: prompt tokens per GPU pass. Shorter passes keep each Metal command buffer short, which matters on a
      // hot iPhone, where 512-token passes failed; 0 keeps llama.cpp's 512.
      microBatchSize: _microBatchSize(options, isIOS: isIOS),
      batchSize: options.batchSize ?? const ll.ModelParams().batchSize,
      preferredBackend: switch (options.compute) {
        ComputeBackend.auto => ll.GpuBackend.auto,
        ComputeBackend.cpu => ll.GpuBackend.cpu,
        ComputeBackend.metal => ll.GpuBackend.metal,
        ComputeBackend.vulkan => ll.GpuBackend.vulkan,
        ComputeBackend.opencl => ll.GpuBackend.opencl,
      },
      flashAttention: options.flashAttention ? ll.FlashAttention.enabled : ll.FlashAttention.disabled,
      cacheTypeK: _kvCacheType(options.kvCacheK),
      cacheTypeV: _kvCacheType(options.kvCacheV),
    );
  }

  static int _microBatchSize(LoadOptions options, {required bool isIOS}) => options.microBatchSize ?? (isIOS ? 128 : 0);

  static ll.KvCacheType _kvCacheType(KvCacheQuant quant) => switch (quant) {
    KvCacheQuant.f16 => ll.KvCacheType.f16,
    KvCacheQuant.q8_0 => ll.KvCacheType.q8_0,
    KvCacheQuant.q4_0 => ll.KvCacheType.q4_0,
  };

  static ll.LlamaLogLevel _llamaLogLevel(EngineLogLevel level) => switch (level) {
    EngineLogLevel.none => ll.LlamaLogLevel.none,
    EngineLogLevel.error => ll.LlamaLogLevel.error,
    EngineLogLevel.warn => ll.LlamaLogLevel.warn,
    EngineLogLevel.info => ll.LlamaLogLevel.info,
    EngineLogLevel.debug => ll.LlamaLogLevel.debug,
  };

  @override
  bool get isLoaded => _info != null && _disposed == null;

  @override
  EngineInfo? get info => _disposed == null ? _info : null;

  @override
  int get contextEpoch => _contextEpoch;

  @override
  bool get supportsStatePersistence => _disposed == null && _native.isReady && _native.supportsStatePersistence;

  @override
  Future<EngineInfo> load(String modelPath, [LoadOptions options = const LoadOptions()]) async {
    _checkOpen();
    if (_loading || _info != null) throw StateError('a model is already loaded or loading: use a new engine');
    _loading = true;
    try {
      return await _queue.run(() => _load(modelPath, options));
    } finally {
      _loading = false;
    }
  }

  Future<EngineInfo> _load(String modelPath, LoadOptions options) async {
    ll.LlamaEngine.configureLogging(
      level: _llamaLogLevel(_logLevel),
      handler: (record) => _log('[llamadart ${record.level.name}] ${record.message}'),
    );
    final params = modelParamsFor(options, isIOS: _isIOS);
    final sw = Stopwatch()..start();
    try {
      await _native.loadModel(modelPath, modelParams: params);
    } catch (e) {
      throw ModelLoadException('cannot load $modelPath', cause: e);
    }
    _loadMs = sw.elapsedMilliseconds;
    try {
      final metadata = await _native.getMetadata();
      final template = metadata['tokenizer.chat_template'];
      final contextTokens = await _native.getContextSize();
      final gpuLayers = await _native.getResolvedGpuLayers();
      return _info = EngineInfo(
        modelPath: modelPath,
        modelBytes: File(modelPath).lengthSync(),
        backend: await _native.getBackendName(),
        gpuLayers: gpuLayers,
        contextTokens: contextTokens,
        loadMs: _loadMs,
        options: options.copyWith(
          contextTokens: contextTokens,
          threads: params.numberOfThreads,
          gpuLayers: gpuLayers ?? params.gpuLayers,
          microBatchSize: params.microBatchSize,
          batchSize: params.batchSize,
        ),
        metadata: metadata,
        runtimeDetails: {
          if (template != null && template.isNotEmpty)
            'llamadart.chat_format': ll.ChatTemplateEngine.detectFormat(template).name,
        },
        runtime: runtime,
        addsBos: (await _native.tokenize('')).isNotEmpty,
      );
    } catch (e) {
      try {
        await _native.unloadModel();
      } catch (_) {
        // The load already failed; its error is the one reported.
      }
      throw ModelLoadException('cannot read $modelPath after loading it', cause: e);
    }
  }

  @override
  Generation generate(String prompt, [GenerationOptions options = const GenerationOptions()]) {
    _checkOpen();
    _contextEpoch++;
    GenerationStats stats({int promptTokens = 0}) => GenerationStats(
      loadMs: _loadMs,
      promptTokens: promptTokens,
      prefillTokens: 0,
      prefillMs: 0,
      decodeTokens: 0,
      decodeMs: 0,
      timeToFirstTokenMs: 0,
      totalMs: 0,
    );
    final generation = QueuedGeneration(maxTokens: options.sampling.maxTokens, emptyStats: stats);
    _queue.runGeneration(generation, () async {
      _checkLoaded();
      final promptTokens = (await _native.tokenize(prompt)).length;
      if (generation.isCancelled) return stats(promptTokens: promptTokens);
      return _stream(generation, prompt, promptTokens, paramsFor(options));
    });
    return generation;
  }

  /// Runs the native generation into [generation] and measures it (prompt tokens, runtime counters, wall clock).
  Future<GenerationStats> _stream(
    QueuedGeneration generation,
    String prompt,
    int promptTokens,
    ll.GenerationParams params,
  ) async {
    final sw = Stopwatch()..start();
    double? ttft;
    generation.onCancel = _native.cancelGeneration;
    try {
      await for (final delta in _native.generate(prompt, params: params)) {
        ttft ??= sw.elapsedMicroseconds / 1000;
        // A cancel that came before the runtime started its generation had nothing to stop yet.
        if (generation.isCancelled) _native.cancelGeneration();
        generation.emit(delta);
      }
    } finally {
      generation.onCancel = null;
    }
    sw.stop();
    final totalMs = sw.elapsedMicroseconds / 1000;
    final ttftMs = ttft ?? totalMs;
    final perf = await _native.getPerformanceContext();
    // llamadart's prompt-token counter is llama.cpp's n_p_eval, which counts
    // only the tokens actually decoded (a reused KV prefix is not re-decoded).
    final prefill = perf?.promptEvalTokens ?? promptTokens;
    return GenerationStats(
      loadMs: _loadMs,
      promptTokens: promptTokens,
      prefillTokens: prefill,
      prefillMs: perf?.promptEvalMs ?? 0,
      decodeTokens: perf?.evalTokens ?? 0,
      // Wall clock after the first token: the Dart-side stopwatch around
      // llama_decode that llamadart reports as evalMs returns before Metal has
      // finished (the wait happens when logits are read, inside sampling).
      decodeMs: math.max(0, totalMs - ttftMs),
      timeToFirstTokenMs: ttftMs,
      totalMs: totalMs,
      reusedPrefixTokens: math.max(0, promptTokens - prefill),
      engineDecodeMs: perf?.evalMs,
      engineSampleMs: perf?.sampleMs,
    );
  }

  @override
  Future<List<int>> tokenize(String text) async {
    _checkOpen();
    return _queue.run(() async {
      _checkLoaded();
      return _native.tokenize(text);
    });
  }

  @override
  Future<int> countTokens(String text) async => (await tokenize(text)).length;

  @override
  Future<SavedState> saveState(String path, String promptPrefix) async {
    _checkOpen();
    _contextEpoch++;
    return _queue.run(() async {
      _checkLoaded();
      final sw = Stopwatch()..start();
      try {
        final tokens = await _native.tokenize(promptPrefix);
        // Fill the context with exactly the prefix tokens and nothing else: maxTokens 0 runs the prompt decode and
        // skips the generation loop. Then persist with the token sequence it came from.
        await _native.generate(promptPrefix, params: _prefixFillParams).drain<void>();
        if (!await _native.stateSaveFile(path, tokens: tokens)) {
          throw StateFileException('stateSaveFile returned false for $path');
        }
        return SavedState(
          path: path,
          tokens: tokens.length,
          bytes: File(path).lengthSync(),
          ms: sw.elapsedMilliseconds,
        );
      } on StateFileException {
        rethrow;
      } catch (e) {
        throw StateFileException('cannot save the state to $path', cause: e);
      }
    });
  }

  @override
  Future<int> loadState(String path) async {
    _checkOpen();
    _contextEpoch++;
    return _queue.run(() async {
      _checkLoaded();
      try {
        final result = await _native.stateLoadFile(path, tokenCapacity: _info!.contextTokens);
        return result.tokens.length;
      } catch (e) {
        throw StateFileException('cannot load the state $path', cause: e);
      }
    });
  }

  @override
  Future<void> dispose() => _disposed ??= _dispose();

  Future<void> _dispose() async {
    await _queue.close();
    await _native.dispose();
  }

  void _checkOpen() {
    if (_disposed != null) throw StateError('the engine is disposed');
  }

  void _checkLoaded() {
    if (_info == null) throw StateError('load() a model first');
  }
}
