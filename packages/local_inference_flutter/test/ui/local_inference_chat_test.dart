// LocalInferenceChat, the zero-ceremony tier, with a toy toolkit on a scripted engine: it makes the assistant, loads
// the model file, chats (a tool call whose result the model answers from), reconfigures on a new config, disposes
// everything when it goes, and shows a retry panel when it cannot start.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_inference/testing.dart';
import 'package:local_inference_flutter/local_inference_flutter.dart';

import '../support/toy_chat.dart';

AssistantConfig _weather({String prompt = 'You tell the weather.'}) => AssistantConfig.basic(
  systemPrompt: prompt,
  tools: [
    AssistantTool(
      name: 'weather',
      description: 'The weather in a city.',
      parameters: ToolSchema.object({'city': ToolSchema.string()}, required: ['city']),
      statusLabel: '☀️ Checking the weather...',
      run: (call, context) => ToolResult.ok({'city': call.string('city'), 'sky': 'sunny'}),
    ),
  ],
);

void main() {
  testWidgets('a model file and a toy toolkit: it loads, answers with a tool, and disposes everything', (tester) async {
    usePhoneSurface(tester);
    final tmp = Directory.systemTemp.createTempSync('local_inference_chat_test');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final model = File('${tmp.path}/weather.gguf')..writeAsStringSync('x');
    final engine = ScriptedEngine(supportsStatePersistence: false);
    Widget chat(AssistantConfig config) => app(
      LocalInferenceChat(
        config: config,
        model: ModelOrigin.file(model.path),
        assistantName: 'Helper',
        welcome: 'Hi! Ask me about the weather.',
        suggestions: const ['Weather in Rome?'],
        engine: () => engine,
        load: const LoadOptions(),
        prefixStore: InMemoryPrefixStateStore(),
      ),
    );
    final config = _weather();
    await tester.pumpWidget(chat(config));
    await pumpUntil(tester, () => find.text('Weather in Rome?').evaluate().isNotEmpty, reason: 'loaded and ready');
    expect(find.text('Helper'), findsOneWidget, reason: 'the title');
    expect(find.text('Hi! Ask me about the weather.'), findsOneWidget);

    engine.outputs.addAll([
      toolCall('weather', {'city': 'Rome'}),
      'It is sunny in Rome.',
    ]);
    await tester.tap(find.text('Weather in Rome?'));
    await pumpUntil(tester, () => find.text('It is sunny in Rome.').evaluate().isNotEmpty, reason: 'answered');
    expect(engine.prompts.last, contains('sunny'), reason: 'the tool\'s result went back to the model');
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    // A new config (a new system prompt) reconfigures the assistant: a new conversation starts.
    await tester.pumpWidget(chat(_weather(prompt: 'You tell the weather, briefly.')));
    await pumpUntil(tester, () => find.text('It is sunny in Rome.').evaluate().isEmpty, reason: 'cleared');

    await tester.pumpWidget(app(const SizedBox()));
    await pumpUntil(tester, () => engine.disposes > 0, reason: 'the owned assistant freed its engine');
  });

  testWidgets('a config that comes during a turn is given to the assistant when the turn ends', (tester) async {
    usePhoneSurface(tester);
    final tmp = Directory.systemTemp.createTempSync('local_inference_chat_test');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final model = File('${tmp.path}/weather.gguf')..writeAsStringSync('x');
    final engine = ScriptedEngine(supportsStatePersistence: false);
    Widget chat(AssistantConfig config) => app(
      LocalInferenceChat(
        config: config,
        model: ModelOrigin.file(model.path),
        suggestions: const ['Weather in Rome?'],
        engine: () => engine,
        load: const LoadOptions(),
        prefixStore: InMemoryPrefixStateStore(),
      ),
    );
    await tester.pumpWidget(chat(_weather()));
    await pumpUntil(tester, () => find.text('Weather in Rome?').evaluate().isNotEmpty, reason: 'loaded and ready');
    engine
      ..gate = Completer<void>()
      ..outputs.add('Sunny.');
    await tester.tap(find.text('Weather in Rome?'));
    await tester.pump();
    await tester.pumpWidget(chat(_weather(prompt: 'You tell the weather, briefly.')));
    await tester.pump();
    expect(find.text('Weather in Rome?'), findsOneWidget, reason: 'the turn goes on: the question stays');
    engine.gate!.complete();
    // The new prompt starts a new conversation once the turn ended: the suggestion is back.
    await pumpUntil(
      tester,
      () => find.byKey(LocalInferenceKeys.suggestion(0)).evaluate().isNotEmpty,
      reason: 'reconfigured after the turn',
    );
    expect(engine.prompts.single, contains('You tell the weather.'), reason: 'the turn ran on the old config');
    expect(find.text('Sunny.'), findsNothing);
    engine.outputs.add('Sunny, briefly.');
    await tester.tap(find.text('Weather in Rome?'));
    await pumpUntil(tester, () => find.text('Sunny, briefly.').evaluate().isNotEmpty, reason: 'answered');
    expect(engine.prompts.last, contains('You tell the weather, briefly.'));
  });

  testWidgets('when it cannot start (no platform folders in a test) it offers to retry', (tester) async {
    usePhoneSurface(tester);
    await tester.pumpWidget(
      app(
        LocalInferenceChat(
          config: _weather(),
          model: ModelOrigin.catalog(ModelCatalog.bundled(() async => testManifestJson())),
          engine: ScriptedEngine.new,
          title: 'Helper',
          features: const ChatFeatures(showDetails: true),
        ),
      ),
    );
    expect(find.text('Helper'), findsOneWidget, reason: 'the app bar, while it starts');
    await pumpUntil(
      tester,
      () => find.text(LocalInferenceStrings.english.chat.loadFailedTitle).evaluate().isNotEmpty,
      reason: 'the failure is shown',
    );
    expect(find.text(LocalInferenceStrings.english.chat.retry), findsOneWidget);
    expect(find.text('Helper'), findsOneWidget, reason: 'and when it cannot');
    expect(find.textContaining('MissingPluginException'), findsOneWidget, reason: 'the cause, with showDetails');
    await tester.tap(find.text(LocalInferenceStrings.english.chat.retry));
    await pumpUntil(
      tester,
      () => find.text(LocalInferenceStrings.english.chat.loadFailedTitle).evaluate().isNotEmpty,
      reason: 'tried again',
    );
  });
}
