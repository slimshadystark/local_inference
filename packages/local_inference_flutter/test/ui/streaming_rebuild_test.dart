// While a reply streams, only its own message rebuilds: over 50 deltas, a frame after each, no other message, the
// composer, the action bar or the list rebuilds.
import 'package:flutter_test/flutter_test.dart';
import 'package:local_inference_flutter/local_inference_flutter.dart';

import '../support/stepped_engine.dart';
import '../support/toy_chat.dart';

void main() {
  testWidgets('50 deltas rebuild the streaming message 50 times and nothing else', (tester) async {
    usePhoneSurface(tester);
    final engine = SteppedEngine();
    final (controller, _) = await toyController(tester, engine: engine);
    final builds = <String, int>{};
    void count(String what) => builds[what] = (builds[what] ?? 0) + 1;
    await tester.pumpWidget(
      app(
        ChatPage(
          controller: controller,
          assistantName: 'Acme',
          welcome: 'Hello.',
          builders: ChatBuilders(
            // The welcome row is built by the list's item builder: it counts the list's rebuilds.
            welcome: (context, slot) {
              count('list');
              return slot.buildDefault();
            },
            userMessage: (context, slot) {
              count('user ${slot.message.id}');
              return slot.buildDefault();
            },
            assistantMessage: (context, slot) {
              count('assistant ${slot.message.id}');
              return slot.buildDefault();
            },
            composer: (context, slot) {
              count('composer');
              return slot.buildDefault();
            },
            confirmation: (context, slot) {
              count('actions');
              return slot.buildDefault();
            },
          ),
        ),
      ),
    );
    engine.outputs.add('Hi there.');
    await sendText(tester, controller, 'hello');

    engine.stepped = true;
    await tester.enterText(find.byKey(LocalInferenceKeys.composerField), 'tell me more');
    await tester.tap(find.byKey(LocalInferenceKeys.sendButton));
    await tester.pump();
    engine.send('A');
    await tester.pump();
    final streaming = controller.itemIds.value.last;
    expect(controller.item(streaming).value.text, 'A');
    final before = Map.of(builds);

    for (var i = 0; i < 50; i++) {
      engine.send('b');
      await tester.pump();
    }
    expect(controller.item(streaming).value.text, 'A${'b' * 50}');
    final after = Map.of(builds);
    expect(after['assistant $streaming']! - before['assistant $streaming']!, 50);
    final others = {
      for (final key in {...before.keys, ...after.keys})
        if (key != 'assistant $streaming') key: (after[key] ?? 0) - (before[key] ?? 0),
    };
    expect(others.values.every((n) => n == 0), isTrue, reason: 'no other rebuild: $others');
    expect(others.keys, containsAll(['list', 'composer', 'user 1', 'assistant 2', 'user 3']));

    await engine.finish();
    await settleTurn(tester, controller);
    expect(find.text('A${'b' * 50}'), findsOneWidget);
  });
}
