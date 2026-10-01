// LlamadartEngine over a llamadart backend with no native code (test/support/fake_llama_backend.dart): the engine's
// behaviors (queueing, cancel, state files, load and generation parameters) as the adapter applies them to llamadart.
// The paramsFor golden is in
// generation_params_golden_test.dart, the engine-agnostic queue in serial_queue_test.dart.
import 'dart:async';
import 'dart:io';

import 'package:llamadart/llamadart.dart' as ll;
import 'package:local_inference/local_inference.dart';
import 'package:test/test.dart';

import 'support/fake_llama_backend.dart';
import 'support/llamadart_source.dart';

late Directory _tmp;

/// A model file for the fake backend; its size is EngineInfo.modelBytes.
String _model() => (File('${_tmp.path}/model.gguf')..writeAsStringSync('gguf model')).path;

/// An engine over [backend] (a new fake by default) with a model loaded, disposed at tear-down.
Future<(LlamadartEngine, FakeLlamaBackend)> _loaded({
  FakeLlamaBackend? backend,
  LoadOptions options = const LoadOptions(),
  bool isIOS = false,
  EngineLogLevel logLevel = EngineLogLevel.warn,
  void Function(String line)? log,
}) async {
  final fake = backend ?? FakeLlamaBackend();
  final engine = LlamadartEngine.withBackend(fake, logLevel: logLevel, log: log ?? (_) {}, isIOS: isIOS);
  addTearDown(engine.dispose);
  await engine.load(_model(), options);
  return (engine, fake);
}

/// Every field of ll.ModelParams in llamadart 0.8.23, in declaration order.
const List<String> _modelParamsFields = [
  'contextSize',
  'gpuLayers',
  'preferredBackend',
  'liteRtLmBackend',
  'liteRtLmActivationDataType',
  'liteRtLmPrefillChunkSize',
  'liteRtLmParallelFileSectionLoading',
  'liteRtLmDispatchLibDir',
  'splitMode',
  'mainGpu',
  'loras',
  'chatTemplate',
  'numberOfThreads',
  'numberOfThreadsBatch',
  'batchSize',
  'microBatchSize',
  'maxParallelSequences',
  'speculativeRollbackTokenMax',
  'useMmap',
  'useMlock',
  'loadMtp',
  'flashAttention',
  'cacheTypeK',
  'cacheTypeV',
  'kvUnified',
  'ropeFrequencyBase',
  'ropeFrequencyScale',
  'preferMemory64',
  'modelBytesHint',
];

/// [params] field by field.
Map<String, Object?> _modelParamsDump(ll.ModelParams params) {
  final dump = <String, Object?>{
    'contextSize': params.contextSize,
    'gpuLayers': params.gpuLayers,
    'preferredBackend': params.preferredBackend,
    'liteRtLmBackend': params.liteRtLmBackend,
    'liteRtLmActivationDataType': params.liteRtLmActivationDataType,
    'liteRtLmPrefillChunkSize': params.liteRtLmPrefillChunkSize,
    'liteRtLmParallelFileSectionLoading': params.liteRtLmParallelFileSectionLoading,
    'liteRtLmDispatchLibDir': params.liteRtLmDispatchLibDir,
    'splitMode': params.splitMode,
    'mainGpu': params.mainGpu,
    'loras': [for (final lora in params.loras) '${lora.path} ${lora.scale}'],
    'chatTemplate': params.chatTemplate,
    'numberOfThreads': params.numberOfThreads,
    'numberOfThreadsBatch': params.numberOfThreadsBatch,
    'batchSize': params.batchSize,
    'microBatchSize': params.microBatchSize,
    'maxParallelSequences': params.maxParallelSequences,
    'speculativeRollbackTokenMax': params.speculativeRollbackTokenMax,
    'useMmap': params.useMmap,
    'useMlock': params.useMlock,
    'loadMtp': params.loadMtp,
    'flashAttention': params.flashAttention,
    'cacheTypeK': params.cacheTypeK,
    'cacheTypeV': params.cacheTypeV,
    'kvUnified': params.kvUnified,
    'ropeFrequencyBase': params.ropeFrequencyBase,
    'ropeFrequencyScale': params.ropeFrequencyScale,
    'preferMemory64': params.preferMemory64,
    'modelBytesHint': params.modelBytesHint,
  };
  expect(dump.keys, _modelParamsFields);
  return dump;
}

