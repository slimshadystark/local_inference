// The demo assistant of the screenshots: real AssistantConfigs and tools of local_inference, on a scripted engine
// that writes what a model would (a tool call, then the answer from its result).
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_inference_flutter/local_inference_flutter.dart';
import 'package:local_inference_flutter/testing.dart';

const _system = 'You are Helper, an assistant that runs on this phone. Answer briefly; use the tools.';

/// The forecast page a weather reply can open again from its chip.
final class ForecastScreen extends ScreenRequest {
  const ForecastScreen();

  @override
  String get label => 'Open the forecast';
}

/// The weather tool: a fixed forecast for tomorrow.
AssistantTool weatherTool() => AssistantTool(
  name: 'get_weather',
  description: 'The weather forecast for a city on a day.',
  parameters: ToolSchema.object(
    {
      'city': ToolSchema.string(description: 'The city.'),
      'day': ToolSchema.string(description: 'today, tomorrow or a weekday.'),
    },
    required: ['city'],
  ),
  statusLabel: 'Checking the weather…',
  run: (call, context) => ToolResult.ok({
    'city': call.string('city'),
    'day': call.string('day') ?? 'today',
    'sky': 'sunny',
    'low_c': 15,
    'high_c': 24,
    'wind': 'light breeze in the afternoon',
  }),
);

/// The calculator, for the demo's one expression.
AssistantTool calculatorTool() => AssistantTool(
  name: 'calculate',
  description: 'Evaluates an arithmetic expression with + - * / and parentheses.',
  parameters: ToolSchema.object(
    {'expression': ToolSchema.string(description: 'The expression to evaluate.')},
    required: ['expression'],
  ),
  statusLabel: 'Calculating…',
  run: (call, context) => ToolResult.ok({'expression': call.string('expression'), 'result': 51.26}),
);

/// The user's calendar: one event on Friday. It waits for [gate] first (the tool still runs when the screenshot is
/// taken).
AssistantTool calendarTool({Future<void>? gate}) => AssistantTool(
  name: 'check_calendar',
  description: "The user's events on a day.",
  parameters: ToolSchema.object({'day': ToolSchema.string(description: 'A date or a weekday.')}, required: ['day']),
  statusLabel: 'Checking your calendar…',
  run: (call, context) async {
    if (gate != null) await gate;
    return ToolResult.ok({
      'day': call.string('day'),
      'events': [
        {'title': 'Yoga', 'start': '18:00', 'end': '19:00'},
      ],
    });
  },
);

/// Free tables near a place: three fixed restaurants.
AssistantTool findTablesTool() => AssistantTool(
  name: 'find_tables',
  description: 'Restaurants with a free table near a place, for a number of people, a day and a time.',
  parameters: ToolSchema.object(
    {
      'near': ToolSchema.string(),
      'people': ToolSchema.integer(minimum: 1, maximum: 12),
      'day': ToolSchema.string(),
      'time': ToolSchema.string(),
    },
    required: ['near', 'people'],
  ),
  statusLabel: 'Looking for a table…',
  run: (call, context) => ToolResult.ok({
    'restaurants': [
      {'name': 'Trattoria Da Lucia', 'kind': 'Roman cooking', 'walk_min': 3},
      {'name': 'Osteria del Sole', 'kind': 'wine and small plates', 'walk_min': 5},
      {'name': 'Pizzeria Il Forno', 'kind': 'wood-fired pizza', 'walk_min': 6},
    ],
  }),
);

/// Books a table: irreversible, so the assistant asks first.
AssistantTool bookTableTool() => AssistantTool(
  name: 'book_table',
  description: 'Books a table at a restaurant.',
  parameters: ToolSchema.object(
    {
      'restaurant': ToolSchema.string(),
      'people': ToolSchema.integer(minimum: 1, maximum: 12),
      'day': ToolSchema.string(),
      'time': ToolSchema.string(),
    },
    required: ['restaurant', 'people', 'day', 'time'],
  ),
  sideEffect: SideEffect.irreversible,
  confirmationQuestion: (call, context) =>
      'Book a table for ${call.arguments['people']} at ${call.string('restaurant')}, '
      '${call.string('day')} at ${call.string('time')}?',
  statusLabel: 'Booking…',
  run: (call, context) => ToolResult.ok({'booked': call.string('restaurant'), 'code': 'R-4821'}),
);

