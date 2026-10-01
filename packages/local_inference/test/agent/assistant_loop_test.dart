// The assistant's turn loop, on the toy shop of support/. What the tests below pin down:
// - send and sendStreaming: a TurnOutcome, never a throw; the checks and the order of the steps of a turn.
// - offers: ToolReply.offer, bound by value (ShownLists.bind/stillNames); a yes runs it without the model
//   (ToolCallSource.offer), a no answers strings.offerDeclined; cleared on every message.
// - questions: ConfirmationRequest, ChatAction data (confirm/act), strings.yes/no/declined/listChanged, and the texts
//   they leave in the history.
// - the model's turn: beforeModel, PromptLayout.messages (window 3/1600, the date line in the newest user message),
//   ChatModel (the prefix restored inside the generation), visibleText and the rewriter per delta (a notification per
//   change), the timing line and the raw output in the details; the stop flag picks the interrupted branch (S1-S5).
// - AssistantConfig.rewriter, and OutputGuard (NumericFactsGuard) on plain answers.
// - the calls: Toolkit.coerce, an unknown tool, validation (missingData), ConfirmationPolicy (skipWhenItemNotShown);
//   earlier replies flushed into their own item, then the question.
// - one call: the status label, toolStatusDelay, ListReferences.annotate, Toolkit.execute, the list recorded,
//   ReplyWriter, the [tool] line, ScreenRequestMapper and BoundScreenRequest, ToolReply.followUp once.
// - lists: ShownLists, ListReferences and ItemBinding.
// - the host's screens: ToolHost (runTool, recordAction, isLastList, isScreenRequestCurrent; R1-R3).
// - loadModel (L1-L5), unloadModel, newConversation, setToolkit.
// - listeners: addListener after each change, the same count on every path; states and events (asynchronous); the
//   phase and loadError (the texts are the UI's).
// The rule labels (S, R, L) are those of assistant_rules_test.dart.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:local_inference/local_inference.dart';
import 'package:local_inference/testing.dart';
import 'package:test/test.dart';

import '../support/fixtures.dart';
import 'support/toy_shop.dart';

