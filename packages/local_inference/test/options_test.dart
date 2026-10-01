// Options, runtime and model info, and the exception family of the L1 engine.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:local_inference/local_inference.dart';
import 'package:test/test.dart';

EngineInfo _info(Map<String, String> metadata) => EngineInfo(
  modelPath: '/m.gguf',
  modelBytes: 1,
  backend: 'Metal',
  gpuLayers: 999,
  contextTokens: 4096,
  loadMs: 1,
  options: const LoadOptions(),
  metadata: metadata,
  runtime: LlamadartEngine.defaultRuntime,
  addsBos: false,
);

/// The GGUF names of llama.cpp's recurrent and hybrid architectures at 5266f24 (v0.4.0), src/llama-arch.cpp:1050-1087.
const Set<String> _recurrentAt5266f24 = {
  'mamba', 'mamba2', 'rwkv6', 'rwkv6qwen2', 'rwkv7', 'arwkv7', // llm_arch_is_recurrent
  'jamba', 'falcon-h1', 'plamo2', 'granitehybrid', 'lfm2', 'lfm2moe', 'nemotron_h', 'nemotron_h_moe', 'qwen3next',
  'kimi-linear', 'bailingmoe3', 'kimi-k3', 'qwen35', 'qwen35moe', 'qwen4exp', 'deepseek4', 'minimax-01',
};

/// The architectures `llm_arch_is_recurrent` and `llm_arch_is_hybrid` accept in [source] (llama-arch.cpp), each
/// mapped to its `LLM_ARCH_NAMES` string.
Set<String> _recurrentIn(String source) {
  final names = {
    for (final m in RegExp(r'\{\s*(LLM_ARCH_\w+)\s*,\s*"([^"]+)"\s*\}').allMatches(source)) m.group(1)!: m.group(2)!,
  };
  return {
    for (final function in ['llm_arch_is_recurrent', 'llm_arch_is_hybrid'])
      for (final m in RegExp(r'case\s+(LLM_ARCH_\w+)\s*:').allMatches(_body(source, 'bool $function(')))
        names[m.group(1)] ?? (throw StateError('${m.group(1)} is not in LLM_ARCH_NAMES')),
  };
}

/// The text of the function whose signature starts with [signature], up to its `default:` label.
String _body(String source, String signature) {
  final start = source.indexOf(signature);
  if (start < 0) throw StateError('$signature not found');
  return source.substring(start, source.indexOf('default:', start));
}

