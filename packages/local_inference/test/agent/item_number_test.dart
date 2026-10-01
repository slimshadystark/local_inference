// ToolSchema.itemNumber in a conversation: its x-item-of marker makes an item-number
// argument without a ListReferences entry, and the grammar holds the number to 1..maxShown.
import 'package:local_inference/local_inference.dart';
import 'package:local_inference/testing.dart';
import 'package:test/test.dart';

void main() {
  test('"cancel the second one": the question and the tool read the item the number named; the grammar admits '
      '1..maxShown only', () async {
    final orders = [
      {'code': 'A-17'},
      {'code': 'B-22'},
    ];
    final cancelled = <Object?>[];
    final config = AssistantConfig.basic(
      systemPrompt: 'You help the customers of a shop.',
      tools: [
        AssistantTool(
          name: 'list_orders',
          description: "Lists the customer's orders, numbered from 1.",
          run: (call, context) => ToolResult.list(collection: 'orders', items: orders),
        ),
        AssistantTool(
          name: 'cancel_order',
          description: 'Cancels one order of the last list of orders.',
          parameters: ToolSchema.object(
            {'order_number': ToolSchema.itemNumber('orders', maxShown: 5)},
            required: ['order_number'],
          ),
          sideEffect: SideEffect.irreversible,
          confirmationQuestion: (call, context) => 'Cancel order ${context.item('order_number')?['code']}?',
          run: (call, context) {
            final order = context.item('order_number');
            cancelled.add(order?['code']);
            return ToolResult.ok({'cancelled': order?['code']});
          },
        ),
      ],
    );
    expect(config.listReferences.itemArguments, isEmpty);
    final (assistant, engine) = await scriptedAssistant(
      config,
      script: [
        const ScriptedTurn.toolCall('list_orders'),
        const ScriptedTurn.text('You have two orders: A-17 and B-22.'),
        const ScriptedTurn.toolCall('cancel_order', {'order_number': 2}),
        const ScriptedTurn.text('Order B-22 is cancelled.'),
      ],
    );
    addTearDown(assistant.dispose);

    expect((await assistant.send('my orders?')).reply, 'You have two orders: A-17 and B-22.');
    final asked = await assistant.send('cancel the second one');
    expect(asked.confirmation?.question, 'Cancel order B-22?');
    expect(cancelled, isEmpty);
    final done = await assistant.confirm(true);
    expect(cancelled, ['B-22']);
    expect(done.reply, 'Order B-22 is cancelled.');

    final grammar = engine.options[2].grammar!;
    final recognizer = GbnfRecognizer(grammar.gbnf);
    String call(int n) => const QwenXmlToolFormat().render(ToolCall('cancel_order', {'order_number': n}));
    expect(
      [
        for (final n in [1, 5, 0, 6]) recognizer.accepts(call(n)),
      ],
      [true, true, false, false],
    );
    expect(engine.prompts[2], isNot(contains('x-item-of')), reason: 'the model never reads the marker');
  });
}
