// AssistantController: each listenable fires only when its own value changes (items by identity), the borrowed or
// owned assistant, retryLoad's rule (the last model, else the setup's candidates), and analytics without text.
import 'package:flutter_test/flutter_test.dart';
import 'package:local_inference/testing.dart';
import 'package:local_inference_flutter/local_inference_flutter.dart';

import '../support/toy_chat.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<(AssistantController, ScriptedEngine)> make({List<ScriptedTurn> script = const []}) async {
    final (assistant, engine) = await scriptedAssistant(toyConfig(), script: script);
    final controller = AssistantController.owning(assistant);
    addTearDown(controller.dispose);
    return (controller, engine);
  }

  test('the listenables start from the assistant\'s state', () async {
    final (controller, _) = await make();
    expect(controller.phase.value, AssistantPhase.ready);
    expect(controller.composer.value, const ComposerState(canSend: true, isBusy: false));
    expect(controller.itemIds.value, isEmpty);
    expect(controller.pendingActions.value, isEmpty);
    expect(controller.state.value, same(controller.assistant.state));
    expect(controller.toolHost, same(controller.assistant));
    expect(() => controller.item(99), throwsArgumentError);
  });

  test(
    'a turn: the ids fire once, the old items never, the phase and composer twice, the coarse one per change',
    () async {
      final (controller, engine) = await make(script: [const ScriptedTurn.text('Hello there.')]);
      await controller.send('hi');
      final first = controller.itemIds.value;
      expect(first, hasLength(2));
      final fired = <String, int>{};
      void count(String name) => fired[name] = (fired[name] ?? 0) + 1;
      controller.itemIds.addListener(() => count('ids'));
      controller.phase.addListener(() => count('phase'));
      controller.composer.addListener(() => count('composer'));
      controller.pendingActions.addListener(() => count('pending'));
      controller.state.addListener(() => count('state'));
      controller.addListener(() => count('coarse'));
      for (final id in first) {
        controller.item(id).addListener(() => count('item $id'));
      }

      engine.outputs.add('A reply of several words, streamed in pieces.');
      await controller.send('more');
      expect(fired['ids'], 1, reason: 'both items of the turn arrive in one change');
      expect(fired['phase'], 2, reason: 'busy, then ready');
      expect(fired['composer'], 2);
      expect(fired['pending'], isNull);
      expect(fired['item ${first[0]}'], isNull);
      expect(fired['item ${first[1]}'], isNull);
      expect(fired['coarse'], greaterThan(4), reason: 'one per streamed piece');
      expect(fired['state'], fired['coarse']);
      final reply = controller.item(controller.itemIds.value.last).value;
      expect(reply.text, 'A reply of several words, streamed in pieces.');
      expect(controller.item(reply.id), same(controller.item(reply.id)), reason: 'one listenable per id');
    },
  );

  test(
    'a question: its buttons fire once when asked and once when answered; each change bumps only its item',
    () async {
      final (controller, engine) = await make(script: [ScriptedTurn.toolCall('list_orders')]);
      await controller.send('orders');
      final list = controller.itemIds.value.last;
      var pending = 0;
      var listFired = 0;
      controller.pendingActions.addListener(() => pending++);
      controller.item(list).addListener(() => listFired++);
      engine.outputs.add(toolCall('cancel_order', {'order_number': 1}));
      await controller.send('cancel the first');
      expect(pending, 1);
      expect(controller.pendingActions.value.map((a) => a.label), ['Yes', 'No']);
      final question = controller.itemIds.value.last;
      var questionFired = 0;
      controller.item(question).addListener(() => questionFired++);
      await controller.act(controller.pendingActions.value.first);
      expect(pending, 2);
      expect(controller.pendingActions.value, isEmpty);
      expect(questionFired, 1, reason: 'its buttons went');
      expect(listFired, 0);
    },
  );

  test('a new conversation empties the ids and drops the items\' listenables', () async {
    final (controller, _) = await make(script: [const ScriptedTurn.text('Hi.')]);
    await controller.send('hello');
    final id = controller.itemIds.value.first;
    final before = controller.item(id);
    expect(controller.newConversation(), isTrue);
    expect(controller.itemIds.value, isEmpty);
    expect(() => controller.item(id), throwsArgumentError);
    before.removeListener(() {});
  });

  test('a borrowing controller leaves the assistant to its owner; an owning one disposes it', () async {
    final (assistant, _) = await scriptedAssistant(toyConfig());
    final borrowing = AssistantController(assistant);
    expect(borrowing.ownsAssistant, isFalse);
    await borrowing.dispose();
    expect(assistant.newConversation(), isTrue, reason: 'still alive');
    final owning = AssistantController.owning(assistant);
    await owning.dispose();
    expect(assistant.newConversation(), isFalse, reason: 'disposed with its controller');
  });

  test('retryLoad: the last model loaded; else the setup\'s first candidate; else nothing', () async {
    var refuse = false;
    final scripted = ScriptedEngine(supportsStatePersistence: false);
    final assistant = Assistant(
      toyConfig(),
      engine: () => refuse ? ScriptedEngine(chatTemplate: '') : scripted,
      prefixStore: InMemoryPrefixStateStore(),
    );
    final controller = AssistantController.owning(assistant);
    addTearDown(controller.dispose);
    expect(await controller.retryLoad(), isFalse, reason: 'no model yet and no setup');

    expect(await controller.loadModel('a.gguf', identity: const ModelIdentity.fixed('a.gguf')), isTrue);
    refuse = true;
    expect(await controller.loadModel('b.gguf', identity: const ModelIdentity.fixed('b.gguf')), isFalse);
    expect(controller.phase.value, AssistantPhase.failed);
    refuse = false;
    expect(await controller.retryLoad(), isTrue);
    expect(controller.assistant.state.modelPath, 'a.gguf', reason: 'the failed load kept the last model');

    final fresh = Assistant(toyConfig(), engine: () => scripted, prefixStore: InMemoryPrefixStateStore());
    final other = AssistantController.owning(fresh);
    addTearDown(other.dispose);
    final setup = ModelSetupController(
      assistant: other,
      autoLoad: false,
      candidates: (_) => [const ModelCandidate(path: 'c.gguf')],
    );
    addTearDown(setup.dispose);
    await setup.init();
    expect(other.phase.value, AssistantPhase.noModel, reason: 'autoLoad off');
    expect(await other.retryLoad(), isTrue);
    expect(other.assistant.state.modelPath, 'c.gguf');
  });

  test('analytics: counts, durations and codes, never what was written', () async {
    final (controller, engine) = await make(script: [ScriptedTurn.toolCall('list_orders')]);
    final events = <ChatAnalyticsEvent>[];
    controller.analytics.listen(events.add);
    await controller.send('my secret question', fromSuggestion: true);
    engine.outputs.add(toolCall('cancel_order', {'order_number': 1}));
    await controller.send('cancel my secret order');
    await controller.act(controller.pendingActions.value.last);
    controller.newConversation();
    await pumpEventQueue();
    final sent = events.whereType<MessageSentEvent>().toList();
    expect(
      [for (final e in sent) (e.length, e.fromSuggestion)],
      [('my secret question'.length, true), ('cancel my secret order'.length, false)],
    );
    expect(events.whereType<TurnCompletedEvent>().map((e) => e.toolCalls), [1, 0, 0]);
    expect(events.whereType<ConfirmationAnsweredEvent>().single.yes, isFalse);
    expect(events.whereType<ConversationStartedEvent>(), hasLength(1));
    expect(events.map((e) => '$e').join(' '), isNot(contains('secret')));
  });
}
