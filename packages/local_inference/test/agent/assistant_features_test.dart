// What the assistant adds to the basic turn loop: model-written replies,
// snapshots and the conversation store, reconfigure and setToolkit, tool timeouts and cancellation, beforeTool,
// ToolErrorPolicy, sendStreaming's ordering and the beforeModel hook.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:local_inference/local_inference.dart';
import 'package:local_inference/testing.dart';
import 'package:test/test.dart';

import 'support/toy_shop.dart';

/// Replies `ok <payload>` or `failed <code>`.
final class _EchoWriter implements ReplyWriter {
  const _EchoWriter();

  @override
  ToolReply write(ToolOutcome outcome) => switch (outcome.result) {
    ToolSuccess(:final payload) => ToolReply(text: 'ok ${jsonEncode(payload)}'),
    ToolFailure(:final code) => ToolReply(text: 'failed $code'),
  };
}

/// Lets every answer through and records the outcomes it could compare with.
final class _RecordingGuard implements OutputGuard {
  _RecordingGuard(this.seen);

  final List<List<ToolOutcome>> seen;

  @override
  GuardVerdict? check(String answer, GuardContext context) {
    seen.add(context.toolOutcomes);
    return null;
  }
}

/// Keeps the snapshots in memory and records every save.
final class _MemoryStore implements ConversationStore {
  final Map<String, ConversationSnapshot> saved = {};
  final List<String> saves = [];

  @override
  Future<List<ConversationSnapshot>> list() async =>
      saved.values.toList()..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

  @override
  Future<ConversationSnapshot?> load(String id) async => saved[id];

  @override
  Future<void> save(ConversationSnapshot snapshot) async {
    saves.add(snapshot.id);
    saved[snapshot.id] = snapshot;
  }

  @override
  Future<void> delete(String id) async => saved.remove(id);
}

/// A codec that throws.
final class _ThrowingCodec implements ScreenRequestCodec {
  const _ThrowingCodec();

  @override
  Map<String, Object?> encode(ScreenRequest request) => throw StateError('encode');

  @override
  ScreenRequest? decode(Map<String, Object?> json) => throw StateError('decode');
}

AssistantConfig _config(
  List<AssistantTool> tools, {
  ToolGate? beforeTool,
  Duration? toolTimeout,
  ToolErrorPolicy toolErrors = ToolErrorPolicy.failTurn,
}) => AssistantConfig(
  toolkit: Toolkit.of(tools),
  prompt: const PromptLayout(systemPrompt: 'You are a test assistant.'),
  replies: const AppWrittenReplies(_EchoWriter()),
  beforeTool: beforeTool,
  toolTimeout: toolTimeout,
  toolErrors: toolErrors,
);

AssistantTool _tool(String name, ToolRunner run, {Duration? timeout, SideEffect sideEffect = SideEffect.read}) =>
    AssistantTool(name: name, description: 'The $name tool.', run: run, timeout: timeout, sideEffect: sideEffect);

/// [snapshot] written as JSON and read back, as a store does.
ConversationSnapshot _roundTrip(ConversationSnapshot snapshot) =>
    ConversationSnapshot.tryParse(jsonDecode(jsonEncode(snapshot.toJson())))!;

/// A snapshot with an open question: the toy's orders listed, then "cancel the second" asked (details left out).
const String _questionSnapshotJson = r'''
{
  "formatVersion": 1,
  "id": "chlz4woa9s08jazt8",
  "title": "my orders?",
  "preview": "Do you really want to cancel order B-22? It cannot be undone.",
  "createdAt": "2026-09-04T10:00:00.000Z",
  "updatedAt": "2026-09-04T10:00:00.000Z",
  "messageCount": 4,
  "items": [
    {"id": 1, "role": "user", "text": "my orders?"},
    {
      "id": 2,
      "role": "assistant",
      "text": "You have 3 orders:\n1. A-17, headphones, open\n2. B-22, kettle, open\n3. C-31, lamp, shipped",
      "source": "app"
    },
    {"id": 3, "role": "user", "text": "cancel the second"},
    {
      "id": 4,
      "role": "assistant",
      "text": "Do you really want to cancel order B-22? It cannot be undone.",
      "actions": [
        {"kind": "confirm", "label": "Yes", "primary": true},
        {"kind": "decline", "label": "No", "primary": false}
      ],
      "source": "app"
    }
  ],
  "history": [
    {
      "user": "my orders?",
      "assistant": "You have 3 orders: 1. A-17, headphones, open; 2. B-22, kettle, open; 3. C-31, lamp, shipped."
    }
  ],
  "lists": {
    "lists": [
      {
        "collection": "orders",
        "version": 1,
        "call": {"tool": "list_orders", "args": {}},
        "payload": {
          "collection": "orders",
          "count": 3,
          "shown": 3,
          "items": [
            {"n": 1, "code": "A-17", "item": "headphones", "status": "open"},
            {"n": 2, "code": "B-22", "item": "kettle", "status": "open"},
            {"n": 3, "code": "C-31", "item": "lamp", "status": "shipped"}
          ]
        },
        "annotations": {}
      }
    ]
  },
  "pending": {
    "userText": "cancel the second",
    "call": {"tool": "cancel_order", "args": {"order_number": 2}},
    "itemId": 4,
    "question": "Do you really want to cancel order B-22? It cannot be undone.",
    "binding": {
      "collection": "orders",
      "number": 2,
      "listVersion": 1,
      "snapshot": "[{},{\"n\":2,\"code\":\"B-22\",\"item\":\"kettle\",\"status\":\"open\"}]"
    }
  },
  "offer": null,
  "toolkitState": null,
  "hostData": {}
}
''';

