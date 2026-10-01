// A toy shop assistant for the UI tests: a numbered list (orders), an irreversible call that asks first
// (cancel_order), a call that opens a screen (open_order), app-written English or Italian replies, on a scripted
// engine. Helpers to drive a chat on a phone-sized surface.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_inference/testing.dart';
import 'package:local_inference_flutter/local_inference_flutter.dart';

/// The page of one order, as a host would open it.
final class OrderScreen extends ScreenRequest {
  const OrderScreen(this.code, this.number);

  final String code;
  final int number;

  @override
  String get label => 'Open order $code';

  @override
  ItemRef get itemRef => ItemRef('orders', number);
}

/// The shop's orders; [reset] brings them back.
final class ToyShop {
  ToyShop() {
    reset();
  }

  late List<Map<String, Object?>> orders;

  void reset() => orders = [
    {'code': 'A-17', 'item': 'headphones'},
    {'code': 'B-22', 'item': 'kettle'},
    {'code': 'C-31', 'item': 'lamp'},
  ];
}

List<AssistantTool> _tools(ToyShop shop) => [
  AssistantTool(
    name: 'list_orders',
    description: "Lists the customer's orders, numbered from 1.",
    statusLabel: '📦 Looking up your orders...',
    run: (call, context) => ToolResult.list(
      collection: 'orders',
      items: [
        for (final order in shop.orders) {...order},
      ],
    ),
  ),
  AssistantTool(
    name: 'cancel_order',
    description: 'Cancels one order of the last list of orders.',
    parameters: ToolSchema.object(
      {'order_number': ToolSchema.integer(minimum: 1, maximum: 8)},
      required: ['order_number'],
    ),
    sideEffect: SideEffect.irreversible,
    confirmationQuestion: (call, context) =>
        'Do you really want to cancel order ${context.item('order_number')?['code']}?',
    run: (call, context) {
      final order = context.item('order_number');
      if (order == null) return const ToolResult.error('stale_list', 'no such order');
      shop.orders.removeWhere((o) => o['code'] == order['code']);
      return ToolResult.ok({'cancelled': order['code']});
    },
  ),
  AssistantTool(
    name: 'open_order',
    description: 'Opens the page of one order of the last list of orders.',
    parameters: ToolSchema.object(
      {'order_number': ToolSchema.integer(minimum: 1, maximum: 8)},
      required: ['order_number'],
    ),
    sideEffect: SideEffect.recoverable,
    run: (call, context) {
      final order = context.item('order_number');
      if (order == null) return const ToolResult.error('stale_list', 'no such order');
      return ToolResult.ok({'opened': order['code'], 'n': order['n']});
    },
  ),
];

/// The app's replies, in English or Italian.
final class ToyWriter implements ReplyWriter {
  const ToyWriter({this.italian = false});

  final bool italian;

  @override
  ToolReply write(ToolOutcome outcome) {
    final result = outcome.result;
    if (result is ToolFailure) return ToolReply(text: italian ? 'Non ha funzionato.' : 'That did not work.');
    final payload = result.payload;
    switch (outcome.call.name) {
      case 'list_orders':
        final items = [for (final item in payload['items']! as List) (item as Map).cast<String, Object?>()];
        return ToolReply.numbered(
          header: italian ? 'Hai ${items.length} ordini' : 'You have ${items.length} orders',
          items: [for (final o in items) '${o['code']}, ${o['item']}'],
        );
      case 'cancel_order':
        return ToolReply(
          text: italian ? 'Fatto: ho annullato ${payload['cancelled']}.' : 'Done: I cancelled ${payload['cancelled']}.',
        );
      case 'open_order':
        return ToolReply(text: italian ? 'Ecco ${payload['opened']}.' : 'Here is ${payload['opened']}.');
    }
    return const ToolReply(text: 'Done.');
  }
}

/// The toy toolkit on [shop]; a new conversation resets the shop.
final class ToyToolkit extends DelegatingToolkit {
  ToyToolkit(this.shop) : super(Toolkit.of(_tools(shop)));

  final ToyShop shop;

