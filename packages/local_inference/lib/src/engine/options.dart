/// Load and generation options of the L1 engine. Plain values: no engine types, no Qwen constants.
library;

import 'package:meta/meta.dart';

/// The compute backend a load asks for.
///
/// [auto] is llamadart's `GpuBackend.auto`: the runtime chooses. llamadart 0.8.23 picks Metal on Apple devices and
/// the CPU on Android, where it leaves Vulkan off unless asked (`resolvePreferredBackendForLoad` in
/// llama_cpp_service.dart).
enum ComputeBackend { auto, cpu, metal, vulkan, opencl }

/// Storage type of the KV cache. The quantized types need flash attention.
enum KvCacheQuant { f16, q8_0, q4_0 }

/// How much the runtime logs. Logging is process-global: the last engine loaded sets it for all.
enum EngineLogLevel { none, error, warn, info, debug }

/// How a model is loaded. The defaults are the settings the package's measurements used: 4096 tokens of context,
/// flash attention on, KV cache f16, every layer on the GPU.
@immutable
final class LoadOptions {
  const LoadOptions({
    this.contextTokens = 4096,
    this.threads,
    this.gpuLayers,
    this.microBatchSize,
    this.batchSize,
    this.flashAttention = true,
    this.kvCacheK = KvCacheQuant.f16,
    this.kvCacheV = KvCacheQuant.f16,
    this.compute = ComputeBackend.auto,
  });

  /// Context size in tokens (n_ctx).
  final int contextTokens;

  /// CPU threads for generation and for prompt processing; null (or 0) lets the runtime choose.
  final int? threads;

  /// Layers offloaded to the GPU; null (or a negative value) offloads all of them.
  final int? gpuLayers;

  /// Prompt tokens per GPU pass (n_ubatch). Null means 128 on iOS, where a hot phone aborted 512-token passes, and
  /// the runtime's default (512) elsewhere; 0 is the runtime's default everywhere.
  final int? microBatchSize;

  /// Logical batch size (n_batch); null (or 0) keeps the runtime's default.
  final int? batchSize;

  /// Flash attention; the quantized KV cache types need it.
  final bool flashAttention;

  /// Storage type of the KV cache's keys.
  final KvCacheQuant kvCacheK;

  /// Storage type of the KV cache's values.
  final KvCacheQuant kvCacheV;

  /// The compute backend asked for.
  final ComputeBackend compute;

  /// A copy with the given fields replaced. A null argument keeps the current value.
  LoadOptions copyWith({
    int? contextTokens,
    int? threads,
    int? gpuLayers,
    int? microBatchSize,
    int? batchSize,
    bool? flashAttention,
    KvCacheQuant? kvCacheK,
    KvCacheQuant? kvCacheV,
    ComputeBackend? compute,
  }) => LoadOptions(
    contextTokens: contextTokens ?? this.contextTokens,
    threads: threads ?? this.threads,
    gpuLayers: gpuLayers ?? this.gpuLayers,
    microBatchSize: microBatchSize ?? this.microBatchSize,
    batchSize: batchSize ?? this.batchSize,
    flashAttention: flashAttention ?? this.flashAttention,
    kvCacheK: kvCacheK ?? this.kvCacheK,
    kvCacheV: kvCacheV ?? this.kvCacheV,
    compute: compute ?? this.compute,
  );

  /// Every field, enums by name, in declaration order.
  Map<String, Object?> toJson() => {
    'contextTokens': contextTokens,
    'threads': threads,
    'gpuLayers': gpuLayers,
    'microBatchSize': microBatchSize,
    'batchSize': batchSize,
    'flashAttention': flashAttention,
    'kvCacheK': kvCacheK.name,
    'kvCacheV': kvCacheV.name,
    'compute': compute.name,
  };

  @override
  bool operator ==(Object other) =>
      other is LoadOptions &&
      other.contextTokens == contextTokens &&
      other.threads == threads &&
      other.gpuLayers == gpuLayers &&
      other.microBatchSize == microBatchSize &&
      other.batchSize == batchSize &&
      other.flashAttention == flashAttention &&
      other.kvCacheK == kvCacheK &&
      other.kvCacheV == kvCacheV &&
      other.compute == compute;

  @override
  int get hashCode => Object.hash(
    contextTokens,
    threads,
    gpuLayers,
    microBatchSize,
    batchSize,
    flashAttention,
    kvCacheK,
    kvCacheV,
    compute,
  );

  @override
  String toString() => 'LoadOptions(${_fields(toJson())})';
}