void main() {
  group('ModelWrittenReplies', () {
    late ToyHarness h;

    setUp(() async => h = await ToyHarness.open(config: (t) => toyConfig(t, replies: const ModelWrittenReplies())));
    tearDown(() => h.close());

    test(
      'the call and its result go back to the model, which writes the answer; the history keeps (user, answer)',
      () async {
        h.engine.outputs
          ..add(call('list_orders'))
          ..add('You have three orders: A-17, B-22 and C-31.');
        final outcome = await h.assistant.send('my orders?');
        expect(outcome.reply, 'You have three orders: A-17, B-22 and C-31.');
        expect(outcome.items.last.source, ReplySource.model);
        final second = h.engine.prompts[1];
        expect(
          second,
          contains(
            '<tool_call>\n<function=list_orders>\n</function>\n</tool_call><|im_end|>\n<|im_start|>user\n'
            '<tool_response>\n{"collection": "orders", "count": 3, "shown": 3, "items": [{"n": 1, ',
          ),
        );
        expect(h.engine.options[1].grammar, isNotNull, reason: 'round 1 of 2: the model may call again');
        expect(h.assistant.history, [const HistoryEntry('my orders?', 'You have three orders: A-17, B-22 and C-31.')]);
        final details = h.last.details!.split('\n');
        expect(details.where((line) => line.startsWith('restore ')), hasLength(2));
        expect(details, contains('[tool] list_orders {} → ok'));
        expect(h.assistant.lists.versionOf('orders'), 1, reason: 'the list is recorded as for app-written replies');

        await h.say('thanks', 'You are welcome.');
        expect(h.engine.prompts.last, isNot(contains('<tool_response>')), reason: 'the history has no tool turns');
      },
    );

    test('after maxToolRounds the model answers without tools; a call it writes anyway is not run', () async {
      h.engine.outputs
        ..add(call('find_store'))
        ..add(call('list_slots', {'store_number': 1}))
        ..add(call('list_orders'));
      final outcome = await h.assistant.send('the first slots');
      expect(h.engine.options.map((o) => o.grammar == null), [false, false, true]);
      expect(outcome.reply, AssistantStrings.english.notUnderstood);
      expect(h.toolkit.calls.map((c) => c.name), ['find_store', 'list_slots']);
    });

    test('numbers from tool results are no invented facts; others are', () async {
      h.engine.outputs
        ..add(call('find_store'))
        ..add(call('list_slots', {'store_number': 1}))
        ..add('The first slot is Mon 7 Sep 09:00.');
      expect((await h.assistant.send('first slot?')).reply, 'The first slot is Mon 7 Sep 09:00.');
      h.engine.outputs
        ..add(call('list_orders'))
        ..add('Your order A-17 was placed at 08:15.');
      expect((await h.assistant.send('when was A-17 placed?')).reply, "I don't have that information.");
    });

    test('results are cut to maxResultChars; invalid arguments and unknown tools are reported to the model', () async {
      final short = await ToyHarness.open(
        config: (t) => toyConfig(t, replies: const ModelWrittenReplies(maxResultChars: 20)),
      );
      addTearDown(short.close);
      short.engine.outputs
        ..add(call('list_orders'))
        ..add('Three orders.');
      await short.assistant.send('my orders?');
      expect(short.engine.prompts[1], contains('<tool_response>\n{"collection": "orde…\n</tool_response>'));

      h.engine.outputs
        ..add(call('cancel_order'))
        ..add(call('refund'))
        ..add('Which order?');
      expect((await h.assistant.send('cancel it')).reply, 'Which order?');
      expect(
        h.engine.prompts[1],
        contains('''{"error": "missing required argument 'order_number'", "code": "invalid_arguments"}'''),
      );
      expect(h.engine.prompts[2], contains('{"error": "unknown tool", "code": "invalid_arguments"}'));
      expect(h.last.details, contains("[validation] cancel_order: missing required argument 'order_number'"));
      expect(h.toolkit.calls, isEmpty);
    });

    test('an irreversible call asks first; the yes runs it and the model writes the reply from its result', () async {
      h.engine.outputs
        ..add(call('list_orders'))
        ..add('You have three orders.');
      await h.assistant.send('my orders?');
      h.engine.outputs.add(call('cancel_order', {'order_number': 2}));
      final question = await h.assistant.send('cancel the second');
      expect(question.confirmation!.question, 'Do you really want to cancel order B-22? It cannot be undone.');
      expect(h.toolkit.calls.map((c) => c.name), ['list_orders'], reason: 'nothing ran yet');
      h.engine.outputs.add('Done, B-22 is cancelled.');
      final done = await h.assistant.confirm(true);
      expect(done.reply, 'Done, B-22 is cancelled.');
      expect(h.toolkit.sources.last, ToolCallSource.confirmation);
      expect(h.engine.prompts.last, contains('<tool_response>\n{"cancelled": "B-22"}\n</tool_response>'));
      expect(h.assistant.history.last, const HistoryEntry('cancel the second', 'Done, B-22 is cancelled.'));
    });

    test('S4: a stop while a call runs lets it finish; the model writes nothing and the reply is `done`, in the '
        'history', () async {
      h.engine.outputs
        ..add(call('list_orders'))
        ..add('You have three orders.');
      await h.assistant.send('my orders?');
      h.engine.outputs.add(call('cancel_order', {'order_number': 2}));
      await h.assistant.send('cancel the second');
      h.toolkit
        ..gatedTool = 'cancel_order'
        ..gate = Completer<void>();
      final confirmed = h.assistant.confirm(true);
      for (var i = 0; i < 20 && h.toolkit.calls.last.name != 'cancel_order'; i++) {
        await pumpEventQueue();
      }
      h.assistant.stop();
      h.toolkit.gate!.complete();
      final outcome = await confirmed;
      expect(h.shop.orders.map((o) => o['code']), ['A-17', 'C-31'], reason: 'the call ran');
      expect((outcome.reply, outcome.items.last.source, outcome.error), ('Done.', ReplySource.app, null));
      expect(h.assistant.history.last, const HistoryEntry('cancel the second', 'Done.'));

      // In a model turn: the round's calls finish, then the model's answer is not generated.
      h.toolkit
        ..gatedTool = 'list_orders'
        ..gate = Completer<void>();
      h.engine.outputs
        ..add(call('list_orders'))
        ..add('Never written.');
      final turn = h.assistant.send('and now?');
      for (var i = 0; i < 20 && h.toolkit.calls.last.name != 'list_orders'; i++) {
        await pumpEventQueue();
      }
      h.assistant.stop();
      h.toolkit.gate!.complete();
      expect((await turn).reply, 'Done.');
      expect(h.assistant.history.last, const HistoryEntry('and now?', 'Done.'));
      expect(h.engine.outputs, ['Never written.']);
    });

    test('after its calls, a stopped answer keeps the text so far; a failed one gives `done`, with the error in the '
        'details and the outcome; both join the history', () async {
      h.engine.outputs
        ..add(call('list_orders'))
        ..add('You have three orders: A-17, B-22 and C-31.');
      void stopOnText() {
        if (h.state.isBusy && h.toolkit.calls.isNotEmpty && h.state.items.last.text.isNotEmpty) h.assistant.stop();
      }

      h.assistant.addListener(stopOnText);
      final stopped = await h.assistant.send('my orders?');
      h.assistant.removeListener(stopOnText);
      expect('You have three orders: A-17, B-22 and C-31', startsWith(stopped.reply));
      expect(stopped.reply.length, lessThan(40), reason: 'stopped before the end');
      expect(stopped.items.last.source, ReplySource.model);
      expect(h.assistant.history.last, HistoryEntry('my orders?', stopped.reply));

      h.toolkit
        ..gatedTool = 'list_orders'
        ..gate = Completer<void>();
      h.engine.outputs
        ..add(call('list_orders'))
        ..add('Three orders.');
      final turn = h.assistant.send('my orders again?');
      for (var i = 0; i < 20 && h.toolkit.calls.length < 2; i++) {
        await pumpEventQueue();
      }
      h.engine.throwAfterDeltas = (0, StateError('engine down'));
      h.toolkit.gate!.complete();
      final failed = await turn;
      expect((failed.reply, failed.items.last.source), ('Done.', ReplySource.app));
      expect(failed.error, isNotNull);
      expect(h.last.details, contains('[tool] list_orders {} → ok'));
      expect(h.last.details!.split('\n').last, 'GenerationException: generation failed (Bad state: engine down)');
      expect(h.assistant.history.last, const HistoryEntry('my orders again?', 'Done.'));
    });

    test('sendStreaming: text written before the calls, then the answer after a blank line; the item keeps the '
        'answer', () async {
      h.engine.outputs
        ..add('Let me look.\n${call('list_orders')}')
        ..add('You have three orders.');
      final turn = h.assistant.sendStreaming('my orders?');
      final text = turn.text.join();
      final outcome = await turn.outcome;
      expect(await text, 'Let me look.\n\nYou have three orders.');
      expect(outcome.reply, 'You have three orders.');
    });

    test('a question among several calls: the calls before it keep their results, the ones after it are answered as '
        'not run; each call has its result, in order', () async {
      final seen = <List<ToolOutcome>>[];
      final several = await ToyHarness.open(
        config: (t) => toyConfig(t, replies: const ModelWrittenReplies()).copyWith(guards: [_RecordingGuard(seen)]),
      );
      addTearDown(several.close);
      several.engine.outputs
        ..add(call('list_orders'))
        ..add('You have three orders.');
      await several.assistant.send('my orders?');
      several.engine.outputs.add(
        [
          call('item_detail', {'collection': 'orders', 'item_number': 1}),
          call('cancel_order', {'order_number': 2}),
          call('list_orders'),
        ].join('\n'),
      );
      final question = await several.assistant.send('show the first, cancel the second, list them again');
      expect(question.confirmation, isNotNull);
      expect(several.toolkit.calls.map((c) => c.name), ['list_orders', 'item_detail']);
      several.engine.outputs.add('A-17 is open and B-22 is cancelled.');
      expect((await several.assistant.confirm(true)).reply, 'A-17 is open and B-22 is cancelled.');
      expect(several.toolkit.calls.map((c) => c.name), ['list_orders', 'item_detail', 'cancel_order']);
      expect(
        several.engine.prompts.last,
        contains(
          '<tool_response>\n{"n": 1, "code": "A-17", "item": "headphones", "status": "open"}\n</tool_response>\n'
          '<tool_response>\n{"cancelled": "B-22"}\n</tool_response>\n'
          '<tool_response>\n{"error": "not run: it came after a call that asked the user first", "code": "not_run"}\n'
          '</tool_response>',
        ),
      );
      expect(seen.last.map((o) => o.call.name), ['item_detail', 'cancel_order']);
    });

    test('a recorded action is answered with strings.done, or its own text', () async {
      final reply = h.assistant.recordAction(
        'Cancelled A-17 (from the app)',
        const ToolCall('list_orders'),
        const ToolResult.ok(),
      );
      expect(reply.text, AssistantStrings.english.done);
      final failed = h.assistant.recordAction('x', const ToolCall('list_orders'), const ToolResult.error('x', 'y'));
      expect(failed.text, AssistantStrings.english.toolFailed);
      expect(
        h.assistant.recordAction('y', const ToolCall('list_orders'), const ToolResult.ok(), reply: 'Noted.').text,
        'Noted.',
      );
    });
  });

  group('snapshots', () {
    late ToyHarness h;

    setUp(() async => h = await ToyHarness.open());
    tearDown(() => h.close());

    Future<void> converse() async {
      await h.say('my orders?', call('list_orders'));
      await h.say('open the first', call('open_order', {'order_number': 1}));
      await h.say('cancel the second', call('cancel_order', {'order_number': 2}));
    }

    test('a round trip through JSON: items, screen requests (codec), history, lists and the open question', () async {
      await converse();
      final snapshot = h.assistant.snapshot(codec: const OrderScreenCodec(), hostData: {'area': 'orders'});
      expect(snapshot.title, 'my orders?');
      expect(snapshot.preview, startsWith('Do you really want to cancel order B-22?'));
      expect(snapshot.messageCount, 6);
      final json = jsonDecode(jsonEncode(snapshot.toJson()));
      final parsed = ConversationSnapshot.tryParse(json)!;
      expect(parsed.toJson(), snapshot.toJson());

      final other = await ToyHarness.open();
      addTearDown(other.close);
      expect(other.assistant.restore(parsed, codec: const OrderScreenCodec()), isTrue);
      expect(other.state.items.map((i) => i.text), h.state.items.map((i) => i.text));
      expect(other.assistant.history, h.assistant.history);
      expect(other.state.conversationId, h.state.conversationId);
      expect(other.state.pendingActions.map((a) => a.label), ['Yes', 'No']);
      final opened = other.state.items[3].screenRequest!;
      expect(opened.request, isA<OrderScreen>());
      expect(other.assistant.isScreenRequestCurrent(opened), isTrue);
      expect(other.assistant.lists['orders']!.version, 1);
      // The restored question still works: its number names the same order.
      expect((await other.assistant.confirm(true)).reply, 'Done: I cancelled order B-22.');
      expect(other.toolkit.resets, 1, reason: 'the toolkit starts over');
    });

    test('by default the offer comes back too: a yes runs the offered call, with no model', () async {
      await h.say('find downtown', call('find_store', {'query': 'down'}));
      final other = await ToyHarness.open();
      addTearDown(other.close);
      expect(other.assistant.config.restoreOpenQuestion, isTrue);
      expect(other.assistant.restore(_roundTrip(h.assistant.snapshot())), isTrue);
      expect((await other.assistant.send('yes')).reply, startsWith('Slots at Downtown:\n1. Mon 7 Sep 09:00'));
      expect(other.engine.prompts, isEmpty);
      expect(other.toolkit.calls.map((c) => c.name), ['list_slots']);
    });

    group('restoreOpenQuestion: false', () {
      late ToyHarness off;

      setUp(() async {
        off = await ToyHarness.open(config: (toolkit) => toyConfig(toolkit).copyWith(restoreOpenQuestion: false));
      });
      tearDown(() => off.close());

      test(
        'the question is dropped: no buttons, the item keeps its text, (its text, declined) joins the history',
        () async {
          await converse();
          final snapshot = _roundTrip(h.assistant.snapshot());
          expect(snapshot.pending, isNotNull);
          expect(off.assistant.restore(snapshot), isTrue);
          expect(off.state.pendingConfirmation, isNull);
          expect(off.state.pendingActions, isEmpty);
          expect(off.state.items.map((i) => i.text), h.state.items.map((i) => i.text));
          expect(off.state.items.last.text, 'Do you really want to cancel order B-22? It cannot be undone.');
          expect(off.state.items.expand((i) => i.actions), isEmpty);
          expect(off.state.items[3].screenRequest, isNotNull, reason: 'the rest of each item stays');
          expect(off.assistant.history, [
            ...h.assistant.history,
            HistoryEntry('cancel the second', AssistantStrings.english.declined),
          ]);
          expect(off.assistant.lists['orders']!.version, 1);
          expect((await off.assistant.confirm(true)).rejection, TurnRejection.noQuestion);
          final again = off.assistant.snapshot();
          expect((again.pending, again.offer), (null, null));
        },
      );

      test('a yes typed next goes to the model as any message; nothing runs', () async {
        await converse();
        expect(off.assistant.restore(h.assistant.snapshot()), isTrue);
        final reply = await off.say('yes', 'Yes to what?');
        expect((reply.text, reply.source), ('Yes to what?', ReplySource.model));
        expect(off.engine.prompts, hasLength(1));
        expect(
          off.engine.prompts.single,
          contains(
            '<|im_start|>user\ncancel the second<|im_end|>\n<|im_start|>assistant\n'
            '${AssistantStrings.english.declined}<|im_end|>',
          ),
        );
        expect(off.toolkit.calls, isEmpty);
        expect(off.assistant.history.last, const HistoryEntry('yes', 'Yes to what?'));
      });

      test('the offer is dropped: a yes goes to the model; an offer joins no history', () async {
        await h.say('find downtown', call('find_store', {'query': 'down'}));
        final snapshot = h.assistant.snapshot();
        expect(snapshot.offer, isNotNull);
        expect(off.assistant.restore(snapshot), isTrue);
        expect(off.assistant.history, h.assistant.history);
        expect(off.assistant.snapshot().offer, isNull);
        expect((await off.say('yes', 'Yes to what?')).text, 'Yes to what?');
        expect(off.engine.prompts, hasLength(1));
        expect(off.toolkit.calls, isEmpty);
      });

      test('copyWith keeps it; a broken question or offer does not refuse the restore, and a question whose item did '
          'not come back joins no history', () async {
        expect(off.assistant.config.copyWith(toolStatusDelay: Duration.zero).restoreOpenQuestion, isFalse);
        expect(off.assistant.config.copyWith(restoreOpenQuestion: true).restoreOpenQuestion, isTrue);
        final broken = ConversationSnapshot(
          id: 'x',
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
          pending: const {'userText': 'x', 'itemId': 99},
          offer: const {'call': 'none'},
        );
        expect(h.assistant.restore(broken), isFalse, reason: 'the default reads them');
        expect(off.assistant.restore(broken), isTrue);
        expect(off.assistant.history, isEmpty, reason: 'no item 99');

        await converse();
        final json = jsonDecode(jsonEncode(h.assistant.snapshot().toJson())) as Map<String, Object?>;
        (json['pending']! as Map<String, Object?>)['itemId'] = 999;
        final orphan = ConversationSnapshot.tryParse(json)!;
        expect(h.assistant.restore(orphan), isFalse);
        expect(off.assistant.restore(orphan), isTrue);
        expect(off.state.items.map((i) => i.text), h.state.items.map((i) => i.text));
        expect(off.assistant.history, h.assistant.history, reason: 'no item 999');
      });
    });

    test('a snapshot written before restoreOpenQuestion existed restores, with its question or without', () async {
      final snapshot = ConversationSnapshot.tryParse(jsonDecode(_questionSnapshotJson))!;
      final on = await ToyHarness.open();
      addTearDown(on.close);
      expect(on.assistant.restore(snapshot), isTrue);
      expect(on.state.pendingActions.map((a) => a.label), ['Yes', 'No']);
      expect((await on.assistant.confirm(true)).reply, 'Done: I cancelled order B-22.');

      final off = await ToyHarness.open(config: (toolkit) => toyConfig(toolkit).copyWith(restoreOpenQuestion: false));
      addTearDown(off.close);
      expect(off.assistant.restore(snapshot), isTrue);
      expect(off.state.pendingActions, isEmpty);
      expect(off.state.items.last.actions, isEmpty);
      expect(off.state.items.last.text, 'Do you really want to cancel order B-22? It cannot be undone.');
      expect(off.assistant.history.last, HistoryEntry('cancel the second', AssistantStrings.english.declined));
    });

    test('the restored event and the listeners fire as before, with the question brought back or dropped', () async {
      await converse();
      final snapshot = h.assistant.snapshot();
      for (final question in [true, false]) {
        final other = await ToyHarness.open(
          config: (toolkit) => toyConfig(toolkit).copyWith(restoreOpenQuestion: question),
        );
        addTearDown(other.close);
        var notified = 0;
        other.assistant.addListener(() => notified++);
        final events = <AssistantEvent>[];
        final states = <AssistantState>[];
        final listening = [other.assistant.events.listen(events.add), other.assistant.states.listen(states.add)];
        addTearDown(() => Future.wait([for (final subscription in listening) subscription.cancel()]));
        expect(other.assistant.restore(snapshot), isTrue);
        await pumpEventQueue();
        expect(notified, 1, reason: 'restoreOpenQuestion: $question');
        expect(events, [
          isA<ConversationChangedEvent>()
              .having((e) => e.change, 'change', ConversationChange.restored)
              .having((e) => e.conversationId, 'conversationId', snapshot.id),
        ]);
        expect(states.single.items.map((i) => i.text), h.state.items.map((i) => i.text));
        expect(states.single.pendingActions, hasLength(question ? 2 : 0));
      }
    });

    test('without a codec the screen requests come back as StoredScreenRequest; items get new ids', () async {
      await converse();
      final snapshot = h.assistant.snapshot();
      final other = await ToyHarness.open();
      addTearDown(other.close);
      await other.say('hi', 'Hello.');
      expect(other.assistant.restore(ConversationSnapshot.tryParse(snapshot.toJson())!), isTrue);
      final request = other.state.items[3].screenRequest!.request;
      expect(request, isA<StoredScreenRequest>());
      expect((request.label, request.itemRef), ('Open order A-17', const ItemRef('orders', 1)));
      final ids = other.state.items.map((i) => i.id).toList();
      expect(ids.toSet(), hasLength(ids.length));
      expect(ids.first, greaterThan(2), reason: 'ids never reused');
    });

    test('tryParse returns null for anything that is not a snapshot, and never throws', () async {
      await converse();
      final good = jsonDecode(jsonEncode(h.assistant.snapshot().toJson())) as Map<String, Object?>;
      Map<String, Object?> without(String key) => {...good}..remove(key);
      Map<String, Object?> replaced(String key, Object? value) => {...good, key: value};
      final bad = <Object?>[
        null,
        42,
        'text',
        <Object?>[],
        without('id'),
        without('items'),
        replaced('formatVersion', 2),
        replaced('id', ''),
        replaced('createdAt', 'yesterday'),
        replaced('items', 'none'),
        replaced('items', [42]),
        replaced('items', [
          {'id': 'one', 'role': 'user', 'text': 'x'},
        ]),
        replaced('items', [
          {'id': 1, 'role': 'system', 'text': 'x'},
        ]),
        replaced('items', [
          {'id': 1, 'role': 'user', 'text': 'x'},
          {'id': 1, 'role': 'user', 'text': 'y'},
        ]),
        replaced('items', [
          {'id': 1, 'role': 'assistant', 'text': 'x', 'source': 'someone'},
        ]),
        replaced('items', [
          {
            'id': 1,
            'role': 'assistant',
            'text': 'x',
            'actions': [
              {'kind': 'maybe', 'label': 'Maybe'},
            ],
          },
        ]),
        replaced('items', [
          {'id': 1, 'role': 'assistant', 'text': 'x', 'screenRequest': 'open'},
        ]),
        replaced('history', [
          {'user': 1, 'assistant': 'x'},
        ]),
        replaced('lists', {'lists': 'none'}),
        replaced('pending', 'yes'),
        replaced('hostData', 7),
      ];
      for (final json in bad) {
        expect(ConversationSnapshot.tryParse(json), isNull, reason: '$json');
      }
      expect(ConversationSnapshot.tryParse(good), isNotNull);
    });

    test(
      'restore refuses a snapshot whose lists or question cannot be read, and while busy; nothing changes',
      () async {
        await converse();
        final snapshot = h.assistant.snapshot();
        final items = h.state.items;
        final broken = ConversationSnapshot(
          id: 'x',
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
          lists: const {
            'lists': [
              {'collection': 'orders'},
            ],
          },
        );
        expect(h.assistant.restore(broken), isFalse);
        final orphan = ConversationSnapshot(
          id: 'x',
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
          pending: const {
            'userText': 'x',
            'call': {'tool': 'cancel_order'},
            'itemId': 99,
            'question': 'Sure?',
          },
        );
        expect(h.assistant.restore(orphan), isFalse);
        expect(h.state.items, same(items));

        h.engine
          ..gate = Completer<void>()
          ..outputs.add('Hello.');
        final turn = h.assistant.send('hi');
        await pumpEventQueue();
        expect(h.assistant.restore(snapshot), isFalse);
        h.engine.gate!.complete();
        await turn;
      },
    );

    test('FileConversationStore: save, list (newest first), load, delete; unreadable files are skipped', () async {
      final store = FileConversationStore('${h.tmp.path}/conversations');
      expect(await store.list(), isEmpty);
      await converse();
      await store.save(h.assistant.snapshot());
      h.assistant.newConversation(id: 'b/2 ü');
      await h.say('hi', 'Hello.');
      await store.save(h.assistant.snapshot());
      File('${h.tmp.path}/conversations/conversation_junk.json').writeAsStringSync('{not json');
      final listed = await store.list();
      expect(listed.map((s) => s.id), ['b/2 ü', listed.last.id]);
      expect(listed.last.title, 'my orders?');
      expect(store.pathOf('b/2 ü'), endsWith('/conversation_b%2F2%20%C3%BC.json'));
      expect((await store.load('b/2 ü'))!.messageCount, 2);
      expect(await store.load('missing'), isNull);
      expect(await store.load('junk'), isNull);
      await store.delete('b/2 ü');
      expect((await store.list()).map((s) => s.id), [listed.last.id]);
      expect(Directory('${h.tmp.path}/conversations').listSync().where((f) => f.path.endsWith('.tmp')), isEmpty);
    });

    test('autosave saves after every call and recorded action, never an empty conversation', () async {
      final store = FileConversationStore('${h.tmp.path}/autosaved');
      final saving = autosave(h.assistant, store);
      addTearDown(saving.cancel);
      // The saves write files: wait for the one with [count] items.
      Future<int?> saved(int count) async {
        for (var i = 0; i < 500; i++) {
          final snapshot = await store.load('first');
          if (snapshot?.messageCount == count) return count;
          await Future<void>.delayed(const Duration(milliseconds: 4));
        }
        return (await store.load('first'))?.messageCount;
      }

      h.assistant.newConversation(id: 'first');
      await pumpEventQueue();
      expect(await store.list(), isEmpty, reason: 'nothing to save yet');
      await h.say('my orders?', call('list_orders'));
      expect(await saved(2), 2);
      h.assistant.recordAction('x (from the app)', const ToolCall('list_orders'), const ToolResult.ok());
      expect(await saved(4), 4);
    });

    test('autosave: one save per change, in order; never an empty conversation, never while busy', () async {
      final store = _MemoryStore();
      final saving = autosave(h.assistant, store);
      addTearDown(saving.cancel);
      h.assistant.newConversation(id: 'first');
      await pumpEventQueue();
      expect(store.saves, isEmpty, reason: 'an empty conversation');
      await h.say('my orders?', call('list_orders'));
      await pumpEventQueue();
      h.assistant.recordAction('x (from the app)', const ToolCall('list_orders'), const ToolResult.ok());
      await pumpEventQueue();
      expect(store.saves, ['first', 'first']);
      expect(store.saved['first']!.messageCount, 4);

      h.engine
        ..gate = Completer<void>()
        ..outputs.add('Hello.');
      final turn = h.assistant.send('hi');
      await pumpEventQueue();
      h.assistant.recordAction('y (from the app)', const ToolCall('list_orders'), const ToolResult.ok());
      await pumpEventQueue();
      expect(store.saves, hasLength(2), reason: 'the turn is running: its end saves');
      h.engine.gate!.complete();
      await turn;
      await pumpEventQueue();
      expect(store.saves, hasLength(3));
      expect(store.saved['first']!.messageCount, 8);
    });

    test('a codec that throws: restore keeps the stored screen request; autosave reports the error', () async {
      await converse();
      final snapshot = ConversationSnapshot.tryParse(
        jsonDecode(jsonEncode(h.assistant.snapshot(codec: const OrderScreenCodec()).toJson())),
      )!;
      final other = await ToyHarness.open();
      addTearDown(other.close);
      expect(other.assistant.restore(snapshot, codec: const _ThrowingCodec()), isTrue);
      expect(other.state.items.map((i) => i.text), h.state.items.map((i) => i.text));
      expect(other.state.items[3].screenRequest!.request, isA<StoredScreenRequest>());
      expect(other.assistant.history, h.assistant.history);

      final errors = <Object>[];
      final saving = autosave(
        h.assistant,
        _MemoryStore(),
        codec: const _ThrowingCodec(),
        onError: (error, _) => errors.add(error),
      );
      addTearDown(saving.cancel);
      h.assistant.recordAction('x (from the app)', const ToolCall('list_orders'), const ToolResult.ok());
      await pumpEventQueue();
      expect(errors, [isA<StateError>()]);
    });

    test('FileConversationStore: saves of one conversation at once end with the last, whole; a reader never sees '
        'half a file; ids that differ only in case get two files', () async {
      final folder = '${h.tmp.path}/conversations';
      final store = FileConversationStore(folder);
      await converse();
      final small = h.assistant.snapshot();
      final big = ConversationSnapshot(
        id: small.id,
        createdAt: small.createdAt,
        updatedAt: small.updatedAt,
        hostData: {'blob': 'x' * 3000000},
      );
      await store.save(small);
      var done = false;
      final saving = store.save(big).then((_) => done = true);
      var reads = 0;
      while (!done) {
        expect(await store.load(small.id), isNotNull, reason: 'the old file or the new one, whole');
        reads++;
      }
      await saving;
      expect(reads, greaterThan(0));
      expect((await store.load(small.id))!.hostData.keys, ['blob']);

      await Future.wait([store.save(big), store.save(small), store.save(big), store.save(small)]);
      expect((await store.load(small.id))!.toJson(), small.toJson(), reason: 'the last save wins');
      expect(Directory(folder).listSync().where((f) => f.path.endsWith('.tmp')), isEmpty);

      // A save never writes into the file it replaces: the file behind a link to it stays as it was.
      final path = store.pathOf(small.id);
      final kept = File('${h.tmp.path}/kept.json')..writeAsStringSync(File(path).readAsStringSync());
      File(path).deleteSync();
      Link(path).createSync(kept.path);
      await store.save(big);
      expect(ConversationSnapshot.tryParse(jsonDecode(kept.readAsStringSync()))!.toJson(), small.toJson());
      expect((await store.load(small.id))!.hostData.keys, ['blob']);

      ConversationSnapshot named(String id, int n) =>
          ConversationSnapshot(id: id, createdAt: DateTime(2026), updatedAt: DateTime(2026), hostData: {'n': n});
      await store.save(named('Chat-A', 1));
      await store.save(named('chat-a', 2));
      expect(store.pathOf('Chat-A'), endsWith('/conversation_%43hat-%41.json'));
      expect((await store.load('Chat-A'))!.hostData, {'n': 1});
      expect((await store.load('chat-a'))!.hostData, {'n': 2});
    });
  });

  group('reconfigure and setToolkit', () {
    late ToyHarness h;

    setUp(() async => h = await ToyHarness.open());
    tearDown(() => h.close());

    test('reconfigure: other texts keep the conversation and the prefix; another system prompt starts over and '
        'prepares its own prefix', () async {
      await h.say('my orders?', call('list_orders'));
      final saves = h.engine.saves;
      final phases = <AssistantPhase>[];
      h.assistant.addListener(() => phases.add(h.state.phase));
      expect(await h.assistant.reconfigure(h.assistant.config.copyWith(strings: AssistantStrings.italian)), isTrue);
      expect(phases, isEmpty);
      expect(h.state.items, hasLength(2));
      final question = await h.say('annulla il secondo', call('cancel_order', {'order_number': 2}));
      expect(question.actions.map((a) => a.label), ['Sì', 'No']);
      expect(h.engine.saves, saves);

      final id = h.state.conversationId;
      phases.clear();
      expect(
        await h.assistant.reconfigure(
          h.assistant.config.copyWith(prompt: const PromptLayout(systemPrompt: 'You sell lamps.')),
        ),
        isTrue,
      );
      // The conversation cleared (one notification), then the new prefix.
      expect(phases, [AssistantPhase.ready, AssistantPhase.loading, AssistantPhase.preparing, AssistantPhase.ready]);
      expect(h.state.items, isEmpty);
      expect(h.state.conversationId, isNot(id));
      expect(h.engine.saves, saves + 1);
      await h.say('hi', 'Hello.');
      expect(h.engine.prompts.last, contains('You sell lamps.'));
    });

    test('setToolkit starts over, unless keepConversation: then items, history and lists stay, an open question '
        'closes, and the new tools get their prefix', () async {
      await h.say('my orders?', call('list_orders'));
      final question = await h.say('cancel the second', call('cancel_order', {'order_number': 2}));
      final lamps = Toolkit.of([
        _tool(
          'list_lamps',
          (call, context) => ToolResult.list(
            collection: 'lamps',
            items: const [
              {'name': 'Arc'},
            ],
          ),
        ),
      ]);
      expect(await h.assistant.setToolkit(lamps, keepConversation: true), isTrue);
      expect(h.state.items, hasLength(4));
      expect(h.item(question.id).actions, isEmpty);
      expect(h.assistant.history.last, HistoryEntry('cancel the second', AssistantStrings.english.declined));
      expect(h.assistant.lists.versionOf('orders'), 1);
      await h.say('lamps?', call('list_lamps'));
      expect(h.engine.prompts.last, contains('"name": "list_lamps"'));
      expect(h.engine.prompts.last, isNot(contains('"name": "list_orders"')));

      expect(await h.assistant.setToolkit(h.toolkit), isTrue);
      expect(h.state.items, isEmpty);
      expect(h.toolkit.resets, 1);
    });

    test('setToolkit: other specs get their prefix, built once; equal specs keep it; keepConversation drops an open '
        'offer', () async {
      await h.say('book at the harbour', call('find_store', {'query': 'harbour'}));
      final saves = h.engine.saves;
      final phases = <AssistantPhase>[];
      h.assistant.addListener(() => phases.add(h.state.phase));
      expect(await h.assistant.setToolkit(ToyToolkit(h.shop), keepConversation: true), isTrue);
      expect(phases, isEmpty, reason: 'the same specs: the same prefix');
      expect((await h.say('yes', 'Yes to what?')).text, 'Yes to what?', reason: 'the offer was dropped');

      phases.clear();
      expect(
        await h.assistant.setToolkit(Toolkit.of(toyTools(h.shop).take(2).toList()), keepConversation: true),
        isTrue,
      );
      expect(phases, [AssistantPhase.loading, AssistantPhase.preparing, AssistantPhase.ready]);
      expect(h.engine.saves, saves + 1);
      phases.clear();
      expect(await h.assistant.setToolkit(h.toolkit, keepConversation: true), isTrue);
      expect(phases, [AssistantPhase.loading, AssistantPhase.ready], reason: 'restored');
      expect(h.engine.saves, saves + 1);
      expect(h.state.items, hasLength(4));
    });

    test('restore reads restoreOpenQuestion from the config of the moment: reconfigure changes it, setToolkit keeps '
        'it', () async {
      await h.say('my orders?', call('list_orders'));
      await h.say('cancel the second', call('cancel_order', {'order_number': 2}));
      final snapshot = h.assistant.snapshot();
      final other = await ToyHarness.open();
      addTearDown(other.close);
      List<String> buttons() => [for (final action in other.state.pendingActions) action.label];

      expect(await other.assistant.reconfigure(other.assistant.config.copyWith(restoreOpenQuestion: false)), isTrue);
      expect(other.assistant.restore(snapshot), isTrue);
      expect(buttons(), isEmpty);
      expect(await other.assistant.setToolkit(other.toolkit), isTrue);
      expect(other.assistant.config.restoreOpenQuestion, isFalse);
      expect(other.assistant.restore(snapshot), isTrue);
      expect(buttons(), isEmpty);
      expect(await other.assistant.reconfigure(other.assistant.config.copyWith(restoreOpenQuestion: true)), isTrue);
      expect(other.assistant.restore(snapshot), isTrue);
      expect(buttons(), ['Yes', 'No']);
    });

    test('refused while busy', () async {
      h.engine
        ..gate = Completer<void>()
        ..outputs.add('Hello.');
      final turn = h.assistant.send('hi');
      await pumpEventQueue();
      expect(await h.assistant.reconfigure(h.assistant.config), isFalse);
      expect(await h.assistant.setToolkit(h.toolkit), isFalse);
      h.engine.gate!.complete();
      await turn;
    });
  });

  group('running tools', () {
    test('a tool timeout gives ToolFailure(timeout) and cancels the call; the tool\'s own timeout wins', () async {
      ToolContext? slowContext;
      final (assistant, engine) = await scriptedAssistant(
        _config([
          _tool('slow', (call, context) {
            slowContext = context;
            return Completer<ToolResult>().future;
          }),
          _tool('quick', (call, context) => Completer<ToolResult>().future, timeout: const Duration(milliseconds: 1)),
        ], toolTimeout: const Duration(milliseconds: 20)),
        script: [const ScriptedTurn.toolCall('slow'), const ScriptedTurn.toolCall('quick')],
      );
      addTearDown(assistant.dispose);
      final events = <AssistantEvent>[];
      final subscription = assistant.events.listen(events.add);
      addTearDown(subscription.cancel);
      expect((await assistant.send('slow')).reply, 'failed timeout');
      expect(slowContext!.isCancelled, isTrue);
      expect((await assistant.send('quick')).reply, 'failed timeout');
      await pumpEventQueue();
      final failures = [for (final event in events.whereType<ToolFinishedEvent>()) event.outcome.result as ToolFailure];
      expect(
        [for (final failure in failures) failure.details],
        [
          {'timeout_ms': 20},
          {'timeout_ms': 1},
        ],
      );
      expect(engine.outputs, isEmpty);
    });

    test('beforeTool: a result stands for the call; null runs it, with the annotations read right before it', () async {
      final ran = <String>[];
      final gated = <String>[];
      final (assistant, engine) = await scriptedAssistant(
        _config(
          [
            _tool('allowed', (call, context) {
              ran.add(call.name);
              return const ToolResult.ok({'ran': true});
            }),
            _tool('vetoed', (call, context) {
              ran.add(call.name);
              return const ToolResult.ok();
            }),
          ],
          beforeTool: (call, context) async {
            gated.add('${call.name} ${context.source.name}');
            return call.name == 'vetoed' ? const ToolResult.error('forbidden', 'not allowed') : null;
          },
        ),
        script: [const ScriptedTurn.toolCall('allowed'), const ScriptedTurn.toolCall('vetoed')],
      );
      addTearDown(assistant.dispose);
      expect((await assistant.send('go')).reply, 'ok {"ran":true}');
      expect((await assistant.send('go on')).reply, 'failed forbidden');
      expect(ran, ['allowed']);
      await assistant.runTool(const ToolCall('vetoed'));
      expect(gated, ['allowed model', 'vetoed model'], reason: "the host's calls are not gated");
      expect(ran, ['allowed', 'vetoed']);
      expect(engine.outputs, isEmpty);

      // A screen renumbers the stores while an asynchronous gate waits: the call's annotation is read again after it.
      final open = Completer<void>();
      final h = await ToyHarness.open(
        config: (toolkit) => toyConfig(
          toolkit,
          beforeTool: (call, context) async {
            if (call.name == 'list_slots') {
              gated.add('store before: ${context.annotations['store']}');
              await open.future;
            }
            return null;
          },
        ),
      );
      addTearDown(h.close);
      await h.say('the harbour', call('find_store', {'query': 'harbour'}));
      h.engine.outputs.add(call('list_slots', {'store_number': 1}));
      final turn = h.assistant.send('the first');
      for (var i = 0; i < 20 && !gated.last.startsWith('store'); i++) {
        await pumpEventQueue();
      }
      expect(gated.last, 'store before: Harbour');
      await h.assistant.runTool(const ToolCall('find_store'));
      open.complete();
      await turn;
      expect(h.toolkit.annotations.last, {'store': 'Downtown'}, reason: 'read again right before the call');
      expect(h.last.text, startsWith('Slots at Downtown'));
    });

    test(
      'ToolErrorPolicy.reportToModel: a throw becomes ToolFailure(tool_exception, toolFailed); the turn goes on',
      () async {
        final (assistant, engine) = await scriptedAssistant(
          _config([
            _tool('broken', (call, context) => throw StateError('secret token 1234 leaked')),
          ], toolErrors: ToolErrorPolicy.reportToModel),
          script: [const ScriptedTurn.toolCall('broken')],
        );
        addTearDown(assistant.dispose);
        final events = <AssistantEvent>[];
        final subscription = assistant.events.listen(events.add);
        addTearDown(subscription.cancel);
        final outcome = await assistant.send('break');
        expect((outcome.reply, outcome.error), ('failed tool_exception', null));
        await pumpEventQueue();
        final finished = events.whereType<ToolFinishedEvent>().single;
        expect(finished.error, isA<StateError>());
        expect((finished.outcome.result as ToolFailure).message, AssistantStrings.english.toolFailed);
        expect(assistant.state.items.last.details, isNot(contains('secret')));
        expect((await assistant.runTool(const ToolCall('broken'))).ok, isFalse);
        expect(engine.outputs, isEmpty);
      },
    );

    test('ToolErrorPolicy.failTurn: runTool rethrows what the tool threw', () async {
      final (assistant, _) = await scriptedAssistant(
        _config([_tool('broken', (call, context) => throw StateError('down'))]),
      );
      addTearDown(assistant.dispose);
      await expectLater(assistant.runTool(const ToolCall('broken')), throwsStateError);
    });
  });

  group('sendStreaming', () {
    late ToyHarness h;

    setUp(() async => h = await ToyHarness.open());
    tearDown(() => h.close());

    test('the text grows in pieces, the events end with TurnFinishedEvent, both close before the outcome', () async {
      h.engine.outputs.add('Hello, how can I help you today?');
      final turn = h.assistant.sendStreaming('hi');
      final order = <String>[];
      final pieces = <String>[];
      final events = <AssistantEvent>[];
      final textDone = turn.text.listen(pieces.add).asFuture<void>().then((_) => order.add('text'));
      final eventsDone = turn.events.listen(events.add).asFuture<void>().then((_) => order.add('events'));
      final outcome = await turn.outcome.then((o) {
        order.add('outcome');
        return o;
      });
      await Future.wait([textDone, eventsDone]);
      expect(order.last, 'outcome');
      expect(pieces.length, greaterThan(1));
      expect(pieces.join(), outcome.reply);
      expect(events.first, isA<PhaseChangedEvent>());
      expect((events.first as PhaseChangedEvent).phase, AssistantPhase.busy);
      expect(events.whereType<ReplyDeltaEvent>().map((e) => e.appended).join(), outcome.reply);
      expect(events.last, isA<TurnFinishedEvent>());
      expect(events[events.length - 2], isA<ConversationChangedEvent>());
      expect((events.last as TurnFinishedEvent).outcome.reply, outcome.reply);
    });

    test('a flushed reply and a question: each reply after the first starts with a blank line', () async {
      await h.say('the stores?', call('find_store'));
      await h.say('the first', call('list_slots', {'store_number': 1}));
      h.engine.outputs.add('${call('find_store', {'query': 'harbour'})}\n${call('book_slot', {'slot_number': 1})}');
      final turn = h.assistant.sendStreaming('find the harbour and book the first');
      final text = turn.text.join();
      final events = turn.events.toList();
      final outcome = await turn.outcome;
      expect(await text, outcome.reply);
      expect(await text, contains('Do you want to see its slots?\n\nShall I book'));
      final kinds = (await events).map((e) => e.runtimeType.toString()).toList();
      expect(kinds, containsAllInOrder(['ToolStartedEvent', 'ToolFinishedEvent', 'ConfirmationRequestedEvent']));
      expect(outcome.confirmation, isNotNull);
    });

    test(
      'a replaced reply: the text stops at what was streamed; the replacement is in the events and the outcome',
      () async {
        h.engine.outputs.add('Your delivery is on 18/09 at 10:00.');
        final turn = h.assistant.sendStreaming('when?');
        final text = turn.text.join();
        final events = turn.events.toList();
        final outcome = await turn.outcome;
        expect('Your delivery is on 18/09 at 10:00.', startsWith(await text));
        expect(outcome.reply, "I don't have that information.");
        expect((await events).whereType<ReplyReplacedEvent>().single.text, "I don't have that information.");
      },
    );

    test('a refused turn has empty streams; cancel() stops the running one', () async {
      final refused = h.assistant.sendStreaming('  ');
      expect(await refused.text.toList(), isEmpty);
      expect(await refused.events.toList(), isEmpty);
      expect((await refused.outcome).rejection, TurnRejection.empty);

      h.engine
        ..gate = Completer<void>()
        ..outputs.add('Hello.');
      final turn = h.assistant.sendStreaming('hi');
      await pumpEventQueue();
      turn.cancel();
      expect((await turn.outcome).reply, 'Stopped.');
    });
  });

  group('beforeModel', () {
    test('an answer replaces the model call; context goes into the newest user message', () async {
      final requests = <TurnRequest>[];
      final h = await ToyHarness.open(
        config: (toolkit) => toyConfig(
          toolkit,
          beforeModel: (request) async {
            requests.add(request);
            if (request.text == 'opening hours?') return const TurnDirective.answer('We open at 9.');
            if (request.text == 'returns?') {
              return const TurnDirective.addContext(['Returns: 30 days.', 'Refunds: 5 days.']);
            }
            return null;
          },
        ),
      );
      addTearDown(h.close);
      final answered = await h.assistant.send('opening hours?');
      expect(answered.reply, 'We open at 9.');
      expect(answered.items.last.source, ReplySource.app);
      expect(h.engine.prompts, isEmpty);
      await h.say('returns?', 'You have 30 days.');
      expect(
        h.engine.prompts.last,
        contains(
          '<|im_start|>user\nToday is Friday, 4 September 2026.\n\nReturns: 30 days.\n\nRefunds: 5 days.\n\n'
          'returns?<|im_end|>',
        ),
      );
      expect(requests.map((r) => r.text), ['opening hours?', 'returns?']);
      expect(requests.last.window, [const HistoryEntry('opening hours?', 'We open at 9.')]);
      expect(requests.last.today, toyToday);
    });
  });

  group('events', () {
    test('tools, screens and the prefix are reported', () async {
      final h = await ToyHarness.open(load: false);
      addTearDown(h.close);
      final events = <AssistantEvent>[];
      final subscription = h.assistant.events.listen(events.add);
      addTearDown(subscription.cancel);
      await h.assistant.loadModel(h.model.path);
      await h.say('my orders?', call('list_orders'));
      await h.say('open the first', call('open_order', {'order_number': 1}));
      await pumpEventQueue();
      expect(events.whereType<PrefixPreparedEvent>().single.how, PrefixPreparation.built);
      final started = events.whereType<ToolStartedEvent>().first;
      expect(
        (started.call.name, started.source, started.label),
        ('list_orders', ToolCallSource.model, '📦 Looking up your orders...'),
      );
      final screen = events.whereType<ScreenRequestedEvent>().single;
      expect(screen.request.request.label, 'Open order A-17');
      expect(screen.itemId, h.last.id);
      expect(events.whereType<ConversationChangedEvent>().map((e) => e.change), [
        ConversationChange.exchange,
        ConversationChange.exchange,
      ]);
    });

    test('R-b: annotate runs once per execution, right before it and after toolStatusDelay; for follow-ups and '
        'runTool too (whose list keeps it)', () async {
      final asked = <String>[];
      final h = await ToyHarness.open(
        config: (toolkit) => toyConfig(toolkit).copyWith(
          toolStatusDelay: const Duration(milliseconds: 40),
          listReferences: ListReferences(
            itemArguments: toyReferences.itemArguments,
            annotate: (call, lists) {
              asked.add(call.name);
              return toyAnnotate(call, lists);
            },
          ),
        ),
      );
      addTearDown(h.close);
      await h.say('the harbour', call('find_store', {'query': 'harbour'}));
      asked.clear();

      // During the status pause a screen shows every store: the number is read after the pause.
      h.engine.outputs.add(call('list_slots', {'store_number': 1}));
      final turn = h.assistant.send('the first');
      for (var i = 0; i < 50 && h.state.items.last.status == null; i++) {
        await pumpEventQueue();
      }
      expect(h.state.items.last.status, '🗓 Looking up the slots...');
      await h.assistant.runTool(const ToolCall('find_store'));
      await turn;
      expect(asked, ['find_store', 'list_slots']);
      expect(h.toolkit.annotations.last, {'store': 'Downtown'});
      expect(h.last.text, startsWith('Slots at Downtown'));

      // A slot never shown: no question, the call refuses it, its follow-up lists the stores again.
      asked.clear();
      await h.say('book the fifth', call('book_slot', {'slot_number': 5}));
      expect(asked, ['book_slot', 'find_store']);

      asked.clear();
      await h.assistant.runTool(const ToolCall('list_slots', {'store_number': 2}));
      expect(asked, ['list_slots']);
      expect(h.assistant.lists['slots']!.annotations, {'store': 'Harbour'}, reason: 'R-d: the host list keeps it');
    });

    test('R-m: a screen is asked for after the calls of the model, a yes to a question and an offer; never after a '
        "follow-up, a host's call or a recorded action", () async {
      // A writer that offers to open the item a one-item list shows, and follows a stale list with an open.
      final writer = _ScreenWriter();
      final (assistant, engine) = await scriptedAssistant(
        AssistantConfig(
          toolkit: Toolkit.of([
            _tool(
              'find',
              (call, context) => ToolResult.list(
                collection: 'things',
                items: const [
                  {'name': 'lamp'},
                ],
              ),
            ),
            _tool('open', (call, context) => const ToolResult.ok({'opened': true}), sideEffect: SideEffect.recoverable),
            _tool(
              'remove',
              (call, context) => const ToolResult.ok({'removed': true}),
              sideEffect: SideEffect.irreversible,
            ),
            _tool('stale', (call, context) => const ToolResult.error('stale_list', 'gone')),
          ]),
          prompt: const PromptLayout(systemPrompt: 'Things.'),
          replies: AppWrittenReplies(writer),
          screenRequests: (outcome) =>
              outcome.result.ok && (outcome.call.name == 'open' || outcome.call.name == 'remove')
              ? _Screen(outcome.call.name)
              : null,
        ),
        script: [
          const ScriptedTurn.toolCall('open'),
          const ScriptedTurn.toolCall('remove'),
          const ScriptedTurn.toolCall('find'),
          const ScriptedTurn.toolCall('stale'),
        ],
      );
      addTearDown(assistant.dispose);
      final screens = <String>[];
      final subscription = assistant.events.listen((event) {
        if (event is ScreenRequestedEvent) screens.add((event.request.request as _Screen).name);
      });
      addTearDown(subscription.cancel);

      expect((await assistant.send('open it')).screenRequests, hasLength(1)); // model
      await assistant.send('remove it'); // a question
      expect((await assistant.confirm(true)).screenRequests, hasLength(1)); // confirmation
      await assistant.send('find it'); // one thing: the writer offers to open it
      expect((await assistant.send('yes')).screenRequests, hasLength(1)); // offer
      final followed = await assistant.send('the stale one'); // its follow-up is an open
      expect(followed.screenRequests, isEmpty);
      expect(writer.written.last, 'open', reason: 'the follow-up ran');
      await assistant.runTool(const ToolCall('open'));
      assistant.recordAction('Opened (from the app)', const ToolCall('open'), const ToolResult.ok({'opened': true}));
      await pumpEventQueue();
      expect(screens, ['open', 'remove', 'open']);
      expect(engine.outputs, isEmpty);
    });
  });
}

final class _Screen extends ScreenRequest {
  const _Screen(this.name);

  final String name;

  @override
  String get label => 'Show $name';
}

/// Replies with the call's name; offers `open` after a one-item list, follows a stale list with `open`.
final class _ScreenWriter implements ReplyWriter {
  final List<String> written = [];

  @override
  ToolReply write(ToolOutcome outcome) {
    written.add(outcome.call.name);
    return switch (outcome.call.name) {
      'find' => const ToolReply(text: 'One lamp. Open it?', offer: ToolCall('open')),
      'stale' => const ToolReply(text: 'The list is gone.', followUp: ToolCall('open')),
      final name => ToolReply(text: 'Done: $name.'),
    };
  }
}
