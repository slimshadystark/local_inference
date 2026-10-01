/// One generation: its handle, its result and its figures; and the result of a state save.
library;

/// Why a generation ended.
enum FinishReason {
  /// The model ended its answer (an end-of-generation token or a stop string).
  stop,

  /// [SamplingOptions.maxTokens] tokens were generated.
  maxTokens,

  /// [Generation.cancel] was called before the result completed.
  cancelled,
}

/// One queued generation. [InferenceEngine.generate] returns it at once; the work starts in its turn.
abstract interface class Generation {
  /// The raw text deltas, in order. Single subscription; deltas are buffered until it is listened to. A failure
  /// arrives as a [GenerationException] error event, then the stream closes. Cancelling the subscription does not
  /// stop the generation: [cancel] does.
  Stream<String> get text;

  /// Completes after the last delta, also when cancelled; fails with the same [GenerationException] as [text].
  /// Ignoring it (or [text]) raises no unhandled error.
  Future<GenerationResult> get result;

  /// Stops the generation: while it waits in the queue it never reaches the runtime (the result is cancelled with
  /// no text); while it streams, the runtime stops at its next token. Does nothing once the result is complete.
  void cancel();
}

/// The outcome of one generation.
final class GenerationResult {
  const GenerationResult({required this.text, required this.finishReason, required this.stats});

  /// Every delta of [Generation.text], joined.
  final String text;

  /// Why the generation ended.
  final FinishReason finishReason;

  /// The figures of this generation.
  final GenerationStats stats;

  @override
  String toString() => 'GenerationResult(${finishReason.name}, ${text.length} chars | $stats)';
}

/// Timing and size figures of one `generate` call.
///
/// Prompt-side numbers come from the engine's own counters; the wall-clock
/// numbers are measured by the caller side of the binding so they include
/// isolate and FFI overhead, which is what the user experiences.
final class GenerationStats {
  const GenerationStats({
    required this.loadMs,
    required this.promptTokens,
    required this.prefillTokens,
    required this.prefillMs,
    required this.decodeTokens,
    required this.decodeMs,
    required this.timeToFirstTokenMs,
    required this.totalMs,
    this.reusedPrefixTokens = 0,
    this.engineDecodeMs,
    this.engineSampleMs,
  });

  /// Engine-reported time inside the decode calls, ms. On asynchronous GPU
  /// backends (Metal) this excludes the GPU work, which is waited for when the
  /// logits are read; kept for the record, not for rates.
  final double? engineDecodeMs;

  /// Engine-reported sampling time, ms (on Metal it absorbs the GPU wait).
  final double? engineSampleMs;

  /// Wall time of `load()` (model + context), in milliseconds.
  final int loadMs;

  /// Tokens in the rendered prompt.
  final int promptTokens;

  /// Prompt tokens the engine actually evaluated (lower than [promptTokens]
  /// when a KV prefix was reused).
  final int prefillTokens;

  /// Engine-reported prompt evaluation time, ms.
  final double prefillMs;

  /// Tokens generated.
  final int decodeTokens;

  /// Wall time from the first text delta to the end of the stream, ms: the
  /// time in which the [decodeTokens] - 1 tokens after the first were
  /// produced. Includes sampling, detokenising and isolate transport, which is
  /// what the user waits for.
  final double decodeMs;

  /// Wall time from the call to the first text delta, ms.
  final double timeToFirstTokenMs;

  /// Wall time from the call to the end of the stream, ms.
  final double totalMs;

  /// Prompt tokens served from a reused KV prefix.
  final int reusedPrefixTokens;

  /// Prefill rate: [prefillTokens] over [prefillMs].
  double get prefillTokensPerSecond => prefillMs > 0 ? prefillTokens * 1000 / prefillMs : 0;

  /// Steady-state decode rate: tokens after the first, over [decodeMs].
  double get decodeTokensPerSecond => decodeMs > 0 && decodeTokens > 1 ? (decodeTokens - 1) * 1000 / decodeMs : 0;

  /// Every figure and both rates, snake_case keys.
  Map<String, dynamic> toJson() => {
    'load_ms': loadMs,
    'prompt_tokens': promptTokens,
    'prefill_tokens': prefillTokens,
    'prefill_ms': prefillMs,
    'prefill_tok_s': prefillTokensPerSecond,
    'decode_tokens': decodeTokens,
    'decode_wall_ms': decodeMs,
    'decode_tok_s': decodeTokensPerSecond,
    'ttft_ms': timeToFirstTokenMs,
    'total_ms': totalMs,
    'reused_prefix_tokens': reusedPrefixTokens,
    'engine_decode_ms': engineDecodeMs,
    'engine_sample_ms': engineSampleMs,
  };

  @override
  String toString() =>
      'load ${loadMs}ms | prompt $promptTokens tok, prefill $prefillTokens tok '
      'in ${prefillMs.toStringAsFixed(0)}ms (${prefillTokensPerSecond.toStringAsFixed(0)} tok/s)'
      '${reusedPrefixTokens > 0 ? ', $reusedPrefixTokens reused' : ''} '
      '| ttft ${timeToFirstTokenMs.toStringAsFixed(0)}ms '
      '| decode $decodeTokens tok, ${decodeTokensPerSecond.toStringAsFixed(1)} tok/s '
      '(${decodeMs.toStringAsFixed(0)}ms wall after first token'
      '${engineDecodeMs == null ? '' : '; engine decode ${engineDecodeMs!.toStringAsFixed(0)}ms + sample ${engineSampleMs?.toStringAsFixed(0) ?? '?'}ms'}) '
      '| total ${totalMs.toStringAsFixed(0)}ms';
}

/// Result of a KV-state save.
final class SavedState {
  const SavedState({required this.path, required this.tokens, required this.bytes, required this.ms});

  /// The state file.
  final String path;

  /// Tokens the state holds: those of the prefix.
  final int tokens;

  /// Size of the state file.
  final int bytes;

  /// Wall time of the save, prefix prefill included, ms.
  final int ms;
}
