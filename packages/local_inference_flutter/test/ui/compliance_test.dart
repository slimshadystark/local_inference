// Compliance: the AI disclosure (banner, dismissible, in the welcome, none), the report of a reply (from the
// selection menu or a button: the reason, the comment and the ReportRequest JSON), and the AI-generated marking of
// model-written text (a semantics hint, an optional badge, a notice on copied text).
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_inference/testing.dart';
import 'package:local_inference_flutter/local_inference_flutter.dart';

import '../support/toy_chat.dart';

void main() {
  const en = LocalInferenceStrings.english;

  group('disclosure', () {
    testWidgets('banner (the default) above the messages, before the first message', (tester) async {
      usePhoneSurface(tester);
      final (controller, _) = await toyController(tester);
      await tester.pumpWidget(app(ChatPage(controller: controller, assistantName: 'Acme')));
      expect(find.byKey(LocalInferenceKeys.disclosureBanner), findsOneWidget);
      expect(find.text(en.chat.disclosure), findsOneWidget);
      expect(find.byKey(LocalInferenceKeys.disclosureDismiss), findsNothing);
      expect(
        tester.getTopLeft(find.byKey(LocalInferenceKeys.disclosureBanner)).dy,
        lessThan(tester.getTopLeft(find.byKey(LocalInferenceKeys.messageList)).dy),
      );
    });

    testWidgets('dismissible: closed for the session (the chat opened again too); the host is told', (tester) async {
      usePhoneSurface(tester);
      final (controller, _) = await toyController(tester);
      var told = 0;
      Widget page() => ChatPage(
        controller: controller,
        assistantName: 'Acme',
        features: const ChatFeatures(aiDisclosure: AiDisclosureMode.dismissible),
        callbacks: ChatCallbacks(onDisclosureDismissed: () => told++),
      );
      await tester.pumpWidget(app(page()));
      await tester.tap(find.byKey(LocalInferenceKeys.disclosureDismiss));
      await tester.pump();
      expect(find.byKey(LocalInferenceKeys.disclosureBanner), findsNothing);
      expect(told, 1);
      await tester.pumpWidget(app(const SizedBox()));
      await tester.pumpWidget(app(page()));
      expect(find.byKey(LocalInferenceKeys.disclosureBanner), findsNothing);
    });

    testWidgets('inWelcome: a paragraph under the welcome; none: nothing', (tester) async {
      usePhoneSurface(tester);
      final (controller, _) = await toyController(tester);
      await tester.pumpWidget(
        app(
          ChatPage(
            controller: controller,
            assistantName: 'Acme',
            welcome: 'Hello!',
            features: const ChatFeatures(aiDisclosure: AiDisclosureMode.inWelcome),
          ),
        ),
      );
      expect(find.byKey(LocalInferenceKeys.disclosureBanner), findsNothing);
      expect(
        find.descendant(of: find.byKey(LocalInferenceKeys.welcome), matching: find.text(en.chat.disclosure)),
        findsOneWidget,
      );

      // Without a welcome text the row holds the disclosure alone.
      await tester.pumpWidget(
        app(
          ChatPage(
            controller: controller,
            assistantName: 'Acme',
            features: const ChatFeatures(aiDisclosure: AiDisclosureMode.inWelcome),
          ),
        ),
      );
      expect(
        find.descendant(of: find.byKey(LocalInferenceKeys.welcome), matching: find.byType(MessageText)),
        findsNothing,
      );
      expect(find.text(en.chat.disclosure), findsOneWidget);

      await tester.pumpWidget(
        app(
          ChatPage(
            controller: controller,
            assistantName: 'Acme',
            welcome: 'Hello!',
            features: const ChatFeatures(aiDisclosure: AiDisclosureMode.none),
          ),
        ),
      );
      expect(find.text(en.chat.disclosure), findsNothing);
    });

    testWidgets('inWelcome with a welcome builder that draws its own row: the disclosure still follows it', (
      tester,
    ) async {
      usePhoneSurface(tester);
      final (controller, _) = await toyController(tester);
      await tester.pumpWidget(
        app(
          ChatPage(
            controller: controller,
            assistantName: 'Acme',
            welcome: 'Hello',
            features: const ChatFeatures(aiDisclosure: AiDisclosureMode.inWelcome),
            builders: ChatBuilders(welcome: (context, slot) => Text('Custom: ${slot.text}')),
          ),
        ),
      );
      expect(find.text('Custom: Hello'), findsOneWidget);
      expect(find.text(en.chat.disclosure), findsOneWidget);
      expect(
        tester.getTopLeft(find.text(en.chat.disclosure)).dy,
        greaterThan(tester.getTopLeft(find.text('Custom: Hello')).dy),
      );
    });
  });

  group('report', () {
    Future<(AssistantController, ScriptedEngine, List<ReportRequest>)> open(
      WidgetTester tester, {
      ReportAffordance affordance = ReportAffordance.menu,
    }) async {
      usePhoneSurface(tester);
      final (controller, engine) = await toyController(tester);
      final reports = <ReportRequest>[];
      await tester.pumpWidget(
        app(
          ChatPage(
            controller: controller,
            assistantName: 'Acme',
            features: ChatFeatures(reportAffordance: affordance),
            callbacks: ChatCallbacks(onReport: reports.add),
          ),
        ),
      );
      return (controller, engine, reports);
    }

    Future<void> answer(WidgetTester tester, ReportReason reason, {String comment = ''}) async {
      await tester.pumpAndSettle();
      expect(find.byKey(LocalInferenceKeys.reportSheet), findsOneWidget);
      expect(find.text(en.chat.reportTitle), findsOneWidget);
      expect(tester.widget<FilledButton>(find.byKey(LocalInferenceKeys.reportSend)).onPressed, isNull);
      await tester.tap(find.byKey(LocalInferenceKeys.reportReason(reason)));
      await tester.pump();
      if (comment.isNotEmpty) await tester.enterText(find.byKey(LocalInferenceKeys.reportComment), comment);
      await tester.tap(find.byKey(LocalInferenceKeys.reportSend));
      await tester.pumpAndSettle();
    }

    testWidgets('from the selection menu: the report carries the reply, its turn and the model', (tester) async {
      final (controller, engine, reports) = await open(tester);
      engine.outputs.add('The shop opens at 9.');
      await sendText(tester, controller, 'When do you open?');
      await tester.longPress(find.text('The shop opens at 9.'));
      await tester.pumpAndSettle();
      expect(find.text(en.chat.report), findsOneWidget, reason: 'in the selection menu');
      await tester.tap(find.text(en.chat.report));
      await answer(tester, ReportReason.wrong, comment: '  It opens at 10.  ');
      expect(find.text(en.chat.reportThanks), findsOneWidget);

      final report = reports.single;
      final json = report.toJson();
      expect(json['reason'], 'wrong');
      expect(json['comment'], 'It opens at 10.');
      expect(json['message'], {'id': 2, 'text': 'The shop opens at 9.', 'source': 'model'});
      expect(json['userText'], 'When do you open?');
      expect(json['conversationId'], controller.assistant.state.conversationId);
      expect(json['modelFile'], 'toy.gguf');
      expect(json['templateSha256'], sha256.convert(utf8.encode(qwen35ChatTemplate)).toString());
      expect(json['runtime'], ScriptedEngine.runtime.id);
      expect(DateTime.parse(json['time']! as String).isUtc, isTrue);
      expect(jsonDecode(jsonEncode(json)), json, reason: 'plain JSON');
    });

    testWidgets('from a flag button under the reply; an error reply cannot be reported', (tester) async {
      final (controller, engine, reports) = await open(tester, affordance: ReportAffordance.icon);
      engine.outputs.add(toolCall('list_orders'));
      await sendText(tester, controller, 'orders');
      final reply = controller.itemIds.value.last;
      await tester.tap(find.byKey(LocalInferenceKeys.reportAction(reply)));
      await answer(tester, ReportReason.other);
      expect(reports.single.message.source, ReplySource.app);
      expect(reports.single.comment, isNull);

      // The thanks SnackBar goes, then the composer can be tapped again.
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      engine.throwAfterDeltas = (0, StateError('boom'));
      engine.outputs.add('never');
      await sendText(tester, controller, 'again');
      final failed = controller.item(controller.itemIds.value.last).value;
      expect(failed.source, ReplySource.error);
      expect(find.byKey(LocalInferenceKeys.reportAction(failed.id)), findsNothing);
    });

    testWidgets('text that cannot be selected has no menu: its report entry becomes the flag button', (tester) async {
      usePhoneSurface(tester);
      final (controller, engine) = await toyController(tester);
      final reports = <ReportRequest>[];
      await tester.pumpWidget(
        app(
          ChatPage(
            controller: controller,
            assistantName: 'Acme',
            features: const ChatFeatures(selectableText: false),
            callbacks: ChatCallbacks(onReport: reports.add),
          ),
        ),
      );
      engine.outputs.add('A reply.');
      await sendText(tester, controller, 'hi');
      await tester.tap(find.byKey(LocalInferenceKeys.reportAction(controller.itemIds.value.last)));
      await answer(tester, ReportReason.harmful);
      expect(reports.single.reason, ReportReason.harmful);
    });

    testWidgets('the sheet speaks the chat\'s language, also in an app of another one', (tester) async {
      usePhoneSurface(tester);
      final (controller, engine) = await toyController(tester, italian: true);
      await tester.pumpWidget(
        app(
          ChatPage(
            controller: controller,
            assistantName: 'Ada',
            strings: LocalInferenceStrings.italian,
            features: const ChatFeatures(reportAffordance: ReportAffordance.icon),
            callbacks: ChatCallbacks(onReport: (_) {}),
          ),
        ),
      );
      engine.outputs.add('Una risposta.');
      await sendText(tester, controller, 'ciao');
      await tester.tap(find.byKey(LocalInferenceKeys.reportAction(controller.itemIds.value.last)));
      await tester.pumpAndSettle();
      expect(find.text('Segnala questa risposta'), findsOneWidget);
      expect(find.text('Sbagliata o inventata'), findsOneWidget);
    });

    testWidgets('a report the host fails to take: no thanks, and the error is reported', (tester) async {
      usePhoneSurface(tester);
      final (controller, engine) = await toyController(tester);
      await tester.pumpWidget(
        app(
          ChatPage(
            controller: controller,
            assistantName: 'Acme',
            features: const ChatFeatures(reportAffordance: ReportAffordance.icon),
            callbacks: ChatCallbacks(onReport: (_) => throw StateError('disk full')),
          ),
        ),
      );
      engine.outputs.add('A reply.');
      await sendText(tester, controller, 'hi');
      await tester.tap(find.byKey(LocalInferenceKeys.reportAction(controller.itemIds.value.last)));
      await answer(tester, ReportReason.wrong);
      expect(find.text(en.chat.reportThanks), findsNothing);
      expect(tester.takeException(), isA<StateError>());
    });

    testWidgets('without onReport nothing can be reported', (tester) async {
      usePhoneSurface(tester);
      final (controller, engine) = await toyController(tester);
      await tester.pumpWidget(
        app(
          ChatPage(
            controller: controller,
            assistantName: 'Acme',
            features: const ChatFeatures(reportAffordance: ReportAffordance.both),
          ),
        ),
      );
      engine.outputs.add('Hello.');
      await sendText(tester, controller, 'hi');
      expect(find.byKey(LocalInferenceKeys.reportAction(controller.itemIds.value.last)), findsNothing);
      await tester.longPress(find.text('Hello.'));
      await tester.pumpAndSettle();
      expect(find.text(en.chat.report), findsNothing);
    });
  });

  group('provenance', () {
    testWidgets('model-written text carries the AI-generated hint; app-written text does not', (tester) async {
      usePhoneSurface(tester);
      final semantics = tester.ensureSemantics();
      final (controller, engine) = await toyController(tester);
      await tester.pumpWidget(app(ChatPage(controller: controller, assistantName: 'Acme')));
      engine.outputs.addAll(['Written by the model.', toolCall('list_orders')]);
      await sendText(tester, controller, 'hi');
      await sendText(tester, controller, 'orders');
      final hinted = find.semantics.byHint(en.a11y.aiGeneratedHint).evaluate().toList();
      expect(hinted, hasLength(1), reason: 'the model-written reply only, not the app-written list');
      final node = hinted.single.getSemanticsData();
      expect('${node.label}${node.value}${node.attributedValue.string}', contains('Written by the model.'));
      semantics.dispose();
    });

    testWidgets('a text builder that draws its own text keeps the hint through the slot', (tester) async {
      usePhoneSurface(tester);
      final semantics = tester.ensureSemantics();
      final (controller, engine) = await toyController(tester);
      await tester.pumpWidget(
        app(
          ChatPage(
            controller: controller,
            assistantName: 'Acme',
            builders: ChatBuilders(
              messageText: (context, slot) =>
                  Semantics(container: true, hint: slot.provenanceHint, child: Text(slot.message.text.toUpperCase())),
            ),
          ),
        ),
      );
      engine.outputs.addAll(['Written by the model.', toolCall('list_orders')]);
      await sendText(tester, controller, 'hi');
      await sendText(tester, controller, 'orders');
      expect(find.text('WRITTEN BY THE MODEL.'), findsOneWidget);
      expect(find.semantics.byHint(en.a11y.aiGeneratedHint).evaluate(), hasLength(1));
      semantics.dispose();
    });

    testWidgets('the badge marks model-written replies; copied text gets the notice', (tester) async {
      usePhoneSurface(tester);
      final clipboard = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') clipboard.add((call.arguments as Map)['text'] as String);
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      final copied = <String>[];
      final (controller, engine) = await toyController(tester);
      await tester.pumpWidget(
        app(
          ChatPage(
            controller: controller,
            assistantName: 'Acme',
            features: const ChatFeatures(provenance: ProvenanceMarking(badge: true, copyNotice: '(AI-generated)')),
            callbacks: ChatCallbacks(onCopy: copied.add),
          ),
        ),
      );
      engine.outputs.addAll(['Model words.', toolCall('list_orders')]);
      await sendText(tester, controller, 'hi');
      await sendText(tester, controller, 'orders');
      expect(find.text(en.chat.aiGeneratedBadge), findsOneWidget, reason: 'the model-written reply only');

      await tester.longPress(find.text('Model words.'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Select all'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Copy'));
      await tester.pumpAndSettle();
      expect(clipboard.last, 'Model words.\n\n(AI-generated)');
      expect(copied, ['Model words.']);
    });
  });
}