/// A config of the demo assistant with [tools]; with [forecastChip] a weather reply offers its forecast page.
AssistantConfig demoConfig(List<AssistantTool> tools, {bool forecastChip = false}) =>
    AssistantConfig.basic(systemPrompt: _system, tools: tools).copyWith(
      screenRequests: forecastChip
          ? (outcome) => outcome.call.name == 'get_weather' && outcome.result.ok ? const ForecastScreen() : null
          : null,
    );

/// A call as the model writes it (Qwen3.5's XML envelope, the scripted engine's template).
String call(String name, Map<String, Object?> arguments) => ScriptedTurn.toolCall(name, arguments).output;

/// The first row of the light chats.
const helperWelcome = "Hi! I'm Helper, and I run on this phone, even offline.";

/// The weather question and its reply (a no-break space keeps each temperature on one line).
const weatherQuestion = "What's the weather in Rome tomorrow?";
final weatherScript = [
  call('get_weather', {'city': 'Rome', 'day': 'tomorrow'}),
  'Tomorrow in Rome: sunny, from 15 to 24 °C, with a light breeze in the afternoon. A good day for a walk.',
];

/// The bill question and its reply.
const billQuestion = 'Split a €186.40 dinner bill between 4 people, plus a 10% tip.';
final billScript = [
  call('calculate', {'expression': '186.40 * 1.10 / 4'}),
  "That's €51.26 each: €205.04 in total, tip included.",
];

/// The calendar question and its reply.
const calendarQuestion = 'Am I free on Friday evening?';
final calendarScript = [
  call('check_calendar', {'day': 'Friday'}),
  'You have yoga from 6 to 7 pm. After that, Friday evening is free.',
];

/// A chat controller over [config] on [engine], its (scripted) model loaded unless [load] is false; disposed at the
/// end of the test.
Future<AssistantController> demoController(
  WidgetTester tester,
  AssistantConfig config,
  ScriptedEngine engine, {
  bool load = true,
}) async {
  final assistant = Assistant(config, engine: () => engine, prefixStore: InMemoryPrefixStateStore());
  if (load) {
    final loaded = await tester.runAsync(
      () => assistant.loadModel('demo.gguf', identity: const ModelIdentity.fixed('demo.gguf')),
    );
    expect(loaded, isTrue, reason: '${assistant.state.loadError}');
  }
  final controller = AssistantController.owning(assistant);
  addTearDown(() => tester.runAsync(controller.dispose));
  return controller;
}

/// Lets the assistant's work go on (short real waits, then frames) until [done].
Future<void> pumpUntil(WidgetTester tester, bool Function() done, {required String reason}) async {
  for (var i = 0; i < 400 && !done(); i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    await tester.pump();
  }
  expect(done(), isTrue, reason: reason);
}

/// Sends [text] as the user would (the composer's send) and waits for the turn to end.
Future<void> ask(WidgetTester tester, AssistantController controller, String text) async {
  unawaited(controller.send(text));
  await pumpUntil(tester, () => !controller.assistant.state.isBusy, reason: 'the turn of "$text" ends');
  // The list follows the new text; a reply that asks for a screen dispatches it after 600 ms.
  await tester.pump(const Duration(seconds: 1));
  await tester.pumpAndSettle();
}

/// A manifest of one model, as an app would publish it (the screenshots never download it).
String demoManifest() => jsonEncode({
  'schemaVersion': 1,
  'manifestVersion': '2026-10-16',
  'models': [
    {
      'id': 'qwen3.5-4b-q4_0',
      'version': 1,
      'displayName': 'Qwen3.5 4B · Q4_0',
      'params': '4B',
      'quant': 'Q4_0',
      'format': 'gguf',
      'status': 'active',
      'recommended': true,
      'file': {'url': 'https://example.org/models/Qwen3.5-4B-Q4_0.gguf', 'sizeBytes': 2583221408, 'sha256': 'f' * 64},
      'requirements': {'minPhysicalRamMB': 6000, 'minAvailableMemoryMB': 3000, 'minFreeDiskMB': 3000},
    },
  ],
});
