// LlamadartFamilyProfile: the other model families through llamadart's own chat-format
// handlers, on the chat templates llamadart 0.8.23 ships for its own tests (Gemma 4, Qwen3's Hermes format, Llama
// 3.2, Ministral, FunctionGemma, and Gemma 3, TranslateGemma and Phi-4 mini, which it has no tool calls for) and on
// those of the stock GGUFs the family matrix runs (test/fixtures/families: gemma-4-E2B-it, LFM2.5-1.2B-Instruct).
import 'dart:convert';

import 'package:local_inference/local_inference.dart';
import 'package:local_inference/testing.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';
import 'support/llamadart_source.dart';

/// The templates by the family llamadart reads them as (null: none with tool calls).
final Map<String, String> _templates = {};

const Map<String, String> _templateFiles = {
  'gemma4': 'tool/litert_lm_templates/gemma4.jinja',
  'hermes': 'test/fixtures/templates/Qwen3-4B.jinja',
  'llama3': 'test/fixtures/templates/Llama-3_2-3B-Instruct.jinja',
  'ministral': 'test/fixtures/templates/Ministral-3-3B-Reasoning.jinja',
  'functionGemma': 'test/fixtures/templates/functiongemma-270m-it.jinja',
  'gemma3': 'test/fixtures/templates/gemma-3-4b-it.jinja',
  'translateGemma': 'test/fixtures/templates/TranslateGemma-2B-it.jinja',
  'phi4': 'test/fixtures/templates/Phi-4-mini-instruct-reasoning.jinja',
};

EngineInfo _info(String? template, {String architecture = 'gemma4'}) => EngineInfo(
  modelPath: '/models/m.gguf',
  modelBytes: 1,
  backend: 'Metal',
  gpuLayers: 99,
  contextTokens: 4096,
  loadMs: 5,
  options: const LoadOptions(),
  metadata: {'tokenizer.chat_template': ?template, 'general.architecture': architecture},
  runtime: LlamadartEngine.defaultRuntime,
  addsBos: true,
);

EngineInfo _of(String family, {String architecture = 'gemma4'}) =>
    _info(_templates[family]!, architecture: architecture);

final ToolSpec _add = ToolSpec(
  name: 'add',
  description: 'Adds two integers.',
  parameters: ToolSchema.object({'a': ToolSchema.integer(), 'b': ToolSchema.integer()}, required: ['a', 'b']),
);

final ToolSpec _pick = ToolSpec(
  name: 'pick',
  description: 'Picks an item.',
  parameters: ToolSchema.object(
    {
      'n': ToolSchema.itemNumber('items'),
      'when': ToolSchema.anyOf([ToolSchema.string(), ToolSchema.integer()]),
    },
    required: ['n'],
  ),
);

final ToolSpec _note = ToolSpec(
  name: 'save_note',
  description: 'Saves a note.',
  parameters: ToolSchema.object({'text': ToolSchema.string()}, required: ['text']),
);

final ToolSpec _time = ToolSpec(
  name: 'get_time',
  description: 'The current time in a time zone.',
  parameters: ToolSchema.object({'timezone': ToolSchema.string()}),
);

/// The template of gemma-4-E2B-it-UD-Q4_K_XL.gguf (sha256 241c50d8…).
final String _gemmaE2b = fixture('families/gemma-4-E2B-it.jinja');

/// The template of LFM2.5-1.2B-Instruct-QAD-Q4_0.gguf (sha256 ba551d58…).
final String _lfm25 = fixture('families/LFM2.5-1.2B-Instruct.jinja');

const List<ChatMessage> _question = [ChatMessage.system('Be brief.'), ChatMessage.user('What is 2 + 3?')];

/// A conversation where the model wrote [text], called get_time and got its result.
List<ChatMessage> _timeRound(String text) => [
  ..._question,
  ChatMessage.assistant(
    text,
    toolCalls: const [
      ToolCall('get_time', {'timezone': 'Asia/Tokyo'}),
    ],
  ),
  const ChatMessage.tool('{"time": "14:30"}', name: 'get_time'),
];

/// A conversation where the model called add and got its result.
const List<ChatMessage> _roundTrip = [
  ..._question,
  ChatMessage.assistant(
    '',
    toolCalls: [
      ToolCall('add', {'a': 2, 'b': 3}),
    ],
  ),
  ChatMessage.tool('{"sum": 5}', name: 'add'),
];

LlamadartFamilyProfile _profile(String family) => LlamadartFamilyProfile.detect(_of(family))!;

