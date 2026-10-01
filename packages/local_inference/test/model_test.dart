// LlamadartEngine, ChatModel and the Assistant on a real model. Skipped unless LI_TEST_MODEL names a Qwen3.5 GGUF:
//
//   (cd packages/local_inference && LI_TEST_MODEL=/abs/path/qwen3.5-4b-...-Q5_K_M.gguf dart test -t model)
//
// LI_TEST_TEMPLATE_SHA overrides the expected template sha256 prefix (default 8452ca85, the 4B's). The groups run
// one after the other in this one file, so a single model is in memory at a time.
@Tags(['model'])
library;

import 'dart:io';

import 'package:local_inference/local_inference.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';
import 'support/llama_grammars.dart';

final String? _model = Platform.environment['LI_TEST_MODEL'];

/// The prompts are rendered by hand in the Qwen3.5 layout (ChatML, thinking off): the engine renders nothing.
const String _prefix =
    '<|im_start|>system\nSei un assistente conciso. Rispondi in italiano.<|im_end|>\n<|im_start|>user\n';

String _prompt(String user) => '$_prefix$user<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n';

GenerationOptions _options({int maxTokens = 48}) => GenerationOptions(
  sampling: SamplingOptions(maxTokens: maxTokens),
  stop: const ['<|im_end|>'],
);

