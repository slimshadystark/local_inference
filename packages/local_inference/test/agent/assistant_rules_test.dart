// The assistant's rules, labeled here for reference: stop (S1-S5), recordAction (R1-R3), errors (E1-E4), the
// loadModel order (L), the prefix key (P), and the listener notifications (the same count on every path), immutable
// items, and refused calls.
import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:local_inference/local_inference.dart';
import 'package:local_inference/testing.dart';
import 'package:test/test.dart';

import '../support/fixtures.dart';
import 'support/toy_shop.dart';

/// A toolkit that answers [stale] tools with a stale-list failure (their follow-up lists the orders again) and throws
/// for [throwing] ones.
final class _FailingToolkit extends DelegatingToolkit {
  _FailingToolkit(super.inner);

  final Set<String> throwing = {};
  final Set<String> stale = {};

  @override
  Future<ToolResult> execute(ToolCall call, ToolContext context) async {
    if (throwing.contains(call.name)) throw StateError('${call.name} is down');
    if (stale.contains(call.name)) {
      return const ToolResult.error(
        'stale_list',
        'the list changed',
        details: {
          'relist': {'tool': 'list_orders', 'args': <String, Object?>{}},
        },
      );
    }
    return inner.execute(call, context);
  }
}

/// An engine that holds each result back until [release] completes, after its last delta.
final class _HoldingEngine implements InferenceEngine {
  _HoldingEngine(this.inner);

  final ScriptedEngine inner;
  Completer<void>? release;

  @override
  Future<EngineInfo> load(String modelPath, [LoadOptions options = const LoadOptions()]) =>
      inner.load(modelPath, options);

  @override
  bool get isLoaded => inner.isLoaded;

  @override
  EngineInfo? get info => inner.info;

  @override
  int get contextEpoch => inner.contextEpoch;

  @override
  Generation generate(String prompt, [GenerationOptions options = const GenerationOptions()]) =>
      _Held(inner.generate(prompt, options), release?.future);

  @override
  Future<List<int>> tokenize(String text) => inner.tokenize(text);

  @override
  Future<int> countTokens(String text) => inner.countTokens(text);

  @override
  bool get supportsStatePersistence => inner.supportsStatePersistence;

  @override
  Future<SavedState> saveState(String path, String promptPrefix) => inner.saveState(path, promptPrefix);

  @override
  Future<int> loadState(String path) => inner.loadState(path);

  @override
  Future<void> dispose() => inner.dispose();
}

final class _Held implements Generation {
  _Held(this._inner, this._release);

  final Generation _inner;
  final Future<void>? _release;

  @override
  Stream<String> get text => _inner.text;

  @override
  Future<GenerationResult> get result => _inner.result.then((result) async {
    await _release;
    return result;
  });

  @override
  void cancel() => _inner.cancel();
}

/// A ScriptedEngine that writes its loads and disposals to [log].
final class _LoggingEngine extends ScriptedEngine {
  _LoggingEngine(this.name, this.log, {super.chatTemplate, this.failLoad = false});

  final String name;
  final List<String> log;
  final bool failLoad;

  @override
  Future<EngineInfo> load(String modelPath, [LoadOptions options = const LoadOptions()]) async {
    log.add('load $name');
    if (failLoad) throw const ModelLoadException('not a model');
    return super.load(modelPath, options);
  }

  @override
  Future<void> dispose() {
    log.add('dispose $name');
    return super.dispose();
  }
}

/// [ToyWriter], but it throws on a list of orders.
final class _NoOrdersWriter implements ReplyWriter {
  const _NoOrdersWriter();

  @override
  ToolReply write(ToolOutcome outcome) {
    if (outcome.shownList?.collection == 'orders') throw StateError('cannot write the orders');
    return const ToyWriter().write(outcome);
  }
}

/// A writer that remembers the outcomes it wrote for, over [ToyWriter].
final class _SpyWriter implements ReplyWriter {
  final List<ToolOutcome> outcomes = [];

  @override
  ToolReply write(ToolOutcome outcome) {
    outcomes.add(outcome);
    return const ToyWriter().write(outcome);
  }
}