void main() {
  group('LoadOptions', () {
    test("defaults are today's load settings: 4096 tokens, flash attention, KV f16, auto backend, the rest unset", () {
      const options = LoadOptions();
      expect(options.toJson(), {
        'contextTokens': 4096,
        'threads': null,
        'gpuLayers': null,
        'microBatchSize': null,
        'batchSize': null,
        'flashAttention': true,
        'kvCacheK': 'f16',
        'kvCacheV': 'f16',
        'compute': 'auto',
      });
    });

    test('value equality, copyWith and toString', () {
      const a = LoadOptions(contextTokens: 2048, microBatchSize: 128);
      expect(a, const LoadOptions().copyWith(contextTokens: 2048, microBatchSize: 128));
      expect(a.hashCode, const LoadOptions(contextTokens: 2048, microBatchSize: 128).hashCode);
      expect(a, isNot(const LoadOptions(contextTokens: 2048)));
      expect(a.copyWith(kvCacheK: KvCacheQuant.q8_0).kvCacheK, KvCacheQuant.q8_0);
      expect(a.copyWith().microBatchSize, 128, reason: 'a null argument keeps the value');
      expect(a.toString(), contains('microBatchSize: 128'));
    });
  });

  group('GrammarTrigger and Grammar', () {
    test('the four trigger kinds, with value equality', () {
      expect(const GrammarTrigger.word('<tool_call>'), const GrammarWordTrigger('<tool_call>'));
      expect(const GrammarTrigger.token(7, '<x>'), const GrammarTokenTrigger(7, '<x>'));
      expect(const GrammarTrigger.pattern('a+'), const GrammarPatternTrigger('a+'));
      expect(const GrammarTrigger.patternFull('a+'), const GrammarPatternFullTrigger('a+'));
      expect(const GrammarTrigger.pattern('a+'), isNot(const GrammarTrigger.patternFull('a+')));
      expect(const GrammarTrigger.word('a').hashCode, const GrammarTrigger.word('a').hashCode);
      expect(const GrammarTrigger.token(1, 'a'), isNot(const GrammarTrigger.token(2, 'a')));
    });

    test('a grammar is lazy exactly when it has triggers', () {
      expect(const Grammar('root ::= "x"').isLazy, isFalse);
      expect(const Grammar('root ::= "x"', triggers: [GrammarTrigger.word('<tool_call>')]).isLazy, isTrue);
      expect(
        Grammar('g', triggers: [const GrammarTrigger.word('a')]),
        const Grammar('g', triggers: [GrammarTrigger.word('a')]),
      );
      expect(const Grammar('g'), isNot(const Grammar('h')));
    });
  });

  group('SamplingOptions and GenerationOptions', () {
    test('defaults: greedy, no penalties, seed 1, 1024 tokens; no stops, no grammar, 1-token deltas, prefix reuse', () {
      const sampling = SamplingOptions();
      expect(
        (
          sampling.maxTokens,
          sampling.temperature,
          sampling.topK,
          sampling.topP,
          sampling.minP,
          sampling.repeatPenalty,
          sampling.presencePenalty,
          sampling.seed,
        ),
        (1024, 0.0, 40, 0.9, 0.0, 1.0, 0.0, 1),
      );
      const options = GenerationOptions();
      expect(options.sampling, const SamplingOptions());
      expect(options.stop, isEmpty);
      expect(options.grammar, isNull);
      expect(options.preservedTokens, isEmpty);
      expect((options.reusePromptPrefix, options.streamChunkTokens), (true, 1));
    });

    test('value equality and copyWith', () {
      final a = GenerationOptions(
        sampling: const SamplingOptions(maxTokens: 256),
        stop: ['<|im_end|>'],
        grammar: const Grammar('g', triggers: [GrammarTrigger.word('<tool_call>')]),
        preservedTokens: ['<tool_call>'],
      );
      const b = GenerationOptions(
        sampling: SamplingOptions(maxTokens: 256),
        stop: ['<|im_end|>'],
        grammar: Grammar('g', triggers: [GrammarTrigger.word('<tool_call>')]),
        preservedTokens: ['<tool_call>'],
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a.copyWith(stop: const []), isNot(b));
      expect(a.copyWith(sampling: a.sampling.copyWith(maxTokens: 4)).sampling.maxTokens, 4);
      expect(const SamplingOptions().copyWith(temperature: 0.7), isNot(const SamplingOptions()));
    });
  });

  group('RuntimeInfo and EngineInfo', () {
    test('the default runtime id is llamadart 0.8.23 / llama.cpp v0.4.0', () {
      expect(LlamadartEngine.defaultRuntime.id, 'llamadart 0.8.23 / llama.cpp v0.4.0');
      expect(
        LlamadartEngine.defaultRuntime,
        const RuntimeInfo(binding: 'llamadart', bindingVersion: '0.8.23', native: 'llama.cpp v0.4.0'),
      );
    });

    test('chatTemplate, its sha256 and the architecture come from the metadata', () {
      const template = "{%- for message in messages %}{{ '<|im_start|>' + message.role }}{%- endfor %}";
      final info = _info({'tokenizer.chat_template': template, 'general.architecture': 'qwen35'});
      expect(info.chatTemplate, template);
      expect(info.chatTemplateSha256, sha256.convert(utf8.encode(template)).toString());
      expect(info.architecture, 'qwen35');
      expect(info.isRecurrent, isTrue);
    });

    test('a model without a template has no template sha', () {
      final info = _info({'general.architecture': 'llama'});
      expect((info.chatTemplate, info.chatTemplateSha256, info.isRecurrent), (null, null, false));
    });

    test('isRecurrent follows llama.cpp llm_arch_is_recurrent and llm_arch_is_hybrid at 5266f24', () {
      expect(recurrentArchitectures, _recurrentAt5266f24);
      for (final name in _recurrentAt5266f24) {
        expect(_info({'general.architecture': name}).isRecurrent, isTrue, reason: name);
      }
      for (final name in ['qwen3', 'llama', 'gemma3', 'granite', 'nemotron-h', 'kimi_k3']) {
        expect(_info({'general.architecture': name}).isRecurrent, isFalse, reason: name);
      }
    });

    test(
      'the recurrent table equals the llama.cpp sources at the runtime tag, when .tools/llama.cpp has them',
      () async {
        final checkout = Directory('../../.tools/llama.cpp');
        final source = File('${checkout.path}/src/llama-arch.cpp');
        if (!source.existsSync()) return markTestSkipped('no ${source.path} (a llama.cpp checkout)');
        final tag = LlamadartEngine.defaultRuntime.native.split(' ').last;
        final described = await Process.run('git', ['-C', checkout.path, 'describe', '--tags', '--exact-match']);
        if ('${described.stdout}'.trim() != tag) return markTestSkipped('${checkout.path} is not at $tag');
        expect(recurrentArchitectures, _recurrentIn(source.readAsStringSync()));
      },
    );

    test('metadata and runtimeDetails are read-only copies', () {
      final metadata = {'general.architecture': 'qwen35'};
      final info = _info(metadata);
      metadata['general.architecture'] = 'llama';
      expect(info.architecture, 'qwen35');
      expect(() => info.metadata['x'] = 'y', throwsUnsupportedError);
      expect(() => info.runtimeDetails['x'] = 'y', throwsUnsupportedError);
    });
  });

  group('exceptions', () {
    test('one sealed family: message, cause and a toString naming the kind', () {
      final cause = Exception('native');
      final all = <LocalInferenceException>[
        ModelLoadException('cannot load', cause: cause),
        const UnsupportedModelException('no template'),
        GenerationException('failed', cause: cause),
        const StateFileException('bad state'),
      ];
      expect(
        [for (final e in all) e.toString()],
        [
          'ModelLoadException: cannot load (Exception: native)',
          'UnsupportedModelException: no template',
          'GenerationException: failed (Exception: native)',
          'StateFileException: bad state',
        ],
      );
      expect([for (final e in all) e.cause], [cause, null, cause, null]);
      final kinds = [
        for (final e in all)
          switch (e) {
            ModelLoadException() => 'load',
            UnsupportedModelException() => 'unsupported',
            GenerationException() => 'generation',
            StateFileException() => 'state',
          },
      ];
      expect(kinds, ['load', 'unsupported', 'generation', 'state']);
    });
  });
}
