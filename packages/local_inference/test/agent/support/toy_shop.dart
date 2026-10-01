// A toy shop for the assistant's tests, in English: every mechanism a real tool set uses. Numbered lists (orders,
// stores, slots), irreversible calls on a list item (cancel_order, book_slot) that refuse a number the user was not
// shown and ask for the list again (a follow-up), an offer (one store found: "see its slots?"), an annotation read as
// the call starts (the store of a slot list), a screen request (open_order), a tool that throws, and a backend whose
// state a new conversation resets.
import 'dart:io';

import 'package:local_inference/local_inference.dart';
import 'package:local_inference/testing.dart';

import '../../support/fixtures.dart';

/// The shop's data; [reset] brings the first state back.
final class ToyShop {
  ToyShop() {
    reset();
  }

  late List<Map<String, Object?>> orders;
  late List<Map<String, Object?>> stores;
  late Map<String, List<String>> slots;
  final List<String> booked = [];

  void reset() {
    orders = [
      {'code': 'A-17', 'item': 'headphones', 'status': 'open'},
      {'code': 'B-22', 'item': 'kettle', 'status': 'open'},
      {'code': 'C-31', 'item': 'lamp', 'status': 'shipped'},
    ];
    stores = [
      {'name': 'Downtown', 'city': 'Springfield'},
      {'name': 'Harbour', 'city': 'Shelbyville'},
      {'name': 'Acme Outlet', 'city': 'Capital City'},
    ];
    slots = {
      'Downtown': ['Mon 7 Sep 09:00', 'Mon 7 Sep 09:30', 'Tue 8 Sep 10:00'],
      'Harbour': ['Tue 8 Sep 10:00', 'Wed 9 Sep 11:00'],
    };
    booked.clear();
  }
}

/// A screen of one order.
final class OrderScreen extends ScreenRequest {
  const OrderScreen(this.code, this.number);

  final String code;
  final int number;

  @override
  String get label => 'Open order $code';

  @override
  ItemRef get itemRef => ItemRef('orders', number);
}

/// Encodes [OrderScreen]s.
final class OrderScreenCodec implements ScreenRequestCodec {
  const OrderScreenCodec();

  @override
  Map<String, Object?> encode(ScreenRequest request) => switch (request) {
    OrderScreen(:final code, :final number) => {'screen': 'order', 'code': code, 'number': number},
    _ => {'screen': 'unknown'},
  };

  @override
  ScreenRequest? decode(Map<String, Object?> json) =>
      json['screen'] == 'order' ? OrderScreen(json['code']! as String, json['number']! as int) : null;
}

const Map<String, Object?> _relistOrders = {'tool': 'list_orders', 'args': <String, Object?>{}};

