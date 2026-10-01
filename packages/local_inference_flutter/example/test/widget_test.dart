// The example on a scripted engine (no model, no download): the chat starts with its welcome and suggestions, a
// suggestion makes the model call convert_units, the result goes back to the model, and its answer is shown. Plus
// the two tools on their own.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_chat/main.dart';
import 'package:flutter_chat/toolkit.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_inference_flutter/local_inference_flutter.dart';
import 'package:local_inference_flutter/testing.dart';

/// Short real waits and frames (the assistant reads the model file and runs the engine), until [done].
Future<void> pumpUntil(WidgetTester tester, bool Function() done, {required String reason}) async {
  for (var i = 0; i < 300 && !done(); i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    await tester.pump();
  }
  expect(done(), isTrue, reason: reason);
}

void main() {
  test('convert_units converts within a kind of unit, both ways, and refuses across kinds', () {
    expect(convertUnits(20, 'celsius', 'fahrenheit'), 68);
    expect(convertUnits(212, 'fahrenheit', 'celsius'), 100);
    expect(convertUnits(42, 'kilometers', 'miles'), closeTo(26.098, 0.001));
    expect(convertUnits(26.2188, 'miles', 'kilometers'), closeTo(42.195, 0.001));
    expect(convertUnits(10, 'kilograms', 'pounds'), closeTo(22.046, 0.001));
    expect(convertUnits(10, 'pounds', 'kilograms'), closeTo(4.536, 0.001));
    expect(convertUnits(5, 'miles', 'miles'), 5);
    expect(convertUnits(1, 'celsius', 'miles'), isNull);
    expect(convertUnits(1, 'lightyears', 'miles'), isNull);
  });

  test('a convert_units call is checked against its schema before it runs', () {
    final toolkit = chatConfig().toolkit;
    expect(toolkit.validate(const ToolCall('convert_units', {'value': 1, 'from': 'celsius', 'to': 'fahrenheit'})), []);
    for (final arguments in [
      {'value': 1, 'from': 'kelvin', 'to': 'celsius'}, // a unit not in the list
      {'value': 1, 'from': 'celsius'}, // no unit to convert to
      {'value': '1', 'from': 'celsius', 'to': 'fahrenheit'}, // a string, not a number
    ]) {
      expect(toolkit.validate(ToolCall('convert_units', arguments)), isNotEmpty, reason: '$arguments');
    }
  });

  test('the model entry is a well-formed published entry, pinned to a commit, with its size and SHA-256', () {
    expect(ModelEntry.fromJson(lfm25.toJson()), lfm25, reason: 'the strict parse of a published manifest');
    expect(lfm25.url.pathSegments, contains('8ed288026e23958ad9dfa92d53ed773a8eee7125'));
    expect(
      (lfm25.sizeBytes, lfm25.sha256),
      (695755488, 'bb741ebb106d543e9de114b843a3d3d73d51c74b5801e69da2abde821a0cb3e1'),
    );
    expect(strings.setup.consentBody('Helper'), contains('about 700 MB'));
  });

  test('the assistant has the two tools; get_time reads the clock it is given', () async {
    final config = chatConfig(now: () => DateTime(2026, 9, 30, 8, 5));
    expect(config.toolkit.specs.map((s) => s.name), ['get_time', 'convert_units']);
    final (assistant, engine) = await scriptedAssistant(
      config,
      script: const [ScriptedTurn.toolCall('get_time'), ScriptedTurn.text('It is 08:05 on Wednesday.')],
    );
    addTearDown(assistant.dispose);
    final outcome = await assistant.send('What time is it?');
    expect(outcome.reply, 'It is 08:05 on Wednesday.');
    expect(engine.prompts.last, contains('"time": "08:05"'), reason: 'the tool read the clock it was given');
    expect(engine.prompts.last, contains('"date": "2026-09-30"'));
    expect(engine.prompts.last, contains('"weekday": "Wednesday"'));
  });

  testWidgets('a suggestion that calls convert_units, answered from its result', (tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final tmp = Directory.systemTemp.createTempSync('flutter_chat_test');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final model = File('${tmp.path}/model.gguf')..writeAsStringSync('x');
    final engine = ScriptedEngine(supportsStatePersistence: false);
    await tester.pumpWidget(
      FlutterChatApp(
        model: ModelOrigin.file(model.path),
        engine: () => engine,
        load: const LoadOptions(),
        prefixStore: InMemoryPrefixStateStore(),
      ),
    );
    const question = 'How much is 20 °C in Fahrenheit?';
    await pumpUntil(tester, () => find.text(question).evaluate().isNotEmpty, reason: 'loaded, with the suggestions');
    expect(find.text('Helper'), findsOneWidget);
    expect(find.textContaining('Ask me the time'), findsOneWidget);

    engine.outputs.addAll([
      const ScriptedTurn.toolCall('convert_units', {'value': 20, 'from': 'celsius', 'to': 'fahrenheit'}).output,
      '20 °C is 68 °F.',
    ]);
    await tester.tap(find.text(question));
    await pumpUntil(tester, () => find.text('20 °C is 68 °F.').evaluate().isNotEmpty, reason: 'the answer');
    expect(engine.prompts.last, contains('"result": 68.0'), reason: 'the tool\'s result went back to the model');
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
    await pumpUntil(tester, () => engine.disposes > 0, reason: 'the chat freed its engine');
  });
}
