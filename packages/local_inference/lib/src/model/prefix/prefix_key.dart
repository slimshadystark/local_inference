/// The key of a saved prefix state.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:meta/meta.dart';

import '../../engine/engine_info.dart';
import 'model_identity.dart';

/// A prefix state belongs to one model file, template, runtime build, set of load settings and prefix text: a
/// change of any of them needs another state.
@immutable
final class PrefixKey {
  const PrefixKey._(this.id);

  /// The key of [prefix] on the model [info] describes, loaded from [model]: the first 16 hex digits of the SHA-256
  /// of these fields joined with `|`: [ModelIdentity.id], the template's sha256, the runtime's id, the context size,
  /// micro-batch and batch sizes, the KV cache types (`k/v`), flash attention, the GPU layers (all as
  /// [EngineInfo.options] resolved them), the backend the runtime selected, and the prefix text.
  factory PrefixKey.of(EngineInfo info, ModelIdentity model, String prefix) {
    final options = info.options;
    final fields = [
      model.id,
      info.chatTemplateSha256 ?? 'none',
      info.runtime.id,
      options.contextTokens,
      options.microBatchSize,
      options.batchSize,
      '${options.kvCacheK.name}/${options.kvCacheV.name}',
      options.flashAttention,
      options.gpuLayers,
      info.backend,
      prefix,
    ];
    return PrefixKey._(sha256.convert(utf8.encode(fields.join('|'))).toString().substring(0, 16));
  }

  /// 16 hex digits.
  final String id;

  @override
  bool operator ==(Object other) => other is PrefixKey && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'PrefixKey($id)';
}