void main() {
  late ToyHarness h;

  tearDown(() => h.close());

  group('S: stop()', () {
    setUp(() async => h = await ToyHarness.open());

    test(
      'S1: while busy, stop() cancels the generation and completes the cancelled future of a running tool',
      () async {
        var stopped = false;
        final waiting = await ToyHarness.open(
          config: (toolkit) => toyConfig(
            Toolkit.of([
              AssistantTool(
                name: 'wait',
                description: 'Waits to be stopped.',
                run: (call, context) async {
                  await context.cancelled;
                  stopped = context.isCancelled;
                  return const ToolResult.ok({'stopped': true});
                },
              ),
            ]),
          ),
        );
        addTearDown(waiting.close);
        waiting.engine.outputs.add(call('wait'));
        final turn = waiting.assistant.send('wait');
        await pumpEventQueue();
        expect(waiting.state.isBusy, isTrue);
        waiting.assistant.stop();
        await turn;
        expect(stopped, isTrue);
        expect(waiting.last.text, 'Done.', reason: 'the tool finished and its reply was written');

        // Not busy: stop() does nothing, and the next turn answers.
        h.assistant.stop();
        expect((await h.say('hi', 'Hello.')).text, 'Hello.');
      },
    );

    test('S2: a generation created while the flag is set is cancelled before its engine call', () async {
      await h.say('hi', 'Hello.');
      h.engine.outputs.add('You are welcome.');
      final loads = h.engine.loads;
      void stopWhenBusy() {
        if (h.state.isBusy) h.assistant.stop();
      }

      h.assistant.addListener(stopWhenBusy);
      await h.assistant.send('thanks');
      h.assistant.removeListener(stopWhenBusy);
      expect(h.last.text, 'Stopped.');
      expect(h.engine.outputs, ['You are welcome.'], reason: 'the engine never generated');
      expect(h.engine.loads, loads + 1, reason: 'the prefix restore still ran');
    });

    test('S3: after the last delta the flag still picks the interrupted branch; no tool call runs', () async {
      final holding = _HoldingEngine(ScriptedEngine(chatTemplate: template4b));
      final held = await ToyHarness.open(engine: holding.inner);
      addTearDown(held.close);
      // Rebuilt on the holding engine.
      final assistant = Assistant(
        toyConfig(held.toolkit),
        engine: () => holding,
        prefixStore: FilePrefixStateStore('${held.tmp.path}/states'),
      );
      addTearDown(assistant.dispose);
      await assistant.loadModel(held.model.path);

      holding
        ..release = Completer<void>()
        ..inner.outputs.add(call('list_orders'));
      final turn = assistant.send('my orders?');
      for (var i = 0; i < 20 && holding.inner.outputs.isNotEmpty; i++) {
        await pumpEventQueue();
      }
      await pumpEventQueue();
      assistant.stop();
      holding.release!.complete();
      final outcome = await turn;
      expect(outcome.reply, 'Stopped.');
      expect(held.toolkit.calls, isEmpty, reason: 'the complete tool call is not run');
      expect(assistant.history, isEmpty);

      holding
        ..release = Completer<void>()
        ..inner.outputs.add('Hello there.');
      final second = assistant.send('hi');
      for (var i = 0; i < 20 && holding.inner.outputs.isNotEmpty; i++) {
        await pumpEventQueue();
      }
      await pumpEventQueue();
      assistant.stop();
      holding.release!.complete();
      expect((await second).reply, 'Hello there.', reason: 'the text so far stays');
      expect(assistant.history, [const HistoryEntry('hi', 'Hello there.')]);
    });

    test('S4: during a tool, an offer or a confirmation, stop() changes nothing: the tool finishes, its reply is '
        'written', () async {
      h.toolkit
        ..gatedTool = 'list_orders'
        ..gate = Completer<void>();
      h.engine.outputs.add(call('list_orders'));
      final turn = h.assistant.send('my orders?');
      for (var i = 0; i < 20 && h.toolkit.calls.isEmpty; i++) {
        await pumpEventQueue();
      }
      h.assistant.stop();
      h.toolkit.gate!.complete();
      expect((await turn).reply, startsWith('You have 3 orders'));
      expect(h.assistant.history.last.assistant, startsWith('You have 3 orders'));

      await h.say('cancel the second', call('cancel_order', {'order_number': 2}));
      h.toolkit
        ..gatedTool = 'cancel_order'
        ..gate = Completer<void>();
      final confirmed = h.assistant.confirm(true);
      for (var i = 0; i < 20 && h.toolkit.calls.last.name != 'cancel_order'; i++) {
        await pumpEventQueue();
      }
      h.assistant.stop();
      h.toolkit.gate!.complete();
      expect((await confirmed).reply, 'Done: I cancelled order B-22.');

      await h.say('book at the harbour', call('find_store', {'query': 'harbour'}));
      h.toolkit
        ..gatedTool = 'list_slots'
        ..gate = Completer<void>();
      final offer = h.assistant.send('yes');
      for (var i = 0; i < 20 && h.toolkit.calls.last.name != 'list_slots'; i++) {
        await pumpEventQueue();
      }
      h.assistant.stop();
      h.toolkit.gate!.complete();
      expect((await offer).reply, startsWith('Slots at Harbour'));
    });

    test('S5: the flag resets when the next model turn starts', () async {
      h.toolkit
        ..gatedTool = 'list_orders'
        ..gate = Completer<void>();
      h.engine.outputs.add(call('list_orders'));
      final turn = h.assistant.send('my orders?');
      for (var i = 0; i < 20 && h.toolkit.calls.isEmpty; i++) {
        await pumpEventQueue();
      }
      h.assistant.stop();
      h.toolkit.gate!.complete();
      await turn;
      expect((await h.say('hi', 'Hello.')).text, 'Hello.', reason: 'the stop of the tool does not reach this turn');
    });
  });

  group('R: recordAction', () {
    setUp(() async => h = await ToyHarness.open());

    test('R1: while busy, the exchange goes before the running turn and into the history at once; the question the '
        'turn ends with stays open', () async {
      await h.say('I would like to book', call('find_store'));
      await h.say('the first', call('list_slots', {'store_number': 1}));
      h.engine
        ..gate = Completer<void>()
        ..outputs.add(call('book_slot', {'slot_number': 2}));
      final turn = h.assistant.send('book the second');
      await pumpEventQueue();
      const cancel = ToolCall('cancel_order', {'order_number': 1});
      await h.assistant.runTool(const ToolCall('list_orders'));
      final reply = h.assistant.recordAction('Cancel A-17 (from the app)', cancel, await h.assistant.runTool(cancel));
      expect(reply.text, 'Done: I cancelled order A-17.');
      expect(
        h.assistant.history.last,
        const HistoryEntry('Cancel A-17 (from the app)', 'Done: I cancelled order A-17.'),
      );
      h.engine.gate!.complete();
      await turn;
      expect(h.state.pendingActions, hasLength(2));
      expect(h.assistant.history.map((e) => e.user).toList(), [
        'I would like to book',
        'the first',
        'Cancel A-17 (from the app)',
      ], reason: 'the question adds no exchange');
    });

    test('R2: otherwise the offer is dropped, an open question closes with (its text, declined), then the exchange '
        'is appended', () async {
      await h.say('my orders?', call('list_orders'));
      final question = await h.say('cancel the second', call('cancel_order', {'order_number': 2}));
      const cancel = ToolCall('cancel_order', {'order_number': 1});
      h.assistant.recordAction('Cancel A-17 (from the app)', cancel, await h.assistant.runTool(cancel));
      expect(h.item(question.id).actions, isEmpty);
      expect(h.assistant.history.sublist(1), [
        HistoryEntry('cancel the second', AssistantStrings.english.declined),
        const HistoryEntry('Cancel A-17 (from the app)', 'Done: I cancelled order A-17.'),
      ]);
      await h.say('thanks', 'You are welcome.');
      expect(
        h.engine.prompts.last,
        contains(
          '<|im_start|>user\ncancel the second<|im_end|>\n<|im_start|>assistant\nAll right, I did nothing.<|im_end|>\n'
          '<|im_start|>user\nCancel A-17 (from the app)<|im_end|>',
        ),
      );

      // The offer.
      await h.say('book at the harbour', call('find_store', {'query': 'harbour'}));
      h.assistant.recordAction('Opened the map (from the app)', const ToolCall('list_orders'), const ToolResult.ok());
      expect((await h.say('yes', 'Yes to what?')).text, 'Yes to what?', reason: 'the offer is gone');
    });

    test(
      "R2, flushed: a question whose turn's earlier replies went into their own item closes with ('', declined)",
      () async {
        await h.say('I would like to book', call('find_store'));
        await h.say('the first', call('list_slots', {'store_number': 1}));
        await h.say(
          'find the harbour store and book the first',
          '${call('find_store', {'query': 'harbour'})}\n${call('book_slot', {'slot_number': 1})}',
        );
        expect(h.assistant.history.last.user, 'find the harbour store and book the first');
        const cancel = ToolCall('cancel_order', {'order_number': 1});
        await h.assistant.runTool(const ToolCall('list_orders'));
        h.assistant.recordAction('Cancel A-17 (from the app)', cancel, await h.assistant.runTool(cancel));
        expect(h.assistant.history.reversed.skip(1).first, HistoryEntry('', AssistantStrings.english.declined));
        await h.say('thanks', 'You are welcome.');
        expect(
          h.engine.prompts.last,
          contains('<|im_start|>user\n<|im_end|>\n<|im_start|>assistant\nAll right, I did nothing.<|im_end|>'),
          reason: 'the empty user text is rendered as it is',
        );
      },
    );

    test('R3: no annotations, no follow-up, no offer, no list, no screen request', () async {
      final spy = _SpyWriter();
      final recorded = await ToyHarness.open(config: (toolkit) => toyConfig(toolkit, replies: AppWrittenReplies(spy)));
      addTearDown(recorded.close);
      final events = <AssistantEvent>[];
      final subscription = recorded.assistant.events.listen(events.add);
      addTearDown(subscription.cancel);
      await recorded.say('I would like to book', call('find_store'));
      final version = recorded.assistant.lists.versionOf('stores');
      final calls = recorded.toolkit.calls.length;

      // A one-store result offers its slots; a stale-list failure asks for a follow-up; an opened order is a screen.
      final oneStore = await recorded.assistant.runTool(const ToolCall('find_store', {'query': 'harbour'}));
      final beforeRecord = recorded.assistant.lists.versionOf('stores');
      final reply = recorded.assistant.recordAction('Harbour (from the app)', const ToolCall('find_store'), oneStore);
      expect(reply.offer, isNotNull, reason: "the writer's reply is returned whole");
      expect(spy.outcomes.last.annotations, isEmpty);
      expect(spy.outcomes.last.source, ToolCallSource.host);
      expect(recorded.assistant.lists.versionOf('stores'), beforeRecord, reason: 'no list recorded');
      expect(beforeRecord, version + 1, reason: 'runTool recorded its own list');
      recorded.assistant.recordAction(
        'Stale (from the app)',
        const ToolCall('cancel_order', {'order_number': 9}),
        const ToolResult.error(
          'stale_list',
          'gone',
          details: {
            'relist': {'tool': 'list_orders'},
          },
        ),
      );
      recorded.assistant.recordAction(
        'Opened A-17 (from the app)',
        const ToolCall('open_order', {'order_number': 1}),
        const ToolResult.ok({'opened': 'A-17', 'n': 1}),
      );
      expect(recorded.toolkit.calls.length, calls + 1, reason: 'only runTool ran a tool');
      expect((await recorded.say('yes', 'Yes to what?')).text, 'Yes to what?', reason: 'no offer');
      await pumpEventQueue();
      expect(events.whereType<ScreenRequestedEvent>(), isEmpty);
    });
  });

  group('E: errors', () {
    late _FailingToolkit failing;

    setUp(() async {
      h = await ToyHarness.open(wrap: (toolkit) => TestToolkit(failing = _FailingToolkit(toolkit)));
    });

    test('E1: a model turn that throws answers strings.error, replaces the details with the error and adds no '
        'history', () async {
      final events = <AssistantEvent>[];
      final subscription = h.assistant.events.listen(events.add);
      addTearDown(subscription.cancel);
      h.engine.outputs.add(call('broken'));
      final outcome = await h.assistant.send('break it');
      expect(outcome.reply, AssistantStrings.english.error);
      expect(outcome.error, isA<StateError>());
      expect(h.last.details, 'Bad state: backend down', reason: 'the timing line and the raw output are gone');
      expect(h.last.source, ReplySource.error);
      expect(h.assistant.history, isEmpty);
      await pumpEventQueue();
      expect(events.whereType<TurnFailedEvent>().single.error, isA<StateError>());
      expect(events.last, isA<TurnFinishedEvent>());
    });

    test('E2: an error on the confirmation or offer path is appended to the details', () async {
      await h.say('my orders?', call('list_orders'));
      await h.say('cancel the second', call('cancel_order', {'order_number': 2}));
      failing
        ..stale.add('cancel_order')
        ..throwing.add('list_orders');
      final outcome = await h.assistant.confirm(true);
      expect(outcome.reply, AssistantStrings.english.error);
      expect(
        h.last.details,
        '[tool] cancel_order {"order_number":2} → {"error":"the list changed","code":"stale_list",'
        '"relist":{"tool":"list_orders","args":{}}}\nBad state: list_orders is down',
      );
      expect(h.state.canSend, isTrue);

      failing.throwing.add('list_slots');
      await h.say('book at the harbour', call('find_store', {'query': 'harbour'}));
      await h.assistant.send('yes');
      expect(h.last.text, AssistantStrings.english.error);
      expect(h.last.details, 'Bad state: list_slots is down');
    });

    test("E3: an offer set by an earlier call survives a later call's throw", () async {
      h.engine.outputs.add('${call('find_store', {'query': 'harbour'})}\n${call('broken')}');
      expect((await h.assistant.send('the harbour store, and break it')).reply, AssistantStrings.english.error);
      final calls = h.engine.prompts.length;
      await h.assistant.send('yes');
      expect(h.engine.prompts.length, calls, reason: 'the offer ran without the model');
      expect(h.last.text, startsWith('Slots at Harbour'));
    });

    test(
      'a reply writer that throws on a list leaves it unrecorded (the reply is written before its list is recorded); '
      "a follow-up's list too",
      () async {
        final writing = await ToyHarness.open(
          config: (toolkit) => toyConfig(toolkit, replies: const AppWrittenReplies(_NoOrdersWriter())),
        );
        addTearDown(writing.close);
        expect((await writing.say('my orders?', call('list_orders'))).text, AssistantStrings.english.error);
        expect(writing.assistant.lists.versionOf('orders'), 0);
        expect(writing.assistant.isLastList('orders', const ToolCall('list_orders')), isFalse);
        // A number never shown: the call refuses it, and its follow-up lists the orders again.
        expect(
          (await writing.say('cancel the fifth', call('cancel_order', {'order_number': 5}))).text,
          AssistantStrings.english.error,
        );
        expect(writing.toolkit.calls.map((c) => c.name), ['list_orders', 'cancel_order', 'list_orders']);
        expect(writing.assistant.lists.versionOf('orders'), 0);
      },
    );

    test(
      'E4: a failed load keeps the previous model path; its engine was disposed; loading that path again works',
      () async {
        final log = <String>[];
        var next = 0;
        final engines = [
          _LoggingEngine('first', log, chatTemplate: template4b),
          _LoggingEngine('broken', log, chatTemplate: template4b, failLoad: true),
          _LoggingEngine('again', log, chatTemplate: template4b),
        ];
        final assistant = Assistant(
          toyConfig(h.toolkit),
          engine: () => engines[next++],
          prefixStore: FilePrefixStateStore('${h.tmp.path}/states'),
        );
        addTearDown(assistant.dispose);
        expect(await assistant.loadModel(h.model.path), isTrue);
        final info = assistant.state.info;
        expect(await assistant.loadModel('${h.tmp.path}/other.gguf'), isFalse);
        expect(assistant.state.phase, AssistantPhase.failed);
        expect(assistant.state.loadError, isA<ModelLoadException>());
        expect(assistant.state.modelPath, h.model.path);
        expect(assistant.state.info, same(info));
        expect(log, ['load first', 'dispose first', 'load broken', 'dispose broken']);
        expect((await assistant.send('hi')).rejection, TurnRejection.notReady);
        expect(await assistant.loadModel(assistant.state.modelPath!), isTrue, reason: 'Retry');
        expect(assistant.state.phase, AssistantPhase.ready);
      },
    );
  });

  group('L: loadModel', () {
    setUp(() async => h = await ToyHarness.open(load: false));

    test('the old engine is disposed before the new one is created; the template is checked; a refused model is '
        'freed; the prefix is prepared (preparing only to build); items and history stay', () async {
      final log = <String>[];
      final phases = <AssistantPhase>[];
      var next = 0;
      final engines = [
        _LoggingEngine('first', log, chatTemplate: template4b),
        _LoggingEngine('second', log, chatTemplate: template4b),
        _LoggingEngine('refused', log, chatTemplate: '$template4b\n'),
      ];
      final assistant = Assistant(
        // The accepted template: the 4B one.
        toyConfig(
          h.toolkit,
          profile: Qwen35Profile(acceptedTemplateSha256: {sha256.convert(utf8.encode(template4b)).toString()}),
        ),
        engine: () {
          log.add('create ${engines[next].name}');
          return engines[next++];
        },
        prefixStore: FilePrefixStateStore('${h.tmp.path}/states'),
      );
      addTearDown(assistant.dispose);
      assistant.addListener(() => phases.add(assistant.state.phase));

      expect(await assistant.loadModel(h.model.path), isTrue);
      expect(phases, [AssistantPhase.loading, AssistantPhase.preparing, AssistantPhase.ready]);
      final engine = engines[0];
      engine.outputs.add('Hello.');
      await assistant.send('hi');

      phases.clear();
      expect(await assistant.loadModel(h.model.path), isTrue);
      expect(phases, [AssistantPhase.loading, AssistantPhase.ready], reason: 'restored: no preparing');
      expect(log, ['create first', 'load first', 'dispose first', 'create second', 'load second']);
      expect(assistant.state.items.map((i) => i.text), ['hi', 'Hello.'], reason: 'the conversation stays');
      expect(assistant.history, [const HistoryEntry('hi', 'Hello.')]);

      phases.clear();
      log.clear();
      expect(await assistant.loadModel(h.model.path), isFalse);
      expect(phases, [AssistantPhase.loading, AssistantPhase.failed]);
      expect(log, ['dispose second', 'create refused', 'load refused', 'dispose refused']);
      expect(assistant.state.loadError, isA<UnsupportedModelException>());
    });

    test('tools on a model with no tool-call format: the load is refused and the model freed; without tools it '
        'loads, and tools set later are refused', () async {
      const chatml =
          '{% for m in messages %}<|im_start|>{{ m.role }}\n{{ m.content }}<|im_end|>\n{% endfor %}'
          '{% if add_generation_prompt %}<|im_start|>assistant\n{% endif %}';
      final log = <String>[];
      final engine = _LoggingEngine('plain', log, chatTemplate: chatml);
      final tools = [AssistantTool(name: 'ping', description: 'Pings.', run: (call, context) => const ToolResult.ok())];
      final withTools = Assistant(
        AssistantConfig.basic(systemPrompt: 'Be brief.', tools: tools),
        engine: () => engine,
        prefixStore: InMemoryPrefixStateStore(),
      );
      addTearDown(withTools.dispose);
      expect(await withTools.loadModel(h.model.path), isFalse);
      expect(withTools.state.phase, AssistantPhase.failed);
      expect(withTools.state.loadError, isA<UnsupportedModelException>());
      expect(log, ['load plain', 'dispose plain']);

      final plain = Assistant(
        AssistantConfig.basic(systemPrompt: 'Be brief.'),
        engine: () => engine,
        prefixStore: InMemoryPrefixStateStore(),
      );
      addTearDown(plain.dispose);
      expect(await plain.loadModel(h.model.path), isTrue);
      expect(plain.model!.profile, isA<TextOnlyProfile>());
      engine.outputs.add('Hi.');
      expect((await plain.send('hello')).reply, 'Hi.');
      expect(await plain.setToolkit(Toolkit.of(tools)), isFalse);
      expect(plain.state.phase, AssistantPhase.failed);
      expect(plain.state.loadError, isA<UnsupportedModelException>());
    });

    test('ignored while loading, preparing or busy', () async {
      final engine = ScriptedEngine(chatTemplate: template4b);
      final assistant = Assistant(
        toyConfig(h.toolkit),
        engine: () => engine,
        prefixStore: FilePrefixStateStore('${h.tmp.path}/states'),
      );
      addTearDown(assistant.dispose);
      final first = assistant.loadModel(h.model.path);
      expect(await assistant.loadModel(h.model.path), isFalse, reason: 'loading');
      expect(await assistant.unloadModel(), isFalse, reason: 'loading');
      expect(await first, isTrue);
      engine
        ..gate = Completer<void>()
        ..outputs.add('Hello.');
      final turn = assistant.send('hi');
      await pumpEventQueue();
      expect(await assistant.loadModel(h.model.path), isFalse, reason: 'busy');
      expect(await assistant.unloadModel(), isFalse, reason: 'busy');
      expect(assistant.newConversation(), isFalse, reason: 'busy');
      engine.gate!.complete();
      await turn;
      expect(await assistant.unloadModel(), isTrue);
      expect(
        (assistant.state.phase, assistant.state.modelPath, assistant.state.info),
        (AssistantPhase.noModel, null, null),
      );
    });
  });

  group('P: the prefix key', () {
    setUp(() async => h = await ToyHarness.open(load: false));

    test("the model file's name, size and time, the template, the runtime and the load settings; never anything "
        'else', () async {
      final engine = ScriptedEngine(chatTemplate: template4b);
      final store = InMemoryPrefixStateStore();
      addTearDown(store.clear);
      Assistant assistant(LoadOptions load) =>
          Assistant(toyConfig(h.toolkit), engine: () => engine, prefixStore: store, load: load);
      final first = assistant(const LoadOptions());
      addTearDown(first.dispose);
      expect(await first.loadModel(h.model.path), isTrue);
      final prefix = first.model!.stablePrefix(systemPrompt: toySystemPrompt, tools: h.toolkit.specs)!;
      final key = PrefixKey.of(engine.info!, await ModelIdentity.ofFile(h.model.path), prefix);
      expect(store.puts, [key.id]);
      // The file's name, size and modification time as one stat gives them (as ModelIdentity.ofFile reads them).
      final stat = h.model.statSync();
      expect(
        key,
        PrefixKey.of(
          engine.info!,
          ModelIdentity.fixed(
            h.model.uri.pathSegments.last,
            sizeBytes: stat.size,
            modifiedMs: stat.modified.millisecondsSinceEpoch,
          ),
          prefix,
        ),
      );

      // Unloaded and loaded again: the same key, restored.
      await first.unloadModel();
      expect(await first.loadModel(h.model.path), isTrue);
      expect((engine.saves, store.puts.length), (1, 1));

      // The file changed: another key.
      h.model.setLastModifiedSync(DateTime(2026, 9, 1));
      expect(await first.loadModel(h.model.path), isTrue);
      expect(engine.saves, 2);

      // Other load settings: another key.
      final other = assistant(const LoadOptions(contextTokens: 8192));
      addTearDown(other.dispose);
      expect(await other.loadModel(h.model.path), isTrue);
      expect(engine.saves, 3);

      // An identity given by the host replaces the file's.
      expect(await other.loadModel(h.model.path, identity: const ModelIdentity.fixed('toy.gguf')), isTrue);
      expect(engine.saves, 4);
      expect(store.puts.last, PrefixKey.of(engine.info!, const ModelIdentity.fixed('toy.gguf'), prefix).id);
    });
  });

  group('notifications at the chat controller\'s sites', () {
    setUp(() async => h = await ToyHarness.open(engine: ScriptedEngine(chatTemplate: template4b, chunkSize: 1)));

    Future<int> count(Future<void> Function() action) async {
      var n = 0;
      void listener() => n++;
      h.assistant.addListener(listener);
      await action();
      h.assistant.removeListener(listener);
      return n;
    }

    test('one per phase change, visible change, status, finished reply, question, cleared buttons and added user '
        'item; none for stop and runTool', () async {
      // A plain answer of 6 characters: busy, 6 visible changes, ready.
      expect(await count(() => h.say('hi', 'Hello.')), 1 + 6 + 1);
      // A tool call (no visible text): busy, status, finished reply, ready.
      expect(await count(() => h.say('my orders?', call('list_orders'))), 4);
      // A question: busy, question, ready.
      expect(await count(() => h.say('cancel the second', call('cancel_order', {'order_number': 2}))), 3);
      // A yes typed: buttons cleared, user item, busy, status, finished reply, ready.
      expect(await count(() => h.assistant.send('yes')), 6);
      // A no tapped: buttons cleared, user item, busy, finished reply, ready.
      await h.say('cancel the first', call('cancel_order', {'order_number': 1}));
      expect(await count(() => h.assistant.act(h.state.pendingActions.last)), 5);
      // A yes to an offer: busy, status, finished reply, ready.
      await h.say('book at the harbour', call('find_store', {'query': 'harbour'}));
      expect(await count(() => h.assistant.send('yes')), 4);
      // A flushed reply then a question: busy, status, finished reply, question, ready.
      await h.say('the stores?', call('find_store'));
      await h.say('the first', call('list_slots', {'store_number': 1}));
      expect(
        await count(
          () => h.say(
            'and the harbour, book the first',
            '${call('find_store', {'query': 'harbour'})}\n${call('book_slot', {'slot_number': 1})}',
          ),
        ),
        5,
      );
      // Another text drops the question: buttons cleared, busy, 5 visible changes, ready.
      expect(await count(() => h.say('later', 'Fine.')), 1 + 1 + 5 + 1);
      // Invalid arguments: busy, finished reply, ready.
      expect(await count(() => h.say('the slots', call('list_slots'))), 3);
      // A failing turn: busy, status, ready.
      expect(await count(() => h.say('break it', call('broken'))), 3);
      // stop() while idle and runTool: none.
      expect(await count(() async => h.assistant.stop()), 0);
      expect(await count(() => h.assistant.runTool(const ToolCall('list_orders'))), 0);
      // recordAction: one; with a question open, two (the buttons, then the exchange).
      expect(
        await count(() async => h.assistant.recordAction('x', const ToolCall('list_orders'), const ToolResult.ok())),
        1,
      );
      await h.say('cancel the first', call('cancel_order', {'order_number': 1}));
      expect(
        await count(() async => h.assistant.recordAction('y', const ToolCall('list_orders'), const ToolResult.ok())),
        2,
      );
      // newConversation: one.
      expect(await count(() async => h.assistant.newConversation()), 1);
    });

    test('loadModel: loading, preparing, ready to build; loading, ready to restore; unloadModel: one', () async {
      final assistant = Assistant(
        toyConfig(h.toolkit),
        engine: () => h.engine,
        prefixStore: FilePrefixStateStore('${h.tmp.path}/other-states'),
      );
      addTearDown(assistant.dispose);
      var n = 0;
      assistant.addListener(() => n++);
      await assistant.loadModel(h.model.path);
      expect(n, 3);
      n = 0;
      await assistant.loadModel(h.model.path);
      expect(n, 2);
      n = 0;
      await assistant.unloadModel();
      expect(n, 1);
    });

    test('states delivers one state per notification, asynchronously', () async {
      final states = <AssistantState>[];
      final subscription = h.assistant.states.listen(states.add);
      addTearDown(subscription.cancel);
      await h.say('hi', 'Hello.');
      await pumpEventQueue();
      expect(states.map((s) => s.phase), [...List.filled(7, AssistantPhase.busy), AssistantPhase.ready]);
      expect(states.map((s) => s.revision).toSet(), hasLength(8));
      expect(states.last.items.last.text, 'Hello.');
    });

    test('states and events deliver after a change, never during it', () async {
      final states = <AssistantState>[];
      final events = <AssistantEvent>[];
      final stateSubscription = h.assistant.states.listen(states.add);
      final eventSubscription = h.assistant.events.listen(events.add);
      addTearDown(stateSubscription.cancel);
      addTearDown(eventSubscription.cancel);
      h.assistant.newConversation();
      expect(states, isEmpty);
      expect(events, isEmpty);
      await pumpEventQueue();
      expect(states, hasLength(1));
      expect(events.single, isA<ConversationChangedEvent>());
      h.assistant.recordAction('x', const ToolCall('list_orders'), const ToolResult.ok());
      expect(states, hasLength(1));
      expect(events, hasLength(1));
      await pumpEventQueue();
      expect(states, hasLength(2));
      expect(events, hasLength(2));
    });
  });

  group('state', () {
    setUp(() async => h = await ToyHarness.open());

    test('immutable: a change makes a new state and a new item; the other items keep their identity', () async {
      await h.say('hi', 'Hello.');
      final before = h.state;
      final first = before.items.first;
      h.engine.outputs.add('Fine, thanks. I hope you are well too.');
      final revisions = <int>[];
      final identities = <bool>[];
      void listener() {
        revisions.add(h.state.items.last.revision);
        identities.add(identical(h.state.items.first, first));
      }

      h.assistant.addListener(listener);
      await h.assistant.send('how are you?');
      h.assistant.removeListener(listener);
      expect(identities.every((same) => same), isTrue);
      expect(revisions, orderedEquals([...revisions]..sort()));
      expect(before.items, hasLength(2), reason: 'an old state does not change');
      expect(h.state.items, hasLength(4));
      expect(() => h.state.items.add(first), throwsUnsupportedError);
      expect(h.state.item(first.id), same(first));
      expect(h.state.revision, greaterThan(before.revision));
    });

    test('nothing a state or an outcome hands out can be changed: items, buttons, the pending call', () async {
      await h.say('my orders?', call('list_orders'));
      h.engine.outputs.add(call('cancel_order', {'order_number': 2}));
      final outcome = await h.assistant.send('cancel the second');
      final state = h.state;
      expect(() => outcome.items.clear(), throwsUnsupportedError);
      expect(() => state.pendingActions.clear(), throwsUnsupportedError);
      expect(() => state.items.last.actions.clear(), throwsUnsupportedError);
      expect(() => state.pendingConfirmation!.call.arguments['order_number'] = 1, throwsUnsupportedError);
      expect(() => outcome.confirmation!.call.arguments.clear(), throwsUnsupportedError);
      expect(state.pendingConfirmation!.call, const ToolCall('cancel_order', {'order_number': 2}));
      expect((await h.assistant.confirm(true)).reply, 'Done: I cancelled order B-22.');
    });

    test('refused calls: empty, busy, not ready, no question', () async {
      expect((await h.assistant.send('   ')).rejection, TurnRejection.empty);
      expect((await h.assistant.confirm(true)).rejection, TurnRejection.noQuestion);
      h.engine
        ..gate = Completer<void>()
        ..outputs.add('Hello.');
      final turn = h.assistant.send('hi');
      await pumpEventQueue();
      expect((await h.assistant.send('again')).rejection, TurnRejection.busy);
      expect((await h.assistant.confirm(true)).rejection, TurnRejection.busy);
      h.engine.gate!.complete();
      final outcome = await turn;
      expect((outcome.accepted, outcome.reply), (true, 'Hello.'));
      expect(outcome.items.map((i) => i.text), ['hi', 'Hello.']);
      await h.assistant.unloadModel();
      expect((await h.assistant.send('hi')).rejection, TurnRejection.notReady);
      final fresh = Assistant(toyConfig(h.toolkit), engine: () => h.engine, prefixStore: InMemoryPrefixStateStore());
      await fresh.dispose();
      expect((await fresh.send('hi')).rejection, TurnRejection.notReady);
    });

    test('revision (the host API) grows when items join or leave; newConversation clears everything and resets the '
        'toolkit', () async {
      final start = h.assistant.revision;
      await h.say('my orders?', call('list_orders'));
      expect(h.assistant.revision, greaterThan(start));
      final afterTurn = h.assistant.revision;
      await h.assistant.runTool(const ToolCall('list_orders'));
      expect(h.assistant.revision, afterTurn, reason: 'runTool adds no item');
      h.assistant.recordAction('x', const ToolCall('list_orders'), const ToolResult.ok());
      expect(h.assistant.revision, greaterThan(afterTurn));
      final id = h.state.conversationId;
      h.shop.orders.clear();
      expect(h.assistant.newConversation(id: 'mine'), isTrue);
      expect(h.state.items, isEmpty);
      expect(h.assistant.history, isEmpty);
      expect(h.state.conversationId, 'mine');
      expect(h.assistant.lists.collections, isEmpty);
      expect(h.shop.orders, hasLength(3), reason: 'the toolkit was reset');
      expect(h.toolkit.resets, 1);
      expect(h.assistant.newConversation(), isTrue);
      expect(h.state.conversationId, isNot(anyOf(id, 'mine')));
    });
  });
}
