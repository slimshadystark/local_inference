// The assistant's values: tool results and replies, list references and
// bindings, the prompt layout and date lines, the facts guard, the rewriter, yes/no parsers, string packs, the
// confirmation policy, toolkits and the config.
import 'package:local_inference/local_inference.dart';
import 'package:local_inference/src/agent/lists.dart';
import 'package:test/test.dart';

final DateTime _friday = DateTime(2026, 9, 4);

void main() {
  group('ToolResult', () {
    test('ok, error and their JSON', () {
      expect(const ToolResult.ok().toJson(), {'ok': true, 'payload': <String, Object?>{}, 'error': null});
      expect(const ToolResult.ok({'a': 1}).payload, {'a': 1});
      const failure = ToolResult.error('timeout', 'too slow', details: {'timeout_ms': 5});
      expect(failure.ok, isFalse);
      expect(failure.payload, isEmpty);
      expect(failure.toJson(), {
        'ok': false,
        'payload': <String, Object?>{},
        'error': {'error': 'too slow', 'code': 'timeout', 'timeout_ms': 5},
      });
    });

    test('list numbers the items from 1 (n first), counts them, and adds extra keys after, never over its own', () {
      final list = ToolResult.list(
        collection: 'orders',
        items: [
          {'code': 'A', 'n': 9},
          {'code': 'B'},
        ],
        total: 5,
        extra: {'page': 1, 'collection': 'other'},
      );
      expect(list.payload, {
        'collection': 'orders',
        'count': 5,
        'shown': 2,
        'items': [
          {'n': 1, 'code': 'A'},
          {'n': 2, 'code': 'B'},
        ],
        'page': 1,
      });
      expect((list.payload['items']! as List).first, isA<Map<String, Object?>>());
      expect((list.payload['items']! as List<Object?>).map((i) => (i! as Map).keys.first), ['n', 'n']);
    });

    test('R-k: fromJson keeps the envelope: toJson returns the same map', () {
      final ok = {
        'ok': true,
        'payload': {'x': 1},
        'error': null,
        'tool': 't',
        'args': <String, Object?>{},
        'side_effect': 'read',
      };
      final success = ToolResult.fromJson(ok);
      expect(identical(success.toJson(), ok), isTrue);
      expect(success.ok, isTrue);
      expect(success.payload, {'x': 1});
      final bad = {
        'ok': false,
        'payload': null,
        'error': {
          'error': 'Nessun elenco',
          'code': 'stale_list',
          'relist': {'tool': 'x'},
        },
      };
      final failure = ToolResult.fromJson(bad) as ToolFailure;
      expect(identical(failure.toJson(), bad), isTrue);
      expect((failure.code, failure.message), ('stale_list', 'Nessun elenco'));
      expect(failure.details, {
        'relist': {'tool': 'x'},
      });
      expect((ToolResult.fromJson({'ok': false, 'error': 'down'}) as ToolFailure).message, 'down');
      expect((ToolResult.fromJson({'ok': false}) as ToolFailure).code, 'error');
    });

    test('encodeToolResult: the payload, or the error and code, as Python JSON; other values as their text', () {
      ToolOutcome outcome(ToolResult result) =>
          ToolOutcome(call: const ToolCall('t'), result: result, source: ToolCallSource.model);
      expect(
        encodeToolResult(outcome(ToolResult.ok({'a': 1, 'when': DateTime.utc(2026, 9, 4)}))),
        '{"a": 1, "when": "2026-09-04 00:00:00.000Z"}',
      );
      expect(
        encodeToolResult(outcome(const ToolResult.error('x', 'no', details: {'secret': 1}))),
        '{"error": "no", "code": "x"}',
      );
    });
  });

  group('ToolReply', () {
    test('numbered: the history text on one line, the display one item per line', () {
      final reply = ToolReply.numbered(header: 'You have 2 orders', items: ['A', 'B'], footer: 'Which one?');
      expect(reply.text, 'You have 2 orders: 1. A; 2. B. Which one?');
      expect(reply.display, 'You have 2 orders:\n1. A\n2. B\n\nWhich one?');
      final bare = ToolReply.numbered(header: 'No orders.', footer: 'Anything else?');
      expect((bare.text, bare.display), ('No orders. Anything else?', 'No orders.\n\nAnything else?'));
      expect(ToolReply.numbered(header: 'Done.').display, 'Done.');
      expect(const ToolReply(text: 'x').display, 'x');
    });
  });

  group('lists', () {
    const references = ListReferences(
      itemArguments: {
        'order_number': ItemSource.collection('orders'),
        'item_number': ItemSource.argument('collection'),
      },
    );

    test('itemRefOf: the first item argument present, then the x-item-of markers; a collection argument that is not '
        'a string names none', () {
      expect(references.itemRefOf(const ToolCall('cancel', {'order_number': 2})), const ItemRef('orders', 2));
      expect(
        references.itemRefOf(const ToolCall('detail', {'collection': 'stores', 'item_number': 1})),
        const ItemRef('stores', 1),
      );
      expect(references.itemRefOf(const ToolCall('detail', {'collection': 3, 'item_number': 1})), isNull);
      expect(references.itemRefOf(const ToolCall('list')), isNull);
      final spec = ToolSpec(
        name: 'pick',
        description: 'Picks a slot.',
        parameters: ToolSchema.object({
          'slot': {'type': 'integer', 'x-item-of': 'slots'},
        }),
      );
      expect(references.itemRefOf(const ToolCall('pick', {'slot': 3}), spec), const ItemRef('slots', 3));
      expect(references.sourceOf('slot', spec), const ItemSource.collection('slots'));
      expect(spec.declaration.toString(), isNot(contains('x-item-of')), reason: 'the model never reads the marker');
    });

    test('ToolSchema.itemNumber declares an item argument with no ListReferences entry; itemArguments win for the '
        'same name, and their arguments come first', () {
      final spec = ToolSpec(
        name: 'swap',
        description: 'Swaps an order for a store.',
        parameters: ToolSchema.object({
          'store_number': ToolSchema.itemNumber('stores'),
          'order_number': ToolSchema.itemNumber('shops'),
        }),
      );
      const plain = ListReferences();
      expect(plain.sourceOf('store_number', spec), const ItemSource.collection('stores'));
      expect(plain.sourceOf('order_number', spec), const ItemSource.collection('shops'));
      expect(plain.sourceOf('store_number'), isNull, reason: 'no spec, no marker');
      expect(plain.itemRefOf(const ToolCall('swap', {'store_number': 2}), spec), const ItemRef('stores', 2));
      expect(
        plain.itemRefOf(const ToolCall('swap', {'order_number': 1, 'store_number': 2}), spec),
        const ItemRef('stores', 2),
        reason: 'markers in property order',
      );
      expect(references.sourceOf('order_number', spec), const ItemSource.collection('orders'));
      expect(
        references.itemRefOf(const ToolCall('swap', {'store_number': 2, 'order_number': 1}), spec),
        const ItemRef('orders', 1),
      );
    });

    test('the ledger: ok list results only, versions, items, the last call, bindings by value (annotations '
        'included), JSON', () {
      final ledger = ListLedger(references);
      ToolResult orders(List<String> codes) => ToolResult.list(
        collection: 'orders',
        items: [
          for (final c in codes) {'code': c},
        ],
      );
      expect(ledger.record(const ToolCall('x'), const ToolResult.ok({'collection': 'orders'}), const {}), isNull);
      expect(ledger.record(const ToolCall('x'), const ToolResult.error('e', 'm'), const {}), isNull);
      final first = ledger.record(const ToolCall('list_orders'), orders(['A', 'B']), const {'shop': 'north'})!;
      expect((first.version, first.items.length, ledger.versionOf('orders'), ledger.versionOf('stores')), (1, 2, 1, 0));
      expect(ledger.item('orders', 2), {'n': 2, 'code': 'B'});
      expect(ledger.item('orders', 3), isNull);
      expect(ledger.item('orders', null), isNull);
      expect(ledger.isShown(const ItemRef('orders', 1)), isTrue);
      expect(ledger.isLastList('orders', const ToolCall('list_orders')), isTrue);
      expect(ledger.isLastList('orders', const ToolCall('list_orders', {'all': true})), isFalse);

      final binding = ledger.bind(const ItemRef('orders', 2))!;
      expect(binding.listVersion, 1);
      expect(ledger.stillNames(binding), isTrue);
      ledger.record(const ToolCall('list_orders'), orders(['A', 'B']), const {'shop': 'north'});
      expect(ledger.stillNames(binding), isTrue, reason: 'a later list with the same item');
      ledger.record(const ToolCall('list_orders'), orders(['A', 'B']), const {'shop': 'south'});
      expect(ledger.stillNames(binding), isFalse, reason: 'R-c: the annotations are part of what was shown');
      ledger.record(const ToolCall('list_orders'), orders(['B', 'A']), const {'shop': 'north'});
      expect(ledger.stillNames(binding), isFalse, reason: 'renumbered');
      expect(ledger.stillNames(null), isTrue);
      expect(ItemBinding.fromJson(binding.toJson()), binding);
      expect(() => ItemBinding.fromJson({'collection': 'orders'}), throwsFormatException);

      final copy = ListLedger(references)..restore(ledger.toJson());
      expect(copy.versionOf('orders'), 4);
      expect(copy.item('orders', 1), {'n': 1, 'code': 'B'});
      expect(copy['orders']!.annotations, {'shop': 'north'});
      expect(copy.isLastList('orders', const ToolCall('list_orders')), isTrue);
      expect(() => ListLedger(references).restore({'lists': 'x'}), throwsFormatException);
      ledger.clear();
      expect(ledger.versionOf('orders'), 0);
      expect(ledger.collections, isEmpty);
    });
  });

  group('PromptLayout', () {
    const layout = PromptLayout(systemPrompt: 'S', contextLine: ContextLines.english, historyCharBudget: 30);

    test('window: the last 3 exchanges within the budget, newest first to fill it; the newest always', () {
      const a = HistoryEntry('a', '1');
      const b = HistoryEntry('bbbbbbbbbb', '2222222222');
      const c = HistoryEntry('c', '3');
      const d = HistoryEntry('d', '4');
      expect(layout.window([a, b, c, d]), [b, c, d]);
      expect(layout.window([a, b, const HistoryEntry('cccccccccc', '3333333333')]), [
        const HistoryEntry('cccccccccc', '3333333333'),
      ]);
      final huge = HistoryEntry('x' * 100, 'y');
      expect(layout.window([a, huge]), [huge]);
      expect(layout.window(const []), isEmpty);
    });

    test('messages: system, the window, then the date line, extra context and the text in one user message', () {
      final messages = layout.messages(
        '  ciao  ',
        history: const [HistoryEntry('u', 'a')],
        today: _friday,
        extraContext: ['one', '', 'two'],
      );
      expect(messages, [
        const ChatMessage.system('S'),
        const ChatMessage.user('u'),
        const ChatMessage.assistant('a'),
        const ChatMessage.user('Today is Friday, 4 September 2026.\n\none\n\ntwo\n\nciao'),
      ]);
      expect(layout.messages('   ', today: _friday).last.content, 'Today is Friday, 4 September 2026.\n\n ');
      expect(const PromptLayout(systemPrompt: 'S').messages('hi', today: _friday).last.content, 'hi');
    });
  });

  test('ContextLines', () {
    expect(ContextLines.english(_friday), 'Today is Friday, 4 September 2026.');
    expect(ContextLines.iso(_friday), 'Today is 2026-09-04.');
    expect(ContextLines.italianDate(_friday), 'venerdì 4 settembre 2026');
    expect(ContextLines.italian(DateTime(2027, 1, 31)), 'Oggi è domenica 31 gennaio 2027.');
  });

  group('the facts guard', () {
    test('R-g: the euro pattern is case-insensitive; facts are normalized, unique and sorted', () {
      expect(FactPatterns.european.extract('costa 10 EURO'), ['10€']);
      expect(FactPatterns.european.extract('costa 142 Euro'), ['142€']);
      expect(FactPatterns.european.extract('€ 1.200,50 il 18/09 alle 10:00, pratica 2026/123, codice 123456'), [
        '10:00',
        '123456',
        '18/09',
        '2026/123',
        '€1.200,50',
      ]);
      expect(FactPatterns.european.invented('alle 10.30 e il 18/09', 'appuntamento 18/09'), ['10.30']);
      expect(FactPatterns.european.invented('', 'x'), isEmpty);
      expect(normalizeFact(' 10 Euro '), '10€');
    });

    test('NumericFactsGuard: a verdict with the note and the facts, null when the context has them', () {
      const guard = NumericFactsGuard(replacement: 'No.', note: 'dati non verificati');
      const context = GuardContext(userText: 'quando?', window: [HistoryEntry('lista', 'il 18/09')]);
      expect(context.text, 'lista\nil 18/09\nquando?');
      final verdict = guard.check('il 18/09 alle 10:00', context)!;
      expect((verdict.replacement, verdict.note), ('No.', 'dati non verificati: 10:00'));
      expect(guard.check('il 18/09', context), isNull);
      final withResults = GuardContext(
        userText: 'x',
        toolOutcomes: [
          ToolOutcome(
            call: const ToolCall('t'),
            result: const ToolResult.ok({'at': '10:00'}),
            source: ToolCallSource.model,
          ),
        ],
      );
      expect(guard.check('alle 10:00', withResults), isNull);
    });

    test('ReplaceText applies its pairs in order', () {
      const rewrite = ReplaceText([
        ('Aria', 'Ada'),
        ('Comune di Valmontana', 'Comune di Esempio'),
        ('Valmontana', 'Esempio'),
      ]);
      expect(
        rewrite('Sono Aria del Comune di Valmontana, a Valmontana.'),
        'Sono Ada del Comune di Esempio, a Esempio.',
      );
      final OutputRewriter asFunction = rewrite.call;
      expect(asFunction('Valmontana'), 'Esempio');
    });
  });

  group('YesNoParser', () {
    test('english', () {
      const parser = YesNoParser.english;
      for (final yes in [
        'yes',
        'Yes!',
        'y',
        'ok',
        'OK.',
        'sure',
        'yes please',
        'Yes, thank you',
        'go ahead',
        'yes yes',
      ]) {
        expect(parser.parse(yes), isTrue, reason: yes);
      }
      for (final no in ['no', 'No.', 'nope', 'cancel', 'not now', 'never mind', 'no thanks', "don't"]) {
        expect(parser.parse(no), isFalse, reason: no);
      }
      for (final other in ['', '   ', 'maybe', 'yes but tomorrow', 'ok 2', '👍', 'what?']) {
        expect(parser.parse(other), isNull, reason: other);
      }
    });

    test('italian: unicode-aware, accents and punctuation tolerated', () {
      const parser = YesNoParser.italian;
      for (final yes in [
        'sì',
        'Sì, grazie',
        'SÌ',
        'si',
        'sí',
        'sì',
        'ok',
        'va bene',
        'va  bene',
        "d'accordo",
        'certo!',
        'procedi pure',
        'sì grazie mille',
      ]) {
        expect(parser.parse(yes), isTrue, reason: yes);
      }
      for (final no in ['no', 'No, grazie', 'annulla', 'lascia stare', 'non ora', 'niente']) {
        expect(parser.parse(no), isFalse, reason: no);
      }
      for (final other in ['forse', 'grazie', 'sì però domani', '1', '']) {
        expect(parser.parse(other), isNull, reason: other);
      }
    });
  });

  test('AssistantStrings: forLanguage picks the pack; copyWith replaces fields', () {
    expect(AssistantStrings.forLanguage('it'), same(AssistantStrings.italian));
    expect(AssistantStrings.forLanguage('it_IT'), same(AssistantStrings.italian));
    expect(AssistantStrings.forLanguage('IT-ch'), same(AssistantStrings.italian));
    expect(AssistantStrings.forLanguage('en-GB'), same(AssistantStrings.english));
    expect(AssistantStrings.forLanguage('fr'), same(AssistantStrings.english));
    final copy = AssistantStrings.english.copyWith(yes: 'Yep');
    expect((copy.yes, copy.no), ('Yep', 'No'));
    expect(copy.yesNo, same(YesNoParser.english));
    expect(AssistantStrings.italian.yesNo.parse('sì'), isTrue);
  });

  group('ConfirmationPolicy', () {
    final ledger = ListLedger(const ListReferences(itemArguments: {'n': ItemSource.collection('orders')}));
    ConfirmationContext context(SideEffect effect, ToolCall call) => ConfirmationContext(
      call: call,
      spec: ToolSpec(name: call.name, description: 'd', sideEffect: effect),
      lists: ledger,
      strings: AssistantStrings.english,
      references: ledger.references,
    );

    test('asks for the side effects it lists; skips an item never shown only when told to', () {
      const call = ToolCall('cancel', {'n': 1});
      expect(const ConfirmationPolicy().shouldAsk(call, context(SideEffect.irreversible, call)), isTrue);
      expect(const ConfirmationPolicy().shouldAsk(call, context(SideEffect.recoverable, call)), isFalse);
      expect(
        const ConfirmationPolicy(ask: {SideEffect.recoverable}).shouldAsk(call, context(SideEffect.recoverable, call)),
        isTrue,
      );
      const skip = ConfirmationPolicy(skipWhenItemNotShown: true);
      expect(skip.shouldAsk(call, context(SideEffect.irreversible, call)), isFalse, reason: 'no list shown');
      ledger.record(
        const ToolCall('list'),
        ToolResult.list(
          collection: 'orders',
          items: [
            {'code': 'A'},
          ],
        ),
        const {},
      );
      expect(skip.shouldAsk(call, context(SideEffect.irreversible, call)), isTrue);
      expect(context(SideEffect.irreversible, call).item('n'), {'n': 1, 'code': 'A'});
      expect(
        skip.shouldAsk(const ToolCall('cancel_all'), context(SideEffect.irreversible, const ToolCall('cancel_all'))),
        isTrue,
        reason: 'no item named',
      );
    });
  });

  group('toolkits', () {
    AssistantTool tool(String name, {Duration? timeout}) => AssistantTool(
      name: name,
      description: 'The $name tool.',
      parameters: ToolSchema.object({'n': ToolSchema.integer(minimum: 1)}, required: ['n']),
      statusLabel: 'Running $name...',
      confirmationQuestion: (call, context) => 'Run $name?',
      timeout: timeout,
      run: (call, context) => ToolResult.ok({'n': call.integer('n')}),
    );

    test(
      'Toolkit.of: specs in order, look-ups, default validation, execution; two tools with one name are refused',
      () async {
        final toolkit = Toolkit.of([tool('a'), tool('b', timeout: const Duration(seconds: 2))]);
        expect(toolkit, isA<ToolRegistry>());
        expect(toolkit.specs.map((s) => s.name), ['a', 'b']);
        expect(toolkit.spec('b')!.name, 'b');
        expect(toolkit.spec('c'), isNull);
        expect(toolkit.validate(const ToolCall('a', {'n': 0})), isNotEmpty);
        expect(toolkit.validate(const ToolCall('a', {'n': 1})), isEmpty);
        expect(toolkit.validate(const ToolCall('c')), ['unknown tool']);
        expect(toolkit.coerce(const ToolCall('a', {'n': '1'})), {'n': '1'});
        final context = ToolContext(call: const ToolCall('a', {'n': 3}));
        expect((await toolkit.execute(const ToolCall('a', {'n': 3}), context)).payload, {'n': 3});
        expect((await toolkit.execute(const ToolCall('c'), context) as ToolFailure).code, 'unknown_tool');
        expect(toolkit.statusLabel(const ToolCall('a')), 'Running a...');
        expect(toolkit.timeoutOf(const ToolCall('b')), const Duration(seconds: 2));
        expect(toolkit.timeoutOf(const ToolCall('a')), isNull);
        expect(() => Toolkit.of([tool('a'), tool('a')]), throwsArgumentError);
      },
    );

    test('DelegatingToolkit forwards every member', () async {
      final inner = Toolkit.of([tool('a')]);
      final outer = DelegatingToolkit(inner);
      expect(outer.specs, same(inner.specs));
      expect(outer.statusLabel(const ToolCall('a')), 'Running a...');
      final context = ConfirmationContext(
        call: const ToolCall('a'),
        spec: inner.specs.first,
        lists: ListLedger(const ListReferences()),
        strings: AssistantStrings.english,
      );
      expect(outer.confirmationQuestion(const ToolCall('a'), context), 'Run a?');
      expect((await outer.execute(const ToolCall('a', {'n': 1}), ToolContext(call: const ToolCall('a')))).ok, isTrue);
      expect((outer.saveState(), outer.timeoutOf(const ToolCall('a'))), (null, null));
    });

    test('ToolContext: item() through the references, and a cancel that completes once', () async {
      final ledger = ListLedger(const ListReferences(itemArguments: {'n': ItemSource.collection('orders')}));
      ledger.record(
        const ToolCall('list'),
        ToolResult.list(
          collection: 'orders',
          items: [
            {'code': 'A'},
          ],
        ),
        const {},
      );
      final context = ToolContext(
        call: const ToolCall('cancel', {'n': 1}),
        lists: ledger,
        references: ledger.references,
        today: _friday,
      );
      expect(context.item('n'), {'n': 1, 'code': 'A'});
      expect(context.item('other'), isNull);
      expect((context.today, context.source, context.isCancelled), (_friday, ToolCallSource.host, false));
      context
        ..cancel()
        ..cancel();
      await context.cancelled;
      expect(context.isCancelled, isTrue);
    });
  });

  group('values', () {
    test('ChatAction and HistoryEntry compare by value; AssistantState reads', () {
      expect(
        const ChatAction(kind: ChatActionKind.confirm, label: 'Yes', primary: true),
        const ChatAction(kind: ChatActionKind.confirm, label: 'Yes', primary: true),
      );
      expect(
        const ChatAction(kind: ChatActionKind.confirm, label: 'Yes'),
        isNot(const ChatAction(kind: ChatActionKind.decline, label: 'Yes')),
      );
      expect(const HistoryEntry('a', 'b'), const HistoryEntry('a', 'b'));
      const item = ChatItem(id: 3, role: MessageRole.user, text: 'hi');
      const state = AssistantState(phase: AssistantPhase.ready, conversationId: 'c', items: [item]);
      expect(
        (state.canSend, state.isBusy, state.hasConversation, state.item(3), state.item(4)),
        (true, false, true, item, null),
      );
    });

    test('AssistantConfig.basic and copyWith', () {
      final config = AssistantConfig.basic(
        systemPrompt: 'Be brief.',
        tools: [AssistantTool(name: 't', description: 'd', run: (call, context) => const ToolResult.ok())],
      );
      expect(config.toolkit.specs.single.name, 't');
      expect(config.prompt.messages('hi', today: _friday).last.content, 'Today is Friday, 4 September 2026.\n\nhi');
      expect(config.replies, isA<ModelWrittenReplies>());
      expect(config.strings, same(AssistantStrings.english));
      expect(config.toolErrors, ToolErrorPolicy.failTurn);
      expect(config.restoreOpenQuestion, isTrue);
      final italian = config.copyWith(strings: AssistantStrings.italian, toolTimeout: const Duration(seconds: 1));
      expect(italian.strings, same(AssistantStrings.italian));
      expect(italian.toolTimeout, const Duration(seconds: 1));
      expect(italian.toolkit, same(config.toolkit));
      expect(italian.copyWith(restoreOpenQuestion: false).restoreOpenQuestion, isFalse);
    });
  });
}
