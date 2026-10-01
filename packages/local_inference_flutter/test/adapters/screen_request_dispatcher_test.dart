// ScreenRequestDispatcher: a reply's screen opens after 600 ms, waits for the end of a turn (only the latest), is
// dropped when the chat is not the visible page (or waits for it), follows a tab host's visibility, and a chip opens
// its screen only while its item is the one it named.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_inference/testing.dart';
import 'package:local_inference_flutter/local_inference_flutter.dart';

import '../support/toy_chat.dart';

void main() {
  final opened = <String>[];
  setUp(opened.clear);

  Widget chat(AssistantController controller, {ScreenRequestPolicy policy = const ScreenRequestPolicy()}) => ChatPage(
    controller: controller,
    assistantName: 'Acme',
    screenRequestPolicy: policy,
    callbacks: ChatCallbacks(
      onScreenRequest: (context, dispatch) =>
          opened.add('${dispatch.origin.name} ${(dispatch.request as OrderScreen).code}'),
    ),
  );

  Future<void> turn(WidgetTester tester, AssistantController controller, ScriptedEngine engine, String output) async {
    engine.outputs.add(output);
    await tester.enterText(find.byKey(LocalInferenceKeys.composerField), 'go');
    await tester.tap(find.byKey(LocalInferenceKeys.sendButton));
    await pumpUntil(tester, () => !controller.assistant.state.isBusy, reason: 'the turn ends');
  }

  testWidgets('during a turn the requests wait; only the latest opens, when the turn ends', (tester) async {
    usePhoneSurface(tester);
    late TestToolkit toolkit;
    final (controller, engine) = await toyController(
      tester,
      config: toyConfig(wrap: (inner) => toolkit = TestToolkit(inner)),
    );
    await tester.pumpWidget(app(chat(controller)));
    await turn(tester, controller, engine, toolCall('list_orders'));

    toolkit
      ..gatedTool = 'list_orders'
      ..gate = Completer<void>();
    engine.outputs.add(
      [
        toolCall('open_order', {'order_number': 1}),
        toolCall('open_order', {'order_number': 2}),
        toolCall('list_orders'),
      ].join('\n'),
    );
    await tester.enterText(find.byKey(LocalInferenceKeys.composerField), 'open them');
    await tester.tap(find.byKey(LocalInferenceKeys.sendButton));
    await pumpUntil(tester, () => toolkit.calls.length == 4, reason: 'the last call waits');
    await tester.pump(const Duration(seconds: 1));
    expect(controller.composer.value.isBusy, isTrue);
    expect(opened, isEmpty, reason: 'not during the turn');

    toolkit.gate!.complete();
    await pumpUntil(tester, () => opened.isNotEmpty, reason: 'opened when the turn ended');
    expect(opened, ['assistant B-22']);
  });

  testWidgets('a request is dropped when the chat is hidden at its time', (tester) async {
    usePhoneSurface(tester);
    final (controller, engine) = await toyController(tester);
    await tester.pumpWidget(app(chat(controller)));
    await turn(tester, controller, engine, toolCall('list_orders'));
    await turn(tester, controller, engine, toolCall('open_order', {'order_number': 1}));
    unawaited(
      Navigator.of(tester.element(find.byType(ChatView))).push(
        MaterialPageRoute<void>(
          builder: (_) => Scaffold(appBar: AppBar(), body: const Text('elsewhere')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1));
    expect(opened, isEmpty);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(opened, isEmpty, reason: 'dropped, not deferred');
  });

  testWidgets('with deferUntilVisible it opens when the chat is visible again', (tester) async {
    usePhoneSurface(tester);
    final (controller, engine) = await toyController(tester);
    await tester.pumpWidget(
      app(chat(controller, policy: const ScreenRequestPolicy(whenHidden: HiddenChatScreenRequest.deferUntilVisible))),
    );
    await turn(tester, controller, engine, toolCall('list_orders'));
    await turn(tester, controller, engine, toolCall('open_order', {'order_number': 1}));
    unawaited(
      Navigator.of(tester.element(find.byType(ChatView))).push(
        MaterialPageRoute<void>(
          builder: (_) => Scaffold(appBar: AppBar(), body: const Text('elsewhere')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1));
    expect(opened, isEmpty);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(opened, ['assistant A-17']);
  });

  testWidgets('a deferred request whose handler pushes a page opens after the frame, not during the build', (
    tester,
  ) async {
    usePhoneSurface(tester);
    final (controller, engine) = await toyController(tester);
    await tester.pumpWidget(
      app(
        ChatPage(
          controller: controller,
          assistantName: 'Acme',
          screenRequestPolicy: const ScreenRequestPolicy(whenHidden: HiddenChatScreenRequest.deferUntilVisible),
          callbacks: ChatCallbacks(
            onScreenRequest: (context, dispatch) => Navigator.of(
              context,
            ).push(MaterialPageRoute<void>(builder: (_) => Text('order ${(dispatch.request as OrderScreen).code}'))),
          ),
        ),
      ),
    );
    await turn(tester, controller, engine, toolCall('list_orders'));
    await turn(tester, controller, engine, toolCall('open_order', {'order_number': 1}));
    unawaited(
      Navigator.of(tester.element(find.byType(ChatView))).push(
        MaterialPageRoute<void>(
          builder: (_) => Scaffold(appBar: AppBar(), body: const Text('elsewhere')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1));
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('order A-17'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final stable in [false, true]) {
    testWidgets('a tab host: a request deferred while the chat\'s tab is hidden opens when it is selected again'
        '${stable ? ' (one policy)' : ' (a policy made in each build)'}', (tester) async {
      usePhoneSurface(tester);
      final (controller, engine) = await toyController(tester);
      final host = GlobalKey<_TabHostState>();
      await tester.pumpWidget(app(_TabHost(key: host, controller: controller, opened: opened, stable: stable)));
      await turn(tester, controller, engine, toolCall('list_orders'));
      await turn(tester, controller, engine, toolCall('open_order', {'order_number': 1}));
      // The user switches tab before the 600 ms pass.
      host.currentState!.select(1);
      await tester.pump(const Duration(seconds: 1));
      expect(opened, isEmpty, reason: 'hidden: it waits');
      host.currentState!.select(0);
      await tester.pump();
      await tester.pump();
      expect(opened, ['assistant A-17']);
    });
  }

  testWidgets('a tab host says whether the chat is visible', (tester) async {
    usePhoneSurface(tester);
    final (controller, engine) = await toyController(tester);
    var visible = false;
    await tester.pumpWidget(app(chat(controller, policy: ScreenRequestPolicy(isVisible: (_) => visible))));
    await turn(tester, controller, engine, toolCall('list_orders'));
    await turn(tester, controller, engine, toolCall('open_order', {'order_number': 1}));
    await tester.pump(const Duration(seconds: 1));
    expect(opened, isEmpty);
    visible = true;
    await turn(tester, controller, engine, toolCall('open_order', {'order_number': 2}));
    await tester.pump(const Duration(seconds: 1));
    expect(opened, ['assistant B-22']);
  });

  testWidgets('openFromChip: nothing during a turn; the stale handler when the item changed; else it opens', (
    tester,
  ) async {
    usePhoneSurface(tester);
    final (controller, engine) = await toyController(tester);
    await tester.pumpWidget(app(const SizedBox()));
    final context = tester.element(find.byType(SizedBox));
    final stale = <String>[];
    final dispatcher = ScreenRequestDispatcher(
      controller: controller,
      onScreenRequest: (context, dispatch) => opened.add('${dispatch.origin.name} ${dispatch.request.label}'),
      onStale: (context, dispatch) => stale.add(dispatch.request.label),
    );
    addTearDown(dispatcher.dispose);
    engine.outputs.addAll([
      toolCall('list_orders'),
      toolCall('open_order', {'order_number': 1}),
    ]);
    await tester.runAsync(() => controller.send('orders'));
    await tester.runAsync(() => controller.send('open the first'));
    final reply = controller.item(controller.itemIds.value.last).value;
    expect(dispatcher.openFromChip(context, reply), isTrue);
    expect(opened.last, 'chip Open order A-17');

    await tester.runAsync(() => controller.assistant.runTool(const ToolCall('cancel_order', {'order_number': 1})));
    engine.outputs.add(toolCall('list_orders'));
    await tester.runAsync(() => controller.send('orders'));
    expect(dispatcher.openFromChip(context, reply), isFalse);
    expect(stale, ['Open order A-17']);

    engine
      ..gate = Completer<void>()
      ..outputs.add('Later.');
    unawaited(controller.send('wait'));
    expect(controller.composer.value.isBusy, isTrue);
    final chip = controller.item(reply.id).value;
    expect(dispatcher.openFromChip(context, chip), isFalse, reason: 'not during a turn');
    engine.gate!.complete();
    await pumpUntil(tester, () => !controller.composer.value.isBusy);
    dispatcher.dispose();
  });
}

/// A host with the chat in the first of two tabs, which [select] switches with setState.
class _TabHost extends StatefulWidget {
  const _TabHost({super.key, required this.controller, required this.opened, required this.stable});

  final AssistantController controller;
  final List<String> opened;

  /// One policy object for every build, else a new one in each.
  final bool stable;

  @override
  State<_TabHost> createState() => _TabHostState();
}

class _TabHostState extends State<_TabHost> {
  int _tab = 0;

  late final ScreenRequestPolicy _policy = ScreenRequestPolicy(
    whenHidden: HiddenChatScreenRequest.deferUntilVisible,
    isVisible: (_) => _tab == 0,
  );

  void select(int tab) => setState(() => _tab = tab);

  @override
  Widget build(BuildContext context) => Scaffold(
    body: IndexedStack(
      index: _tab,
      children: [
        ChatView(
          controller: widget.controller,
          screenRequestPolicy: widget.stable
              ? _policy
              : ScreenRequestPolicy(whenHidden: HiddenChatScreenRequest.deferUntilVisible, isVisible: (_) => _tab == 0),
          callbacks: ChatCallbacks(
            onScreenRequest: (context, dispatch) =>
                widget.opened.add('${dispatch.origin.name} ${(dispatch.request as OrderScreen).code}'),
          ),
        ),
        const Center(child: Text('the other tab')),
      ],
    ),
  );
}
