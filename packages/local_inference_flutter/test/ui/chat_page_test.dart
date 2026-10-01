// ChatPage and ChatView on long-lived controllers: the chat survives its page being closed and opened again (items,
// draft), the default look (bubble widths from the list's width, radii), builders wrap the defaults,
// the title's hidden long press, the details, the keyboard's send key and Enter on a desktop.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_inference_flutter/local_inference_flutter.dart';

import '../support/toy_chat.dart';

void main() {
  testWidgets('closed and opened again, the chat keeps its messages and the draft', (tester) async {
    usePhoneSurface(tester);
    final (controller, engine) = await toyController(tester);
    Widget home() => Builder(
      builder: (context) => Scaffold(
        body: TextButton(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => ChatPage(controller: controller, assistantName: 'Acme'),
            ),
          ),
          child: const Text('open chat'),
        ),
      ),
    );
    await tester.pumpWidget(app(LocalInferenceScope(assistant: controller, child: home())));
    await tester.tap(find.text('open chat'));
    await tester.pumpAndSettle();
    engine.outputs.add('Hi there.');
    await sendText(tester, controller, 'hello');
    await tester.enterText(find.byKey(LocalInferenceKeys.composerField), 'half a thought');
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(ChatView), findsNothing);

    await tester.tap(find.text('open chat'));
    await tester.pumpAndSettle();
    expect(find.text('Hi there.'), findsOneWidget);
    expect(find.text('half a thought'), findsOneWidget, reason: 'the draft survived');
    expect(controller.draft.text, 'half a thought');
  });

  testWidgets('the default look: bubble widths from the list, the radii, the reply without a bubble', (tester) async {
    usePhoneSurface(tester);
    final (controller, engine) = await toyController(tester);
    await tester.pumpWidget(app(ChatPage(controller: controller, assistantName: 'Acme')));
    engine.outputs.add('A reply long enough to use the whole width it may take, and then some more words after it.');
    await sendText(
      tester,
      controller,
      'A question long enough to wrap onto a second line of the bubble for sure, surely.',
    );
    final width = tester.getSize(find.byType(ChatMessageList)).width;
    final user = tester.widget<Container>(find.byKey(LocalInferenceKeys.message(1)));
    expect(user.constraints!.maxWidth, moreOrLessEquals(width * 0.78));
    expect((user.decoration! as BoxDecoration).borderRadius, BorderRadius.circular(14));
    expect(tester.getSize(find.byKey(LocalInferenceKeys.message(1))).width, moreOrLessEquals(width * 0.78));
    final reply = find.byKey(LocalInferenceKeys.message(2));
    expect(tester.getSize(reply).width, moreOrLessEquals(width * 0.9));
    expect(tester.widget<Container>(reply).decoration, isNull);
    final field = tester.widget<TextField>(find.byKey(LocalInferenceKeys.composerField));
    expect((field.decoration!.enabledBorder! as OutlineInputBorder).borderRadius, BorderRadius.circular(24));
  });

  testWidgets('builders wrap the defaults; the title\'s long press; the details when asked', (tester) async {
    usePhoneSurface(tester);
    final (controller, engine) = await toyController(tester);
    var pressed = 0;
    await tester.pumpWidget(
      app(
        ChatPage(
          controller: controller,
          assistantName: 'Acme',
          onTitleLongPress: () => pressed++,
          features: const ChatFeatures(showDetails: true),
          builders: ChatBuilders(
            header: (context, slot) => const Text('header'),
            assistantMessage: (context, slot) => Row(
              children: [
                const Icon(Icons.smart_toy),
                Expanded(child: slot.buildDefault()),
              ],
            ),
            composer: (context, slot) => Row(
              children: [
                Expanded(child: slot.buildDefault()),
                TextButton(onPressed: () => slot.send('from the builder'), child: const Text('quick')),
              ],
            ),
          ),
        ),
      ),
    );
    expect(find.text('header'), findsOneWidget);
    await tester.longPress(find.byKey(LocalInferenceKeys.titleArea));
    expect(pressed, 1);
    engine.outputs.add('Hi.');
    await tester.tap(find.text('quick'));
    await settleTurn(tester, controller);
    expect(find.text('from the builder'), findsOneWidget);
    expect(find.byIcon(Icons.smart_toy), findsOneWidget);
    expect(find.byType(MessageDetails), findsOneWidget);
    expect(find.textContaining('restore 0ms'), findsOneWidget, reason: 'the timing line of the details');
  });

  testWidgets('the keyboard\'s send key sends on a phone; Enter sends on a desktop, Shift+Enter does not', (
    tester,
  ) async {
    usePhoneSurface(tester);
    final (controller, engine) = await toyController(tester);
    await tester.pumpWidget(app(ChatPage(controller: controller, assistantName: 'Acme')));
    engine.outputs.addAll(['One.', 'Two.']);
    await tester.enterText(find.byKey(LocalInferenceKeys.composerField), 'first');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await settleTurn(tester, controller);
    expect(find.text('One.'), findsOneWidget);

    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await tester.pumpWidget(app(ChatPage(controller: controller, assistantName: 'Acme')));
    await tester.enterText(find.byKey(LocalInferenceKeys.composerField), 'second');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(controller.assistant.state.items, hasLength(2), reason: 'Shift+Enter did not send');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await settleTurn(tester, controller);
    expect(find.text('Two.'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });
}
