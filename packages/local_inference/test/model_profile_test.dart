// Model profiles: detection, accepted templates, prepare per ToolMode, stop
// strings and preserved tokens, and the text-only fallback.
import 'package:local_inference/local_inference.dart';
import 'package:local_inference/testing.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

EngineInfo _info(String? template, {String architecture = 'qwen35', Map<String, String> more = const {}}) => EngineInfo(
  modelPath: '/models/m.gguf',
  modelBytes: 1,
  backend: 'Metal',
  gpuLayers: 99,
  contextTokens: 4096,
  loadMs: 5,
  options: const LoadOptions(),
  metadata: {'tokenizer.chat_template': ?template, 'general.architecture': architecture, ...more},
  runtimeDetails: const {'llamadart.chat_format': 'generic'},
  runtime: LlamadartEngine.defaultRuntime,
  addsBos: false,
);

/// A ChatML template with no tool envelope.
const String _chatml =
    '{% for m in messages %}<|im_start|>{{ m.role }}\n{{ m.content }}<|im_end|>\n{% endfor %}'
    '{% if add_generation_prompt %}<|im_start|>assistant\n{% endif %}';

const String _sha2b = 'ea210e5b4997b7b1d3af5ee3ad34e7677ffe38df7469e8d88089789b5a27fae5';
const String _sha4b = '8452ca85cb1e0ff04304c02f417a53305d5ba17f6eb9d5693343ad8355f985a8';

const List<ChatMessage> _messages = [ChatMessage.system('Be brief.'), ChatMessage.user('Weather in Rome?')];

