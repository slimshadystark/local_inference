// The assistant's testing kit in package:local_inference/testing.dart: scriptedAssistant with its grammar check,
// ScriptedTurn and TestToolkit.
import 'dart:async';

import 'package:local_inference/local_inference.dart';
import 'package:local_inference/testing.dart';
import 'package:test/test.dart';

final List<Map<String, Object?>> _asked = [];

final AssistantTool _weather = AssistantTool(
  name: 'get_weather',
  description: 'Current weather for a city.',
  parameters: ToolSchema.object(
    {
      'city': ToolSchema.string(),
      'unit': ToolSchema.string(enumValues: ['c', 'f']),
    },
    required: ['city'],
  ),
  run: (call, context) {
    _asked.add(call.arguments);
    return ToolResult.ok({'city': call.string('city'), 'sky': 'sunny', 'temperature': 24});
  },
);

void main() {
  setUp(_asked.clear);

  test('ScriptedTurn: text as it is, a tool call as the Qwen3.5 model writes it', () {
    expect(const ScriptedTurn.text('Hi.').output, 'Hi.');
    expect(
      const ScriptedTurn.toolCall('get_weather', {'city': 'Rome', 'days': 2}).output,
      '<tool_call>\n<function=get_weather>\n<parameter=city>\nRome\n</parameter>\n<parameter=days>\n2\n</parameter>\n'
      '</function>\n</tool_call>',
    );
  });

  test('scriptedAssistant: a loaded assistant with no model file; the model writes the reply from the result by '
      'default', () async {
    final (assistant, engine) = await scriptedAssistant(
      AssistantConfig.basic(systemPrompt: 'You tell the weather.', tools: [_weather]),
      script: [
        const ScriptedTurn.toolCall('get_weather', {'city': 'Rome'}),
        const ScriptedTurn.text('It is sunny in Rome, 24 degrees.'),
      ],
    );
    addTearDown(assistant.dispose);
    expect(assistant.state.phase, AssistantPhase.ready);
    expect(assistant.state.modelPath, 'scripted.gguf');
    final outcome = await assistant.send('Weather in Rome?');
    expect(outcome.reply, 'It is sunny in Rome, 24 degrees.');
    expect(_asked, [
      {'city': 'Rome'},
    ]);
    expect(engine.prompts, hasLength(2));
    expect(engine.outputs, isEmpty);
    expect(engine.saves, 0, reason: 'no store given: no state file');
  });

  test('scriptedAssistant: a scripted call the grammar would not admit fails its generation and the test', () async {
    final errors = <Object>[];
    final outcome = await runZonedGuarded(() async {
      final (assistant, _) = await scriptedAssistant(
        AssistantConfig.basic(systemPrompt: 'You tell the weather.', tools: [_weather]),
        script: [
          const ScriptedTurn.toolCall('get_weather', {'city': 'Rome', 'unit': 'kelvin'}),
        ],
      );
      final outcome = await assistant.send('Weather in Rome, in kelvin?');
      await assistant.dispose();
      return outcome;
    }, (error, stack) => errors.add(error));
    expect(errors.single, isA<ScriptRejectedByGrammar>());
    expect('${errors.single}', contains('unit'));
    expect(outcome!.error, isA<GenerationException>());
    expect(_asked, isEmpty);
  });

  test('scriptedAssistant: without the check the call goes through (and the validator stops it); text is never '
      'checked', () async {
    final (assistant, engine) = await scriptedAssistant(
      AssistantConfig.basic(systemPrompt: 'You tell the weather.', tools: [_weather]),
      script: [
        const ScriptedTurn.toolCall('get_weather', {'city': 'Rome', 'unit': 'kelvin'}),
        const ScriptedTurn.text('Which unit?'),
      ],
      validateAgainstGrammar: false,
    );
    addTearDown(assistant.dispose);
    expect((await assistant.send('Weather in Rome, in kelvin?')).reply, 'Which unit?');
    expect(assistant.state.items.last.details, contains('[validation] get_weather: '));
    expect(_asked, isEmpty);

    final (checked, _) = await scriptedAssistant(
      AssistantConfig.basic(systemPrompt: 'Chat.'),
      script: [const ScriptedTurn.text('I can write <tool_call> in plain text.')],
    );
    addTearDown(checked.dispose);
    expect((await checked.send('hi')).reply, 'I can write <tool_call> in plain text.', reason: 'no tools, no grammar');
    expect(engine.outputs, isEmpty);
  });

  test('scriptedAssistant: with a prefix store the states are saved; a refused template throws', () async {
    final store = InMemoryPrefixStateStore();
    addTearDown(store.clear);
    final (assistant, engine) = await scriptedAssistant(
      AssistantConfig.basic(systemPrompt: 'Chat.'),
      prefixStore: store,
    );
    addTearDown(assistant.dispose);
    expect(engine.saves, 1);
    await expectLater(
      scriptedAssistant(
        AssistantConfig(
          toolkit: Toolkit.of(const []),
          prompt: const PromptLayout(systemPrompt: 'Chat.'),
          profile: const Qwen35Profile(acceptedTemplateSha256: {'none'}),
        ),
      ),
      throwsStateError,
    );
  });

  test('TestToolkit records the calls with their source and annotations, holds back one tool, counts resets', () async {
    final toolkit = TestToolkit(Toolkit.of([_weather]));
    final context = ToolContext(call: const ToolCall('get_weather', {'city': 'Oslo'}), annotations: {'x': 1});
    final gate = Completer<void>();
    toolkit
      ..gatedTool = 'get_weather'
      ..gate = gate;
    var done = false;
    final running = toolkit.execute(const ToolCall('get_weather', {'city': 'Oslo'}), context).then((r) {
      done = true;
      return r;
    });
    await pumpEventQueue();
    expect(_asked, [
      {'city': 'Oslo'},
    ], reason: 'the call started at once');
    expect(done, isFalse, reason: 'its answer waits for the gate');
    gate.complete();
    expect((await running).payload['sky'], 'sunny');
    expect(toolkit.calls, [
      const ToolCall('get_weather', {'city': 'Oslo'}),
    ]);
    expect(toolkit.sources, [ToolCallSource.host]);
    expect(toolkit.annotations, [
      {'x': 1},
    ]);
    toolkit.reset();
    expect(toolkit.resets, 1);
  });
}