/// What switches a lazy [Grammar] on. llamadart's trigger types: 0 word, 1 token, 2 pattern, 3 pattern_full
/// (generation_params.dart:18).
@immutable
sealed class GrammarTrigger {
  const GrammarTrigger();

  /// The grammar applies from the first occurrence of [word] in the output.
  const factory GrammarTrigger.word(String word) = GrammarWordTrigger;

  /// The grammar applies from token [id] on; [text] is that token's text.
  const factory GrammarTrigger.token(int id, String text) = GrammarTokenTrigger;

  /// The grammar applies from the first match of [regex] in the output.
  const factory GrammarTrigger.pattern(String regex) = GrammarPatternTrigger;

  /// The grammar applies once [regex] matches the whole output.
  const factory GrammarTrigger.patternFull(String regex) = GrammarPatternFullTrigger;
}

/// [GrammarTrigger.word].
final class GrammarWordTrigger extends GrammarTrigger {
  const GrammarWordTrigger(this.word);

  /// The text that switches the grammar on.
  final String word;

  @override
  bool operator ==(Object other) => other is GrammarWordTrigger && other.word == word;

  @override
  int get hashCode => Object.hash(GrammarWordTrigger, word);

  @override
  String toString() => 'GrammarTrigger.word($word)';
}

/// [GrammarTrigger.token].
final class GrammarTokenTrigger extends GrammarTrigger {
  const GrammarTokenTrigger(this.id, this.text);

  /// The token's id in the model's vocabulary.
  final int id;

  /// The token's text.
  final String text;

  @override
  bool operator ==(Object other) => other is GrammarTokenTrigger && other.id == id && other.text == text;

  @override
  int get hashCode => Object.hash(GrammarTokenTrigger, id, text);

  @override
  String toString() => 'GrammarTrigger.token($id, $text)';
}

/// [GrammarTrigger.pattern].
final class GrammarPatternTrigger extends GrammarTrigger {
  const GrammarPatternTrigger(this.regex);

  /// A regular expression searched in the output.
  final String regex;

  @override
  bool operator ==(Object other) => other is GrammarPatternTrigger && other.regex == regex;

  @override
  int get hashCode => Object.hash(GrammarPatternTrigger, regex);

  @override
  String toString() => 'GrammarTrigger.pattern($regex)';
}

/// [GrammarTrigger.patternFull].
final class GrammarPatternFullTrigger extends GrammarTrigger {
  const GrammarPatternFullTrigger(this.regex);

  /// A regular expression the whole output must match.
  final String regex;

  @override
  bool operator ==(Object other) => other is GrammarPatternFullTrigger && other.regex == regex;

  @override
  int get hashCode => Object.hash(GrammarPatternFullTrigger, regex);

  @override
  String toString() => 'GrammarTrigger.patternFull($regex)';
}

/// A GBNF grammar the output must follow: from the start, or from the first trigger when there are [triggers].
@immutable
final class Grammar {
  const Grammar(this.gbnf, {this.triggers = const []});

  /// The grammar in GBNF; its start rule is `root`.
  final String gbnf;

  /// What switches the grammar on; with none it applies from the first token.
  final List<GrammarTrigger> triggers;

  /// Whether the grammar waits for a trigger (plain text before it stays free).
  bool get isLazy => triggers.isNotEmpty;

  @override
  bool operator ==(Object other) => other is Grammar && other.gbnf == gbnf && _listEquals(other.triggers, triggers);

  @override
  int get hashCode => Object.hash(gbnf, Object.hashAll(triggers));

  @override
  String toString() => 'Grammar(${gbnf.length} chars, triggers: $triggers)';
}

/// Sampling of one generation. The defaults are greedy decoding (temperature 0) with no penalties and a fixed seed,
/// so a run can be repeated. Every field is explicit, so the runtime's own defaults (penalty 1.1) never apply.
@immutable
final class SamplingOptions {
  const SamplingOptions({
    this.maxTokens = 1024,
    this.temperature = 0,
    this.topK = 40,
    this.topP = 0.9,
    this.minP = 0,
    this.repeatPenalty = 1.0,
    this.presencePenalty = 0,
    this.seed = 1,
  });

  /// Most tokens generated; reaching it ends the generation with [FinishReason.maxTokens].
  final int maxTokens;

  /// 0 is greedy decoding: the most likely token every time.
  final double temperature;

  /// Only the [topK] most likely tokens are candidates.
  final int topK;

  /// Nucleus sampling: the most likely tokens whose probabilities add up to [topP] are candidates.
  final double topP;