void main() {
  group(
    'LlamadartEngine on LI_TEST_MODEL',
    skip: _model == null ? 'set LI_TEST_MODEL to a Qwen3.5 GGUF to run the model tests' : false,
    timeout: const Timeout(Duration(minutes: 5)),
    () {
      late LlamadartEngine engine;
      late EngineInfo info;
      late Directory tmp;

      setUpAll(() async {
        tmp = Directory.systemTemp.createTempSync('li_model_test');
        engine = LlamadartEngine(log: (_) {});
        info = await engine.load(_model!);
      });

      tearDownAll(() async {
        await engine.dispose();
        tmp.deleteSync(recursive: true);
      });

      test('load: the runtime and backend, no BOS, a recurrent qwen35 model with the expected template', () {
        expect(info.runtime.id, 'llamadart 0.8.23 / llama.cpp v0.4.0');
        expect(info.backend, Platform.isMacOS || Platform.isIOS ? 'Metal' : isNotEmpty);
        expect(info.addsBos, isFalse);
        expect((info.architecture, info.isRecurrent), ('qwen35', true));
        expect(info.chatTemplateSha256, startsWith(Platform.environment['LI_TEST_TEMPLATE_SHA'] ?? '8452ca85'));
        expect(info.runtimeDetails['llamadart.chat_format'], isNotNull);
        expect(info.metadata.containsKey('_llamadart.chat_format'), isFalse);
        expect((info.contextTokens, info.options.microBatchSize), (4096, Platform.isIOS ? 128 : 0));
        expect(engine.supportsStatePersistence, isTrue);
      });

      test('1-token streaming: N decoded tokens arrive in at least N - 1 deltas', () async {
        final generation = engine.generate(_prompt('Descrivi il mare in tre frasi.'), _options(maxTokens: 40));
        final deltas = await generation.text.toList();
        final result = await generation.result;
        expect(result.stats.decodeTokens, greaterThan(5));
        expect(deltas.length, greaterThanOrEqualTo(result.stats.decodeTokens - 1));
        expect(deltas.join(), result.text);
      });

      test('greedy decoding: the same prompt twice gives the same text', () async {
        final prompt = _prompt('Come ti chiami?');
        final first = await engine.generate(prompt, _options()).result;
        final second = await engine.generate(prompt, _options()).result;
        expect(first.text, isNotEmpty);
        expect(second.text, first.text);
      });

      test('state round trip: after loadState the prompt gives the same text and prefills only the suffix', () async {
        final prompt = _prompt('Quali servizi offre il Comune?');
        final fresh = await engine.generate(prompt, _options()).result;
        final path = '${tmp.path}/prefix.state';
        final prefixTokens = await engine.countTokens(_prefix);
        final saved = await engine.saveState(path, _prefix);
        expect(saved.tokens, prefixTokens);
        await engine.generate(_prompt('Dimmi una parola.'), _options(maxTokens: 4)).result;
        expect(await engine.loadState(path), prefixTokens);
        final restored = await engine.generate(prompt, _options()).result;
        expect(restored.text, fresh.text);
        expect(restored.stats.promptTokens, fresh.stats.promptTokens);
        expect(restored.stats.prefillTokens, restored.stats.promptTokens - prefixTokens);
      });

      test('cancel mid-stream: finish reason cancelled, with the text so far', () async {
        final generation = engine.generate(_prompt('Racconta una lunga storia su un gatto.'), _options(maxTokens: 200));
        final deltas = <String>[];
        await for (final delta in generation.text) {
          deltas.add(delta);
          if (deltas.length == 3) generation.cancel();
        }
        final result = await generation.result;
        expect(result.finishReason, FinishReason.cancelled);
        expect(result.text, deltas.join());
        expect(deltas.length, lessThan(10), reason: 'the runtime stops at its next token');
      });

      test('cancel while queued: the second generation never runs', () async {
        final first = engine.generate(_prompt('Dimmi una parola.'), _options(maxTokens: 8));
        final second = engine.generate(_prompt('Dimmi un numero.'), _options(maxTokens: 8));
        second.cancel();
        final ran = await first.result;
        final skipped = await second.result;
        expect(ran.finishReason, isNot(FinishReason.cancelled));
        expect(ran.text, isNotEmpty);
        expect(
          (skipped.finishReason, skipped.text, skipped.stats.promptTokens, skipped.stats.decodeTokens),
          (FinishReason.cancelled, '', 0, 0),
        );
      });

      test('contextEpoch: generate, saveState and loadState move it, tokenize does not', () async {
        final path = '${tmp.path}/epoch.state';
        final start = engine.contextEpoch;
        final generation = engine.generate(_prompt('Ciao'), _options(maxTokens: 2));
        expect(engine.contextEpoch, start + 1);
        await generation.result;
        final save = engine.saveState(path, _prefix);
        expect(engine.contextEpoch, start + 2);
        await save;
        final load = engine.loadState(path);
        expect(engine.contextEpoch, start + 3);
        await load;
        await engine.countTokens(_prefix);
        expect(engine.contextEpoch, start + 3);
      });

      test('a generation cut at sampling.maxTokens finishes with maxTokens', () async {
        final result = await engine
            .generate(_prompt('Descrivi il mare in dieci frasi.'), _options(maxTokens: 3))
            .result;
        expect((result.finishReason, result.stats.decodeTokens), (FinishReason.maxTokens, 3));
      });

      test("llama.cpp's grammar parser gives GbnfRecognizer's verdicts (support/llama_grammars.dart)", () async {
        for (final (name, grammar, accepted) in llamaCppGrammars) {
          final result = engine
              .generate(
                _prompt('Scrivi una parola.'),
                GenerationOptions(sampling: const SamplingOptions(maxTokens: 1), grammar: Grammar(grammar)),
              )
              .result;
          if (accepted) {
            try {
              await result;
            } on GenerationException catch (e) {
              fail('$name: refused ($e)');
            }
          } else {
            await expectLater(result, throwsA(isA<GenerationException>()), reason: name);
          }
        }
      });

      test('llama.cpp accepts the grammars the builder writes for every kind of value', () async {
        for (final MapEntry(key: name, value: grammar) in builderGrammars().entries) {
          try {
            await engine
                .generate(
                  _prompt('Scrivi una parola.'),
                  GenerationOptions(sampling: const SamplingOptions(maxTokens: 1), grammar: Grammar(grammar)),
                )
                .result;
          } on GenerationException catch (e) {
            fail('$name: refused ($e)');
          }
        }
      });
    },
  );

  group(
    'ChatModel on LI_TEST_MODEL with a FilePrefixStateStore',
    skip: _model == null ? 'set LI_TEST_MODEL to a Qwen3.5 GGUF to run the model tests' : false,
    timeout: const Timeout(Duration(minutes: 5)),
    () {
      const system = 'You are a helpful assistant. Answer briefly.';
      late Directory tmp;
      late FilePrefixStateStore store;
      late ChatModel model;
      late String prefix;

      List<ChatMessage> turn(String user) => [const ChatMessage.system(system), ChatMessage.user(user)];

      setUpAll(() async {
        tmp = Directory.systemTemp.createTempSync('li_chat_model_test');
        store = FilePrefixStateStore('${tmp.path}/states');
        model = await ChatModel.load(
          _model!,
          engine: () => LlamadartEngine(log: (_) {}),
          prefixStore: store,
        );
        prefix = model.stablePrefix(systemPrompt: system, tools: toyTools)!;
      });

      tearDownAll(() async {
        await model.dispose();
        tmp.deleteSync(recursive: true);
      });

      test('the profile: Qwen35Profile, a model that cannot rewind', () {
        expect(model.profile, isA<Qwen35Profile>());
        expect(model.profile.canRewind(model.info), isFalse);
        expect(prefix, endsWith('<|im_start|>user\n'));
      });

      test('preparePrefix builds the state (onBuild first), then another ChatModel on the file restores it', () async {
        var builds = 0;
        final built = await model.preparePrefix(systemPrompt: system, tools: toyTools, onBuild: () => builds++);
        expect((built, builds), (PrefixPreparation.built, 1));
        expect(Directory(store.directory).listSync().single.path, endsWith('.state'));
        final again = ChatModel.attach(model.engine, prefixStore: store);
        final restored = await again.preparePrefix(systemPrompt: system, tools: toyTools, onBuild: () => builds++);
        expect((restored, builds), (PrefixPreparation.restored, 1));
      });

      test('complete() with the toy tools returns a parsed tool call that validates', () async {
        final result = await model.complete(
          turn('What will the weather be like in Rome over the next three days?'),
          tools: toyTools,
          toolMode: ToolMode.required,
          sampling: const SamplingOptions(maxTokens: 128),
        );
        expect(result.hasToolCalls, isTrue, reason: result.raw);
        final call = result.toolCalls.first;
        final spec = toyTools.firstWhere((tool) => tool.name == call.name);
        expect(validateArguments(spec.parameters, call.arguments), isEmpty, reason: '$call');
        expect(result.parseError, isNull);
        printOnFailure('call: $call');
      });

      test('before each call the prefix is restored, so only the rest of the prompt is prefilled', () async {
        final prefixTokens = await model.engine.countTokens(prefix);
        for (final question in ['Is it going to rain in Oslo?', 'Any notes tagged travel?']) {
          final result = await model.complete(
            turn(question),
            tools: toyTools,
            sampling: const SamplingOptions(maxTokens: 64),
          );
          expect(result.restore, greaterThan(Duration.zero), reason: 'the previous call moved the context');
          final stats = result.stats;
          expect(stats.promptTokens, greaterThan(prefixTokens));
          expect(stats.prefillTokens, stats.promptTokens - prefixTokens);
          expect(stats.reusedPrefixTokens, prefixTokens);
          expect(stats.decodeTokens, greaterThan(0));
          expect(result.finishReason, isNot(FinishReason.cancelled));
          expect(result.prompt.prompt, startsWith(prefix));
        }
      });

      test('streamed visible text equals the parsed text of a plain answer', () async {
        final generation = model.generate(
          turn('Say hello in one short sentence.'),
          sampling: const SamplingOptions(maxTokens: 40),
        );
        final visible = (await generation.text.toList()).join();
        final result = await generation.result;
        expect(result.hasToolCalls, isFalse);
        expect(visible, result.text);
        expect(visible, isNotEmpty);
      });
    },
  );

  group(
    'Assistant on LI_TEST_MODEL',
    skip: _model == null ? 'set LI_TEST_MODEL to a Qwen3.5 GGUF to run the model tests' : false,
    timeout: const Timeout(Duration(minutes: 5)),
    () {
      late Directory tmp;
      late Assistant assistant;
      final ran = <ToolCall>[];

      AssistantTool tool(ToolSpec spec) => AssistantTool(
        name: spec.name,
        description: spec.description,
        parameters: spec.parameters,
        run: (call, context) {
          ran.add(call);
          return ToolResult.ok({'city': call.string('city') ?? 'Rome', 'sky': 'sunny', 'celsius': 24});
        },
      );

      setUpAll(() async {
        tmp = Directory.systemTemp.createTempSync('li_assistant_model_test');
        assistant = Assistant(
          AssistantConfig(
            toolkit: Toolkit.of([for (final spec in toyTools) tool(spec)]),
            prompt: const PromptLayout(
              systemPrompt: 'You are a helpful assistant. Answer briefly.',
              contextLine: ContextLines.english,
            ),
            sampling: const SamplingOptions(maxTokens: 96),
          ),
          engine: () => LlamadartEngine(log: (_) {}),
          prefixStore: FilePrefixStateStore('${tmp.path}/states'),
        );
      });

      tearDownAll(() async {
        await assistant.dispose();
        tmp.deleteSync(recursive: true);
      });

      test('loadModel builds the prefix state the first time; after an unload the same file restores it', () async {
        final phases = <AssistantPhase>[];
        void listener() => phases.add(assistant.state.phase);
        assistant.addListener(listener);
        expect(await assistant.loadModel(_model!), isTrue, reason: '${assistant.state.loadError}');
        expect(phases, [AssistantPhase.loading, AssistantPhase.preparing, AssistantPhase.ready]);
        phases.clear();
        expect(await assistant.unloadModel(), isTrue);
        expect(await assistant.loadModel(_model!), isTrue);
        assistant.removeListener(listener);
        expect(phases, [AssistantPhase.noModel, AssistantPhase.loading, AssistantPhase.ready]);
        expect(assistant.state.info!.architecture, 'qwen35');
      });

      test('a turn with model-written replies: accepted, a reply, the timing line first, one history entry', () async {
        final outcome = await assistant.send('What will the weather be like in Rome tomorrow?');
        final reply = outcome.items.last;
        printOnFailure('${reply.details}');
        expect((outcome.accepted, outcome.error), (true, null));
        expect(outcome.reply, isNotEmpty);
        expect(reply.details, startsWith('restore '));
        expect(reply.stats!.decodeTokens, greaterThan(0));
        expect(assistant.state.phase, AssistantPhase.ready);
        expect(assistant.history.single.user, 'What will the weather be like in Rome tomorrow?');
        expect(assistant.history.single.assistant, outcome.reply);
        // The model calls the tool, then answers from its result.
        expect(ran, isNotEmpty);
        expect(ran.first.name, 'get_weather');
        expect(reply.details, contains('[tool] get_weather '));
        expect(reply.details!.split('\n').where((line) => line.startsWith('restore ')).length, greaterThanOrEqualTo(2));
      });

      test('stop while the model writes: the turn ends at once with the text so far', () async {
        var stopped = false;
        void listener() {
          if (!stopped && assistant.state.isBusy && assistant.state.items.last.text.length > 12) {
            stopped = true;
            assistant.stop();
          }
        }

        assistant.addListener(listener);
        final outcome = await assistant.send('Write four sentences about a lighthouse keeper and the sea.');
        assistant.removeListener(listener);
        printOnFailure('${outcome.items.last.details}');
        expect(outcome.error, isNull);
        expect(assistant.state.phase, AssistantPhase.ready);
        if (stopped) {
          expect(outcome.items.last.stats!.decodeTokens, lessThan(96));
          expect(assistant.history.last.assistant, outcome.reply);
        }
      });
    },
  );
}