void main() {
  setUpAll(() async {
    for (final MapEntry(:key, :value) in _templateFiles.entries) {
      _templates[key] = await llamadartFile(value);
    }
  });

  group('detect', () {
    test('a template llamadart reads as a format with tool calls gives LlamadartFamilyProfile of that family', () {
      for (final family in ['gemma4', 'hermes', 'llama3', 'ministral', 'functionGemma']) {
        final profile = ModelProfile.detect(_of(family));
        expect(profile, isA<LlamadartFamilyProfile>(), reason: family);
        expect((profile as LlamadartFamilyProfile).family, family);
        expect(profile.matches(_of(family)), isTrue);
      }
    });

    test('Qwen3.5 keeps Qwen35Profile; Gemma 3, TranslateGemma, content-only templates and none are text-only', () {
      for (final template in [template2b, template4b, qwen35ChatTemplate]) {
        expect(ModelProfile.detect(_info(template)), isA<Qwen35Profile>());
        expect(LlamadartFamilyProfile.detect(_info(template))?.family, 'qwen3CoderXml', reason: "llamadart's reading");
      }
      for (final family in ['gemma3', 'translateGemma', 'phi4']) {
        expect(LlamadartFamilyProfile.detect(_of(family)), isNull, reason: family);
        expect(ModelProfile.detect(_of(family)), isA<TextOnlyProfile>(), reason: family);
      }
      expect(LlamadartFamilyProfile.detect(_info(null)), isNull);
      expect(ModelProfile.detect(_info(null)), isA<TextOnlyProfile>());
    });

    test("TextOnlyProfile's refusal of tools names llamadart's reading of the template", () {
      expect(
        () => const TextOnlyProfile().prepare(_of('gemma3'), _question, tools: [_add]),
        throwsA(
          isA<UnsupportedModelException>().having((e) => e.message, 'message', contains('template family gemma')),
        ),
      );
      expect(
        () => const TextOnlyProfile().prepare(_of('phi4'), _question, tools: [_add]),
        throwsA(isA<UnsupportedModelException>().having((e) => e.message, 'message', contains('contentOnly'))),
      );
    });

    test('families: the formats with tool calls, not the generic, content-only, parser-only, Gemma 3 or '
        'TranslateGemma ones', () {
      final families = LlamadartFamilyProfile.families;
      expect(families, containsAll(['gemma4', 'hermes', 'llama3', 'lfm2', 'granite', 'qwen3CoderXml', 'gptOss']));
      for (final none in ['contentOnly', 'generic', 'pegSimple', 'pegNative', 'pegConstructed', 'gemma']) {
        expect(families, isNot(contains(none)));
      }
      expect(families, isNot(contains('translateGemma')));
      expect(families.length, greaterThan(30));
    });

    test('the constructor takes a family name; templateFor refuses a template of another family, or none', () {
      expect(LlamadartFamilyProfile('gemma4'), _profile('gemma4'));
      expect(LlamadartFamilyProfile('gemma4', thinking: true), isNot(_profile('gemma4')));
      for (final name in ['generic', 'gemma', 'contentOnly', 'nope']) {
        expect(() => LlamadartFamilyProfile(name), throwsArgumentError, reason: name);
      }
      expect(LlamadartFamilyProfile('hermes').matches(_of('gemma4')), isFalse);
      expect(
        () => LlamadartFamilyProfile('hermes').templateFor(_of('gemma4')),
        throwsA(
          isA<UnsupportedModelException>().having((e) => e.message, 'message', contains('as gemma4, not hermes')),
        ),
      );
      expect(
        () => LlamadartFamilyProfile('gemma4').templateFor(_info(null)),
        throwsA(isA<UnsupportedModelException>().having((e) => e.message, 'message', contains('no chat template'))),
      );
    });

    test('its constants: the id, no marker, thinking off, the generic sampling; recurrent models cannot rewind', () {
      final profile = _profile('gemma4');
      expect((profile.id, profile.prefixMarker, profile.thinking), ('llamadart:gemma4', null, false));
      expect(profile.templateVariables, {'enable_thinking': false});
      expect(LlamadartFamilyProfile('gemma4', thinking: true).templateVariables, {'enable_thinking': true});
      expect(profile.sampling, const SamplingOptions());
      expect(profile.canRewind(_of('gemma4')), isTrue);
      expect(profile.canRewind(_of('gemma4', architecture: 'lfm2')), isFalse);
      expect('$profile', 'LlamadartFamilyProfile(gemma4)');
    });
  });

  group('prepare', () {
    test('Gemma 4: no grammar for auto (the parser finds the call), an eager one for required, none for none; the '
        'tools stay in the prompt of every mode; its stop strings', () {
      final info = _of('gemma4');
      final profile = _profile('gemma4');
      final auto = profile.prepare(info, _question, tools: [_add]);
      final required = profile.prepare(info, _question, tools: [_add], mode: ToolMode.required);
      final none = profile.prepare(info, _question, tools: [_add], mode: ToolMode.none);
      expect(auto.prompt, contains('<|tool>declaration:add{description:<|"|>Adds two integers.<|"|>'));
      expect(auto.prompt, contains('<|turn>user\nWhat is 2 + 3?<turn|>\n<|turn>model\n'));
      expect((required.prompt, none.prompt), (auto.prompt, auto.prompt));
      expect((auto.grammar, none.grammar), (null, null));
      expect(required.grammar!.isLazy, isFalse);
      expect(GbnfRecognizer(required.grammar!.gbnf).accepts('<|tool_call>call:add{"a":2,"b":3}<tool_call|>'), isTrue);
      expect(auto.stop, ['<tool_call|>', '<turn|>']);
      expect(profile.prepare(info, _question).stop, ['<turn|>']);
      expect(auto.preservedTokens, isEmpty);
    });

    test('Hermes: a lazy grammar from <tool_call> for auto, an eager one for required, none for none, with its '
        'preserved tokens; the tool block carries the full schema (ranges, anyOf, key order), without the x-item-of '
        'marker', () {
      final info = _of('hermes', architecture: 'qwen3');
      final profile = _profile('hermes');
      final auto = profile.prepare(info, _question, tools: [_pick]);
      expect(auto.grammar!.triggers, [const GrammarTrigger.word('<tool_call>')]);
      expect(auto.preservedTokens, ['<tool_call>', '</tool_call>']);
      expect(auto.stop, ['<|im_end|>']);
      expect(
        auto.prompt,
        contains(
          '{"type": "function", "function": {"name": "pick", "description": "Picks an item.", "parameters": {"type": '
          '"object", "properties": {"n": {"type": "integer", "minimum": 1, "maximum": 8}, "when": {"anyOf": [{"type": '
          '"string"}, {"type": "integer"}]}}, "required": ["n"]}}}',
        ),
        reason: "Python's json.dumps form, as Hugging Face's tojson writes it",
      );
      expect(auto.prompt, isNot(contains('x-item-of')));
      expect(profile.prepare(info, _question, tools: [_pick], mode: ToolMode.none).grammar, isNull);
      final required = profile.prepare(info, _question, tools: [_pick], mode: ToolMode.required);
      expect(required.grammar!.isLazy, isFalse);
      expect(required.grammar!.gbnf, auto.grammar!.gbnf);
      expect(
        GbnfRecognizer(
          required.grammar!.gbnf,
        ).accepts('<tool_call>{"name": "pick", "arguments": {"n": 3, "when": "now"}}</tool_call>'),
        isTrue,
      );
    });

    test('a response schema: the eager JSON grammar every profile uses, and the prompt of auto', () {
      final info = _of('gemma4');
      final profile = _profile('gemma4');
      final schema = ToolSchema.object({'sum': ToolSchema.integer()}, required: ['sum']);
      final structured = profile.prepare(info, _question, tools: [_add], responseSchema: schema);
      expect(structured.grammar, Grammar(jsonSchemaGrammar(schema)));
      expect(structured.prompt, profile.prepare(info, _question, tools: [_add]).prompt);
    });

    test('thinking is off by default where the template has a switch, on when asked', () {
      final info = _of('hermes', architecture: 'qwen3');
      expect(
        _profile('hermes').prepare(info, _question).prompt,
        endsWith('<|im_start|>assistant\n<think>\n\n</think>\n\n'),
      );
      expect(
        LlamadartFamilyProfile('hermes', thinking: true).prepare(info, _question).prompt,
        endsWith('<|im_start|>assistant\n'),
      );
    });

    test('the history: a call and its result; Gemma 4 gets the result as text with the tool name (llamadart 0.8.23 '
        'hands it over as tool_responses, which Gemma 4 templates render as null)', () {
      final gemma = _profile('gemma4').prepare(_of('gemma4'), _roundTrip, tools: [_add]).prompt;
      expect(gemma, contains('<|tool_call>call:add{a:2,b:3}<tool_call|>'), reason: "Gemma's call syntax, not JSON");
      expect(gemma, contains('<|tool_response>response:add{value:<|"|>{"sum": 5}<|"|>}<tool_response|>'));
      expect(gemma, isNot(contains('value:null')));
      final hermes = _profile('hermes').prepare(_of('hermes'), _roundTrip, tools: [_add]).prompt;
      expect(hermes, contains('<tool_call>\n{"name": "add", "arguments": {"a":2,"b":3}}\n</tool_call>'));
      expect(hermes, contains('<tool_response>\n{"sum": 5}\n</tool_response>'));
    });

    test("LFM2: a past call's arguments reach the template as a mapping (LFM2.5's template refuses JSON text)", () {
      // Detected as lfm2 by its markers; like LFM2.5's, it writes a past call from the argument mapping.
      const lfm2Like =
          '{%- if tools %}<|im_start|>system\nList of tools: [{% for t in tools %}{{ t.name }}{% endfor %}]<|im_end|>\n'
          '{% endif -%}{%- for m in messages %}<|im_start|>{{ m.role }}\n{%- if m.tool_calls %}{% for c in m.tool_calls %}'
          '<|tool_call_start|>[{{ c.function.name }}({%- for k, v in c.function.arguments | dictsort %}{{ k }}={{ v }}'
          '{% if not loop.last %}, {% endif %}{% endfor %})]<|tool_call_end|>{% endfor %}{% else %}{{ m.content }}'
          '{% endif %}<|im_end|>\n{% endfor -%}{%- if add_generation_prompt %}<|im_start|>assistant\n{% endif %}';
      final info = _info(lfm2Like, architecture: 'lfm2');
      final profile = LlamadartFamilyProfile.detect(info)!;
      expect(profile.family, 'lfm2');
      final prompt = profile.prepare(info, _roundTrip, tools: [_add]).prompt;
      expect(prompt, contains('<|im_start|>assistant<|tool_call_start|>[add(a=2, b=3)]<|tool_call_end|><|im_end|>'));
      expect(prompt, contains('<|im_start|>tool{"sum": 5}<|im_end|>'));
      expect(profile.canRewind(info), isFalse, reason: 'lfm2 is hybrid');
    });

    test('call ids: call00000, call00001, … in conversation order; a tool message answers the next unanswered call '
        '(Mistral templates want 9 characters)', () {
      // Detected as lfm2 by its markers; it writes each call's id and each result's.
      const idsTemplate =
          'List of tools: [{% for t in tools %}{{ t.name }}{% endfor %}]{% for m in messages %}{% if m.tool_calls %}'
          '{% for c in m.tool_calls %}<|tool_call_start|>{{ c.id }}:{{ c.function.name }}<|tool_call_end|>'
          '{% endfor %}{% elif m.role == "tool" %}[{{ m.tool_call_id }}={{ m.content }}]{% endif %}{% endfor %}';
      final info = _info(idsTemplate, architecture: 'lfm2');
      final prompt = LlamadartFamilyProfile.detect(info)!
          .prepare(
            info,
            [
              ..._roundTrip,
              const ChatMessage.assistant(
                '',
                toolCalls: [
                  ToolCall('add', {'a': 5, 'b': 1}),
                  ToolCall('add', {'a': 6, 'b': 1}),
                ],
              ),
              const ChatMessage.tool('{"sum": 6}'),
              const ChatMessage.tool('{"sum": 7}'),
            ],
            tools: [_add],
          )
          .prompt;
      expect(
        prompt,
        endsWith(
          '<|tool_call_start|>call00000:add<|tool_call_end|>[call00000={"sum": 5}]'
          '<|tool_call_start|>call00001:add<|tool_call_end|><|tool_call_start|>call00002:add<|tool_call_end|>'
          '[call00001={"sum": 6}][call00002={"sum": 7}]',
        ),
      );
    });

    test('FunctionGemma: a past call in its own syntax (the arguments reach the template as a mapping)', () {
      final prompt = _profile('functionGemma').prepare(_of('functionGemma'), _roundTrip, tools: [_add]).prompt;
      expect(prompt, contains('<start_function_call>call:add{a:2,b:3}<end_function_call>'));
      expect(prompt, contains('<start_function_response>response:add{sum:5}<end_function_response>'));
    });

    test("Gemma 4: a tool result keeps its tool's name where no call of the message answers it", () {
      final prompt = _profile('gemma4')
          .prepare(
            _of('gemma4'),
            [..._roundTrip, const ChatMessage.tool('{"time": "14:30"}', name: 'get_time')],
            tools: [_add, _time],
          )
          .prompt;
      expect(prompt, contains('response:add{'));
      expect(prompt, contains('response:get_time{'));
    });

    test('templateFor renders through llamadart as prepare does, with the model template hash', () {
      final info = _of('gemma4');
      final profile = _profile('gemma4');
      final template = profile.templateFor(info);
      expect(template.sha256, info.chatTemplateSha256);
      expect(template.source, info.chatTemplate);
      expect(
        template.render(_roundTrip, tools: [_add.declaration]),
        profile.prepare(info, _roundTrip, tools: [_add], mode: ToolMode.none).prompt,
      );
    });

    test('tools llamadart refuses (two with one name) fail with UnsupportedModelException', () {
      expect(
        () => _profile('hermes').prepare(_of('hermes'), _question, tools: [_add, _add]),
        throwsA(isA<UnsupportedModelException>().having((e) => e.cause, 'cause', isNotNull)),
      );
    });
  });

  group('parse and visibleText', () {
    PreparedPrompt prepared(String family, {ToolMode mode = ToolMode.auto, List<ToolSpec>? tools}) =>
        _profile(family).prepare(_of(family), _question, tools: tools ?? [_add], mode: mode);

    test('Gemma 4: a call with typed arguments, a plain answer, the reasoning channel', () {
      final profile = _profile('gemma4');
      final prompt = prepared('gemma4');
      final call = profile.parse('<|tool_call>call:add{a:2,b:3}<tool_call|>', [_add], prompt);
      expect((call.text, call.error), ('', null));
      expect(call.toolCalls, [
        const ToolCall('add', {'a': 2, 'b': 3}),
      ]);
      expect(profile.parse('The sum is 5.', [_add], prompt).text, 'The sum is 5.');
      final thought = profile.parse('<|channel>thought\nAdding.<channel|>The sum is 5.', [_add], prompt);
      expect((thought.text, thought.reasoning), ('The sum is 5.', 'Adding.'));
    });

    test('Hermes: a call; a call it cannot read is an error, and the text stops before it', () {
      final profile = _profile('hermes');
      final prompt = prepared('hermes');
      final call = profile.parse('<tool_call>\n{"name": "add", "arguments": {"a": 2, "b": 3}}\n</tool_call>', [
        _add,
      ], prompt);
      expect((call.text, call.error), ('', null));
      expect(call.toolCalls, [
        const ToolCall('add', {'a': 2, 'b': 3}),
      ]);
      final broken = profile.parse('Sure. <tool_call>\n{"name": "ad', [_add], prompt);
      expect((broken.text, broken.toolCalls.length), ('Sure.', 0));
      expect(broken.error, startsWith('a tool call llamadart could not read: <tool_call>'));
      final list = profile.parse('<tool_call>\n{"name": "add", "arguments": [2, 3]}\n</tool_call>', [_add], prompt);
      expect(list.toolCalls, isEmpty);
      expect(list.error, 'the arguments of add are not a JSON object: [2,3]');
      expect(profile.parse('Just text.', const [], prepared('hermes', tools: const [])).error, isNull);
    });

    test('visibleText: the text before a call, a partial opener held back, nothing of a call', () {
      String? shown(String family, String raw, {ToolMode mode = ToolMode.auto}) =>
          _profile(family).visibleText(raw, prepared(family, mode: mode));
      expect(shown('gemma4', 'The answer <|tool'), 'The answer');
      expect(shown('gemma4', '<|tool_call>call:add{a:2'), '');
      expect(shown('gemma4', 'Hello wor'), 'Hello wor');
      expect(shown('hermes', 'Sure. <tool_call>\n{"na'), 'Sure.');
      expect(shown('hermes', '<tool_ca'), '');
      expect(shown('hermes', 'a <'), 'a');
      expect(shown('hermes', '  Hello  '), 'Hello');
      expect(shown('llama3', '{"name": "add", "parameters": {"a"'), '', reason: "the family's trigger pattern");
      expect(shown('llama3', 'Hello'), 'Hello');
      expect(shown('ministral', 'Ok[TOOL_CALLS]add[ARGS]{"a"'), 'Ok');
      expect(shown('functionGemma', 'Ok <start_function_call>call:add{a'), 'Ok');
      expect(shown('hermes', '<tool_call>\n{"name": "add"', mode: ToolMode.required), '', reason: 'eager: all a call');
      expect(shown('hermes', 'Sure', mode: ToolMode.required), '', reason: 'eager: all a call');
    });

    test('without tools the answer is text; a prompt the profile did not prepare is read with its family', () {
      final profile = _profile('hermes');
      expect(profile.visibleText('Hi <there', prepared('hermes', tools: const [])), 'Hi <there');
      const foreign = PreparedPrompt(prompt: 'x');
      expect(profile.parse('<tool_call>\n{"name": "add", "arguments": {}}\n</tool_call>', [_add], foreign).toolCalls, [
        const ToolCall('add'),
      ]);
      expect(profile.visibleText('Hello', foreign), 'Hello');
    });
  });

  group("the stock models' templates", () {
    test('Gemma 4 E2B: a string argument is read verbatim (commas, colons, quotes, line breaks, backslashes, braces), '
        "in the model's syntax and in JSON (the grammar of ToolMode.required)", () {
      final info = _info(_gemmaE2b);
      final profile = LlamadartFamilyProfile.detect(info)!;
      final prompt = profile.prepare(info, _question, tools: [_note, _time]);
      String? note(String raw) {
        final parsed = profile.parse(raw, [_note, _time], prompt);
        expect((parsed.error, parsed.toolCalls.length, parsed.text), (null, 1, ''), reason: raw);
        return parsed.toolCalls.single.string('text');
      }

      for (final text in [
        'Call Anna, time: 5pm',
        'He said "hi" to me',
        'Buy milk.\nBuy bread.',
        r'C:\temp',
        '{a}, <b>',
      ]) {
        expect(note('<|tool_call>call:save_note{text:<|"|>$text<|"|>}<tool_call|>'), text);
        expect(note('<|tool_call>call:save_note{"text": ${jsonEncode(text)}}<tool_call|>'), text);
      }
      final two = profile.parse(
        '<|tool_call>call:get_time{timezone:<|"|>Asia/Tokyo<|"|>}<tool_call|>'
        '<|tool_call>call:save_note{text:<|"|>a, b: c<|"|>}<tool_call|>',
        [_note, _time],
        prompt,
      );
      expect(two.toolCalls, [
        const ToolCall('get_time', {'timezone': 'Asia/Tokyo'}),
        const ToolCall('save_note', {'text': 'a, b: c'}),
      ]);
    });

    test('Gemma 4 E2B: a call that cannot be read is an error, never a call without its arguments', () {
      final info = _info(_gemmaE2b);
      final profile = LlamadartFamilyProfile.detect(info)!;
      final prompt = profile.prepare(info, _question, tools: [_note, _time]);
      final bare = profile.parse('<|tool_call>call:save_note{text:Call Anna}<tool_call|>', [_note, _time], prompt);
      expect(bare.toolCalls, isEmpty);
      expect(bare.error, startsWith('the arguments of save_note cannot be read: <|tool_call>call:save_note{'));
      final open = profile.parse('<|tool_call>call:save_note{text:<|"|>Call}<tool_call|>', [_note, _time], prompt);
      expect(open.toolCalls, isEmpty);
      expect(open.error, startsWith('a tool call that cannot be read: <|tool_call>call:save_note{'));
      final braceless = profile.parse('Sure.<|tool_call>call:get_time<tool_call|>', [_note, _time], prompt);
      expect((braceless.text, braceless.toolCalls.length), ('Sure.', 0));
      expect(braceless.error, 'a tool call that cannot be read: <|tool_call>call:get_time<tool_call|>');
      final second = profile.parse(
        '<|tool_call>call:get_time{}<tool_call|><|tool_call>call:save_note{text:x}<tool_call|>',
        [_note, _time],
        prompt,
      );
      expect(second.toolCalls, [const ToolCall('get_time')]);
      expect(second.error, startsWith('the arguments of save_note cannot be read'));
    });

    test('Gemma 4 E2B: after a tool response to a message that also had text, the prompt opens a model turn (as '
        'llama.cpp adds it); after a call alone the model goes on in its own turn', () {
      final info = _info(_gemmaE2b);
      final profile = LlamadartFamilyProfile.detect(info)!;
      const response = '<|tool_response>response:get_time{value:<|"|>{"time": "14:30"}<|"|>}<tool_response|>';
      final withText = profile.prepare(info, _timeRound('Let me check.'), tools: [_time]).prompt;
      expect(withText, endsWith('$response${'Let me check.'}<turn|>\n<|turn>model\n'));
      final alone = profile.prepare(info, _timeRound(''), tools: [_time]).prompt;
      expect(
        alone,
        endsWith('<|turn>model\n<|tool_call>call:get_time{timezone:<|"|>Asia/Tokyo<|"|>}<tool_call|>$response'),
      );
      final noGeneration = profile.prepare(
        info,
        _timeRound('Let me check.'),
        tools: [_time],
        addGenerationPrompt: false,
      );
      expect(noGeneration.prompt, endsWith('Let me check.<turn|>\n'));
      expect(
        profile.templateFor(info).render(_timeRound('Let me check.'), tools: [_time.declaration]),
        withText,
        reason: 'templateFor renders as prepare does',
      );
    });

    test('LFM2.5: its Python-style calls (none, several, escapes, Python literals) and the JSON list of '
        'ToolMode.required are read; an envelope that cannot be read is an error', () {
      final info = _info(_lfm25, architecture: 'lfm2');
      final profile = LlamadartFamilyProfile.detect(info)!;
      expect(profile.family, 'lfm2');
      final tools = [_note, _time, _add];
      final prompt = profile.prepare(info, _question, tools: tools);
      ParsedOutput parse(String raw) => profile.parse(raw, tools, prompt);
      final none = parse('<|tool_call_start|>[get_time()]<|tool_call_end|>I am checking.');
      expect(none.toolCalls, [const ToolCall('get_time')]);
      expect((none.text, none.error), ('I am checking.', null));
      expect(parse('<|tool_call_start|>[get_time(), add(a=2, b=-3)]<|tool_call_end|>').toolCalls, [
        const ToolCall('get_time'),
        const ToolCall('add', {'a': 2, 'b': -3}),
      ]);
      expect(
        parse(r'<|tool_call_start|>[save_note(text="He said \"hi\", then: bye\nC:\\temp")]<|tool_call_end|>').toolCalls,
        [
          const ToolCall('save_note', {'text': 'He said "hi", then: bye\nC:\\temp'}),
        ],
      );
      expect(parse(r"<|tool_call_start|>[save_note(text='It\'s 5')]<|tool_call_end|>").toolCalls, [
        const ToolCall('save_note', {'text': "It's 5"}),
      ]);
      expect(
        parse("<|tool_call_start|>[x(a=1.5, b=True, c=None, d=[1, 'two'], e={'k': False})]<|tool_call_end|>").toolCalls,
        [
          const ToolCall('x', {
            'a': 1.5,
            'b': true,
            'c': null,
            'd': [1, 'two'],
            'e': {'k': false},
          }),
        ],
      );
      final json = parse(
        '<|tool_call_start|>[{"name": "add", "arguments": {"a": 17, "b": 25}\n\n    \t,"id": "add_result"}]'
        '<|tool_call_end|>',
      );
      expect(json.toolCalls, [
        const ToolCall('add', {'a': 17, 'b': 25}),
      ]);
      expect(json.error, isNull);
      expect(
        parse('<|tool_call_start|>[get_time(timezone=Europe/Rome), add(a=2, b=1 + 2)]<|tool_call_end|>').toolCalls,
        [
          const ToolCall('get_time', {'timezone': 'Europe/Rome'}),
          const ToolCall('add', {'a': 2, 'b': '1 + 2'}),
        ],
        reason: 'an unquoted value is its text, as llamadart reads it',
      );
      expect(parse('<|tool_call_start|>[save_note(text="abc)]<|tool_call_end|>').toolCalls, isEmpty);
      final unreadable = parse('<|tool_call_start|>[get_time(Europe/Rome)]<|tool_call_end|>');
      expect(unreadable.toolCalls, isEmpty);
      expect(
        unreadable.error,
        'a tool call that cannot be read: <|tool_call_start|>[get_time(Europe/Rome)]<|tool_call_end|>',
      );
      final cut = parse('Sure <|tool_call_start|>[get_time(');
      expect((cut.text, cut.toolCalls.length), ('Sure', 0));
      expect(cut.error, startsWith('a tool call llamadart could not read: <|tool_call_start|>'));
      expect(profile.visibleText('Sure <|tool_call_st', prompt), 'Sure');
    });

    test("LFM2.5: the tool block as Hugging Face's tojson writes it, a past call in LFM2's own syntax", () {
      final info = _info(_lfm25, architecture: 'lfm2');
      final prompt = LlamadartFamilyProfile.detect(info)!.prepare(info, _timeRound(''), tools: [_time]).prompt;
      expect(
        prompt,
        contains(
          'List of tools: [{"name": "get_time", "description": "The current time in a time zone.", "parameters": '
          '{"type": "object", "properties": {"timezone": {"type": "string"}}}}]<|im_end|>',
        ),
      );
      expect(prompt, contains("<|im_start|>assistant\n<|tool_call_start|>[get_time(timezone='Asia/Tokyo')]"));
    });

    test("the text stops only at the family's own call opener: prose about other formats is text", () {
      const prose = 'Qwen writes <tool_call>, Mistral [TOOL_CALLS] and Llama <function=x>.';
      for (final (template, architecture) in [(_gemmaE2b, 'gemma4'), (_lfm25, 'lfm2')]) {
        final info = _info(template, architecture: architecture);
        final profile = LlamadartFamilyProfile.detect(info)!;
        final prompt = profile.prepare(info, _question, tools: [_add]);
        final parsed = profile.parse(prose, [_add], prompt);
        expect((parsed.text, parsed.error), (prose, null), reason: architecture);
        expect(profile.visibleText(prose, prompt), prose, reason: architecture);
      }
      final hermes = _profile('hermes');
      expect(hermes.parse(prose, [_add], hermes.prepare(_of('hermes'), _question, tools: [_add])).text, 'Qwen writes');
    });
  });

  group('on a scripted engine', () {
    test('ChatModel: the profile is detected, the call parsed, no markup in the text; the stable prefix compares two '
        'renderings', () async {
      final engine = ScriptedEngine(
        chatTemplate: _templates['gemma4']!,
        metadata: const {'general.architecture': 'gemma4'},
      );
      await engine.load('m.gguf');
      final model = ChatModel.attach(engine);
      expect(model.profile, isA<LlamadartFamilyProfile>());
      engine.outputs.add('<|tool_call>call:add{a:2,b:3}<tool_call|>');
      final generation = model.generate(_question, tools: [_add]);
      expect(await generation.text.toList(), isEmpty);
      final result = await generation.result;
      expect(result.toolCalls, [
        const ToolCall('add', {'a': 2, 'b': 3}),
      ]);
      expect(result.text, '');
      expect(engine.options.single.stop, ['<tool_call|>', '<turn|>']);
      expect(model.stablePrefix(systemPrompt: 'Be brief.', tools: [_add]), endsWith('<|turn>user\n'));
      await engine.dispose();
    });

    test('Assistant: one tool round with model-written replies; the result reaches the second prompt', () async {
      final ran = <ToolCall>[];
      final (assistant, engine) = await scriptedAssistant(
        AssistantConfig.basic(
          systemPrompt: 'Be brief.',
          tools: [
            AssistantTool(
              name: 'add',
              description: 'Adds two integers.',
              parameters: _add.parameters,
              run: (call, context) {
                ran.add(call);
                return ToolResult.ok({'sum': call.integer('a')! + call.integer('b')!});
              },
            ),
          ],
        ),
        chatTemplate: _templates['gemma4']!,
        script: [const ScriptedTurn.text('<|tool_call>call:add{a:2,b:3}<tool_call|>'), const ScriptedTurn.text('5.')],
      );
      addTearDown(assistant.dispose);
      expect(assistant.model!.profile, isA<LlamadartFamilyProfile>());
      final outcome = await assistant.send('What is 2 + 3?');
      expect(outcome.reply, '5.');
      expect(ran, [
        const ToolCall('add', {'a': 2, 'b': 3}),
      ]);
      expect(engine.prompts[1], contains('<|tool_response>response:add{value:<|"|>'));
      expect(engine.prompts[1], contains('"sum": 5'));
    });

    test(
      "scriptedAssistant refuses a ScriptedTurn.toolCall (Qwen3.5's XML envelope) that the family does not read",
      () async {
        final config = AssistantConfig.basic(
          systemPrompt: 'Be brief.',
          tools: [
            AssistantTool(
              name: 'add',
              description: 'Adds two integers.',
              parameters: _add.parameters,
              run: (call, context) => ToolResult.ok({'sum': 5}),
            ),
          ],
        );
        await expectLater(
          scriptedAssistant(
            config,
            chatTemplate: _templates['gemma4']!,
            script: [
              const ScriptedTurn.toolCall('add', {'a': 2, 'b': 3}),
            ],
          ),
          throwsA(isA<ArgumentError>().having((e) => e.message, 'message', contains('ScriptedTurn.text'))),
        );
        final (assistant, _) = await scriptedAssistant(
          config,
          script: [
            const ScriptedTurn.toolCall('add', {'a': 2, 'b': 3}),
          ],
        );
        await assistant.dispose();
      },
    );
  });
}