/// The shop's tools on [shop].
List<AssistantTool> toyTools(ToyShop shop) => [
  AssistantTool(
    name: 'list_orders',
    description: "Lists the customer's orders, numbered from 1.",
    parameters: ToolSchema.object({
      'status': ToolSchema.string(enumValues: ['open', 'shipped', 'all']),
    }),
    statusLabel: '📦 Looking up your orders...',
    run: (call, context) {
      final status = call.string('status') ?? 'all';
      return ToolResult.list(
        collection: 'orders',
        items: [
          for (final order in shop.orders)
            if (status == 'all' || order['status'] == status) {...order},
        ],
      );
    },
  ),
  AssistantTool(
    name: 'cancel_order',
    description: 'Cancels one order of the last list of orders.',
    parameters: ToolSchema.object(
      {'order_number': ToolSchema.integer(minimum: 1, maximum: 8)},
      required: ['order_number'],
    ),
    sideEffect: SideEffect.irreversible,
    statusLabel: '📦 Cancelling the order...',
    confirmationQuestion: (call, context) =>
        'Do you really want to cancel order ${context.item('order_number')?['code']}? It cannot be undone.',
    run: (call, context) {
      final order = context.item('order_number');
      if (order == null) {
        return const ToolResult.error(
          'stale_list',
          'no such order in the last list',
          details: {'relist': _relistOrders},
        );
      }
      final found = shop.orders.where((o) => o['code'] == order['code']).firstOrNull;
      if (found == null || found['status'] != 'open') {
        return ToolResult.error('not_cancellable', 'order ${order['code']} cannot be cancelled');
      }
      shop.orders.remove(found);
      return ToolResult.ok({'cancelled': found['code']});
    },
  ),
  AssistantTool(
    name: 'find_store',
    description: 'Finds the stores whose name matches the query, numbered from 1.',
    parameters: ToolSchema.object({'query': ToolSchema.string()}),
    run: (call, context) {
      final query = (call.string('query') ?? '').toLowerCase();
      return ToolResult.list(
        collection: 'stores',
        items: [
          for (final store in shop.stores)
            if ((store['name']! as String).toLowerCase().contains(query)) {...store},
        ],
      );
    },
  ),
  AssistantTool(
    name: 'list_slots',
    description: 'Lists the free slots of one store of the last list of stores, numbered from 1.',
    parameters: ToolSchema.object(
      {'store_number': ToolSchema.integer(minimum: 1, maximum: 8)},
      required: ['store_number'],
    ),
    statusLabel: '🗓 Looking up the slots...',
    run: (call, context) {
      final store = context.item('store_number');
      if (store == null) {
        return const ToolResult.error(
          'stale_list',
          'no such store in the last list',
          details: {
            'relist': {'tool': 'find_store', 'args': <String, Object?>{}},
          },
        );
      }
      return ToolResult.list(
        collection: 'slots',
        items: [
          for (final slot in shop.slots[store['name']] ?? const <String>[]) {'when': slot},
        ],
      );
    },
  ),
  AssistantTool(
    name: 'book_slot',
    description: 'Books one slot of the last list of slots.',
    parameters: ToolSchema.object(
      {'slot_number': ToolSchema.integer(minimum: 1, maximum: 8)},
      required: ['slot_number'],
    ),
    sideEffect: SideEffect.irreversible,
    confirmationQuestion: (call, context) =>
        'Shall I book ${context.item('slot_number')?['when']} at ${context.lists['slots']?.annotations['store']}?',
    run: (call, context) {
      final slot = context.item('slot_number');
      if (slot == null) {
        return const ToolResult.error(
          'stale_list',
          'no such slot in the last list',
          details: {
            'relist': {'tool': 'find_store', 'args': <String, Object?>{}},
          },
        );
      }
      final store = context.lists['slots']?.annotations['store'];
      shop.booked.add('${slot['when']} at $store');
      return ToolResult.ok({'booked': slot['when'], 'store': store});
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
      if (order == null) {
        return const ToolResult.error(
          'stale_list',
          'no such order in the last list',
          details: {'relist': _relistOrders},
        );
      }
      return ToolResult.ok({'opened': order['code'], 'n': order['n']});
    },
  ),
  AssistantTool(
    name: 'item_detail',
    description: 'The details of one item of a list already shown.',
    parameters: ToolSchema.object(
      {
        'collection': ToolSchema.string(enumValues: ['orders', 'stores']),
        'item_number': ToolSchema.integer(minimum: 1, maximum: 8),
      },
      required: ['collection', 'item_number'],
    ),
    run: (call, context) {
      final item = context.item('item_number');
      return item == null
          ? const ToolResult.error('stale_list', 'no such item', details: {'relist': _relistOrders})
          : ToolResult.ok({...item});
    },
  ),
  AssistantTool(
    name: 'broken',
    description: 'Always throws.',
    run: (call, context) => throw StateError('backend down'),
  ),
];

/// The toy tools' list references: item numbers of orders, stores and slots, the item of any collection, and the
/// store of a slot list (read when list_slots starts).
final ListReferences toyReferences = ListReferences(
  itemArguments: const {
    'order_number': ItemSource.collection('orders'),
    'store_number': ItemSource.collection('stores'),
    'slot_number': ItemSource.collection('slots'),
    'item_number': ItemSource.argument('collection'),
  },
  annotate: toyAnnotate,
);

/// `{'store': name}` for list_slots when its number names a shown store; `{}` otherwise.
Map<String, Object?> toyAnnotate(ToolCall call, ShownLists lists) {
  if (call.name != 'list_slots') return const {};
  final name = lists.item('stores', call.arguments['store_number'])?['name'];
  return name == null ? const {} : {'store': name};
}

/// The app's English replies to the toy tools.
final class ToyWriter implements ReplyWriter {
  const ToyWriter();

  @override
  ToolReply write(ToolOutcome outcome) {
    final result = outcome.result;
    final call = outcome.call;
    if (result is ToolFailure) {
      final relist = result.details['relist'];
      if (result.code == 'stale_list' && relist is Map) {
        return ToolReply(
          text: 'I no longer have that list: here it is again.',
          followUp: ToolCall.fromJson(relist.cast<String, Object?>()),
        );
      }
      return ToolReply(text: 'That did not work: ${result.message}.');
    }
    final payload = result.payload;
    final items = [for (final item in (payload['items'] as List?) ?? const []) (item as Map).cast<String, Object?>()];
    switch (call.name) {
      case 'list_orders':
        if (items.isEmpty) return const ToolReply(text: 'You have no orders.');
        return ToolReply.numbered(
          header: 'You have ${items.length} orders',
          items: [for (final o in items) '${o['code']}, ${o['item']}, ${o['status']}'],
        );
      case 'cancel_order':
        return ToolReply(text: 'Done: I cancelled order ${payload['cancelled']}.');
      case 'find_store':
        if (items.isEmpty) return const ToolReply(text: 'No store matches.');
        if (items.length == 1) {
          return ToolReply.numbered(
            header: 'I found one store',
            items: ['${items.single['name']}, ${items.single['city']}'],
            footer: 'Do you want to see its slots?',
            offer: const ToolCall('list_slots', {'store_number': 1}),
          );
        }
        return ToolReply.numbered(header: 'Our stores', items: [for (final s in items) '${s['name']}, ${s['city']}']);
      case 'list_slots':
        return ToolReply.numbered(
          header: 'Slots at ${outcome.annotations['store']}',
          items: [for (final s in items) '${s['when']}'],
        );
      case 'book_slot':
        return ToolReply(text: 'Done: I booked ${payload['booked']} at ${payload['store']}.');
      case 'open_order':
        return ToolReply(text: 'Here is order ${payload['opened']}.');
      case 'item_detail':
        return ToolReply(text: 'Details: ${payload.entries.map((e) => '${e.key} ${e.value}').join(', ')}.');
    }
    return const ToolReply(text: 'Done.');
  }
}