  @override
  void reset() => shop.reset();
}

/// The toy assistant's behavior, English or Italian.
AssistantConfig toyConfig({bool italian = false, ToyShop? shop, Toolkit Function(Toolkit toolkit)? wrap}) =>
    AssistantConfig(
      toolkit: (wrap ?? (toolkit) => toolkit)(ToyToolkit(shop ?? ToyShop())),
      prompt: const PromptLayout(systemPrompt: 'You are the Acme shop assistant.'),
      replies: AppWrittenReplies(ToyWriter(italian: italian)),
      listReferences: const ListReferences(itemArguments: {'order_number': ItemSource.collection('orders')}),
      screenRequests: (outcome) => outcome.call.name == 'open_order' && outcome.result.ok
          ? OrderScreen(outcome.result.payload['opened']! as String, outcome.result.payload['n']! as int)
          : null,
      strings: italian ? AssistantStrings.italian : AssistantStrings.english,
      sampling: const SamplingOptions(maxTokens: 256),
    );

/// The raw output of a call as the model writes it.
String toolCall(String name, [Map<String, Object?> arguments = const {}]) =>
    const QwenXmlToolFormat().render(ToolCall(name, arguments));

/// A controller over the toy assistant on a scripted engine, its model loaded; disposed at the end of the test.
Future<(AssistantController, ScriptedEngine)> toyController(
  WidgetTester tester, {
  bool italian = false,
  ScriptedEngine? engine,
  bool load = true,
  AssistantConfig? config,
}) async {
  final scripted = engine ?? ScriptedEngine(supportsStatePersistence: false);
  final assistant = Assistant(
    config ?? toyConfig(italian: italian),
    engine: () => scripted,
    prefixStore: InMemoryPrefixStateStore(),
  );
  if (load) {
    await tester.runAsync(() => assistant.loadModel('toy.gguf', identity: const ModelIdentity.fixed('toy.gguf')));
  }
  final controller = AssistantController.owning(assistant);
  addTearDown(() => tester.runAsync(controller.dispose));
  return (controller, scripted);
}

/// An iPhone-sized surface (1290 x 2796 at 3x), reset at the end of the test.
void usePhoneSurface(WidgetTester tester, {Size size = const Size(1290, 2796), double pixelRatio = 3}) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = pixelRatio;
  addTearDown(tester.view.reset);
}

/// Lets the assistant and real I/O started from callbacks go on: short real waits and frames, until [done].
Future<void> pumpUntil(WidgetTester tester, bool Function() done, {String reason = '', int maxSteps = 300}) async {
  for (var i = 0; i < maxSteps && !done(); i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    await tester.pump();
  }
  expect(done(), isTrue, reason: reason);
  await tester.pump();
}

/// Types [text] in the composer and taps send; returns once the turn ended and the frames settled.
Future<void> sendText(WidgetTester tester, AssistantController controller, String text) async {
  await tester.enterText(find.byKey(LocalInferenceKeys.composerField), text);
  await tester.tap(find.byKey(LocalInferenceKeys.sendButton));
  await tester.pump();
  await settleTurn(tester, controller);
}

/// Waits until no turn runs, then pumps the frames that follow.
Future<void> settleTurn(WidgetTester tester, AssistantController controller) async {
  await pumpUntil(tester, () => !controller.assistant.state.isBusy, reason: 'the turn ends');
  await tester.pumpAndSettle();
}

/// [child] in an English MaterialApp with the UI kit's delegate (the Italian texts come from a scope or a widget's
/// `strings:`, as an Italian app passes them: the SDK's material texts here are English only).
Widget app(Widget child, {ThemeData? theme, ThemeData? darkTheme, ThemeMode? themeMode, TransitionBuilder? builder}) =>
    MaterialApp(
      theme: theme,
      darkTheme: darkTheme,
      themeMode: themeMode,
      builder: builder,
      localizationsDelegates: const [
        LocalInferenceLocalizations.delegate,
        DefaultMaterialLocalizations.delegate,
        DefaultWidgetsLocalizations.delegate,
      ],
      home: child,
    );
