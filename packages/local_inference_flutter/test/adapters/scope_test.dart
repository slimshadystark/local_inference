// LocalInferenceScope: the precedence of the look, texts and switches (widget > scope > theme extension and
// localizations > defaults), the lifecycle policy (a turn stopped in the background, a prefix build that failed in
// the background loaded again on return, an unload on memory pressure) and owned controllers.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_inference/testing.dart';
import 'package:local_inference_flutter/local_inference_flutter.dart';

import '../support/toy_chat.dart';

/// A scripted engine whose prefix build waits for [hold] and fails once with [failSave].
final class _HeldSave extends ScriptedEngine {
  Completer<void>? hold;
  Object? failSave;

  @override
  Future<SavedState> saveState(String path, String promptPrefix) async {
    final waiting = hold;
    if (waiting != null) await waiting.future;
    final failure = failSave;
    failSave = null;
    if (failure != null) throw StateFileException('the build stopped', cause: failure);
    return super.saveState(path, promptPrefix);
  }
}

void main() {
  group('precedence', () {
    late LocalInferenceStrings strings;
    late LocalInferenceStyle style;
    late ChatFeatures features;
    final probe = Builder(
      builder: (context) {
        strings = LocalInferenceStrings.of(context);
        style = LocalInferenceStyle.of(context);
        features = ChatFeatures.of(context);
        return const SizedBox();
      },
    );

    testWidgets('the defaults: English, the ColorScheme, the default switches', (tester) async {
      final theme = ThemeData(colorSchemeSeed: Colors.indigo);
      await tester.pumpWidget(app(probe, theme: theme));
      expect(strings, same(LocalInferenceStrings.english));
      expect(style.accent, theme.colorScheme.primary);
      expect(features, const ChatFeatures());
      expect(LocalInferenceScope.maybeOf(tester.element(find.byType(SizedBox))), isNull);
      expect(() => LocalInferenceScope.of(tester.element(find.byType(SizedBox))), throwsFlutterError);
    });

    testWidgets('the delegate gives the locale\'s pack', (tester) async {
      await tester.pumpWidget(
        Localizations(
          locale: const Locale('it'),
          delegates: const [LocalInferenceLocalizations.delegate, DefaultWidgetsLocalizations.delegate],
          child: probe,
        ),
      );
      expect(strings, same(LocalInferenceStrings.italian));
      expect(LocalInferenceLocalizations.delegate.isSupported(const Locale('de')), isFalse);
      expect(LocalInferenceStrings.forLocale(const Locale('de')), same(LocalInferenceStrings.english));
      expect(LocalInferenceStrings.forLocale(const Locale('it', 'CH')), same(LocalInferenceStrings.italian));
    });

    testWidgets('the extension, then the scope, then the widget; the override applies after the locale', (
      tester,
    ) async {
      const extension = LocalInferenceTheme(accent: Colors.green, bubbleRadius: 20);
      const scopeTheme = LocalInferenceTheme(accent: Colors.orange);
      final theme = ThemeData(extensions: const [extension]);
      await tester.pumpWidget(app(probe, theme: theme));
      expect((style.accent, style.bubbleRadius, style.userBubble), (Colors.green, 20.0, Colors.green));

      await tester.pumpWidget(
        app(
          probe,
          theme: theme,
          builder: (context, child) => LocalInferenceScope(
            theme: scopeTheme,
            features: const ChatFeatures(tooltips: false),
            stringsOverride: (resolved) =>
                resolved.copyWith(chat: resolved.chat.copyWith(composerHint: 'Ask ${resolved.a11y.send}')),
            child: child!,
          ),
        ),
      );
      expect((style.accent, style.bubbleRadius), (Colors.orange, 20.0), reason: 'the scope over the extension');
      expect(features.tooltips, isFalse);
      expect(strings.chat.composerHint, 'Ask Send');

      final context = tester.element(find.byType(SizedBox));
      expect(LocalInferenceStyle.of(context, const LocalInferenceTheme(accent: Colors.pink)).accent, Colors.pink);
      expect(LocalInferenceStyle.of(context, const LocalInferenceTheme(accent: Colors.pink)).bubbleRadius, 20);
      expect(
        LocalInferenceStrings.of(context, LocalInferenceStrings.italian),
        same(LocalInferenceStrings.italian),
        reason: 'a widget\'s own texts are taken as they are',
      );
      expect(ChatFeatures.of(context, const ChatFeatures(jumpToLatest: false)).jumpToLatest, isFalse);
    });

    testWidgets('a chat view\'s own parameters reach the widgets under it', (tester) async {
      final (controller, _) = await toyController(tester);
      await tester.pumpWidget(
        app(
          LocalInferenceScope(
            strings: LocalInferenceStrings.english,
            child: ChatView(
              controller: controller,
              strings: LocalInferenceStrings.italian,
              theme: const LocalInferenceTheme(composerRadius: 3),
            ),
          ),
        ),
      );
      expect(find.text(LocalInferenceStrings.italian.chat.composerHint), findsOneWidget);
      final field = tester.widget<TextField>(find.byKey(LocalInferenceKeys.composerField));
      expect((field.decoration!.enabledBorder! as OutlineInputBorder).borderRadius, BorderRadius.circular(3));
    });
  });

  group('lifecycle', () {
    Future<void> lifecycle(WidgetTester tester, List<AppLifecycleState> states) async {
      for (final state in states) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pump();
    }

    const leave = [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused];
    const back = [AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed];
    const cancelling = LifecyclePolicy(cancelTurnOnBackground: true);

    testWidgets('by default a turn running when the app leaves the foreground goes on', (tester) async {
      addTearDown(() => tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed));
      final (controller, engine) = await toyController(tester);
      await tester.pumpWidget(app(LocalInferenceScope(assistant: controller, child: const ChatPage())));
      engine
        ..gate = Completer<void>()
        ..outputs.add('A long answer.');
      unawaited(controller.send('hello'));
      await tester.pump();
      await lifecycle(tester, leave);
      expect(controller.composer.value.isBusy, isTrue);
      await lifecycle(tester, back);
      engine.gate!.complete();
      await pumpUntil(tester, () => !controller.composer.value.isBusy);
      expect(controller.item(controller.itemIds.value.last).value.text, 'A long answer.');
    });

    testWidgets('cancelTurnOnBackground: a turn running when the app leaves the foreground stops', (tester) async {
      addTearDown(() => tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed));
      final (controller, engine) = await toyController(tester);
      await tester.pumpWidget(
        app(LocalInferenceScope(assistant: controller, lifecycle: cancelling, child: const ChatPage())),
      );
      engine
        ..gate = Completer<void>()
        ..outputs.add('A long answer.');
      unawaited(controller.send('hello'));
      await tester.pump();
      expect(controller.composer.value.isBusy, isTrue);
      await lifecycle(tester, leave);
      await pumpUntil(tester, () => !controller.composer.value.isBusy, reason: 'stopped');
      expect(controller.item(controller.itemIds.value.last).value.text, AssistantStrings.english.interrupted);
      await lifecycle(tester, back);
    });

    testWidgets('cancelTurnOnBackground: a desktop window hidden (not paused) keeps its turn', (tester) async {
      addTearDown(() => tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed));
      final (controller, engine) = await toyController(tester);
      await tester.pumpWidget(
        app(LocalInferenceScope(assistant: controller, lifecycle: cancelling, child: const ChatPage())),
      );
      engine
        ..gate = Completer<void>()
        ..outputs.add('A long answer.');
      unawaited(controller.send('hello'));
      await tester.pump();
      await lifecycle(tester, const [AppLifecycleState.inactive, AppLifecycleState.hidden]);
      expect(controller.composer.value.isBusy, isTrue);
      await lifecycle(tester, const [AppLifecycleState.inactive, AppLifecycleState.resumed]);
      engine.gate!.complete();
      await pumpUntil(tester, () => !controller.composer.value.isBusy);
      expect(controller.item(controller.itemIds.value.last).value.text, 'A long answer.');
    });

    testWidgets('LifecyclePolicy.none lets the turn go on', (tester) async {
      addTearDown(() => tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed));
      final (controller, engine) = await toyController(tester);
      await tester.pumpWidget(
        app(LocalInferenceScope(assistant: controller, lifecycle: LifecyclePolicy.none, child: const ChatPage())),
      );
      engine
        ..gate = Completer<void>()
        ..outputs.add('A long answer.');
      unawaited(controller.send('hello'));
      await tester.pump();
      await lifecycle(tester, leave);
      expect(controller.composer.value.isBusy, isTrue);
      await lifecycle(tester, back);
      engine.gate!.complete();
      await pumpUntil(tester, () => !controller.composer.value.isBusy);
      expect(controller.item(controller.itemIds.value.last).value.text, 'A long answer.');
    });

    testWidgets('a prefix build that failed while the app was away loads again on return', (tester) async {
      addTearDown(() => tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed));
      final tmp = Directory.systemTemp.createTempSync('scope_test');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final model = File('${tmp.path}/toy.gguf')..writeAsStringSync('x');
      final engine = _HeldSave()
        ..hold = Completer<void>()
        ..failSave = 'no GPU in the background';
      final store = InMemoryPrefixStateStore();
      addTearDown(store.clear);
      final controller = AssistantController.owning(Assistant(toyConfig(), engine: () => engine, prefixStore: store));
      addTearDown(() => tester.runAsync(controller.dispose));
      await tester.pumpWidget(app(LocalInferenceScope(assistant: controller, child: const ChatPage())));
      unawaited(controller.loadModel(model.path));
      await pumpUntil(tester, () => controller.phase.value == AssistantPhase.preparing, reason: 'building');
      expect(find.text(LocalInferenceStrings.english.chat.preparingFirstTime), findsOneWidget);
      await lifecycle(tester, leave);
      final hold = engine.hold!;
      engine.hold = null;
      hold.complete();
      await pumpUntil(tester, () => controller.phase.value == AssistantPhase.failed, reason: 'the build failed');
      await lifecycle(tester, back);
      await pumpUntil(tester, () => controller.phase.value == AssistantPhase.ready, reason: 'loaded again');
      expect(controller.assistant.state.modelPath, model.path);
    });

    /// A controller whose model's prefix build waits for the engine's hold, then fails once; and the model's path.
    (AssistantController, _HeldSave, String) held(WidgetTester tester) {
      final tmp = Directory.systemTemp.createTempSync('scope_test');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final model = File('${tmp.path}/toy.gguf')..writeAsStringSync('x');
      final engine = _HeldSave()
        ..hold = Completer<void>()
        ..failSave = 'no GPU in the background';
      final store = InMemoryPrefixStateStore();
      addTearDown(store.clear);
      final controller = AssistantController.owning(Assistant(toyConfig(), engine: () => engine, prefixStore: store));
      addTearDown(() => tester.runAsync(controller.dispose));
      return (controller, engine, model.path);
    }

    /// Lets the held prefix build go on (and fail).
    void release(_HeldSave engine) {
      final hold = engine.hold!;
      engine.hold = null;
      hold.complete();
    }

    testWidgets(
      'a load that starts while the app is away (a download finished there) and fails loads again on return',
      (tester) async {
        addTearDown(() => tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed));
        final (controller, engine, model) = held(tester);
        await tester.pumpWidget(app(LocalInferenceScope(assistant: controller, child: const ChatPage())));
        await lifecycle(tester, leave);
        unawaited(controller.loadModel(model));
        await pumpUntil(tester, () => controller.phase.value == AssistantPhase.preparing, reason: 'building');
        release(engine);
        await pumpUntil(tester, () => controller.phase.value == AssistantPhase.failed, reason: 'the build failed');
        await lifecycle(tester, back);
        await pumpUntil(tester, () => controller.phase.value == AssistantPhase.ready, reason: 'loaded again');
        expect(controller.assistant.state.modelPath, model);
      },
    );

    testWidgets('a scope made while the app is in the background (a background launch) counts the app as away', (
      tester,
    ) async {
      addTearDown(() => tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed));
      final (controller, engine, model) = held(tester);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pumpWidget(app(LocalInferenceScope(assistant: controller, child: const ChatPage())));
      // The first frame of an app started in the background (runApp's warm-up frame).
      tester.binding.scheduleForcedFrame();
      await tester.pump();
      expect(find.byType(ChatPage), findsOneWidget);
      unawaited(controller.loadModel(model));
      await pumpUntil(tester, () => controller.phase.value == AssistantPhase.preparing, reason: 'building');
      release(engine);
      await pumpUntil(tester, () => controller.phase.value == AssistantPhase.failed, reason: 'the build failed');
      await lifecycle(tester, back);
      await pumpUntil(tester, () => controller.phase.value == AssistantPhase.ready, reason: 'loaded again');
    });

    testWidgets('memory pressure unloads the model when asked; it loads again on return', (tester) async {
      addTearDown(() => tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed));
      final (controller, _) = await toyController(tester);
      await tester.pumpWidget(
        app(
          LocalInferenceScope(
            assistant: controller,
            lifecycle: const LifecyclePolicy(unloadOnMemoryPressure: true),
            child: const ChatPage(),
          ),
        ),
      );
      await lifecycle(tester, leave);
      await tester.runAsync(() async => tester.binding.handleMemoryPressure());
      await pumpUntil(tester, () => controller.phase.value == AssistantPhase.noModel, reason: 'unloaded');
      await lifecycle(tester, back);
      await pumpUntil(tester, () => controller.phase.value == AssistantPhase.ready, reason: 'loaded again');
      expect(controller.assistant.state.modelPath, 'toy.gguf');
    });
  });

  testWidgets('disposeControllers: the scope disposes what it was given', (tester) async {
    final (assistant, _) = await tester.runAsync(() => scriptedAssistant(toyConfig())) as (Assistant, ScriptedEngine);
    final controller = AssistantController.owning(assistant);
    final setup = ModelSetupController(assistant: controller);
    await tester.pumpWidget(
      LocalInferenceScope(assistant: controller, setup: setup, disposeControllers: true, child: const SizedBox()),
    );
    await tester.pumpWidget(const SizedBox());
    await pumpUntil(tester, () => !assistant.newConversation(), reason: 'the owned assistant was disposed');
    expect(() => setup.addListener(() {}), throwsFlutterError, reason: 'disposed');
  });
}