/// The shop's toolkit: [toyTools] on [shop], whose data a new conversation resets.
final class ToyToolkit extends DelegatingToolkit {
  ToyToolkit(this.shop) : super(Toolkit.of(toyTools(shop)));

  final ToyShop shop;

  @override
  void reset() => shop.reset();
}

/// The system prompt of the toy assistant.
const String toySystemPrompt = 'You are the Acme shop assistant. Refer to list items by number.';

/// The toy's today: Friday, 4 September 2026.
final DateTime toyToday = DateTime(2026, 9, 4);

/// The toy assistant's config, as a domain preset might set it (app-written replies, questions skipped for
/// numbers never shown, the facts guard, a rewriter, the 450 ms pause set to zero).
AssistantConfig toyConfig(
  Toolkit toolkit, {
  ReplyStrategy replies = const AppWrittenReplies(ToyWriter()),
  OutputRewriter? rewriter,
  TurnHook? beforeModel,
  ToolGate? beforeTool,
  Duration? toolTimeout,
  ToolErrorPolicy toolErrors = ToolErrorPolicy.failTurn,
  ModelProfile? profile,
  String systemPrompt = toySystemPrompt,
}) => AssistantConfig(
  toolkit: toolkit,
  prompt: PromptLayout(systemPrompt: systemPrompt, contextLine: ContextLines.english),
  profile: profile,
  replies: replies,
  confirmation: const ConfirmationPolicy(skipWhenItemNotShown: true),
  listReferences: toyReferences,
  screenRequests: (outcome) => outcome.call.name == 'open_order' && outcome.result.ok
      ? OrderScreen(outcome.result.payload['opened']! as String, outcome.result.payload['n']! as int)
      : null,
  guards: const [NumericFactsGuard(replacement: "I don't have that information.")],
  rewriter: rewriter,
  beforeModel: beforeModel,
  beforeTool: beforeTool,
  sampling: const SamplingOptions(maxTokens: 256),
  toolTimeout: toolTimeout,
  toolErrors: toolErrors,
  today: () => toyToday,
);

/// The raw output of a call as the model writes it.
String call(String name, [Map<String, Object?> arguments = const {}]) =>
    const QwenXmlToolFormat().render(ToolCall(name, arguments));

/// One assistant on a [ScriptedEngine] with the 4B template, its model file in a temporary folder and its prefix
/// states in `<tmp>/states`.
final class ToyHarness {
  ToyHarness._(this.tmp, this.model, this.engine, this.shop, this.toolkit, this.assistant);

  static Future<ToyHarness> open({
    AssistantConfig Function(Toolkit toolkit)? config,
    ScriptedEngine? engine,
    bool load = true,
    TestToolkit Function(Toolkit toolkit)? wrap,
  }) async {
    final tmp = Directory.systemTemp.createTempSync('assistant_test');
    final model = File('${tmp.path}/toy-4b-test-Q5_K_M.gguf')..writeAsStringSync('not a model');
    final scripted = engine ?? ScriptedEngine(chatTemplate: template4b);
    final shop = ToyShop();
    final base = ToyToolkit(shop);
    final toolkit = wrap == null ? TestToolkit(base) : wrap(base);
    final assistant = Assistant(
      (config ?? toyConfig)(toolkit),
      engine: () => scripted,
      prefixStore: FilePrefixStateStore('${tmp.path}/states'),
      wallClock: () => DateTime(2026, 9, 4, 12),
    );
    final harness = ToyHarness._(tmp, model, scripted, shop, toolkit, assistant);
    if (load) {
      final ready = await assistant.loadModel(model.path);
      if (!ready) throw StateError('the toy model did not load: ${assistant.state.loadError}');
    }
    return harness;
  }

  final Directory tmp;
  final File model;
  final ScriptedEngine engine;
  final ToyShop shop;
  final TestToolkit toolkit;
  final Assistant assistant;

  AssistantState get state => assistant.state;

  /// The newest item.
  ChatItem get last => assistant.state.items.last;

  /// Sends [text] with [output] as the model's answer; the newest item after the turn.
  Future<ChatItem> say(String text, String output) async {
    engine.outputs.add(output);
    await assistant.send(text);
    return last;
  }

  /// The item [id] as it is now.
  ChatItem item(int id) => assistant.state.item(id)!;

  Future<void> close() async {
    await assistant.dispose();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  }
}
