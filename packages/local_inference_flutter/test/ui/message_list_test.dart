// The message list: lazy (only what is on screen is built), opens at the newest message, follows new messages only
// while at the bottom (within 48 points), keeps the text the user reads in place when scrolled up, offers
// jump-to-latest (which reaches the true end of a reply that grew below), goes to the newest message when the user
// sends or answers, and follows again after a new conversation.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_inference_flutter/local_inference_flutter.dart';

import '../support/stepped_engine.dart';
import '../support/toy_chat.dart';

void main() {
  /// Adds [count] exchanges through the host's side (no model): a user item and a reply each.
  void exchanges(AssistantController controller, int from, int count) {
    for (var i = from; i < from + count; i++) {
      controller.toolHost.recordAction(
        'question $i',
        const ToolCall('list_orders'),
        const ToolResult.ok(),
        reply: 'reply $i',
      );
    }
  }

  Future<(AssistantController, Map<int, int>)> open(
    WidgetTester tester, {
    int initial = 60,
    ChatFeatures? features,
  }) async {
    usePhoneSurface(tester);
    final (controller, _) = await toyController(tester);
    exchanges(controller, 0, initial);
    final built = <int, int>{};
    int count(MessageContext slot) => built[slot.message.id] = (built[slot.message.id] ?? 0) + 1;
    await tester.pumpWidget(
      app(
        ChatPage(
          controller: controller,
          assistantName: 'Acme',
          features: features,
          builders: ChatBuilders(
            userMessage: (context, slot) {
              count(slot);
              return slot.buildDefault();
            },
            assistantMessage: (context, slot) {
              count(slot);
              return slot.buildDefault();
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (controller, built);
  }

  ScrollPosition position(WidgetTester tester) => tester
      .state<ScrollableState>(
        find.descendant(of: find.byKey(LocalInferenceKeys.messageList), matching: find.byType(Scrollable)).first,
      )
      .position;

  /// Sends a message whose reply the test then streams delta by delta.
  Future<void> startStreaming(WidgetTester tester, SteppedEngine engine) async {
    engine.stepped = true;
    await tester.enterText(find.byKey(LocalInferenceKeys.composerField), 'tell me more');
    await tester.tap(find.byKey(LocalInferenceKeys.sendButton));
    await tester.pump();
    await pumpUntilLive(tester, engine);
  }

  /// A chat of 40 exchanges on a stepped engine, open at the bottom.
  Future<(AssistantController, SteppedEngine)> openStepped(WidgetTester tester) async {
    usePhoneSurface(tester);
    final engine = SteppedEngine();
    final (controller, _) = await toyController(tester, engine: engine);
    exchanges(controller, 0, 40);
    await tester.pumpWidget(app(ChatPage(controller: controller, assistantName: 'Acme')));
    await tester.pumpAndSettle();
    return (controller, engine);
  }

  testWidgets('lazy: only the messages near the screen are kept; the list opens at the newest', (tester) async {
    final (controller, built) = await open(tester);
    expect(controller.itemIds.value, hasLength(120));
    // Reaching the end the first time measures the messages on the way (their heights are estimates until then);
    // only those near the screen stay.
    final mounted =
        find.byType(UserMessageBubble, skipOffstage: false).evaluate().length +
        find.byType(AssistantMessage, skipOffstage: false).evaluate().length;
    expect(mounted, lessThan(40), reason: 'the others are not kept');
    built.clear();
    exchanges(controller, 60, 1);
    await tester.pumpAndSettle();
    expect(
      built.keys.toSet().intersection(controller.itemIds.value.take(100).toSet()),
      isEmpty,
      reason: 'a new message builds no old one far above',
    );
    expect(find.text('reply 59'), findsOneWidget, reason: 'opened at the bottom');
    expect(find.text('question 0'), findsNothing);
    expect(position(tester).extentAfter, 0);
  });

  testWidgets('at the bottom, new messages are followed', (tester) async {
    final (controller, _) = await open(tester);
    exchanges(controller, 60, 3);
    await tester.pumpAndSettle();
    expect(find.text('reply 62'), findsOneWidget);
    expect(position(tester).extentAfter, 0);
    expect(find.byKey(LocalInferenceKeys.jumpToLatest), findsNothing);
  });

  testWidgets('scrolled up, the text read stays in place; jump-to-latest brings the newest back', (tester) async {
    final (controller, _) = await open(tester);
    await tester.drag(find.byKey(LocalInferenceKeys.messageList), const Offset(0, 1500));
    await tester.pumpAndSettle();
    final reading = find.text('reply 45');
    expect(reading, findsOneWidget);
    final before = tester.getTopLeft(reading);

    exchanges(controller, 60, 3);
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(reading), before, reason: 'nothing moved');
    expect(find.text('reply 62'), findsNothing);
    expect(find.byKey(LocalInferenceKeys.jumpToLatest), findsOneWidget);

    await tester.tap(find.byKey(LocalInferenceKeys.jumpToLatest));
    await tester.pumpAndSettle();
    expect(find.text('reply 62'), findsOneWidget);
    expect(position(tester).extentAfter, 0);
    expect(find.byKey(LocalInferenceKeys.jumpToLatest), findsNothing);

    // Back at the bottom by hand also clears it.
    await tester.drag(find.byKey(LocalInferenceKeys.messageList), const Offset(0, 800));
    await tester.pumpAndSettle();
    exchanges(controller, 63, 1);
    await tester.pumpAndSettle();
    expect(find.byKey(LocalInferenceKeys.jumpToLatest), findsOneWidget);
    await tester.drag(find.byKey(LocalInferenceKeys.messageList), const Offset(0, -5000));
    await tester.pumpAndSettle();
    expect(find.byKey(LocalInferenceKeys.jumpToLatest), findsNothing);
  });

  testWidgets('a slow drag toward older messages is not pulled back to the bottom by new text', (tester) async {
    final (controller, _) = await open(tester);
    final gesture = await tester.startGesture(tester.getCenter(find.byKey(LocalInferenceKeys.messageList)));
    await gesture.moveBy(const Offset(0, 30));
    await tester.pump();
    await gesture.moveBy(const Offset(0, 10));
    await tester.pump();
    final pixels = position(tester).pixels;
    expect(position(tester).extentAfter, lessThan(48), reason: 'still within the threshold');
    exchanges(controller, 60, 2);
    await tester.pump();
    await tester.pump();
    expect(position(tester).pixels, pixels, reason: 'not pulled back');
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.byKey(LocalInferenceKeys.jumpToLatest), findsOneWidget);
  });

  testWidgets('within 48 points of the bottom the list still follows', (tester) async {
    final (controller, _) = await open(tester);
    final scroll = position(tester);
    scroll.jumpTo(scroll.maxScrollExtent - 30);
    await tester.pump();
    exchanges(controller, 60, 2);
    await tester.pumpAndSettle();
    expect(find.text('reply 61'), findsOneWidget);
    expect(position(tester).extentAfter, 0);
    expect(find.byKey(LocalInferenceKeys.jumpToLatest), findsNothing);

    scroll.jumpTo(scroll.maxScrollExtent - 100);
    await tester.pump();
    exchanges(controller, 62, 1);
    await tester.pumpAndSettle();
    expect(position(tester).extentAfter, greaterThan(48), reason: 'further up, not followed');
    expect(find.byKey(LocalInferenceKeys.jumpToLatest), findsOneWidget);
  });

  for (final finished in [false, true]) {
    testWidgets('jump-to-latest reaches the end of a reply that grew below the reader'
        '${finished ? ' and finished' : ', and the list follows it again'}', (tester) async {
      final (controller, engine) = await openStepped(tester);
      await startStreaming(tester, engine);
      engine.send('Start. ');
      await tester.pump();
      await tester.drag(find.byKey(LocalInferenceKeys.messageList), const Offset(0, 1200));
      await tester.pumpAndSettle();
      // The reply grows far below, where the lazy list only estimates the heights.
      for (var i = 0; i < 30; i++) {
        engine.send('word$i and more words to grow the reply line after line ');
        await tester.pump();
      }
      if (finished) {
        engine.send('THE LAST WORDS.');
        await engine.finish();
        await settleTurn(tester, controller);
      }
      await tester.tap(find.byKey(LocalInferenceKeys.jumpToLatest));
      await tester.pumpAndSettle();
      expect(position(tester).extentAfter, 0, reason: 'one tap reaches the true end');
      expect(find.byKey(LocalInferenceKeys.jumpToLatest), findsNothing);
      if (finished) {
        final reply = tester.getRect(find.byKey(LocalInferenceKeys.message(controller.itemIds.value.last)));
        final list = tester.getRect(find.byKey(LocalInferenceKeys.messageList));
        expect(reply.bottom, inInclusiveRange(list.top, list.bottom), reason: 'its last words are on screen');
        return;
      }
      engine.send('one more piece of text that is followed now ');
      await tester.pump();
      await tester.pump();
      expect(position(tester).extentAfter, 0, reason: 'followed again');
      await engine.finish();
      await settleTurn(tester, controller);
    });
  }

  testWidgets('a new conversation while scrolled up: the list follows new text again', (tester) async {
    final (controller, engine) = await openStepped(tester);
    await tester.drag(find.byKey(LocalInferenceKeys.messageList), const Offset(0, 900));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(LocalInferenceKeys.newConversation));
    await tester.pumpAndSettle();
    expect(controller.itemIds.value, isEmpty);
    expect(find.byKey(LocalInferenceKeys.jumpToLatest), findsNothing);

    await startStreaming(tester, engine);
    for (var i = 0; i < 60; i++) {
      engine.send('word$i and more words to grow the reply line after line ');
      await tester.pump();
    }
    expect(find.byKey(LocalInferenceKeys.jumpToLatest), findsNothing, reason: 'the chat fits: nothing unseen');
    expect(position(tester).extentAfter, 0, reason: 'the long reply is followed');
    await engine.finish();
    await settleTurn(tester, controller);
  });

  testWidgets('autoScroll off: new messages are not followed, the button offers them', (tester) async {
    final (controller, _) = await open(tester, features: const ChatFeatures(autoScroll: false));
    expect(position(tester).extentAfter, 0, reason: 'it still opens at the bottom');
    exchanges(controller, 60, 3);
    await tester.pumpAndSettle();
    expect(find.text('reply 62'), findsNothing);
    expect(find.byKey(LocalInferenceKeys.jumpToLatest), findsOneWidget);
  });

  testWidgets('sending, or answering a question, while reading back goes to the newest message', (tester) async {
    usePhoneSurface(tester);
    final (controller, engine) = await toyController(tester);
    exchanges(controller, 0, 40);
    await tester.pumpWidget(app(ChatPage(controller: controller, assistantName: 'Acme')));
    await tester.pumpAndSettle();
    engine.outputs.add(toolCall('list_orders'));
    await sendText(tester, controller, 'my orders');
    final list = tester.getRect(find.byKey(LocalInferenceKeys.messageList));
    void expectOnScreen(Finder finder, String reason) {
      final rect = tester.getRect(finder);
      expect(rect.top >= list.top && rect.bottom <= list.bottom, isTrue, reason: '$reason: $rect in $list');
    }

    await tester.drag(find.byKey(LocalInferenceKeys.messageList), const Offset(0, 1500));
    await tester.pumpAndSettle();
    expect(position(tester).extentAfter, greaterThan(1000), reason: 'reading back');
    engine.outputs.add(toolCall('cancel_order', {'order_number': 1}));
    await sendText(tester, controller, 'cancel the first');
    expect(position(tester).extentAfter, 0);
    expectOnScreen(find.text('cancel the first'), 'the message sent');
    expectOnScreen(find.text('Do you really want to cancel order A-17?'), 'the question above its buttons');
    expect(find.byKey(LocalInferenceKeys.jumpToLatest), findsNothing);

    await tester.drag(find.byKey(LocalInferenceKeys.messageList), const Offset(0, 1500));
    await tester.pumpAndSettle();
    expect(position(tester).extentAfter, greaterThan(1000), reason: 'reading back');
    await tester.tap(find.byKey(LocalInferenceKeys.confirmAction(ChatActionKind.confirm)));
    await tester.pump();
    await settleTurn(tester, controller);
    expect(position(tester).extentAfter, 0);
    expectOnScreen(find.text('Done: I cancelled A-17.'), 'the answer');
    expect(find.byKey(LocalInferenceKeys.jumpToLatest), findsNothing);
  });

  testWidgets('autoScroll off: sending while reading back moves nothing either', (tester) async {
    usePhoneSurface(tester);
    final (controller, engine) = await toyController(tester);
    exchanges(controller, 0, 40);
    await tester.pumpWidget(
      app(ChatPage(controller: controller, assistantName: 'Acme', features: const ChatFeatures(autoScroll: false))),
    );
    await tester.pumpAndSettle();
    await tester.drag(find.byKey(LocalInferenceKeys.messageList), const Offset(0, 1500));
    await tester.pumpAndSettle();
    final pixels = position(tester).pixels;
    engine.outputs.add('Hello!');
    await sendText(tester, controller, 'hello');
    expect(position(tester).pixels, pixels);
    expect(find.byKey(LocalInferenceKeys.jumpToLatest), findsOneWidget);
  });

  testWidgets('ChatScrollController with an infinite threshold always follows', (tester) async {
    usePhoneSurface(tester);
    final (controller, _) = await toyController(tester);
    exchanges(controller, 0, 60);
    final scroll = ChatScrollController(stickThreshold: double.infinity);
    addTearDown(scroll.dispose);
    await tester.pumpWidget(
      app(
        Scaffold(
          body: ChatView(controller: controller, scrollController: scroll),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.drag(find.byKey(LocalInferenceKeys.messageList), const Offset(0, 1500));
    await tester.pumpAndSettle();
    exchanges(controller, 60, 1);
    await tester.pumpAndSettle();
    expect(find.text('reply 60'), findsOneWidget);
    expect(scroll.position.extentAfter, 0);
  });
}