  /// Tokens less likely than [minP] times the most likely one are dropped; 0 keeps them.
  final double minP;

  /// 1.0 is no penalty.
  final double repeatPenalty;

  /// 0 is no penalty.
  final double presencePenalty;

  /// Seed of the sampler's random numbers.
  final int seed;

  /// A copy with the given fields replaced. A null argument keeps the current value.
  SamplingOptions copyWith({
    int? maxTokens,
    double? temperature,
    int? topK,
    double? topP,
    double? minP,
    double? repeatPenalty,
    double? presencePenalty,
    int? seed,
  }) => SamplingOptions(
    maxTokens: maxTokens ?? this.maxTokens,
    temperature: temperature ?? this.temperature,
    topK: topK ?? this.topK,
    topP: topP ?? this.topP,
    minP: minP ?? this.minP,
    repeatPenalty: repeatPenalty ?? this.repeatPenalty,
    presencePenalty: presencePenalty ?? this.presencePenalty,
    seed: seed ?? this.seed,
  );

  @override
  bool operator ==(Object other) =>
      other is SamplingOptions &&
      other.maxTokens == maxTokens &&
      other.temperature == temperature &&
      other.topK == topK &&
      other.topP == topP &&
      other.minP == minP &&
      other.repeatPenalty == repeatPenalty &&
      other.presencePenalty == presencePenalty &&
      other.seed == seed;

  @override
  int get hashCode => Object.hash(maxTokens, temperature, topK, topP, minP, repeatPenalty, presencePenalty, seed);

  @override
  String toString() =>
      'SamplingOptions(maxTokens: $maxTokens, temperature: $temperature, topK: $topK, topP: $topP, minP: $minP, '
      'repeatPenalty: $repeatPenalty, presencePenalty: $presencePenalty, seed: $seed)';
}

/// Options of one generation. The engine adds nothing model-specific: stop strings, grammar and preserved tokens
/// come from the caller (the model family's profile, for a ChatModel).
@immutable
final class GenerationOptions {
  const GenerationOptions({
    this.sampling = const SamplingOptions(),
    this.stop = const [],
    this.grammar,
    this.preservedTokens = const [],
    this.reusePromptPrefix = true,
    this.streamChunkTokens = 1,
  });

  /// How tokens are chosen, and how many at most.
  final SamplingOptions sampling;

  /// Strings that end the generation when generated.
  final List<String> stop;

  /// A grammar the output must follow; null for free text.
  final Grammar? grammar;

  /// Special strings kept as one token each during constrained decoding.
  final List<String> preservedTokens;

  /// Reuse the part of the context that equals the prompt's start (the runtime re-decodes only the rest).
  final bool reusePromptPrefix;

  /// Tokens per text delta. 1 streams token by token (llamadart would batch 8).
  final int streamChunkTokens;

  /// A copy with the given fields replaced. A null argument keeps the current value.
  GenerationOptions copyWith({
    SamplingOptions? sampling,
    List<String>? stop,
    Grammar? grammar,
    List<String>? preservedTokens,
    bool? reusePromptPrefix,
    int? streamChunkTokens,
  }) => GenerationOptions(
    sampling: sampling ?? this.sampling,
    stop: stop ?? this.stop,
    grammar: grammar ?? this.grammar,
    preservedTokens: preservedTokens ?? this.preservedTokens,
    reusePromptPrefix: reusePromptPrefix ?? this.reusePromptPrefix,
    streamChunkTokens: streamChunkTokens ?? this.streamChunkTokens,
  );

  @override
  bool operator ==(Object other) =>
      other is GenerationOptions &&
      other.sampling == sampling &&
      _listEquals(other.stop, stop) &&
      other.grammar == grammar &&
      _listEquals(other.preservedTokens, preservedTokens) &&
      other.reusePromptPrefix == reusePromptPrefix &&
      other.streamChunkTokens == streamChunkTokens;

  @override
  int get hashCode => Object.hash(
    sampling,
    Object.hashAll(stop),
    grammar,
    Object.hashAll(preservedTokens),
    reusePromptPrefix,
    streamChunkTokens,
  );

  @override
  String toString() =>
      'GenerationOptions(sampling: $sampling, stop: $stop, grammar: $grammar, preservedTokens: $preservedTokens, '
      'reusePromptPrefix: $reusePromptPrefix, streamChunkTokens: $streamChunkTokens)';
}

bool _listEquals<T>(List<T> a, List<T> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

String _fields(Map<String, Object?> json) => [for (final e in json.entries) '${e.key}: ${e.value}'].join(', ');
