// The engine-agnostic queue and generation handle (call order, cancel, dispose), with no runtime.
import 'dart:async';

import 'package:local_inference/local_inference.dart';
import 'package:local_inference/src/engine/serial_queue.dart';
import 'package:test/test.dart';

GenerationStats _stats({int decodeTokens = 0, int promptTokens = 0}) => GenerationStats(
  loadMs: 0,
  promptTokens: promptTokens,
  prefillTokens: promptTokens,
  prefillMs: 0,
  decodeTokens: decodeTokens,
  decodeMs: 0,
  timeToFirstTokenMs: 0,
  totalMs: 0,
);

QueuedGeneration _generation({int maxTokens = 10}) => QueuedGeneration(maxTokens: maxTokens, emptyStats: _stats);

void main() {
  group('behavior 1 (FIFO)', () {
    test('operations run one at a time, in call order, each after the previous one finished', () async {
      final queue = SerialQueue();
      final log = <String>[];
      final gates = [Completer<void>(), Completer<void>(), Completer<void>()];
      final results = [
        for (var i = 0; i < 3; i++)
          queue.run(() async {
            log.add('start $i');
            await gates[i].future;
            log.add('end $i');
            return i;
          }),
      ];
      await pumpEventQueue();
      expect(log, ['start 0']);
      gates[2].complete();
      gates[1].complete();
      await pumpEventQueue();
      expect(log, ['start 0'], reason: 'the later operations wait for the first even when they could finish');
      gates[0].complete();
      expect(await Future.wait(results), [0, 1, 2]);
      expect(log, ['start 0', 'end 0', 'start 1', 'end 1', 'start 2', 'end 2']);
    });

    test('an idle queue starts the operation before run() returns', () {
      final queue = SerialQueue();
      var started = false;
      unawaited(
        queue.run(() async {
          started = true;
        }),
      );
      expect(started, isTrue);
    });

    test('a failed operation fails its own future and the next one still runs', () async {
      final queue = SerialQueue();
      final first = queue.run<int>(() async => throw StateError('boom'));
      final second = queue.run(() async => 2);
      await expectLater(first, throwsStateError);
      expect(await second, 2);
    });

    test('generations and other operations share the one order', () async {
      final queue = SerialQueue();
      final log = <String>[];
      final gate = Completer<void>();
      unawaited(
        queue.run(() async {
          log.add('save');
          await gate.future;
        }),
      );
      final generation = _generation();
      queue.runGeneration(generation, () async {
        log.add('generate');
        return _stats();
      });
      unawaited(queue.run(() async => log.add('load')));
      await pumpEventQueue();
      expect(log, ['save']);
      gate.complete();
      await generation.result;
      await pumpEventQueue();
      expect(log, ['save', 'generate', 'load']);
    });

    test('close: waiting generations complete as cancelled, other waiting calls fail, later calls throw', () async {
      final queue = SerialQueue();
      final gate = Completer<void>();
      final running = queue.run(() => gate.future);
      final waitingGeneration = _generation();
      var bodyRan = false;
      queue.runGeneration(waitingGeneration, () async {
        bodyRan = true;
        return _stats();
      });
      final waitingCall = queue.run(() async => 1);
      final closed = queue.close();
      expect(queue.isClosed, isTrue);
      expect((await waitingGeneration.result).finishReason, FinishReason.cancelled);
      await expectLater(waitingCall, throwsStateError);
      expect(() => queue.run(() async => 1), throwsStateError);
      expect(() => queue.runGeneration(_generation(), () async => _stats()), throwsStateError);
      var done = false;
      unawaited(closed.then((_) => done = true));
      await pumpEventQueue();
      expect(done, isFalse, reason: 'close waits for the running operation');
      gate.complete();
      await running;
      await closed;
      expect(bodyRan, isFalse);
    });

    test('close cancels the running generation', () async {
      final queue = SerialQueue();
      final generation = _generation();
      final stop = Completer<void>();
      queue.runGeneration(generation, () async {
        generation.onCancel = stop.complete;
        generation.emit('a');
        await stop.future;
        return _stats(decodeTokens: 1);
      });
      await pumpEventQueue();
      await queue.close();
      final result = await generation.result;
      expect((result.finishReason, result.text), (FinishReason.cancelled, 'a'));
    });
  });

  group('behavior 3 (generation lifecycle)', () {
    test('cancel while queued: the body never runs, text closes, the result is cancelled with no text', () async {
      final queue = SerialQueue();
      final gate = Completer<void>();
      unawaited(queue.run(() => gate.future));
      final generation = _generation();
      var bodyRan = false;
      queue.runGeneration(generation, () async {
        bodyRan = true;
        return _stats();
      });
      generation.cancel();
      final result = await generation.result;
      expect((result.finishReason, result.text, result.stats.decodeTokens), (FinishReason.cancelled, '', 0));
      expect(await generation.text.toList(), isEmpty);
      gate.complete();
      await pumpEventQueue();
      expect(bodyRan, isFalse);
    });

    test('cancel after dequeue, before the runtime call: the body sees it and skips its runtime call', () async {
      final queue = SerialQueue();
      final generation = _generation();
      final counted = Completer<void>();
      var runtimeCalled = false;
      queue.runGeneration(generation, () async {
        await counted.future; // the prompt token count
        if (generation.isCancelled) return _stats(promptTokens: 7);
        runtimeCalled = true;
        return _stats();
      });
      generation.cancel();
      counted.complete();
      final result = await generation.result;
      expect((result.finishReason, result.text, result.stats.promptTokens), (FinishReason.cancelled, '', 7));
      expect(runtimeCalled, isFalse);
    });

    test('cancel mid-stream: the runtime cancel is called and the result keeps the text so far', () async {
      final queue = SerialQueue();
      final generation = _generation();
      final stopped = Completer<void>();
      var runtimeCancels = 0;
      queue.runGeneration(generation, () async {
        generation.onCancel = () {
          runtimeCancels++;
          stopped.complete();
        };
        generation.emit('Hel');
        generation.emit('lo');
        await stopped.future;
        generation.onCancel = null;
        return _stats(decodeTokens: 2);
      });
      final deltas = <String>[];
      await for (final delta in generation.text) {
        deltas.add(delta);
        if (deltas.length == 2) generation.cancel();
      }
      final result = await generation.result;
      expect(runtimeCancels, 1);
      expect(deltas, ['Hel', 'lo']);
      expect((result.finishReason, result.text), (FinishReason.cancelled, 'Hello'));
      generation.cancel();
      expect(runtimeCancels, 1, reason: 'cancel after the result is a no-op');
    });

    test('generate returns at once: deltas are buffered until the text is listened to', () async {
      final queue = SerialQueue();
      final generation = _generation();
      queue.runGeneration(generation, () async {
        generation.emit('a');
        generation.emit('b');
        return _stats(decodeTokens: 2);
      });
      final result = await generation.result;
      expect(result.text, 'ab');
      expect(await generation.text.toList(), ['a', 'b']);
    });

    test('the result completes after the listener received the last delta', () async {
      final queue = SerialQueue();
      final generation = _generation();
      final events = <String>[];
      generation.text.listen(events.add, onDone: () => events.add('done'));
      unawaited(generation.result.then((_) => events.add('result')));
      queue.runGeneration(generation, () async {
        for (final piece in ['a', 'b', 'c']) {
          generation.emit(piece);
        }
        return _stats(decodeTokens: 3);
      });
      await generation.result;
      await pumpEventQueue();
      expect(events, ['a', 'b', 'c', 'done', 'result']);
    });

    test('a runtime error fails the result with GenerationException(cause) and ends the text with it', () async {
      final queue = SerialQueue();
      final generation = _generation();
      final cause = Exception('native');
      queue.runGeneration(generation, () async {
        generation.emit('par');
        throw cause;
      });
      final deltas = <String>[];
      Object? streamError;
      try {
        await for (final delta in generation.text) {
          deltas.add(delta);
        }
      } catch (e) {
        streamError = e;
      }
      expect(deltas, ['par']);
      expect(streamError, isA<GenerationException>().having((e) => e.cause, 'cause', cause));
      await expectLater(generation.result, throwsA(isA<GenerationException>().having((e) => e.cause, 'cause', cause)));
    });

    test('a GenerationException from the body is passed on as it is', () async {
      final queue = SerialQueue();
      final generation = _generation();
      const failure = GenerationException('scripted');
      queue.runGeneration(generation, () async => throw failure);
      await expectLater(generation.result, throwsA(same(failure)));
    });

    test('a caller that ignores the result, or the text, gets no unhandled error', () async {
      final errors = <Object>[];
      await runZonedGuarded(() async {
        final queue = SerialQueue();
        final onlyText = _generation();
        queue.runGeneration(onlyText, () async => throw Exception('a'));
        try {
          await onlyText.text.drain<void>();
        } on GenerationException {
          // expected: the caller handles the text's error and never looks at the result
        }
        final onlyResult = _generation();
        queue.runGeneration(onlyResult, () async => throw Exception('b'));
        await expectLater(onlyResult.result, throwsA(isA<GenerationException>()));
        final neither = _generation();
        queue.runGeneration(neither, () async => throw Exception('c'));
        await pumpEventQueue();
      }, (error, _) => errors.add(error));
      expect(errors, isEmpty);
    });
  });

  group('behavior 4 (finish reason)', () {
    Future<FinishReason> finish(int decodeTokens, {required int maxTokens, bool cancel = false}) async {
      final queue = SerialQueue();
      final generation = QueuedGeneration(maxTokens: maxTokens, emptyStats: _stats);
      final gate = Completer<void>();
      queue.runGeneration(generation, () async {
        await gate.future;
        return _stats(decodeTokens: decodeTokens);
      });
      await pumpEventQueue();
      if (cancel) generation.cancel();
      gate.complete();
      return (await generation.result).finishReason;
    }

    test('stop below maxTokens, maxTokens at or above it, cancelled whenever cancel came first', () async {
      expect(await finish(9, maxTokens: 10), FinishReason.stop);
      expect(await finish(10, maxTokens: 10), FinishReason.maxTokens);
      expect(await finish(11, maxTokens: 10), FinishReason.maxTokens);
      expect(await finish(10, maxTokens: 10, cancel: true), FinishReason.cancelled);
      expect(await finish(0, maxTokens: 10, cancel: true), FinishReason.cancelled);
    });
  });
}