void main() {
  group('detect', () {
    test('both Qwen3.5 templates give Qwen35Profile', () {
      expect(ModelProfile.detect(_info(template2b)), isA<Qwen35Profile>());
      expect(ModelProfile.detect(_info(template4b)), isA<Qwen35Profile>());
      expect(ModelProfile.detect(_info(qwen35ChatTemplate)).id, 'qwen3.5');
    });

    test('another template, or none, gives TextOnlyProfile', () {
      expect(ModelProfile.detect(_info(_chatml, architecture: 'llama')), isA<TextOnlyProfile>());
      expect(ModelProfile.detect(_info(null)), isA<TextOnlyProfile>());
      expect(const TextOnlyProfile().matches(_info(_chatml)), isTrue);
      expect(const TextOnlyProfile().matches(_info(null)), isFalse);
      expect(const Qwen35Profile().matches(_info('<|im_start|> <function=')), isFalse);
    });
  });

  group('Qwen35Profile', () {
    test('its constants: ChatML stop, the user marker, thinking off, the generic sampling', () {
      const profile = Qwen35Profile();
      expect(profile.prefixMarker, '<|im_start|>user\n');
      expect(profile.templateVariables, {'enable_thinking': false});
      expect(profile.sampling, const SamplingOptions());
      expect(profile.canRewind(_info(template2b)), isFalse, reason: 'qwen35 is hybrid (recurrent layers)');
      expect(profile.canRewind(_info(template2b, architecture: 'qwen3')), isTrue);
    });

    test('accepted template SHAs: null accepts any; a set refuses another template, naming its SHA', () {
      expect(const Qwen35Profile().templateFor(_info(template4b)).sha256, _sha4b);
      const only2b = Qwen35Profile(acceptedTemplateSha256: {_sha2b});
      expect(only2b.templateFor(_info(template2b)).sha256, _sha2b);
      expect(
        () => only2b.templateFor(_info(template4b)),
        throwsA(isA<UnsupportedModelException>().having((e) => e.message, 'message', contains(_sha4b))),
      );
      expect(
        () => const Qwen35Profile().templateFor(_info(null)),
        throwsA(isA<UnsupportedModelException>().having((e) => e.message, 'message', contains('no chat template'))),
      );
      expect(identical(only2b.templateFor(_info(template2b)), only2b.templateFor(_info(template2b))), isFalse);
      final info = _info(template2b);
      expect(identical(only2b.templateFor(info), const Qwen35Profile().templateFor(info)), isTrue);
    });

    test('prepare renders with the declarations and thinking off, whatever the mode', () {
      final info = _info(template4b);
      final expected = JinjaChatTemplate(template4b).render(
        _messages,
        tools: [for (final tool in toyTools) tool.declaration],
        variables: const {'enable_thinking': false},
      );
      for (final mode in ToolMode.values) {
        expect(const Qwen35Profile().prepare(info, _messages, tools: toyTools, mode: mode).prompt, expected);
      }
      expect(
        const Qwen35Profile().prepare(info, _messages, addGenerationPrompt: false).prompt,
        JinjaChatTemplate(
          template4b,
        ).render(_messages, addGenerationPrompt: false, variables: const {'enable_thinking': false}),
      );
    });

    test('auto: a lazy grammar on <tool_call>; required: the same grammar, eager; none or no tools: none', () {
      final info = _info(template2b);
      const options = GrammarOptions(order: ParameterOrder.declared);
      final gbnf = const QwenXmlToolFormat().grammar(toyTools, options);
      final auto = const Qwen35Profile().prepare(info, _messages, tools: toyTools, grammar: options);
      expect(auto.grammar, Grammar(gbnf, triggers: const [GrammarTrigger.word('<tool_call>')]));
      final required = const Qwen35Profile().prepare(
        info,
        _messages,
        tools: toyTools,
        mode: ToolMode.required,
        grammar: options,
      );
      expect(required.grammar, Grammar(gbnf));
      expect(required.grammar!.isLazy, isFalse);
      expect(const Qwen35Profile().prepare(info, _messages, tools: toyTools, mode: ToolMode.none).grammar, isNull);
      expect(const Qwen35Profile().prepare(info, _messages).grammar, isNull);
    });

    test('stop is always <|im_end|>; the preserved tokens come with a grammar only', () {
      final info = _info(template2b);
      for (final (tools, mode, preserved) in [
        (toyTools, ToolMode.auto, true),
        (toyTools, ToolMode.required, true),
        (toyTools, ToolMode.none, false),
        (const <ToolSpec>[], ToolMode.auto, false),
      ]) {
        final prepared = const Qwen35Profile().prepare(info, _messages, tools: tools, mode: mode);
        expect(prepared.stop, ['<|im_end|>']);
        expect(prepared.preservedTokens, preserved ? const QwenXmlToolFormat().preservedTokens : isEmpty);
      }
    });

    test('a responseSchema asks for an eager JSON grammar, the tools aside', () {
      const schema = {
        'type': 'object',
        'properties': {
          'city': {'type': 'string'},
        },
      };
      final prepared = const Qwen35Profile().prepare(
        _info(template2b),
        _messages,
        tools: toyTools,
        responseSchema: schema,
      );
      expect(prepared.grammar, Grammar(jsonSchemaGrammar(schema)));
      expect(prepared.preservedTokens, isNotEmpty);
    });

    test('the generation options carry the sampling, stop, grammar and preserved tokens', () {
      final prepared = const Qwen35Profile().prepare(_info(template2b), _messages, tools: toyTools);
      const sampling = SamplingOptions(maxTokens: 256);
      expect(
        prepared.options(sampling),
        GenerationOptions(
          sampling: sampling,
          stop: const ['<|im_end|>'],
          grammar: prepared.grammar,
          preservedTokens: const QwenXmlToolFormat().preservedTokens,
        ),
      );
    });

    test('parse and visibleText are the XML format\'s', () {
      final prepared = const Qwen35Profile().prepare(_info(template2b), _messages, tools: toyTools);
      const raw =
          '<tool_call>\n<function=get_weather>\n<parameter=city>\nRome\n</parameter>\n<parameter=days>\n2\n'
          '</parameter>\n</function>\n</tool_call>';
      expect(
        const Qwen35Profile().parse(raw, toyTools, prepared).toolCalls.single,
        const ToolCall('get_weather', {'city': 'Rome', 'days': 2}),
      );
      expect(const Qwen35Profile().visibleText('Sure <tool', prepared), 'Sure');
    });
  });

  group('TextOnlyProfile', () {
    test('any template; no stop strings; no prefix marker; thinking off', () {
      final info = _info(_chatml, architecture: 'llama');
      final prepared = const TextOnlyProfile().prepare(info, _messages);
      expect(
        prepared.prompt,
        '<|im_start|>system\nBe brief.<|im_end|>\n<|im_start|>user\nWeather in Rome?<|im_end|>\n'
        '<|im_start|>assistant\n',
      );
      expect(prepared.stop, isEmpty);
      expect(prepared.grammar, isNull);
      expect(prepared.preservedTokens, isEmpty);
      expect(const TextOnlyProfile().prefixMarker, isNull);
      expect(const TextOnlyProfile().templateVariables, {'enable_thinking': false});
      expect(const TextOnlyProfile().canRewind(info), isTrue);
    });

    test('tools with a mode other than none throw UnsupportedModelException naming the family', () {
      final info = _info(_chatml, architecture: 'llama');
      for (final mode in [ToolMode.auto, ToolMode.required]) {
        expect(
          () => const TextOnlyProfile().prepare(info, _messages, tools: toyTools, mode: mode),
          throwsA(isA<UnsupportedModelException>().having((e) => e.message, 'message', contains('generic'))),
        );
      }
      expect(const TextOnlyProfile().prepare(info, _messages, tools: toyTools, mode: ToolMode.none).grammar, isNull);
    });

    test('a responseSchema gives an eager JSON grammar', () {
      const schema = {
        'type': 'array',
        'items': {'type': 'integer'},
      };
      final prepared = const TextOnlyProfile().prepare(_info(_chatml), _messages, responseSchema: schema);
      expect(prepared.grammar, Grammar(jsonSchemaGrammar(schema)));
    });

    test('parse: a think block is the reasoning, the rest the text; visibleText hides an open think block', () {
      final prepared = const TextOnlyProfile().prepare(_info(_chatml), _messages);
      final parsed = const TextOnlyProfile().parse('<think>\nhmm\n</think>\n\nIt is sunny. ', const [], prepared);
      expect((parsed.text, parsed.reasoning, parsed.hasToolCalls), ('It is sunny.', 'hmm', false));
      expect(const TextOnlyProfile().parse('  plain ', const [], prepared).reasoning, isNull);
      expect(const TextOnlyProfile().visibleText('<think>\nstill', prepared), isNull);
      expect(const TextOnlyProfile().visibleText(' <thi', prepared), '', reason: 'it may still open a think block');
      expect(const TextOnlyProfile().visibleText('<3 you', prepared), '<3 you');
      expect(const TextOnlyProfile().visibleText('<think>x</think>\nHi there ', prepared), 'Hi there');
      expect(const TextOnlyProfile().visibleText('  Hi ', prepared), 'Hi');
    });

    test('the model\'s bos and eos texts are template globals when the runtime reports them', () {
      final info = _info(
        '{{ bos_token }}{{ messages[0].content }}{{ eos_token }}',
        more: const {'tokenizer.ggml.bos_token': '<s>', 'tokenizer.ggml.eos_token': '</s>'},
      );
      expect(const TextOnlyProfile().prepare(info, const [ChatMessage.user('x')]).prompt, '<s>x</s>');
      expect(
        const TextOnlyProfile().prepare(_info('{{ bos_token }}|{{ messages[0].content }}'), const [
          ChatMessage.user('x'),
        ]).prompt,
        '|x',
      );
    });
  });
}
