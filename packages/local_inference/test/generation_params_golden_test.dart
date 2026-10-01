// The paramsFor golden: LlamadartEngine.paramsFor and the prefix fill of saveState give exactly the llamadart
// parameters recorded in test/fixtures/generation_params.json, captured from the first llamadart adapter, so a change
// of the mapping (or of llamadart's fields) shows up byte for byte. The dump helpers below wrote that capture.
import 'dart:convert';
import 'dart:io';

import 'package:llamadart/llamadart.dart' as ll;
import 'package:local_inference/local_inference.dart';
import 'package:test/test.dart';

import 'support/fake_llama_backend.dart';
import 'support/llamadart_source.dart';

/// The Qwen3.5 tool envelope's special strings, as a caller passes them with a grammar.
const List<String> _qwenPreservedTokens = [
  '<think>',
  '</think>',
  '<tool_call>',
  '</tool_call>',
  '<function=',
  '</function>',
  '<parameter=',
  '</parameter>',
];

const String _grammar = 'root ::= "x"';

/// The captured generation: greedy, stop at `<|im_end|>`, 256 tokens; with a grammar, the preserved tokens.
GenerationOptions _qwen({Grammar? grammar}) => GenerationOptions(
  sampling: const SamplingOptions(maxTokens: 256),
  stop: const ['<|im_end|>'],
  grammar: grammar,
  preservedTokens: grammar == null ? const [] : _qwenPreservedTokens,
);

/// Canonical JSON: keys sorted at every level, 2-space indent, trailing newline.
String _stableJson(Object? value) => '${const JsonEncoder.withIndent('  ').convert(_sortKeys(value))}\n';

Object? _sortKeys(Object? value) => switch (value) {
  Map() => {for (final key in value.keys.cast<String>().toList()..sort()) key: _sortKeys(value[key])},
  List() => [for (final v in value) _sortKeys(v)],
  _ => value,
};

/// Every instance field of ll.GenerationParams in llamadart 0.8.23, in declaration order.
const List<String> _paramsFields = [
  'maxTokens',
  'temp',
  'topK',
  'topP',
  'minP',
  'penalty',
  'presencePenalty',
  'seed',
  'stopSequences',
  'grammar',
  'grammarLazy',
  'thinkingBudget',
  'grammarTriggers',
  'preservedTokens',
  'grammarRoot',
  'speculativeDecoding',
  'speculativeDecodingConfig',
  'reusePromptPrefix',
  'streamBatchTokenThreshold',
  'streamBatchByteThreshold',
];

/// Every instance field of ll.GenerationGrammarTrigger.
const List<String> _triggerFields = ['type', 'value', 'token'];

/// A nested option no case sets; a value means a default changed and the dump needs its fields.
Object? _unset(Object? value, String field) {
  if (value != null) fail('GenerationParams.$field is set ($value): dump its fields');
  return null;
}

/// [params] field by field, from the explicit lists above.
Map<String, Object?> _paramsDump(ll.GenerationParams params) {
  final dump = <String, Object?>{
    'maxTokens': params.maxTokens,
    'temp': params.temp,
    'topK': params.topK,
    'topP': params.topP,
    'minP': params.minP,
    'penalty': params.penalty,
    'presencePenalty': params.presencePenalty,
    'seed': params.seed,
    'stopSequences': params.stopSequences,
    'grammar': params.grammar,
    'grammarLazy': params.grammarLazy,
    'thinkingBudget': _unset(params.thinkingBudget, 'thinkingBudget'),
    'grammarTriggers': [
      for (final trigger in params.grammarTriggers)
        {'type': trigger.type, 'value': trigger.value, 'token': trigger.token},
    ],
    'preservedTokens': params.preservedTokens,
    'grammarRoot': params.grammarRoot,
    'speculativeDecoding': params.speculativeDecoding,
    'speculativeDecodingConfig': _unset(params.speculativeDecodingConfig, 'speculativeDecodingConfig'),
    'reusePromptPrefix': params.reusePromptPrefix,
    'streamBatchTokenThreshold': params.streamBatchTokenThreshold,
    'streamBatchByteThreshold': params.streamBatchByteThreshold,
  };
  expect(dump.keys, _paramsFields);
  for (final trigger in dump['grammarTriggers'] as List) {
    expect((trigger as Map).keys, _triggerFields);
  }
  return dump;
}

