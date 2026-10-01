// Accessibility: tap targets of 48 (Android) and 44 (iOS) points with labels, text contrast in light and dark, text
// scaled to 2.0 without overflow, live regions for "Thinking…" and the tool status (emoji not read), the reply read
// aloud when a screen reader is on, tooltips (and labels without them), the download bar's label and value.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_inference/testing.dart';
import 'package:local_inference_flutter/local_inference_flutter.dart';

import '../support/toy_chat.dart';

void main() {
  const en = LocalInferenceStrings.english;

  Future<(AssistantController, ScriptedEngine)> chat(
    WidgetTester tester, {
    ThemeData? theme,
    ChatFeatures? features,
    double scale = 1,
  }) async {
    usePhoneSurface(tester);
    final (controller, engine) = await toyController(tester);
    await tester.pumpWidget(
      app(
        MediaQuery.withClampedTextScaling(
          minScaleFactor: scale,
          maxScaleFactor: scale,
          child: ChatPage(
            controller: controller,
            assistantName: 'Acme',
            welcome: 'Hello! I can look up your orders.',
            suggestions: const ['Which orders do I have?', 'Cancel an order'],
            features: features,
          ),
        ),
        theme: theme,
      ),
    );
    await tester.pump();
    return (controller, engine);
  }

  Future<void> guidelines(WidgetTester tester, {bool contrast = true}) async {
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(iOSTapTargetGuideline));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    if (contrast) await expectLater(tester, meetsGuideline(textContrastGuideline));
  }

  for (final brightness in Brightness.values) {
    testWidgets('${brightness.name}: the chat meets the tap-target, label and contrast guidelines', (tester) async {
      final handle = tester.ensureSemantics();
      final theme = ThemeData(colorSchemeSeed: Colors.indigo, brightness: brightness);
      final (controller, engine) = await chat(tester, theme: theme);
      await guidelines(tester);

      engine.outputs.addAll([
        toolCall('list_orders'),
        toolCall('cancel_order', {'order_number': 1}),
      ]);
      await sendText(tester, controller, 'orders');
      await sendText(tester, controller, 'cancel the first');
      expect(find.byKey(LocalInferenceKeys.confirmAction(ChatActionKind.confirm)), findsOneWidget);
      await guidelines(tester);
      handle.dispose();
    });
  }

  testWidgets('the setup views meet the tap-target and label guidelines', (tester) async {
    final handle = tester.ensureSemantics();
    usePhoneSurface(tester);
    final entry = ModelManifest.parse(testManifestJson()).models.first;
    await tester.pumpWidget(
      app(
        Scaffold(
          body: ModelConsentView(entry: entry, assistantName: 'Acme', onDownload: () {}, onChooseOther: () {}),
        ),
      ),
    );
    await guidelines(tester);
    await tester.pumpWidget(
      app(
        Scaffold(
          body: ModelProgressView(
            entry: entry,
            status: const ModelStatus(state: ModelState.downloading, progress: 0.42, bytesDone: 400, bytesTotal: 960),
            onPause: () {},
            onCancel: () {},
          ),
        ),
      ),
    );
    await guidelines(tester);
    final bar = find.semantics.byLabel(en.setup.progressSemanticsLabel).evaluate().single;
    expect(bar.getSemanticsData().value, '42%');
    handle.dispose();
  });

  testWidgets('text scaled to 2.0: the chat, its panels and the setup views do not overflow', (tester) async {
    final (controller, engine) = await chat(tester, scale: 2);
    expect(tester.takeException(), isNull);
    engine.outputs.addAll([
      toolCall('list_orders'),
      toolCall('cancel_order', {'order_number': 1}),
    ]);
    await sendText(tester, controller, 'orders');
    await sendText(tester, controller, 'cancel the first');
    expect(tester.takeException(), isNull);

    Future<void> scaled(Widget child) async {
      await tester.pumpWidget(
        app(MediaQuery.withClampedTextScaling(minScaleFactor: 2, maxScaleFactor: 2, child: Scaffold(body: child))),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
    }

    await scaled(
      ChatStatusPanel(
        icon: Icons.error_outline,
        title: en.chat.loadFailedTitle,
        subtitle: en.chat.loadFailed(StateError('x')),
        isError: true,
        action: FilledButton(onPressed: () {}, child: Text(en.chat.retry)),
      ),
    );
    await scaled(
      ChatStatusPanel(
        icon: Icons.memory,
        title: en.chat.preparingTitle,
        subtitle: en.chat.preparingFirstTime,
        progress: true,
      ),
    );
    final entry = ModelManifest.parse(testManifestJson()).models.first;
    await scaled(
      ModelConsentView(entry: entry, assistantName: 'Acme', onDownload: () {}, notice: 'x', onChooseOther: () {}),
    );
    await scaled(
      ModelProgressView(
        entry: entry,
        status: const ModelStatus(state: ModelState.waitingForWifi, progress: 0.1),
        onCancel: () {},
        onUseCellular: () {},
      ),
    );
  });

  for (final (name, size, dismissible) in [
    ('360 x 640', const Size(360, 640), false),
    ('320 x 568, dismissible banner', const Size(320, 568), true),
  ]) {
    testWidgets('text scaled to 2.0 on a $name phone: nothing overflows, the messages keep their share', (
      tester,
    ) async {
      usePhoneSurface(tester, size: size * 3);
      final (controller, _) = await toyController(tester, italian: true);
      await tester.pumpWidget(
        app(
          MediaQuery.withClampedTextScaling(
            minScaleFactor: 2,
            maxScaleFactor: 2,
            child: ChatPage(
              controller: controller,
              assistantName: 'Ada',
              strings: LocalInferenceStrings.italian,
              welcome: 'Ciao! Sono Ada.',
              features: ChatFeatures(
                aiDisclosure: dismissible ? AiDisclosureMode.dismissible : AiDisclosureMode.banner,
              ),
              suggestions: const [
                'Quali appuntamenti ho?',
                'Vorrei prenotare un appuntamento',
                'Ho avvisi PagoPA da pagare?',
                'Che eventi ci sono questo weekend?',
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      final body = tester.getRect(find.byType(ChatView));
      final list = tester.getRect(find.byKey(LocalInferenceKeys.messageList));
      expect(list.height, greaterThanOrEqualTo(body.height * 0.3 - 1), reason: 'the messages keep their share');
      expect(tester.getRect(find.byKey(LocalInferenceKeys.sendButton)).bottom, lessThanOrEqualTo(body.bottom));
      expect(find.byKey(LocalInferenceKeys.disclosureBanner), findsOneWidget);
      expect(find.byKey(LocalInferenceKeys.suggestion(3)), findsOneWidget, reason: 'in the scrolling bar');

      // A long draft (five lines) still leaves the messages their share.
      await tester.enterText(find.byKey(LocalInferenceKeys.composerField), 'uno\ndue\ntre\nquattro\ncinque');
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(
        tester.getRect(find.byKey(LocalInferenceKeys.messageList)).height,
        greaterThanOrEqualTo(body.height * 0.3 - 1),
      );
    });
  }

  testWidgets('"Thinking…" and the tool status are live regions; emoji are not read', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      app(
        const Scaffold(
          body: Column(
            children: [
              ThinkingIndicator(),
              ToolStatusIndicator(label: '📦 Looking up your orders...'),
            ],
          ),
        ),
      ),
    );
    final thinking = tester.getSemantics(find.byType(ThinkingIndicator));
    expect(thinking.getSemanticsData().label, en.a11y.thinking);
    expect(thinking.getSemanticsData().flagsCollection.isLiveRegion, isTrue);
    final status = tester.getSemantics(find.byType(ToolStatusIndicator));
    expect(status.getSemanticsData().label, 'Looking up your orders...');
    expect(status.getSemanticsData().flagsCollection.isLiveRegion, isTrue);
    handle.dispose();
  });

  testWidgets('a finished reply is read aloud when a screen reader is on, not otherwise', (tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(
      accessibleNavigation: true,
    );
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    final (controller, engine) = await chat(tester);
    engine.outputs.add('Your orders are 🚚 on the way.');
    await sendText(tester, controller, 'where are my orders?');
    expect(tester.takeAnnouncements().map((a) => a.message), contains('Acme: Your orders are on the way.'));

    tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures();
    await tester.pump();
    engine.outputs.add('Nothing else.');
    await sendText(tester, controller, 'thanks');
    expect(tester.takeAnnouncements(), isEmpty);
  });

  group('announceReplies follows the precedence', () {
    Future<List<String>> said(WidgetTester tester, Widget Function(AssistantController controller) page) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(
        accessibleNavigation: true,
      );
      addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
      usePhoneSurface(tester);
      final (controller, engine) = await toyController(tester);
      await tester.pumpWidget(app(page(controller)));
      engine.outputs.add('Your orders are on the way.');
      await sendText(tester, controller, 'where are my orders?');
      return [for (final announcement in tester.takeAnnouncements()) announcement.message];
    }

    testWidgets("ChatPage's switch off: nothing is read", (tester) async {
      final messages = await said(
        tester,
        (controller) => ChatPage(
          controller: controller,
          assistantName: 'Acme',
          features: const ChatFeatures(announceReplies: false),
        ),
      );
      expect(messages, isEmpty);
    });

    testWidgets("the scope's switch off, ChatPage's on: the page's wins", (tester) async {
      final messages = await said(
        tester,
        (controller) => LocalInferenceScope(
          features: const ChatFeatures(announceReplies: false),
          child: ChatPage(controller: controller, assistantName: 'Acme', features: const ChatFeatures()),
        ),
      );
      expect(messages, ['Acme: Your orders are on the way.']);
    });

    testWidgets("the scope's switch off: nothing is read", (tester) async {
      final messages = await said(
        tester,
        (controller) => LocalInferenceScope(
          features: const ChatFeatures(announceReplies: false),
          child: ChatPage(controller: controller, assistantName: 'Acme'),
        ),
      );
      expect(messages, isEmpty);
    });
  });

  testWidgets('tooltips on the icon buttons; without them the labels stay', (tester) async {
    final handle = tester.ensureSemantics();
    final (controller, engine) = await chat(tester);
    expect(find.byTooltip(en.a11y.send), findsOneWidget);
    expect(find.byTooltip(en.a11y.newConversation), findsOneWidget);
    engine
      ..gate = Completer<void>()
      ..outputs.add('Later.');
    await tester.enterText(find.byKey(LocalInferenceKeys.composerField), 'hi');
    await tester.tap(find.byKey(LocalInferenceKeys.sendButton));
    await tester.pump();
    expect(find.byTooltip(en.a11y.stop), findsOneWidget);
    engine.gate!.complete();
    await settleTurn(tester, controller);

    await tester.pumpWidget(
      app(
        ChatPage(
          controller: controller,
          assistantName: 'Acme',
          features: const ChatFeatures(
            tooltips: false,
            aiDisclosure: AiDisclosureMode.dismissible,
            reportAffordance: ReportAffordance.icon,
          ),
          callbacks: ChatCallbacks(onReport: (_) {}),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(Tooltip), findsNothing);
    // Each label is on the node that can be tapped, not on a node of its own or on the message.
    for (final label in [en.a11y.send, en.a11y.newConversation, en.a11y.dismiss, en.a11y.reportAction]) {
      final node = find.semantics.byLabel(label).evaluate().single.getSemanticsData();
      expect(node.flagsCollection.isButton, isTrue, reason: label);
      expect(node.hasAction(SemanticsAction.tap), isTrue, reason: label);
    }
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    handle.dispose();
  });

  testWidgets("a screen chip's hint is on the chip itself", (tester) async {
    final handle = tester.ensureSemantics();
    usePhoneSurface(tester);
    final (controller, engine) = await toyController(tester);
    await tester.pumpWidget(
      app(
        ChatPage(
          controller: controller,
          assistantName: 'Acme',
          callbacks: ChatCallbacks(onScreenRequest: (context, dispatch) {}),
        ),
      ),
    );
    engine.outputs.addAll([
      toolCall('list_orders'),
      toolCall('open_order', {'order_number': 1}),
    ]);
    await sendText(tester, controller, 'orders');
    await sendText(tester, controller, 'open the first');
    await tester.pump(const Duration(seconds: 1));
    final chip = find.semantics.byHint(en.a11y.screenChipHint).evaluate().single.getSemanticsData();
    expect(chip.label, 'Open order A-17');
    expect(chip.flagsCollection.isButton, isTrue);
    expect(chip.hasAction(SemanticsAction.tap), isTrue);
    handle.dispose();
  });

  testWidgets('messages are labelled with who wrote them', (tester) async {
    final handle = tester.ensureSemantics();
    final (controller, engine) = await chat(tester);
    engine.outputs.add('Hi.');
    await sendText(tester, controller, 'hello');
    expect(find.bySemanticsLabel(RegExp('^${en.a11y.userMessage}')), findsWidgets);
    expect(find.bySemanticsLabel(RegExp('^Acme')), findsWidgets);
    handle.dispose();
  });
}