void main() {
  late ToyHarness h;

  setUp(() async => h = await ToyHarness.open());
  tearDown(() => h.close());

  test('the prefix is built once, then restored before every later call', () async {
    expect(h.engine.saves, 1);
    await h.say('hi', 'Hello, how can I help?');
    expect(h.engine.loads, 0, reason: 'the context still holds the freshly saved prefix');
    await h.say('thanks', 'You are welcome.');
    expect(h.engine.loads, 1);
    final prefix = h.assistant.model!.stablePrefix(systemPrompt: toySystemPrompt, tools: h.toolkit.specs)!;
    for (final prompt in h.engine.prompts) {
      expect(prompt.startsWith(prefix), isTrue);
    }

    // A second assistant on the same model file finds the saved state.
    final again = Assistant(
      toyConfig(h.toolkit),
      engine: () => h.engine,
      prefixStore: FilePrefixStateStore('${h.tmp.path}/states'),
    );
    addTearDown(again.dispose);
    expect(await again.loadModel(h.model.path), isTrue);
    expect(h.engine.saves, 1);
  });

  test('a prefix state the system deleted from the caches folder is rebuilt, not loaded', () async {
    await h.say('hi', 'Hello, how can I help?');
    for (final f in Directory('${h.tmp.path}/states').listSync()) {
      f.deleteSync();
    }
    await h.say('thanks', 'You are welcome.');
    expect((h.engine.saves, h.engine.loads), (2, 0));
    expect(h.last.text, 'You are welcome.');
    await h.say('ok', 'Fine.');
    expect(h.engine.loads, 1, reason: 'the rebuilt state is used from then on');
  });

  test('a list call is answered by the app and becomes plain history', () async {
    final reply = await h.say('my orders?', call('list_orders'));
    expect(reply.text, startsWith('You have 3 orders:\n1. A-17, headphones, open'));
    expect(reply.thinking, isFalse);
    expect(reply.source, ReplySource.app);

    await h.say('cancel the second', call('cancel_order', {'order_number': 2}));
    final second = h.engine.prompts.last;
    expect(
      second,
      contains('<|im_start|>user\nmy orders?<|im_end|>\n<|im_start|>assistant\nYou have 3 orders: 1. A-17, headphones'),
    );
    expect(second, contains('<|im_start|>user\nToday is Friday, 4 September 2026.\n\ncancel the second<|im_end|>'));
    expect(second, isNot(contains('Today is Friday, 4 September 2026.\n\nmy orders')));
  });

  test('cancel waits for Yes and then runs', () async {
    await h.say('my orders?', call('list_orders'));
    final question = await h.say('cancel the second', call('cancel_order', {'order_number': 2}));
    expect(question.text, 'Do you really want to cancel order B-22? It cannot be undone.');
    expect(question.actions.map((a) => a.label), ['Yes', 'No']);

    await h.assistant.send('yes');
    expect(h.item(question.id).actions, isEmpty);
    expect(h.last.text, 'Done: I cancelled order B-22.');

    await h.say('my orders?', call('list_orders'));
    expect(h.last.text, isNot(contains('B-22')));
  });

  test('booking: stores, slots, then No keeps everything as it was', () async {
    final stores = await h.say('I would like to book', call('find_store'));
    expect(stores.text, startsWith('Our stores:\n1. Downtown'));
    final slots = await h.say('the first', call('list_slots', {'store_number': 1}));
    expect(slots.text, startsWith('Slots at Downtown:\n1. Mon 7 Sep 09:00'));
    final question = await h.say('book the second', call('book_slot', {'slot_number': 2}));
    expect(question.text, 'Shall I book Mon 7 Sep 09:30 at Downtown?');
    await h.assistant.act(question.actions.last);
    expect(h.last.text, 'All right, I did nothing.');
    expect(h.state.canSend, isTrue);
    expect(h.shop.booked, isEmpty);
  });

  test("a yes to the app's own offer runs the offered call without the model", () async {
    final store = await h.say('book at the harbour', call('find_store', {'query': 'harbour'}));
    expect(store.text, endsWith('Do you want to see its slots?'));
    final calls = h.engine.prompts.length;
    await h.assistant.send('yes');
    expect(h.engine.prompts.length, calls, reason: 'no model call');
    expect(h.last.text, startsWith('Slots at Harbour:'));
    expect(h.toolkit.sources.last, ToolCallSource.offer);
    // The offer is used once: the next "yes" goes to the model.
    await h.say('yes', 'Tell me which one to book.');
    expect(h.engine.prompts.length, calls + 1);
  });

  test('an item number beyond a one-item list: the tool refuses it and the list is shown again, once', () async {
    await h.say('book at the harbour', call('find_store', {'query': 'harbour'}));
    final reply = await h.say('the second', call('list_slots', {'store_number': 2}));
    expect(reply.text, startsWith('I no longer have that list: here it is again.\n\nOur stores:\n1. Downtown'));
    expect(h.toolkit.sources.sublist(h.toolkit.sources.length - 2), [ToolCallSource.model, ToolCallSource.followUp]);
    expect(h.assistant.history.last.assistant, startsWith('I no longer have that list: here it is again. Our stores:'));
  });

  test('a booking button Yes books the slot', () async {
    await h.say('I would like to book', call('find_store'));
    await h.say('harbour', call('list_slots', {'store_number': 2}));
    final question = await h.say('the first', call('book_slot', {'slot_number': 1}));
    await h.assistant.act(question.actions.first);
    expect(h.last.text, 'Done: I booked Tue 8 Sep 10:00 at Harbour.');
    expect(h.shop.booked, ['Tue 8 Sep 10:00 at Harbour']);
  });

  test("the rewriter: the model's trained names are shown as the configured ones, app-written replies are not "
      'rewritten', () async {
    final branded = await ToyHarness.open(
      config: (toolkit) => toyConfig(
        toolkit,
        rewriter: const ReplaceText([
          ('Acme Bot', 'Shopper'),
          ('Acme City Hall', 'Springfield City Hall'),
          ('Acme', 'Springfield'),
        ]).call,
      ),
    );
    addTearDown(branded.close);
    final answer = await branded.say(
      'who are you?',
      "I'm Acme Bot, the assistant of Acme City Hall: I help with the services of Acme.",
    );
    expect(
      answer.text,
      "I'm Shopper, the assistant of Springfield City Hall: I help with the services of Springfield.",
    );
    final stores = await branded.say('outlets?', call('find_store', {'query': 'outlet'}));
    expect(stores.text, contains('Acme Outlet'), reason: 'the app wrote it');
  });

  test('an invented number in a plain answer is not shown', () async {
    final reply = await h.say('when is my delivery?', 'Your next delivery is on 18/09 at 10:00.');
    expect(reply.guarded, isTrue);
    expect(reply.source, ReplySource.guard);
    expect(reply.text, "I don't have that information.");
    expect(reply.details, endsWith('\n[guard] unverified facts: 10:00, 18/09'));
    final ok = await h.say('hi', 'Hello, how can I help?');
    expect(ok.guarded, isFalse);
    expect(ok.text, 'Hello, how can I help?');
  });

  test('a call missing a required argument asks for it', () async {
    final reply = await h.say('show me the slots', call('list_slots'));
    expect(reply.text, AssistantStrings.english.missingData);
    expect(reply.details, contains('\n[validation] list_slots: '));
  });

  test('booking an item never shown asks nothing and shows the list again', () async {
    final reply = await h.say('book the 2', call('book_slot', {'slot_number': 2}));
    expect(reply.actions, isEmpty);
    expect(reply.text, startsWith('I no longer have that list: here it is again.'));
    expect(reply.text, contains('Our stores'));
  });

  test('tool-call markup never reaches the bubble while streaming', () async {
    h.engine.outputs.add(call('list_orders'));
    final seen = <String>[];
    void listener() {
      if (h.state.items.isNotEmpty) seen.add(h.state.items.last.text);
    }

    h.assistant.addListener(listener);
    await h.assistant.send('any orders?');
    h.assistant.removeListener(listener);
    expect(seen.where((t) => t.contains('<')), isEmpty);
    expect(h.last.text, startsWith('You have 3 orders:'));
  });

  test('a screen action closes the open question: a later "ok thanks" is not a yes', () async {
    await h.say('I would like to book', call('find_store'));
    await h.say('the first', call('list_slots', {'store_number': 1}));
    final question = await h.say('book the second', call('book_slot', {'slot_number': 2}));
    expect(h.state.pendingActions.map((a) => a.label), ['Yes', 'No']);

    const booking = ToolCall('book_slot', {'slot_number': 1});
    final booked = await h.assistant.runTool(booking);
    h.assistant.recordAction('Book Mon 7 Sep 09:00 (from the app)', booking, booked);
    expect(h.item(question.id).actions, isEmpty);
    expect(h.state.pendingActions, isEmpty);

    final calls = h.engine.prompts.length;
    final reply = await h.say('ok thanks', 'You are welcome.');
    expect(h.engine.prompts.length, calls + 1, reason: 'the model answers, the old question is not run');
    expect(reply.text, 'You are welcome.');
    expect(h.shop.booked, ['Mon 7 Sep 09:00 at Downtown'], reason: 'one booking, from the screen');
  });

  test('Yes after a screen renumbered the list does nothing; the same list shown again still counts', () async {
    await h.say('my orders?', call('list_orders'));
    await h.say('cancel the second', call('cancel_order', {'order_number': 2}));
    await h.assistant.runTool(const ToolCall('list_orders', {'status': 'shipped'}));
    await h.assistant.send('yes');
    expect(h.last.text, AssistantStrings.english.listChanged);
    expect(h.state.canSend, isTrue);
    final unchanged = await h.assistant.runTool(const ToolCall('list_orders'));
    expect(unchanged.payload['count'], 3);

    await h.say('cancel the second', call('cancel_order', {'order_number': 2}));
    await h.assistant.runTool(const ToolCall('list_orders'));
    await h.assistant.act(h.state.pendingActions.first);
    expect(h.last.text, 'Done: I cancelled order B-22.');
  });

  test("the app's offer is not run once a screen renumbered its list or recorded an action", () async {
    await h.say('book at the harbour', call('find_store', {'query': 'harbour'}));
    await h.assistant.runTool(const ToolCall('find_store', {'query': 'harbour'}));
    await h.assistant.send('yes');
    expect(h.last.text, startsWith('Slots at Harbour'), reason: 'same list, same store');

    await h.say('book at the harbour', call('find_store', {'query': 'harbour'}));
    await h.assistant.runTool(const ToolCall('find_store'));
    var reply = await h.say('yes', 'Tell me which store.');
    expect(reply.text, 'Tell me which store.');

    await h.say('book at the harbour', call('find_store', {'query': 'harbour'}));
    await h.assistant.runTool(const ToolCall('list_orders'));
    const cancel = ToolCall('cancel_order', {'order_number': 1});
    final cancelled = await h.assistant.runTool(cancel);
    h.assistant.recordAction('Cancel order A-17 (from the app)', cancel, cancelled);
    reply = await h.say('ok', 'Fine.');
    expect(reply.text, 'Fine.');
  });

  test(
    'a screen action recorded during a turn goes before it; the question the turn asks keeps its Yes / No',
    () async {
      await h.say('I would like to book', call('find_store'));
      await h.say('the first', call('list_slots', {'store_number': 1}));
      h.engine
        ..gate = Completer<void>()
        ..outputs.add(call('book_slot', {'slot_number': 2}));
      final turn = h.assistant.send('book the second');
      await pumpEventQueue();
      expect(h.state.isBusy, isTrue);

      await h.assistant.runTool(const ToolCall('list_orders'));
      const cancel = ToolCall('cancel_order', {'order_number': 1});
      final cancelled = await h.assistant.runTool(cancel);
      const screenText = 'Cancel order A-17 (from the app)';
      h.assistant.recordAction(screenText, cancel, cancelled);
      h.engine.gate!.complete();
      await turn;

      final texts = h.state.items.map((i) => i.text).toList();
      expect(texts.indexOf(screenText), texts.indexOf('book the second') - 2, reason: 'chat order = history order');
      expect(h.last.text, startsWith('Shall I book'));
      expect(h.state.pendingActions.map((a) => a.label), ['Yes', 'No']);
      await h.assistant.act(h.state.pendingActions.first);
      expect(h.last.text, startsWith('Done: I booked Mon 7 Sep 09:30 at Downtown'));

      await h.say('thanks', 'You are welcome.');
      final prompt = h.engine.prompts.last;
      expect(prompt.indexOf(screenText), lessThan(prompt.indexOf('book the second')));
    },
  );

  test('answering a question also closes an offer made earlier in its turn', () async {
    await h.say('I would like to book', call('find_store'));
    await h.say('the first', call('list_slots', {'store_number': 1}));
    final question = await h.say(
      'find the harbour store and book the first',
      '${call('find_store', {'query': 'harbour'})}\n${call('book_slot', {'slot_number': 1})}',
    );
    expect(question.text, startsWith('Shall I book'));
    await h.assistant.act(h.state.pendingActions.last);
    expect(h.last.text, 'All right, I did nothing.');

    final reply = await h.say('ok', 'Tell me.');
    expect(reply.text, 'Tell me.', reason: 'the store offer is not run by a later "ok"');
  });

  test('the store of a slot list is the one named when the call started', () async {
    await h.say('book at the harbour', call('find_store', {'query': 'harbour'}));
    h.toolkit
      ..gatedTool = 'list_slots'
      ..gate = Completer<void>();
    h.engine.outputs.add(call('list_slots', {'store_number': 1}));
    final turn = h.assistant.send('the first');
    for (var i = 0; i < 20 && h.engine.outputs.isNotEmpty; i++) {
      await pumpEventQueue();
    }
    await h.assistant.runTool(const ToolCall('find_store'));
    h.toolkit.gate!.complete();
    await turn;
    expect(h.last.text, contains('Harbour'));
    expect(h.last.text, isNot(contains('Downtown')));
    final question = await h.say('book the first', call('book_slot', {'slot_number': 1}));
    expect(question.text, isNot(contains('Downtown')));
    expect(question.text, contains('Harbour'));
  });

  test('an "Open" chip stays usable when the same list is shown again', () async {
    await h.say('my orders?', call('list_orders'));
    final opened = await h.say('open the first', call('open_order', {'order_number': 1}));
    final request = opened.screenRequest!;
    expect(request.request.label, 'Open order A-17');
    await h.assistant.runTool(const ToolCall('list_orders'));
    expect(h.assistant.isScreenRequestCurrent(request), isTrue);
    await h.say('and the shipped ones?', call('list_orders', {'status': 'shipped'}));
    expect(h.assistant.isScreenRequestCurrent(request), isFalse);
  });

  test('Stop before the first token: "Stopped." and nothing goes into the history', () async {
    h.engine
      ..gate = Completer<void>()
      ..outputs.add('Hello.');
    final turn = h.assistant.send('hi');
    for (var i = 0; i < 20 && h.engine.prompts.isEmpty; i++) {
      await pumpEventQueue();
    }
    expect(h.state.isBusy, isTrue);
    h.assistant.stop();
    await turn;
    expect(h.last.text, 'Stopped.');
    expect(h.state.canSend, isTrue);
    expect(h.engine.outputs, ['Hello.'], reason: 'the generation never started');
    h.engine
      ..gate = null
      ..outputs.clear();
    await h.say('thanks', 'You are welcome.');
    expect(h.engine.prompts.last, isNot(contains('<|im_start|>user\nhi<|im_end|>')));
  });

  test('Stop while the answer streams: the text so far stays and goes into the history', () async {
    const output = 'Hello, I am here to help you with your orders.';
    h.engine.outputs.add(output);
    void stopAtFirstText() {
      if (h.state.isBusy && h.state.items.last.text.isNotEmpty) h.assistant.stop();
    }

    h.assistant.addListener(stopAtFirstText);
    await h.assistant.send('hi');
    h.assistant.removeListener(stopAtFirstText);
    final shown = h.last.text;
    expect(shown.isNotEmpty && shown.length < output.length && output.startsWith(shown), isTrue, reason: shown);
    await h.say('thanks', 'You are welcome.');
    expect(h.engine.prompts.last, contains('<|im_start|>user\nhi<|im_end|>\n<|im_start|>assistant\n$shown<|im_end|>'));
  });

  test("the config's today dates the prompt and the tools", () async {
    expect(h.assistant.today, toyToday);
    DateTime? seen;
    final dated = await ToyHarness.open(
      config: (toolkit) => toyConfig(
        toolkit,
        beforeTool: (call, context) {
          seen = context.today;
          return null;
        },
      ),
    );
    addTearDown(dated.close);
    await dated.say('orders?', call('list_orders'));
    expect(seen, toyToday);
    expect(dated.engine.prompts.last, contains('Today is Friday, 4 September 2026.\n\norders?'));
  });

  test(
    'the prefix key adds the runtime and the load settings, so a state saved under a key without them is built again',
    () async {
      final stat = h.model.statSync();
      final prefix = h.assistant.model!.stablePrefix(systemPrompt: toySystemPrompt, tools: h.toolkit.specs)!;
      // A key without the runtime and the load settings (file name, size, modification time, template, prefix).
      final oldKey = sha256
          .convert(
            utf8.encode(
              '${h.model.uri.pathSegments.last}|${stat.size}|${stat.modified.millisecondsSinceEpoch}|'
              '${h.engine.info!.chatTemplateSha256}|$prefix',
            ),
          )
          .toString()
          .substring(0, 16);
      final states = Directory('${h.tmp.path}/old-states')..createSync();
      File('${states.path}/prefix_$oldKey.state').writeAsStringSync(prefix);
      final again = Assistant(
        toyConfig(h.toolkit),
        engine: () => h.engine,
        prefixStore: FilePrefixStateStore(states.path),
      );
      addTearDown(again.dispose);
      final phases = <AssistantPhase>[];
      again.addListener(() => phases.add(again.state.phase));
      await again.loadModel(h.model.path);
      expect((h.engine.saves, again.state.phase), (2, AssistantPhase.ready));
      expect(phases, contains(AssistantPhase.preparing), reason: 'built once more');
    },
  );

  test('a prefix state that fails to load before a turn is removed and built again; the turn answers', () async {
    await h.say('hi', 'Hello, how can I help?');
    h.engine.failNextLoadState = 'corrupt state';
    final reply = await h.say('thanks', 'You are welcome.');
    expect(reply.text, 'You are welcome.');
    expect((h.engine.saves, h.engine.loads), (2, 1));
    expect(h.state.phase, AssistantPhase.ready);
    await h.say('ok', 'Fine.');
    expect(h.engine.loads, 2, reason: 'the rebuilt state is used from then on');
  });

  test('a model whose template the profile does not accept fails to load and is freed; an accepting profile '
      'loads it', () async {
    final stock = ScriptedEngine(chatTemplate: '$template4b\n');
    Assistant assistant(Set<String>? accepted) => Assistant(
      toyConfig(h.toolkit, profile: Qwen35Profile(acceptedTemplateSha256: accepted)),
      engine: () => stock,
      prefixStore: FilePrefixStateStore('${h.tmp.path}/states'),
    );
    final trained = assistant({sha256.convert(utf8.encode(template4b)).toString()});
    addTearDown(trained.dispose);
    expect(await trained.loadModel(h.model.path), isFalse);
    expect(trained.state.phase, AssistantPhase.failed);
    expect(trained.state.loadError, isA<UnsupportedModelException>());
    expect('${trained.state.loadError}', contains(sha256.convert(utf8.encode(stock.chatTemplate)).toString()));
    expect(stock.disposes, 1, reason: 'the refused model does not stay in memory');
    final any = assistant(null);
    addTearDown(any.dispose);
    expect(await any.loadModel(h.model.path), isTrue);
    expect(any.state.phase, AssistantPhase.ready);
  });

  test('Stop during the prefix restore (before the engine call): "Stopped.", the generation never starts', () async {
    await h.say('hi', 'Hello, how can I help?');
    h.engine.outputs.add('You are welcome.');
    final loads = h.engine.loads;
    final turn = h.assistant.send('thanks');
    h.assistant.stop(); // the restore of this turn has not run yet
    await turn;
    expect(h.engine.loads, loads + 1, reason: 'the prefix was restored');
    expect(h.last.text, 'Stopped.');
    expect(h.engine.outputs, ['You are welcome.'], reason: 'the generation never started');
  });
}