/// Where [actual] first departs from [expected]: line, column and the text around it in both.
String _firstDifference(String expected, String actual) {
  final n = expected.length < actual.length ? expected.length : actual.length;
  var i = 0;
  while (i < n && expected.codeUnitAt(i) == actual.codeUnitAt(i)) {
    i++;
  }
  final lineStart = i == 0 ? 0 : expected.lastIndexOf('\n', i - 1) + 1;
  final line = '\n'.allMatches(expected.substring(0, lineStart)).length + 1;
  String around(String s) {
    final start = i - 50 < lineStart ? lineStart : i - 50;
    var end = s.indexOf('\n', i);
    if (end < 0 || end > i + 50) end = i + 50 < s.length ? i + 50 : s.length;
    return jsonEncode(s.substring(start, end));
  }

  return 'differs at line $line, column ${i - lineStart + 1} (offset $i; ${expected.length} chars expected, '
      '${actual.length} now):\n  expected: ${around(expected)}\n  now:      ${around(actual)}';
}

/// The parameters saveState fills the context with, as the runtime receives them.
Future<ll.GenerationParams> _prefixFillParams() async {
  final tmp = Directory.systemTemp.createTempSync('li_golden');
  addTearDown(() => tmp.deleteSync(recursive: true));
  final model = File('${tmp.path}/m.gguf')..writeAsStringSync('gguf');
  final backend = FakeLlamaBackend()..reply = (prompt, params) => const [];
  final engine = LlamadartEngine.withBackend(backend, isIOS: false);
  addTearDown(engine.dispose);
  await engine.load(model.path);
  await engine.saveState('${tmp.path}/prefix.state', '<|im_start|>system\nx<|im_end|>\n<|im_start|>user\n');
  return backend.generations.single.params;
}

void main() {
  late String version;

  setUpAll(() async => version = await llamadartVersion());

  test('the dump covers every field llamadart declares on GenerationParams and GenerationGrammarTrigger', () async {
    final source = await llamadartSource('core/models/inference/generation_params.dart');
    const classes = [('GenerationParams', _paramsFields), ('GenerationGrammarTrigger', _triggerFields)];
    for (final (className, dumped) in classes) {
      expect(
        declaredFields(source, className),
        unorderedEquals(dumped),
        reason: 'llamadart $version: the fields of $className changed; update the dump',
      );
    }
  });

  test('generation_params.json: paramsFor and the prefix fill of saveState equal the capture byte for byte', () async {
    // Each case's "call" names the adapter call the capture recorded.
    final cases = <(String, String, ll.GenerationParams)>[
      ('a_no_grammar', 'generationParams()', LlamadartEngine.paramsFor(_qwen())),
      (
        'b_lazy_grammar',
        "generationParams(grammar: '$_grammar', grammarTriggers: ['<tool_call>'])",
        LlamadartEngine.paramsFor(
          _qwen(grammar: const Grammar(_grammar, triggers: [GrammarTrigger.word('<tool_call>')])),
        ),
      ),
      (
        'c_eager_grammar',
        "generationParams(grammar: '$_grammar')",
        LlamadartEngine.paramsFor(_qwen(grammar: const Grammar(_grammar))),
      ),
      ('d_prefix_fill', 'prefixFillParams', await _prefixFillParams()),
    ];
    final actual = _stableJson({
      'llamadart': version,
      'fields': {'GenerationParams': _paramsFields, 'GenerationGrammarTrigger': _triggerFields},
      'static_defaults': {
        'defaultReusePromptPrefix': ll.GenerationParams.defaultReusePromptPrefix,
        'defaultStreamBatchTokenThreshold': ll.GenerationParams.defaultStreamBatchTokenThreshold,
        'defaultStreamBatchByteThreshold': ll.GenerationParams.defaultStreamBatchByteThreshold,
      },
      'cases': [
        for (final (name, call, params) in cases)
          {
            'name': name,
            'call': 'LlamadartEngine.$call',
            'params': _paramsDump(params),
            'derived': {
              'isSpeculativeDecodingEnabled': params.isSpeculativeDecodingEnabled,
              'resolvedSpeculativeDecodingConfig': _unset(
                params.resolvedSpeculativeDecodingConfig,
                'resolvedSpeculativeDecodingConfig',
              ),
            },
            'toString': params.toString(),
          },
      ],
    });
    final expected = File('test/fixtures/generation_params.json').readAsStringSync();
    if (actual != expected) fail('test/fixtures/generation_params.json ${_firstDifference(expected, actual)}');
  });
}
