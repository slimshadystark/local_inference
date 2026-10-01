// The chat on a scripted engine with a toy toolkit, in English and in Italian: welcome, suggestions, bubbles, the
// question's buttons, the phases' panels, the screens the replies open and their chips.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_inference/testing.dart';
import 'package:local_inference_flutter/local_inference_flutter.dart';

import '../support/toy_chat.dart';

void main() {
  for (final italian in [false, true]) {
    final strings = italian ? LocalInferenceStrings.italian : LocalInferenceStrings.english;
    final language = italian ? 'Italian' : 'English';
    final suggestion = italian ? 'Quali ordini ho?' : 'Which orders do I have?';
    final welcome = italian ? 'Ciao! Sono Acme. Come posso aiutarti?' : 'Hello! I am Acme. How can I help?';

    testWidgets('$language: suggestions, bubbles, a question and its buttons on a phone-sized screen', (tester) async {
      usePhoneSurface(tester);
      final (controller, engine) = await toyController(tester, italian: italian);
      await tester.pumpWidget(
        app(
          ChatPage(
            controller: controller,
            assistantName: 'Acme',
            welcome: welcome,
            suggestions: [suggestion],
            strings: strings,
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Acme'), findsOneWidget, reason: 'the title');
      expect(find.text(welcome), findsOneWidget);
      expect(find.byKey(LocalInferenceKeys.suggestion(0)), findsOneWidget);
      expect(find.text(strings.chat.composerHint), findsOneWidget);
      expect(find.text(strings.chat.disclosure), findsOneWidget, reason: 'the banner is on by default');

      engine.outputs.addAll([
        toolCall('list_orders'),
        toolCall('cancel_order', {'order_number': 1}),
      ]);
      await tester.tap(find.text(suggestion));
      await tester.pump();
      await settleTurn(tester, controller);
      expect(find.textContaining(italian ? 'Hai 3 ordini' : 'You have 3 orders'), findsOneWidget);
      expect(find.text(suggestion), findsOneWidget, reason: 'now a user bubble');
      expect(find.byKey(LocalInferenceKeys.suggestion(0)), findsNothing, reason: 'the chips are gone');

      await sendText(tester, controller, italian ? 'annulla il primo' : 'cancel the first');
      expect(find.text('Do you really want to cancel order A-17?'), findsOneWidget);
      final yes = find.byKey(LocalInferenceKeys.confirmAction(ChatActionKind.confirm));
      expect(find.descendant(of: yes, matching: find.text(italian ? 'Sì' : 'Yes')), findsOneWidget);
      expect(find.byKey(LocalInferenceKeys.confirmAction(ChatActionKind.decline)), findsOneWidget);
      await tester.tap(yes);
      await tester.pump();
      await settleTurn(tester, controller);
      expect(find.text(italian ? 'Fatto: ho annullato A-17.' : 'Done: I cancelled A-17.'), findsOneWidget);
      expect(yes, findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('$language: the panel without a model', (tester) async {
      usePhoneSurface(tester);
      final (controller, _) = await toyController(tester, italian: italian, load: false);
      await tester.pumpWidget(app(ChatPage(controller: controller, assistantName: 'Acme', strings: strings)));
      expect(find.text(strings.chat.noModelTitle), findsOneWidget);
      expect(find.text(strings.chat.noModelSubtitle), findsNothing, reason: 'nothing here can look for models');
      expect(find.text(strings.chat.refresh), findsNothing, reason: 'no setup to look for models');
    });

    testWidgets('$language: a refused model: the error panel, without the raw exception; Retry loads it again', (
      tester,
    ) async {
      usePhoneSurface(tester);
      final tmp = Directory.systemTemp.createTempSync('chat_view_test');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final model = File('${tmp.path}/toy.gguf')..writeAsStringSync('x');
      final engine = ScriptedEngine(chatTemplate: '', supportsStatePersistence: false);
      final (controller, _) = await toyController(tester, italian: italian, engine: engine, load: false);
      final setup = ModelSetupController(
        assistant: controller,
        candidates: (_) => [ModelCandidate(path: model.path)],
      );
      addTearDown(setup.dispose);
      final phases = <AssistantPhase>[];
      controller.phase.addListener(() => phases.add(controller.phase.value));
      await tester.pumpWidget(
        app(ChatPage(controller: controller, setup: setup, assistantName: 'Acme', strings: strings)),
      );
      await pumpUntil(tester, () => controller.phase.value == AssistantPhase.failed, reason: 'loaded at start');
      expect(phases, [AssistantPhase.loading, AssistantPhase.failed]);
      final error = controller.assistant.state.loadError!;
      expect(error, isA<UnsupportedModelException>());
      expect(find.text(strings.chat.loadFailedTitle), findsOneWidget);
      expect(find.text(strings.chat.loadFailed(error)), findsOneWidget);
      expect(find.textContaining('tokenizer.chat_template'), findsNothing);

      await tester.tap(find.byKey(LocalInferenceKeys.retryLoad));
      await pumpUntil(tester, () => phases.length == 4, reason: 'loaded again');
      expect(phases, [AssistantPhase.loading, AssistantPhase.failed, AssistantPhase.loading, AssistantPhase.failed]);
      expect(tester.takeException(), isNull);

      // With the technical details on, the raw error shows under the panel.
      await tester.pumpWidget(
        app(
          ChatPage(
            controller: controller,
            setup: setup,
            assistantName: 'Acme',
            strings: strings,
            features: const ChatFeatures(showDetails: true),
          ),
        ),
      );
      expect(find.text('$error'), findsOneWidget);
    });
  }

  testWidgets('the preparing panel shows while a model loads; the first-time note while its state is built', (
    tester,
  ) async {
    usePhoneSurface(tester);
    final (controller, _) = await toyController(tester, load: false);
    final phases = <AssistantPhase>[];
    controller.phase.addListener(() => phases.add(controller.phase.value));
    await tester.pumpWidget(app(ChatPage(controller: controller, assistantName: 'Acme')));
    const strings = LocalInferenceStrings.english;
    final loading = tester.runAsync(
      () => controller.loadModel('toy.gguf', identity: const ModelIdentity.fixed('toy.gguf')),
    );
    await tester.pump();
    expect(find.text(strings.chat.preparingTitle), findsOneWidget);
    await loading;
    await tester.pump();
    expect(phases, contains(AssistantPhase.loading));
    expect(find.text(strings.chat.composerHint), findsOneWidget, reason: 'ready: the conversation');
  });

  group('screens', () {
    Future<(AssistantController, ScriptedEngine, List<String>)> open(WidgetTester tester) async {
      usePhoneSurface(tester);
      final (controller, engine) = await toyController(tester);
      final opened = <String>[];
      await tester.pumpWidget(
        app(
          ChatPage(
            controller: controller,
            assistantName: 'Acme',
            callbacks: ChatCallbacks(
              onScreenRequest: (context, dispatch) {
                final screen = dispatch.request as OrderScreen;
                opened.add('${dispatch.origin.name} ${screen.code}');
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => Scaffold(appBar: AppBar(), body: Text('Order ${screen.code}')),
                  ),
                );
              },
            ),
          ),
        ),
      );
      return (controller, engine, opened);
    }

    Future<void> say(WidgetTester tester, AssistantController controller, ScriptedEngine engine, String output) async {
      engine.outputs.add(output);
      await sendText(tester, controller, 'go');
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pumpAndSettle();
    }

    testWidgets('a screen a reply asks for opens 600 ms later; its chip opens it again', (tester) async {
      final (controller, engine, opened) = await open(tester);
      await say(tester, controller, engine, toolCall('list_orders'));
      engine.outputs.add(toolCall('open_order', {'order_number': 1}));
      await tester.enterText(find.byKey(LocalInferenceKeys.composerField), 'open the first');
      await tester.tap(find.byKey(LocalInferenceKeys.sendButton));
      // Real waits only: the screen's 600 ms run on the test's clock.
      await pumpUntil(tester, () => !controller.assistant.state.isBusy, reason: 'the turn ends');
      await tester.pump(const Duration(milliseconds: 500));
      expect(opened, isEmpty, reason: 'not before 600 ms');
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();
      expect(opened, ['assistant A-17']);
      expect(find.text('Order A-17'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(LocalInferenceKeys.screenChip(controller.itemIds.value.last)));
      await tester.pumpAndSettle();
      expect(opened, ['assistant A-17', 'chip A-17']);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a chip whose list item changed shows the stale note instead', (tester) async {
      final (controller, engine, opened) = await open(tester);
      await say(tester, controller, engine, toolCall('list_orders'));
      await say(tester, controller, engine, toolCall('open_order', {'order_number': 1}));
      await tester.pageBack();
      await tester.pumpAndSettle();
      final chip = controller.itemIds.value.last;
      // The first order goes: number 1 now names another order.
      await tester.runAsync(() => controller.assistant.runTool(const ToolCall('cancel_order', {'order_number': 1})));
      await say(tester, controller, engine, toolCall('list_orders'));
      await tester.ensureVisible(find.byKey(LocalInferenceKeys.screenChip(chip)));
      await tester.tap(find.byKey(LocalInferenceKeys.screenChip(chip)));
      await tester.pump();
      expect(opened, ['assistant A-17']);
      expect(find.text(LocalInferenceStrings.english.chat.staleScreenRequest), findsOneWidget);
    });

    testWidgets('while a turn runs the chips wait', (tester) async {
      final (controller, engine, _) = await open(tester);
      await say(tester, controller, engine, toolCall('list_orders'));
      await say(tester, controller, engine, toolCall('open_order', {'order_number': 1}));
      await tester.pageBack();
      await tester.pumpAndSettle();
      final chip = find.byKey(LocalInferenceKeys.screenChip(controller.itemIds.value.last));
      engine.gate = Completer<void>();
      engine.outputs.add('Here you go.');
      await tester.enterText(find.byKey(LocalInferenceKeys.composerField), 'thanks');
      await tester.tap(find.byKey(LocalInferenceKeys.sendButton));
      await tester.pump();
      expect(controller.composer.value.isBusy, isTrue);
      expect(tester.widget<ActionChip>(find.descendant(of: chip, matching: find.byType(ActionChip))).onPressed, isNull);
      expect(find.byKey(LocalInferenceKeys.stopButton), findsOneWidget, reason: 'send became stop');
      engine.gate!.complete();
      await settleTurn(tester, controller);
      expect(
        tester.widget<ActionChip>(find.descendant(of: chip, matching: find.byType(ActionChip))).onPressed,
        isNotNull,
      );
    });

    testWidgets('without onScreenRequest no chip shows and nothing opens', (tester) async {
      usePhoneSurface(tester);
      final (controller, engine) = await toyController(tester);
      await tester.pumpWidget(app(ChatPage(controller: controller, assistantName: 'Acme')));
      engine.outputs.addAll([
        toolCall('list_orders'),
        toolCall('open_order', {'order_number': 1}),
      ]);
      await sendText(tester, controller, 'orders');
      await sendText(tester, controller, 'open the first');
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(ScreenRequestChip), findsNothing);
      expect(find.text('Here is A-17.'), findsOneWidget);
    });
  });

  testWidgets('a reply still thinking shows no screen chip yet', (tester) async {
    usePhoneSurface(tester);
    const request = BoundScreenRequest(OrderScreen('A-17', 1));
    Future<void> show({required bool thinking}) => tester.pumpWidget(
      app(
        Scaffold(
          body: AssistantMessage(
            message: ChatItem(
              id: 7,
              role: MessageRole.assistant,
              text: 'Here is A-17.',
              thinking: thinking,
              source: ReplySource.model,
              screenRequest: request,
            ),
            onOpenScreen: () {},
          ),
        ),
      ),
    );
    await show(thinking: true);
    expect(find.byType(ScreenRequestChip), findsNothing);
    await show(thinking: false);
    expect(find.byType(ScreenRequestChip), findsOneWidget);
  });

  testWidgets('the suggestions wait until a message can be sent', (tester) async {
    usePhoneSurface(tester);
    final (controller, _) = await toyController(tester, load: false);
    await tester.pumpWidget(
      app(
        Scaffold(
          body: ChatActionBar(
            controller: controller,
            suggestions: const ['Which orders do I have?'],
            onSuggestion: (_) {},
          ),
        ),
      ),
    );
    expect(controller.composer.value.canSend, isFalse);
    expect(find.byKey(LocalInferenceKeys.suggestion(0)), findsNothing, reason: 'no model yet');
    await tester.runAsync(() => controller.loadModel('toy.gguf', identity: const ModelIdentity.fixed('toy.gguf')));
    await tester.pump();
    expect(find.byKey(LocalInferenceKeys.suggestion(0)), findsOneWidget);
  });

  testWidgets('stop during a turn ends it; beforeSend can keep a message unsent', (tester) async {
    usePhoneSurface(tester);
    final (controller, engine) = await toyController(tester);
    final checked = <String>[];
    await tester.pumpWidget(
      app(
        ChatPage(
          controller: controller,
          assistantName: 'Acme',
          callbacks: ChatCallbacks(
            beforeSend: (text) {
              checked.add(text);
              return text != 'secret';
            },
          ),
        ),
      ),
    );
    await tester.enterText(find.byKey(LocalInferenceKeys.composerField), 'secret');
    await tester.tap(find.byKey(LocalInferenceKeys.sendButton));
    await tester.pump();
    expect(controller.itemIds.value, isEmpty);
    expect(controller.draft.text, 'secret', reason: 'kept in the composer');

    engine.gate = Completer<void>();
    engine.outputs.add('A long answer.');
    await tester.enterText(find.byKey(LocalInferenceKeys.composerField), 'hello');
    await tester.tap(find.byKey(LocalInferenceKeys.sendButton));
    await tester.pump();
    expect(controller.draft.text, isEmpty);
    await tester.tap(find.byKey(LocalInferenceKeys.stopButton));
    await settleTurn(tester, controller);
    expect(find.text(AssistantStrings.english.interrupted), findsOneWidget);
    expect(checked, ['secret', 'hello']);
  });

  testWidgets('the new-conversation button clears the chat and is off during a turn', (tester) async {
    usePhoneSurface(tester);
    final (controller, engine) = await toyController(tester);
    await tester.pumpWidget(app(ChatPage(controller: controller, assistantName: 'Acme')));
    engine.outputs.add('Hi there.');
    await sendText(tester, controller, 'hi');
    expect(find.text('Hi there.'), findsOneWidget);
    engine.gate = Completer<void>();
    engine.outputs.add('Later.');
    await tester.enterText(find.byKey(LocalInferenceKeys.composerField), 'again');
    await tester.tap(find.byKey(LocalInferenceKeys.sendButton));
    await tester.pump();
    expect(tester.widget<IconButton>(find.byKey(LocalInferenceKeys.newConversation)).onPressed, isNull);
    engine.gate!.complete();
    await settleTurn(tester, controller);
    await tester.tap(find.byKey(LocalInferenceKeys.newConversation));
    await tester.pumpAndSettle();
    expect(controller.itemIds.value, isEmpty);
    expect(find.text('Hi there.'), findsNothing);
  });
}