/// The load parameters of the first llamadart adapter with its defaults (contextTokens 4096, threads 0, gpuLayers
/// -1), built as its load() built them; it passed microBatchSize 128 on iOS and 0 elsewhere. The defaults of
/// LoadOptions must keep giving these.
ll.ModelParams _m0ModelParams({required int microBatchSize}) => ll.ModelParams(
  contextSize: 4096,
  gpuLayers: ll.ModelParams.maxGpuLayers,
  numberOfThreads: 0,
  numberOfThreadsBatch: 0,
  microBatchSize: microBatchSize,
  preferredBackend: ll.GpuBackend.auto,
  flashAttention: ll.FlashAttention.enabled,
  cacheTypeK: ll.KvCacheType.f16,
  cacheTypeV: ll.KvCacheType.f16,
);

void main() {
  setUp(() => _tmp = Directory.systemTemp.createTempSync('llamadart_engine_test'));
  tearDown(() => _tmp.deleteSync(recursive: true));

  group('load (behavior 9)', () {
    test('load passes modelParamsFor(options) and reports the model, the runtime and the resolved options', () async {
      final backend = FakeLlamaBackend()..contextSize = 2048;
      final (engine, _) = await _loaded(backend: backend, options: const LoadOptions(contextTokens: 2048));
      expect(
        _modelParamsDump(backend.modelParams!),
        _modelParamsDump(LlamadartEngine.modelParamsFor(const LoadOptions(contextTokens: 2048), isIOS: false)),
      );
      final info = engine.info!;
      expect(info.modelPath, '${_tmp.path}/model.gguf');
      expect(info.modelBytes, 'gguf model'.length);
      expect((info.backend, info.gpuLayers, info.contextTokens), ('Metal', 999, 2048));
      expect(info.loadMs, greaterThanOrEqualTo(0));
      expect(info.metadata, fakeMetadata, reason: 'the raw GGUF metadata, no synthetic keys');
      final format = ll.ChatTemplateEngine.detectFormat(fakeMetadata['tokenizer.chat_template']!).name;
      expect(info.runtimeDetails, {'llamadart.chat_format': format});
      expect(info.runtime, LlamadartEngine.defaultRuntime);
      expect(info.addsBos, isFalse);
      expect(
        info.options,
        const LoadOptions(contextTokens: 2048, threads: 0, gpuLayers: 999, microBatchSize: 0, batchSize: 0),
        reason: 'resolved: what the runtime was given or reports; 0 is its own default',
      );
      expect((engine.isLoaded, engine.supportsStatePersistence), (true, true));
      expect(engine.native.isReady, isTrue);
    });

    test('the resolved options: micro-batch 128 on iOS unless set; gpu layers as passed when unreported', () async {
      final (ios, iosBackend) = await _loaded(isIOS: true);
      expect((ios.info!.options.microBatchSize, iosBackend.modelParams!.microBatchSize), (128, 128));
      final (explicit, _) = await _loaded(isIOS: true, options: const LoadOptions(microBatchSize: 64));
      expect(explicit.info!.options.microBatchSize, 64);
      final (unreported, _) = await _loaded(
        backend: FakeLlamaBackend()..resolvedGpuLayers = null,
        options: const LoadOptions(gpuLayers: 12),
      );
      expect((unreported.info!.gpuLayers, unreported.info!.options.gpuLayers), (null, 12));
    });

    test('load points the process-global llamadart logging at the engine level and log sink', () async {
      final verbose = <String>[];
      await _loaded(logLevel: EngineLogLevel.info, log: verbose.add);
      expect(verbose, contains(startsWith('[llamadart info] Loading model')));
      final quiet = <String>[];
      await _loaded(log: quiet.add);
      expect(quiet, isEmpty, reason: 'warn: no info lines');
    });

    test('a model without a chat template loads; its template, sha and chat format are absent', () async {
      final (engine, _) = await _loaded(backend: FakeLlamaBackend(metadata: {'general.architecture': 'llama'}));
      final info = engine.info!;
      expect((info.chatTemplate, info.chatTemplateSha256, info.isRecurrent), (null, null, false));
      expect(info.runtimeDetails, isEmpty);
    });

    test('a native load failure is a ModelLoadException with the cause; the engine can load afterwards', () async {
      final backend = FakeLlamaBackend()..loadError = Exception('not a gguf');
      final engine = LlamadartEngine.withBackend(backend, isIOS: false, log: (_) {});
      addTearDown(engine.dispose);
      await expectLater(
        engine.load(_model()),
        throwsA(isA<ModelLoadException>().having((e) => '${e.cause}', 'cause', contains('not a gguf'))),
      );
      expect((engine.isLoaded, engine.info), (false, null));
      backend.loadError = null;
      expect((await engine.load(_model())).backend, 'Metal');
    });

    test('a failure after the native load unloads the model and is a ModelLoadException', () async {
      final backend = FakeLlamaBackend()..tokenizeError = Exception('no vocabulary');
      final engine = LlamadartEngine.withBackend(backend, isIOS: false, log: (_) {});
      addTearDown(engine.dispose);
      await expectLater(engine.load(_model()), throwsA(isA<ModelLoadException>()));
      expect(backend.calls, containsAllInOrder(['modelLoad', 'contextFree', 'modelFree']));
      expect(engine.isLoaded, isFalse);
    });

    test('a second load throws StateError, also while the first one is loading', () async {
      final engine = LlamadartEngine.withBackend(FakeLlamaBackend(), isIOS: false, log: (_) {});
      addTearDown(engine.dispose);
      final first = engine.load(_model());
      await expectLater(engine.load(_model()), throwsStateError);
      await first;
      await expectLater(engine.load(_model()), throwsStateError);
    });

    test(
      'BOS rule: tokenize and countTokens add special tokens as generate does; addsBos is the vocabulary\'s',
      () async {
        final (engine, backend) = await _loaded(backend: FakeLlamaBackend(bosToken: 1)..reply = (_, _) => ['ok']);
        expect(engine.info!.addsBos, isTrue);
        expect(await engine.tokenize('abcdefgh'), [1, 100, 101]);
        expect(await engine.countTokens('abcdefgh'), 3);
        expect((await engine.generate('abcdefgh').result).stats.promptTokens, 3);
        expect(backend.calls.where((c) => c.startsWith('tokenize(')), everyElement(endsWith(', true)')));
      },
    );
  });

  group('FIFO (behavior 1)', () {
    test('each operation reaches the runtime after the previous one finished, in call order', () async {
      final (engine, backend) = await _loaded();
      backend.calls.clear();
      final first = engine.generate('first prompt');
      final tokens = engine.tokenize('abcd');
      final saved = engine.saveState('${_tmp.path}/s.state', 'prefix');
      final second = engine.generate('second');
      final restored = engine.loadState('${_tmp.path}/s.state');
      await pumpEventQueue();
      expect(backend.calls, ['tokenize(12 chars, true)', 'generate(1024)'], reason: 'the rest waits');
      backend.reply = (_, _) => ['ok']; // the later generations answer at once
      await backend.generations.first.end();
      await Future.wait([first.result, tokens, saved, second.result, restored]);
      expect(backend.calls, [
        'tokenize(12 chars, true)',
        'generate(1024)',
        'tokenize(4 chars, true)',
        'tokenize(6 chars, true)',
        'generate(0)',
        'stateSaveFile(2 tokens)',
        'tokenize(6 chars, true)',
        'generate(1024)',
        'stateLoadFile(4096)',
      ]);
    });

    test('a generation called while the model loads runs once the load is done', () async {
      final backend = FakeLlamaBackend()..reply = (_, _) => ['ok'];
      final engine = LlamadartEngine.withBackend(backend, isIOS: false, log: (_) {});
      addTearDown(engine.dispose);
      final load = engine.load(_model());
      final generation = engine.generate('hello');
      expect((await generation.result).text, 'ok');
      await load;
      expect(backend.calls.indexOf('modelLoad'), lessThan(backend.calls.indexOf('generate(1024)')));
    });

    test('generate passes paramsFor(options) to the runtime', () async {
      final (engine, backend) = await _loaded();
      backend.reply = (_, _) => ['ok'];
      const options = GenerationOptions(
        sampling: SamplingOptions(maxTokens: 9),
        stop: ['<|im_end|>'],
        grammar: Grammar('root ::= "ok"', triggers: [GrammarTrigger.word('<tool_call>')]),
      );
      await engine.generate('hello', options).result;
      final sent = backend.generations.single.params;
      final expected = LlamadartEngine.paramsFor(options);
      expect(
        [sent.maxTokens, sent.stopSequences, sent.grammar, sent.grammarLazy, sent.streamBatchTokenThreshold],
        [expected.maxTokens, expected.stopSequences, expected.grammar, expected.grammarLazy, 1],
      );
    });
  });

  group('contextEpoch (behavior 2)', () {
    test('generate, saveState and loadState add 1 before they return, also when cancelled or failing', () async {
      final (engine, backend) = await _loaded();
      backend.reply = (_, _) => ['ok'];
      expect(engine.contextEpoch, 0);
      final generation = engine.generate('a');
      expect(engine.contextEpoch, 1);
      await generation.result;
      final cancelled = engine.generate('b')..cancel();
      expect(engine.contextEpoch, 2);
      expect((await cancelled.result).finishReason, FinishReason.cancelled);
      backend.saveResult = false;
      final save = engine.saveState('${_tmp.path}/s.state', 'prefix');
      expect(engine.contextEpoch, 3);
      await expectLater(save, throwsA(isA<StateFileException>()));
      backend.stateLoadError = Exception('corrupt');
      final load = engine.loadState('${_tmp.path}/s.state');
      expect(engine.contextEpoch, 4);
      await expectLater(load, throwsA(isA<StateFileException>()));
      await engine.tokenize('abc');
      await engine.countTokens('abc');
      expect(engine.contextEpoch, 4, reason: 'tokenize and countTokens leave the context alone');
      backend.tokenizeError = Exception('tokenizer');
      final failing = engine.generate('c');
      expect(engine.contextEpoch, 5);
      await expectLater(failing.result, throwsA(isA<GenerationException>()));
    });

    test(
      'behind a running generation each call adds 1 when called, not when it runs; a queued cancel keeps it',
      () async {
        final (engine, backend) = await _loaded();
        final running = engine.generate('running');
        await pumpEventQueue();
        expect((engine.contextEpoch, backend.generations.length), (1, 1), reason: 'the first one streams');
        final queued = engine.generate('queued');
        expect(engine.contextEpoch, 2);
        queued.cancel();
        expect((await queued.result).finishReason, FinishReason.cancelled);
        final save = engine.saveState('${_tmp.path}/s.state', 'prefix');
        expect(engine.contextEpoch, 3);
        final load = engine.loadState('${_tmp.path}/s.state');
        expect(engine.contextEpoch, 4);
        backend.reply = (_, _) => const []; // the prefix fill of saveState ends at once
        await backend.generations.single.end();
        await Future.wait([running.result, save, load]);
        expect(engine.contextEpoch, 4, reason: 'running the queued calls adds nothing');
      },
    );
  });

  group('generation lifecycle (behavior 3)', () {
    test('cancel while queued: the runtime never sees it, the text closes empty, the result is cancelled', () async {
      final (engine, backend) = await _loaded();
      backend.calls.clear();
      final running = engine.generate('running');
      final queued = engine.generate('queued');
      queued.cancel();
      final result = await queued.result;
      expect((result.finishReason, result.text, result.stats.decodeTokens), (FinishReason.cancelled, '', 0));
      expect(await queued.text.toList(), isEmpty);
      await pumpEventQueue();
      await backend.generations.single.end();
      await running.result;
      await pumpEventQueue();
      expect(backend.calls, ['tokenize(7 chars, true)', 'generate(1024)'], reason: 'nothing of "queued" ran');
    });

    test('cancel during the prompt token count: the native generate is not called', () async {
      final (engine, backend) = await _loaded();
      backend.calls.clear();
      // The idle engine starts the generation at once: it is counting the prompt tokens when cancel() comes.
      final generation = engine.generate('hello')..cancel();
      final result = await generation.result;
      expect((result.finishReason, result.text, result.stats.promptTokens), (FinishReason.cancelled, '', 2));
      expect(backend.calls, ['tokenize(5 chars, true)']);
    });

    test('cancel mid-stream: the runtime cancel stops it and the result keeps the text so far', () async {
      final (engine, backend) = await _loaded();
      final generation = engine.generate('hello');
      final deltas = <String>[];
      final listened = generation.text.forEach((delta) {
        deltas.add(delta);
        if (deltas.length == 2) generation.cancel();
      });
      await pumpEventQueue();
      final native = backend.generations.single;
      native.piece('Hel');
      await pumpEventQueue();
      native.piece('lo');
      await pumpEventQueue();
      expect(backend.calls.last, 'cancelGeneration');
      final result = await generation.result;
      await listened;
      expect((result.finishReason, result.text), (FinishReason.cancelled, 'Hello'));
      expect(deltas, ['Hel', 'lo']);
      expect(result.stats.decodeTokens, 3, reason: 'the stats are measured as for a finished generation');
    });

    test('a native error fails the result with GenerationException(cause) and ends the text with it', () async {
      final (engine, backend) = await _loaded();
      final generation = engine.generate('hello');
      final deltas = <String>[];
      Object? streamError;
      final listened = () async {
        try {
          await for (final delta in generation.text) {
            deltas.add(delta);
          }
        } catch (e) {
          streamError = e;
        }
      }();
      await pumpEventQueue();
      final native = backend.generations.single;
      native.piece('par');
      await pumpEventQueue();
      await native.fail(Exception('decode failed'));
      await listened;
      expect(deltas, ['par']);
      expect(streamError, isA<GenerationException>());
      await expectLater(
        generation.result,
        throwsA(isA<GenerationException>().having((e) => '${e.cause}', 'cause', contains('decode failed'))),
      );
    });

    test('a caller that ignores the result or the text of a failed generation gets no unhandled error', () async {
      final errors = <Object>[];
      await runZonedGuarded(() async {
        final (engine, backend) = await _loaded();
        backend.tokenizeError = Exception('tokenizer');
        try {
          await engine.generate('text only').text.drain<void>();
        } on GenerationException {
          // expected: this caller reads the text and never looks at the result
        }
        await expectLater(engine.generate('result only').result, throwsA(isA<GenerationException>()));
        engine.generate('neither');
        await pumpEventQueue();
      }, (error, _) => errors.add(error));
      expect(errors, isEmpty);
    });

    test('a generation whose turn comes with no model loaded fails its handle, not the call', () async {
      final engine = LlamadartEngine.withBackend(FakeLlamaBackend(), isIOS: false, log: (_) {});
      addTearDown(engine.dispose);
      final generation = engine.generate('hello');
      await expectLater(
        generation.result,
        throwsA(isA<GenerationException>().having((e) => e.cause, 'cause', isStateError)),
      );
    });
  });

  group('finish reason (behavior 4)', () {
    test(
      'maxTokens once the decoded tokens reach sampling.maxTokens, stop below, cancelled when cancel came first',
      () async {
        final (engine, backend) = await _loaded();
        backend.reply = (_, _) => ['a', 'b', 'c']; // the fake's counters say 3 decoded tokens
        Future<FinishReason> finish(int maxTokens) async =>
            (await engine.generate('p', GenerationOptions(sampling: SamplingOptions(maxTokens: maxTokens))).result)
                .finishReason;
        expect(await finish(3), FinishReason.maxTokens);
        expect(await finish(2), FinishReason.maxTokens);
        expect(await finish(4), FinishReason.stop);
        backend.reply = null;
        final cancelled = engine.generate('p', const GenerationOptions(sampling: SamplingOptions(maxTokens: 3)));
        await pumpEventQueue();
        backend.generations.last.piece('a');
        await pumpEventQueue();
        cancelled.cancel();
        expect((await cancelled.result).finishReason, FinishReason.cancelled, reason: 'even with 3 decoded tokens');
      },
    );
  });

  group('per-call stats (behavior 5)', () {
    test('measured as the first adapter measured them: prompt count, runtime counters, wall clock', () async {
      final (engine, backend) = await _loaded();
      backend.reply = (_, _) => ['Ciao', '!'];
      final result = await engine.generate('x' * 40).result;
      final stats = result.stats;
      expect(result.text, 'Ciao!');
      expect(
        [stats.promptTokens, stats.prefillTokens, stats.prefillMs, stats.decodeTokens, stats.reusedPrefixTokens],
        [10, 9, 30.0, 3, 1],
        reason: 'prompt = tokenize(prompt); prefill, decode and their times = the runtime counters',
      );
      expect((stats.engineDecodeMs, stats.engineSampleMs, stats.loadMs), (5.0, 7.0, engine.info!.loadMs));
      expect(stats.timeToFirstTokenMs, lessThanOrEqualTo(stats.totalMs));
      expect(stats.decodeMs, closeTo(stats.totalMs - stats.timeToFirstTokenMs, 1e-9));
    });

    test('without runtime counters the prefill is the prompt token count', () async {
      final (engine, backend) = await _loaded();
      backend
        ..perf = null
        ..reply = (_, _) => ['ok'];
      final stats = (await engine.generate('x' * 40).result).stats;
      expect(
        [stats.promptTokens, stats.prefillTokens, stats.prefillMs, stats.decodeTokens, stats.reusedPrefixTokens],
        [10, 10, 0.0, 0, 0],
      );
      expect((stats.engineDecodeMs, stats.engineSampleMs), (null, null));
    });
  });

  group('paramsFor (behavior 6)', () {
    test('every GenerationOptions field maps to its llamadart parameter; the others keep llamadart defaults', () {
      const options = GenerationOptions(
        sampling: SamplingOptions(
          maxTokens: 64,
          temperature: 0.7,
          topK: 20,
          topP: 0.8,
          minP: 0.05,
          repeatPenalty: 1.1,
          presencePenalty: 0.5,
          seed: 42,
        ),
        stop: ['</s>'],
        grammar: Grammar('root ::= "a"'),
        preservedTokens: ['<a>'],
        reusePromptPrefix: false,
        streamChunkTokens: 4,
      );
      final params = LlamadartEngine.paramsFor(options);
      expect(
        {
          'maxTokens': params.maxTokens,
          'temp': params.temp,
          'topK': params.topK,
          'topP': params.topP,
          'minP': params.minP,
          'penalty': params.penalty,
          'presencePenalty': params.presencePenalty,
          'seed': params.seed,
          'stopSequences': params.stopSequences,
          'grammar': params.grammar,
          'grammarLazy': params.grammarLazy,
          'grammarTriggers': params.grammarTriggers,
          'preservedTokens': params.preservedTokens,
          'reusePromptPrefix': params.reusePromptPrefix,
          'streamBatchTokenThreshold': params.streamBatchTokenThreshold,
        },
        {
          'maxTokens': 64,
          'temp': 0.7,
          'topK': 20,
          'topP': 0.8,
          'minP': 0.05,
          'penalty': 1.1,
          'presencePenalty': 0.5,
          'seed': 42,
          'stopSequences': ['</s>'],
          'grammar': 'root ::= "a"',
          'grammarLazy': false,
          'grammarTriggers': isEmpty,
          'preservedTokens': ['<a>'],
          'reusePromptPrefix': false,
          'streamBatchTokenThreshold': 4,
        },
      );
      const defaults = ll.GenerationParams();
      expect(
        [
          params.thinkingBudget,
          params.grammarRoot,
          params.speculativeDecoding,
          params.speculativeDecodingConfig,
          params.streamBatchByteThreshold,
        ],
        [
          defaults.thinkingBudget,
          defaults.grammarRoot,
          defaults.speculativeDecoding,
          defaults.speculativeDecodingConfig,
          defaults.streamBatchByteThreshold,
        ],
      );
    });

    test('the four trigger kinds are llamadart trigger types 0 to 3; a grammar with triggers is lazy', () {
      final params = LlamadartEngine.paramsFor(
        const GenerationOptions(
          grammar: Grammar(
            'root ::= "a"',
            triggers: [
              GrammarTrigger.word('<tool_call>'),
              GrammarTrigger.token(151657, '<tool_call>'),
              GrammarTrigger.pattern(r'\{"'),
              GrammarTrigger.patternFull(r'.*\{"'),
            ],
          ),
        ),
      );
      expect(params.grammarLazy, isTrue);
      expect(
        [for (final trigger in params.grammarTriggers) (trigger.type, trigger.value, trigger.token)],
        [(0, '<tool_call>', null), (1, '<tool_call>', 151657), (2, r'\{"', null), (3, r'.*\{"', null)],
      );
    });
  });

  group('modelParamsFor (behavior 7)', () {
    test('the dump covers every field llamadart declares on ModelParams', () async {
      final source = await llamadartSource('core/models/inference/model_params.dart');
      expect(declaredFields(source, 'ModelParams'), unorderedEquals(_modelParamsFields));
    });

    test('default LoadOptions give the first load parameters field by field: micro-batch 0 on macOS, 128 on iOS', () {
      expect(
        _modelParamsDump(LlamadartEngine.modelParamsFor(const LoadOptions(), isIOS: false)),
        _modelParamsDump(_m0ModelParams(microBatchSize: 0)),
      );
      expect(
        _modelParamsDump(LlamadartEngine.modelParamsFor(const LoadOptions(), isIOS: true)),
        _modelParamsDump(_m0ModelParams(microBatchSize: 128)),
      );
    });

    test('every LoadOptions field maps to its llamadart parameter', () {
      final params = LlamadartEngine.modelParamsFor(
        const LoadOptions(
          contextTokens: 2048,
          threads: 4,
          gpuLayers: 10,
          microBatchSize: 64,
          batchSize: 256,
          flashAttention: false,
          kvCacheK: KvCacheQuant.q8_0,
          kvCacheV: KvCacheQuant.q4_0,
          compute: ComputeBackend.vulkan,
        ),
        isIOS: true,
      );
      expect(
        [
          params.contextSize,
          params.numberOfThreads,
          params.numberOfThreadsBatch,
          params.gpuLayers,
          params.microBatchSize,
          params.batchSize,
          params.flashAttention,
          params.cacheTypeK,
          params.cacheTypeV,
          params.preferredBackend,
        ],
        [
          2048,
          4,
          4,
          10,
          64,
          256,
          ll.FlashAttention.disabled,
          ll.KvCacheType.q8_0,
          ll.KvCacheType.q4_0,
          ll.GpuBackend.vulkan,
        ],
      );
      expect(
        [
          for (final compute in ComputeBackend.values)
            LlamadartEngine.modelParamsFor(LoadOptions(compute: compute), isIOS: false).preferredBackend,
        ],
        [ll.GpuBackend.auto, ll.GpuBackend.cpu, ll.GpuBackend.metal, ll.GpuBackend.vulkan, ll.GpuBackend.opencl],
      );
      expect(
        LlamadartEngine.modelParamsFor(const LoadOptions(gpuLayers: -1), isIOS: false).gpuLayers,
        ll.ModelParams.maxGpuLayers,
      );
    });
  });

  group('state files (behavior 8)', () {
    test(
      'saveState tokenizes the prefix with special tokens, prefills it with maxTokens 0, saves those tokens',
      () async {
        final (engine, backend) = await _loaded();
        backend.reply = (_, _) => const [];
        backend.calls.clear();
        const prefix = '<|im_start|>system\nSei un assistente.<|im_end|>\n<|im_start|>user\n';
        final path = '${_tmp.path}/prefix.state';
        final saved = await engine.saveState(path, prefix);
        final tokens = backend.tokensOf(prefix).length;
        expect(backend.calls, [
          'tokenize(${prefix.length} chars, true)',
          'generate(0)',
          'stateSaveFile($tokens tokens)',
        ]);
        expect(backend.generations.single.prompt, prefix);
        expect(backend.generations.single.params.maxTokens, 0, reason: 'every field: the golden, case d');
        expect((saved.path, saved.tokens, saved.bytes), (path, tokens, File(path).lengthSync()));
        expect(saved.ms, greaterThanOrEqualTo(0));
      },
    );

    test('saveState failures are StateFileExceptions: stateSaveFile false, a runtime error', () async {
      final (engine, backend) = await _loaded();
      backend.reply = (_, _) => const [];
      backend.saveResult = false;
      await expectLater(
        engine.saveState('${_tmp.path}/a.state', 'prefix'),
        throwsA(
          isA<StateFileException>().having((e) => e.message, 'message', contains('stateSaveFile returned false')),
        ),
      );
      backend
        ..saveResult = true
        ..tokenizeError = Exception('tokenizer');
      await expectLater(
        engine.saveState('${_tmp.path}/b.state', 'prefix'),
        throwsA(isA<StateFileException>().having((e) => '${e.cause}', 'cause', contains('tokenizer'))),
      );
    });

    test('loadState restores with the context size as token capacity and returns the tokens restored', () async {
      final (engine, backend) = await _loaded(backend: FakeLlamaBackend()..contextSize = 2048);
      expect(await engine.loadState('${_tmp.path}/prefix.state'), 3);
      expect(backend.calls.last, 'stateLoadFile(2048)');
      backend.stateLoadError = Exception('corrupt');
      await expectLater(
        engine.loadState('${_tmp.path}/prefix.state'),
        throwsA(isA<StateFileException>().having((e) => '${e.cause}', 'cause', contains('corrupt'))),
      );
    });
  });

  group('dispose (behavior 10)', () {
    test(
      'queued generations end cancelled, other queued calls fail, the running one is cancelled, then the runtime is freed',
      () async {
        final (engine, backend) = await _loaded();
        final running = engine.generate('running');
        final queued = engine.generate('queued');
        final tokens = engine.tokenize('abcd');
        final save = engine.saveState('${_tmp.path}/s.state', 'prefix');
        await pumpEventQueue();
        backend.generations.single.piece('par');
        await pumpEventQueue();
        final disposed = engine.dispose();
        expect((await queued.result).finishReason, FinishReason.cancelled);
        await expectLater(tokens, throwsStateError);
        await expectLater(save, throwsStateError);
        final result = await running.result;
        expect((result.finishReason, result.text), (FinishReason.cancelled, 'par'));
        await disposed;
        expect(backend.calls.last, 'dispose');
        expect(backend.calls.indexOf('cancelGeneration'), lessThan(backend.calls.indexOf('modelFree')));
        expect((engine.isLoaded, engine.info, engine.supportsStatePersistence), (false, null, false));
      },
    );

    test('after dispose every call throws StateError; a second dispose does nothing', () async {
      final (engine, backend) = await _loaded();
      await engine.dispose();
      expect(() => engine.generate('x'), throwsStateError);
      await expectLater(engine.load(_model()), throwsStateError);
      await expectLater(engine.tokenize('x'), throwsStateError);
      await expectLater(engine.countTokens('x'), throwsStateError);
      await expectLater(engine.saveState('${_tmp.path}/s.state', 'p'), throwsStateError);
      await expectLater(engine.loadState('${_tmp.path}/s.state'), throwsStateError);
      await engine.dispose();
      expect(backend.calls.where((call) => call == 'dispose'), hasLength(1));
    });
  });
}
