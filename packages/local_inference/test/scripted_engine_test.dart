// The testing kit (testing.dart): ScriptedEngine and qwen35ChatTemplate.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:local_inference/local_inference.dart';
import 'package:local_inference/testing.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('scripted_engine_test'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('qwen35ChatTemplate is the Qwen3.5-2B template (sha256 ea210e5b…)', () {
    expect(
      sha256.convert(utf8.encode(qwen35ChatTemplate)).toString(),
      'ea210e5b4997b7b1d3af5ee3ad34e7677ffe38df7469e8d88089789b5a27fae5',
    );
  });

  test('load reports a scripted qwen35 model with its template and metadata; it may load again', () async {
    final engine = ScriptedEngine(metadata: {'general.name': 'test'});
    final model = File('${tmp.path}/m.gguf')..writeAsStringSync('12345');
    final info = await engine.load(model.path, const LoadOptions(contextTokens: 2048));
    expect(
      (info.backend, info.gpuLayers, info.contextTokens, info.modelBytes, info.loadMs, info.addsBos),
      ('scripted', 0, 2048, 5, 0, false),
    );
    expect(info.metadata, {
      'tokenizer.chat_template': qwen35ChatTemplate,
      'general.architecture': 'qwen35',
      'general.name': 'test',
    });
    expect(info.runtime, const RuntimeInfo(binding: 'scripted', bindingVersion: '1', native: 'none'));
    expect(
      (info.chatTemplateSha256, info.isRecurrent),
      ('ea210e5b4997b7b1d3af5ee3ad34e7677ffe38df7469e8d88089789b5a27fae5', true),
    );
    await engine.dispose();
    expect((engine.isLoaded, engine.info, engine.disposes), (false, null, 1));
    await engine.load(model.path);
    expect(engine.isLoaded, isTrue);
    final other = await ScriptedEngine(chatTemplate: 'T').load(model.path);
    expect(other.chatTemplate, 'T');
  });

  test('generate answers with the next output in 7-character deltas and records the prompt and options', () async {
    final engine = ScriptedEngine()..outputs.addAll(['Buongiorno, come posso aiutarti?', 'Ciao']);
    const options = GenerationOptions(stop: ['<|im_end|>']);
    final first = engine.generate('the first prompt', options);
    expect(engine.contextEpoch, 1);
    expect(await first.text.toList(), ['Buongio', 'rno, co', 'me poss', 'o aiuta', 'rti?']);
    final result = await first.result;
    expect((result.text, result.finishReason), ('Buongiorno, come posso aiutarti?', FinishReason.stop));
    final stats = result.stats;
    expect(
      [stats.promptTokens, stats.prefillTokens, stats.decodeTokens, stats.totalMs, stats.timeToFirstTokenMs],
      [4, 4, 5, 0, 0],
    );
    expect((await engine.generate('second').result).text, 'Ciao');
    expect(engine.prompts, ['the first prompt', 'second']);
    expect(engine.options, [options, const GenerationOptions()]);
    expect(engine.outputs, isEmpty);
    final chunks = ScriptedEngine(chunkSize: 3)..outputs.add('abcdefg');
    expect(await chunks.generate('p').text.toList(), ['abc', 'def', 'g']);
  });

  test('countTokens is text.length ~/ 4, tokenize gives that many tokens; neither moves contextEpoch', () async {
    final engine = ScriptedEngine();
    expect(await engine.countTokens('x' * 41), 10);
    expect(await engine.tokenize('x' * 8), hasLength(2));
    expect(engine.contextEpoch, 0);
  });

  test(
    'saveState writes the prefix to the file and loadState reads it back; both count and move contextEpoch',
    () async {
      final engine = ScriptedEngine();
      final path = '${tmp.path}/prefix.state';
      final saved = await engine.saveState(path, 'x' * 40);
      expect((saved.path, saved.tokens, saved.bytes, engine.saves, engine.contextEpoch), (path, 10, 40, 1, 1));
      expect(File(path).readAsStringSync(), 'x' * 40);
      expect(await engine.loadState(path), 10);
      expect((engine.loads, engine.contextEpoch), (1, 2));
    },
  );

  test('behind a gated generation each call moves contextEpoch when called; a queued cancel keeps it', () async {
    final engine = ScriptedEngine()
      ..outputs.add('ok')
      ..gate = Completer<void>();
    final running = engine.generate('running');
    final queued = engine.generate('queued');
    expect(engine.contextEpoch, 2);
    queued.cancel();
    expect((await queued.result).finishReason, FinishReason.cancelled);
    final path = '${tmp.path}/prefix.state';
    final save = engine.saveState(path, 'prefix');
    expect(engine.contextEpoch, 3);
    final load = engine.loadState(path);
    expect(engine.contextEpoch, 4);
    engine.gate!.complete();
    await Future.wait([running.result, save, load]);
    expect((engine.contextEpoch, engine.prompts.length, engine.saves, engine.loads), (4, 2, 1, 1));
  });

  test('failNextLoadState fails the next loadState once, as a StateFileException with that cause', () async {
    final engine = ScriptedEngine();
    final path = '${tmp.path}/prefix.state';
    await engine.saveState(path, 'prefix');
    final cause = Exception('corrupt');
    engine.failNextLoadState = cause;
    await expectLater(
      engine.loadState(path),
      throwsA(isA<StateFileException>().having((e) => e.cause, 'cause', cause)),
    );
    expect(engine.failNextLoadState, isNull);
    expect(await engine.loadState(path), 1);
    expect(engine.loads, 2);
  });

  test('without state persistence, saveState and loadState throw StateFileException', () async {
    final engine = ScriptedEngine(supportsStatePersistence: false);
    expect(engine.supportsStatePersistence, isFalse);
    await expectLater(engine.saveState('${tmp.path}/s', 'p'), throwsA(isA<StateFileException>()));
    await expectLater(engine.loadState('${tmp.path}/s'), throwsA(isA<StateFileException>()));
  });

  test(
    'gate: a generation waits for it before its first delta, and later operations wait for the generation',
    () async {
      final engine = ScriptedEngine()
        ..outputs.add('ok')
        ..gate = Completer<void>();
      final generation = engine.generate('p');
      final deltas = <String>[];
      generation.text.listen(deltas.add);
      final saved = engine.saveState('${tmp.path}/prefix.state', 'prefix');
      await pumpEventQueue();
      expect(deltas, isEmpty);
      expect(engine.saves, 0);
      engine.gate!.complete();
      await saved;
      expect(deltas, ['ok']);
      expect(engine.saves, 1);
    },
  );

  test('cancel at the gate leaves the output for the next generation; mid-stream the text so far is kept', () async {
    final engine = ScriptedEngine()
      ..outputs.addAll(['first output', 'second output'])
      ..gate = Completer<void>();
    final waiting = engine.generate('p')..cancel();
    engine.gate!.complete();
    final cancelled = await waiting.result;
    expect((cancelled.finishReason, cancelled.text, engine.outputs.length), (FinishReason.cancelled, '', 2));
    final streaming = engine.generate('p');
    final seen = <String>[];
    await for (final delta in streaming.text) {
      seen.add(delta);
      streaming.cancel();
    }
    final result = await streaming.result;
    expect((result.finishReason, result.text, seen.length), (FinishReason.cancelled, 'first o', 1));
  });

  test('dispose acts as on a real engine until the next load: generations end cancelled, other calls fail', () async {
    final engine = ScriptedEngine()
      ..outputs.addAll(['first output', 'second output'])
      ..gate = Completer<void>();
    final model = File('${tmp.path}/m.gguf')..writeAsStringSync('m');
    await engine.load(model.path);
    final running = engine.generate('running');
    final queued = engine.generate('queued');
    final tokens = expectLater(engine.tokenize('abcd'), throwsStateError);
    await pumpEventQueue();
    await engine.dispose();
    expect(engine.gate!.isCompleted, isFalse, reason: 'the cancel ended the wait at the gate');
    expect((await running.result).finishReason, FinishReason.cancelled);
    expect((await queued.result).finishReason, FinishReason.cancelled);
    await tokens;
    expect((engine.isLoaded, engine.info, engine.disposes, engine.outputs.length), (false, null, 1, 2));
    expect(() => engine.generate('after dispose'), throwsStateError);
    await expectLater(engine.countTokens('x'), throwsStateError);
    await expectLater(engine.saveState('${tmp.path}/s', 'p'), throwsStateError);
    await expectLater(engine.loadState('${tmp.path}/s'), throwsStateError);
    expect((engine.prompts.length, engine.contextEpoch), (2, 2), reason: 'the calls after dispose did nothing');
    await engine.dispose();
    expect(engine.disposes, 2);
    await engine.load(model.path);
    engine.gate = null;
    expect((await engine.generate('reloaded').result).text, 'first output');
  });

  test('throwAfterDeltas fails the next generation after n deltas, as a GenerationException with that cause', () async {
    final cause = Exception('native');
    final engine = ScriptedEngine()
      ..outputs.addAll(['abcdefghijklmnopq', 'ok'])
      ..throwAfterDeltas = (1, cause);
    final generation = engine.generate('p');
    final deltas = <String>[];
    Object? streamError;
    try {
      await for (final delta in generation.text) {
        deltas.add(delta);
      }
    } catch (e) {
      streamError = e;
    }
    expect(deltas, ['abcdefg']);
    expect(streamError, isA<GenerationException>().having((e) => e.cause, 'cause', cause));
    await expectLater(generation.result, throwsA(isA<GenerationException>()));
    expect(engine.throwAfterDeltas, isNull);
    expect((await engine.generate('p').result).text, 'ok');
  });

  test('an exhausted script fails the generation and reports ScriptExhausted to the zone of the call', () async {
    final reported = <Object>[];
    Object? failure;
    await runZonedGuarded(() async {
      final generation = ScriptedEngine().generate('<|im_start|>user\nciao<|im_end|>\n');
      try {
        await generation.result;
      } catch (e) {
        failure = e; // what a harness that catches everything sees; the test fails anyway
      }
    }, (error, _) => reported.add(error));
    expect(reported, [isA<ScriptExhausted>().having((e) => e.message, 'message', contains(r'ciao<|im_end|>\n'))]);
    expect(failure, isA<GenerationException>().having((e) => e.cause, 'cause', isA<ScriptExhausted>()));
    expect(reported.single, isA<Error>());
  });
}
