/// What an engine knows about its runtime and the loaded model.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:meta/meta.dart';

import 'options.dart';

/// The binding and the native build behind an engine. A state file saved by one native build may not load in
/// another, so it is part of every prefix-state key.
@immutable
final class RuntimeInfo {
  const RuntimeInfo({required this.binding, required this.bindingVersion, required this.native});

  /// The Dart binding, for example `llamadart`.
  final String binding;

  /// The binding's exact version, for example `0.8.23`.
  final String bindingVersion;

  /// The native build, for example `llama.cpp v0.4.0`.
  final String native;

  /// `binding bindingVersion / native`, for example `llamadart 0.8.23 / llama.cpp v0.4.0`.
  String get id => '$binding $bindingVersion / $native';

  @override
  bool operator ==(Object other) =>
      other is RuntimeInfo &&
      other.binding == binding &&
      other.bindingVersion == bindingVersion &&
      other.native == native;

  @override
  int get hashCode => Object.hash(binding, bindingVersion, native);

  @override
  String toString() => id;
}

/// GGUF architectures whose context holds a recurrent state, alone or next to attention layers. Such a state cannot
/// be rewound, so a prompt that shares only a prefix with the context is prefilled again in full, and a saved state is
/// the only way to skip a common prefix.
///
/// llama.cpp's `llm_arch_is_recurrent` and `llm_arch_is_hybrid` (src/llama-arch.cpp:1050-1087 at 5266f24, the llama.cpp
/// commit of llamadart-native v0.4.0), each enum mapped to its `LLM_ARCH_NAMES` string (llama-arch.cpp:38-151).
const Set<String> recurrentArchitectures = {
  // llm_arch_is_recurrent
  'mamba', 'mamba2', 'rwkv6', 'rwkv6qwen2', 'rwkv7', 'arwkv7',
  // llm_arch_is_hybrid
  'jamba', 'falcon-h1', 'plamo2', 'granitehybrid', 'lfm2', 'lfm2moe', 'nemotron_h', 'nemotron_h_moe', 'qwen3next',
  'kimi-linear', 'bailingmoe3', 'kimi-k3', 'qwen35', 'qwen35moe', 'qwen4exp', 'deepseek4', 'minimax-01',
};

/// The loaded model and how it was loaded.
final class EngineInfo {
  EngineInfo({
    required this.modelPath,
    required this.modelBytes,
    required this.backend,
    required this.gpuLayers,
    required this.contextTokens,
    required this.loadMs,
    required this.options,
    required Map<String, String> metadata,
    Map<String, String> runtimeDetails = const {},
    required this.runtime,
    required this.addsBos,
  }) : metadata = Map.unmodifiable(metadata),
       runtimeDetails = Map.unmodifiable(runtimeDetails);

  /// The model file.
  final String modelPath;

  /// Size of the model file.
  final int modelBytes;

  /// The compute backend the runtime selected, as it names it (for example `Metal`).
  final String backend;

  /// Layers on the GPU as the runtime resolved them; null when it does not say.
  final int? gpuLayers;

  /// Context size in tokens, as created.
  final int contextTokens;

  /// Wall time of the model load, ms.
  final int loadMs;

  /// The load options as applied: microBatchSize, threads and gpuLayers resolved (0 = the runtime's default).
  final LoadOptions options;

  /// The model's GGUF metadata, values as strings.
  final Map<String, String> metadata;

  /// What the runtime derived from the model, for example `{'llamadart.chat_format': 'qwen3CoderXml'}`.
  final Map<String, String> runtimeDetails;

  /// The runtime that loaded the model.
  final RuntimeInfo runtime;

  /// Whether the vocabulary adds a BOS token to a tokenized text (false for Qwen3.5).
  final bool addsBos;

  /// The chat template stored in the model (`tokenizer.chat_template`), null when there is none.
  String? get chatTemplate => metadata['tokenizer.chat_template'];

  /// SHA-256 (hex) of [chatTemplate]'s UTF-8 bytes, null when there is no template.
  late final String? chatTemplateSha256 = switch (chatTemplate) {
    final template? => sha256.convert(utf8.encode(template)).toString(),
    null => null,
  };

  /// `general.architecture`, for example `qwen35`.
  String? get architecture => metadata['general.architecture'];

  /// Whether [architecture] is one of [recurrentArchitectures].
  bool get isRecurrent => recurrentArchitectures.contains(architecture);

  @override
  String toString() =>
      'EngineInfo($modelPath, ${runtime.id}, $backend, context $contextTokens, architecture $architecture, '
      'template ${chatTemplateSha256?.substring(0, 8)})';
}
