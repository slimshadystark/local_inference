// Rendering with a model's chat template: byte-identical to the jinja2 /
// Hugging Face renderings of tool/render_reference.py, on both Qwen3.5 templates.
import 'dart:convert';
import 'dart:io';

import 'package:local_inference/local_inference.dart';
import 'package:local_inference/testing.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

void main() {
  late Directory tmp;
  late File modelFile;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('chat_template_test');
    modelFile = File('${tmp.path}/model.gguf')..writeAsStringSync('not a model');
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  test('the fixture templates are the Qwen3.5-2B and 4B ones', () {
    expect(JinjaChatTemplate(template2b).sha256, 'ea210e5b4997b7b1d3af5ee3ad34e7677ffe38df7469e8d88089789b5a27fae5');
    expect(JinjaChatTemplate(template4b).sha256, '8452ca85cb1e0ff04304c02f417a53305d5ba17f6eb9d5693343ad8355f985a8');
    expect(template2b, qwen35ChatTemplate);
  });

  test('the toy tools derive the declarations of toy_tools.json (key order included)', () {
    expect(
      [for (final tool in toyTools) pythonJson(tool.declaration)],
      [for (final declaration in toyDeclarations) pythonJson(declaration)],
    );
  });

  test('each case message is a ChatMessage whose toJson is the case JSON, key order included', () {
    for (final referenceCase in referenceCases) {
      expect(
        [for (final message in referenceCase.messages) jsonEncode(message.toJson())],
        [for (final json in referenceCase.messageJson) jsonEncode(json)],
        reason: referenceCase.name,
      );
    }
  });

  group('JinjaChatTemplate equals the jinja2 rendering byte for byte', () {
    for (final referenceCase in referenceCases) {
      for (final tag in referenceTemplates.keys) {
        test('${referenceCase.name} (${tag.toUpperCase()} template)', () {
          final prompt = JinjaChatTemplate(referenceTemplates[tag]!).render(
            referenceCase.messages,
            tools: [for (final tool in referenceCase.tools) tool.declaration],
            addGenerationPrompt: referenceCase.addGenerationPrompt,
            variables: referenceCase.variables,
          );
          final difference = firstDifference(prompt, referenceCase.reference(tag));
          if (difference != null) fail(difference);
        });
      }
    }
  });

  group('ChatModel.render with Qwen35Profile equals the jinja2 rendering byte for byte', () {
    // The profile always passes enable_thinking false and asks for the generation prompt.
    final profileCases = [
      for (final referenceCase in referenceCases)
        if (jsonEncode(referenceCase.variables) == jsonEncode(const Qwen35Profile().templateVariables) &&
            referenceCase.addGenerationPrompt)
          referenceCase,
    ];

    test('the profile cases are most of the cases', () => expect(profileCases.length, greaterThanOrEqualTo(7)));

    for (final referenceCase in profileCases) {
      for (final tag in referenceTemplates.keys) {
        test('${referenceCase.name} (${tag.toUpperCase()} template)', () async {
          final engine = ScriptedEngine(chatTemplate: referenceTemplates[tag]!);
          await engine.load(modelFile.path);
          final model = ChatModel.attach(engine, profile: const Qwen35Profile());
          final prompt = model.render(referenceCase.messages, tools: referenceCase.tools);
          final difference = firstDifference(prompt, referenceCase.reference(tag));
          if (difference != null) fail(difference);
          expect(model.prepare(referenceCase.messages, tools: referenceCase.tools).prompt, prompt);
        });
      }
    }
  });

  test('thinking: with the flag explicit both templates end with the empty think block and agree; by default the '
      '4B opens a think block', () {
    const emptyThink = '<|im_start|>assistant\n<think>\n\n</think>\n\n';
    final off = referenceCases.firstWhere((c) => c.name == 'thinking_off');
    expect(off.reference('2b'), endsWith(emptyThink));
    expect(off.reference('4b'), off.reference('2b'));
    final byDefault = referenceCases.firstWhere((c) => c.name == 'thinking_default');
    expect(byDefault.reference('2b'), endsWith(emptyThink));
    expect(byDefault.reference('4b'), endsWith('<|im_start|>assistant\n<think>\n'));
    final on = referenceCases.firstWhere((c) => c.name == 'thinking_on');
    expect(on.reference('4b'), endsWith('<|im_start|>assistant\n<think>\n'));
    expect(on.reference('2b'), on.reference('4b'));
  });

  test('the tool block holds each declaration as Python json.dumps writes it, non-ASCII unescaped', () {
    final tools = [for (final tool in toyTools) tool.declaration];
    final prompt = JinjaChatTemplate(
      template2b,
    ).render(const [ChatMessage.user('hi')], tools: tools, variables: const {'enable_thinking': false});
    for (final tool in tools) {
      expect(prompt, contains(pythonJson(tool)));
    }
    expect(prompt, contains('Zürich'));
    expect(prompt, isNot(contains(r'\u00')), reason: 'no \\u escape of dinja is left');
  });

  test('no tools: the tools variable is left out, so the template writes no tool block', () {
    final template = JinjaChatTemplate('{% if tools is defined %}T{% else %}none{% endif %}');
    expect(template.render(const [ChatMessage.user('x')]), 'none');
    expect(
      template.render(
        const [ChatMessage.user('x')],
        tools: [
          {'type': 'function'},
        ],
      ),
      'T',
    );
  });

  test('the context: messages as toJson, add_generation_prompt, the variables, then the globals', () {
    final template = JinjaChatTemplate(
      '{{ messages[0].role }}:{{ messages[0].content }}|{{ add_generation_prompt }}|{{ a }}|{{ b }}|{{ bos_token }}',
      globals: const {'b': 'global', 'bos_token': '<s>'},
    );
    expect(
      template.render(
        const [ChatMessage.user('hi')],
        addGenerationPrompt: false,
        variables: const {'a': 1, 'b': 'var'},
      ),
      'user:hi|False|1|global|<s>',
    );
    expect(template.globals, {'b': 'global', 'bos_token': '<s>'});
  });

  test('the swap replaces a tool JSON only once, and only when dinja and Python differ', () {
    final template = JinjaChatTemplate('{% for t in tools %}{{ t | tojson }};{% endfor %}{{ tools[0] | tojson }}');
    final tool = <String, Object?>{'a': 1, 'b': 'è'};
    expect(template.render(const [ChatMessage.user('x')], tools: [tool]), '{"a": 1, "b": "è"};{"a":1,"b":"\\u00e8"}');
    final plain = JinjaChatTemplate('{{ tools[0] | tojson }}');
    expect(
      plain.render(
        const [ChatMessage.user('x')],
        tools: const [
          {'x': []},
        ],
      ),
      '{"x": []}',
    );
  });

  group('pythonJson', () {
    test("matches Python's json.dumps defaults", () {
      expect(
        pythonJson({
          'a': 1,
          'b': [true, null, 'x"y'],
          'c': {'d': 'è'},
        }),
        '{"a": 1, "b": [true, null, "x\\"y"], "c": {"d": "è"}}',
      );
      expect(pythonJson(2.0), '2.0');
      expect(pythonJson(1.5), '1.5');
      // A known difference: whole doubles from 1e16 on are Dart's toString (Python would write 1e+16).
      expect(pythonJson(1e20), '100000000000000000000.0');
      expect(pythonJson(1e21), '1e+21');
      expect(pythonJson('tab\there\nand \u0001'), r'"tab\there\nand \u0001"');
      expect(pythonJson(const []), '[]');
      expect(pythonJson(const <String, Object?>{}), '{}');
    });

    test('rejects what is not JSON', () => expect(() => pythonJson(DateTime(2026)), throwsArgumentError));
  });
}
