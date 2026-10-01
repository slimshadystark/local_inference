// ChatModel on a ScriptedEngine: attach and load, render, stablePrefix,
// generate and complete (visible text, raw deltas, parsed calls, cancel, failures) and the prefix state (build,
// restore, the contextEpoch rule, a missing or unloadable state, unsupported engines, the no-store notice).
import 'dart:async';
import 'dart:io';

import 'package:local_inference/local_inference.dart';
import 'package:local_inference/testing.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

const String _system = 'You are a helpful assistant. Answer briefly.';

List<ChatMessage> _turn(String user, {List<ChatMessage> history = const []}) => [
  const ChatMessage.system(_system),
  ...history,
  ChatMessage.user(user),
];

/// ChatModel.attach with its notices dropped (the no-store notice has its own test).
ChatModel _attach(InferenceEngine engine, {ModelProfile? profile, PrefixStateStore? prefixStore}) =>
    ChatModel.attach(engine, profile: profile, prefixStore: prefixStore, log: (_) {});

/// A ChatML template with no tool envelope.
const String _chatml =
    '{% for m in messages %}<|im_start|>{{ m.role }}\n{{ m.content }}<|im_end|>\n{% endfor %}'
    '{% if add_generation_prompt %}<|im_start|>assistant\n{% endif %}';

/// Qwen35Profile with another streaming rule, to see what ChatGeneration.text does with it.
final class _StreamingProfile extends ModelProfile {
  _StreamingProfile(this.visible);

  final String? Function(String raw) visible;

  static const Qwen35Profile _qwen = Qwen35Profile();

  @override
  String get id => 'streaming';

  @override
  bool matches(EngineInfo info) => true;

  @override
  String? get prefixMarker => _qwen.prefixMarker;

  @override
  Map<String, Object?> get templateVariables => _qwen.templateVariables;

  @override
  SamplingOptions get sampling => const SamplingOptions(maxTokens: 64);

  @override
  ChatTemplate templateFor(EngineInfo info) => _qwen.templateFor(info);

  @override
  PreparedPrompt prepare(
    EngineInfo info,
    List<ChatMessage> messages, {
    List<ToolSpec> tools = const [],
    ToolMode mode = ToolMode.auto,
    GrammarOptions grammar = const GrammarOptions(),
    Map<String, Object?>? responseSchema,
    bool addGenerationPrompt = true,
  }) => _qwen.prepare(
    info,
    messages,
    tools: tools,
    mode: mode,
    grammar: grammar,
    responseSchema: responseSchema,
    addGenerationPrompt: addGenerationPrompt,
  );

  @override
  ParsedOutput parse(String raw, List<ToolSpec> tools, PreparedPrompt prompt) => _qwen.parse(raw, tools, prompt);

  @override
  String? visibleText(String partialRaw, PreparedPrompt prompt) => visible(partialRaw);
}

void main() {
  late Directory tmp;
  late File modelFile;
  late ScriptedEngine engine;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('chat_model_test');
    modelFile = File('${tmp.path}/qwen3.5-4b-test.gguf')..writeAsStringSync('not a model');
    engine = ScriptedEngine(chatTemplate: template4b);
    await engine.load(modelFile.path);
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  group('attach and load', () {
    test('attach borrows a loaded engine and detects the profile', () async {
      final model = _attach(engine);
      expect(model.profile, isA<Qwen35Profile>());
      expect(model.template.sha256, '8452ca85cb1e0ff04304c02f417a53305d5ba17f6eb9d5693343ad8355f985a8');
      expect((model.engine, model.info), (engine, engine.info));
      await model.dispose();
      expect((engine.disposes, engine.isLoaded), (0, true), reason: 'the engine stays its owner\'s');
      expect(() => model.generate(_turn('hi')), throwsStateError);
      expect(() => _attach(ScriptedEngine()), throwsStateError);
    });

    test('a profile that refuses the template refuses the model', () {
      expect(
        () => _attach(
          engine,
          profile: const Qwen35Profile(
            acceptedTemplateSha256: {'ea210e5b4997b7b1d3af5ee3ad34e7677ffe38df7469e8d88089789b5a27fae5'},
          ),
        ),
        throwsA(isA<UnsupportedModelException>()),
      );
    });

    test('load creates the engine from the factory, loads it, and disposes it with the model', () async {
      final created = ScriptedEngine(chatTemplate: template2b);
      final model = await ChatModel.load(
        modelFile.path,
        options: const LoadOptions(contextTokens: 2048),
        engine: () => created,
        log: (_) {},
      );
      expect((model.engine, model.info.contextTokens), (created, 2048));
      expect(model.profile, isA<Qwen35Profile>());
      await model.dispose();
      await model.dispose();
      expect(created.disposes, 1);
    });

    test('load disposes the engine when the profile refuses the model, and rethrows', () async {
      final created = ScriptedEngine(chatTemplate: template2b);
      await expectLater(
        ChatModel.load(
          modelFile.path,
          engine: () => created,
          log: (_) {},
          profile: const Qwen35Profile(acceptedTemplateSha256: {}),
        ),
        throwsA(isA<UnsupportedModelException>()),
      );
      expect((created.disposes, created.isLoaded), (1, false));
    });
  });

  group('render and stablePrefix', () {
    test('render is the profile\'s rendering with the tools\' declarations', () {
      final model = _attach(engine);
      expect(
        model.render(_turn('Weather?'), tools: toyTools),
        JinjaChatTemplate(template4b).render(
          _turn('Weather?'),
          tools: [for (final tool in toyTools) tool.declaration],
          variables: const {'enable_thinking': false},
        ),
      );
      expect(model.render(_turn('x'), addGenerationPrompt: false), isNot(endsWith('<think>\n\n</think>\n\n')));
    });

    test('with a marker: the rendering of system and tools cut after the first user marker (cp:111-118)', () {
      final model = _attach(engine);
      final prefix = model.stablePrefix(systemPrompt: _system, tools: toyTools)!;
      final probe = model.render(_turn('.'), tools: toyTools);
      expect(prefix, probe.substring(0, probe.indexOf('<|im_start|>user\n') + '<|im_start|>user\n'.length));
      expect(prefix, endsWith('</IMPORTANT>\n\n$_system<|im_end|>\n<|im_start|>user\n'));
      final history = [const ChatMessage.user('Hi'), const ChatMessage.assistant('Hello!')];
      for (final prompt in [
        model.render(_turn('What now?', history: history), tools: toyTools),
        model.render(_turn('Another question'), tools: toyTools),
      ]) {
        expect(prompt, startsWith(prefix));
      }
      expect(model.stablePrefix(systemPrompt: _system), isNot(prefix));
    });

    test('without a marker: the common prefix of two renderings; null when there is none', () async {
      final chatml = ScriptedEngine(chatTemplate: _chatml, metadata: const {'general.architecture': 'llama'});
      await chatml.load(modelFile.path);
      final model = _attach(chatml);
      expect(model.profile, isA<TextOnlyProfile>());
      expect(model.stablePrefix(systemPrompt: 'S'), '<|im_start|>system\nS<|im_end|>\n<|im_start|>user\n');
      final bare = ScriptedEngine(chatTemplate: '{{ messages[1].content }}');
      await bare.load(modelFile.path);
      expect(_attach(bare, profile: const TextOnlyProfile()).stablePrefix(systemPrompt: 'S'), isNull);
      final noMarker = ScriptedEngine(chatTemplate: 'system: {{ messages[0].content }}');
      await noMarker.load(modelFile.path);
      expect(_attach(noMarker, profile: const Qwen35Profile()).stablePrefix(systemPrompt: 'S'), isNull);
    });
  });

  group('generate', () {
    test('streams the visible text in appended pieces and the raw deltas; the result is parsed', () async {
      final model = _attach(engine);
      engine.outputs.add('Buongiorno, come posso aiutarti?  ');
      final generation = model.generate(_turn('Ciao'), tools: toyTools);
      expect(generation.prompt.prompt, model.render(_turn('Ciao'), tools: toyTools));
      final raw = <String>[];
      generation.raw.listen(raw.add);
      final text = await generation.text.toList();
      final result = await generation.result;
      expect(text.join(), 'Buongiorno, come posso aiutarti?');
      expect(text, everyElement(isNotEmpty));
      expect(raw, ['Buongio', 'rno, co', 'me poss', 'o aiuta', 'rti?  ']);
      expect(
        (result.raw, result.text, result.hasToolCalls),
        ('Buongiorno, come posso aiutarti?  ', 'Buongiorno, come posso aiutarti?', false),
      );
      expect((result.finishReason, result.restore, result.stats.decodeTokens), (FinishReason.stop, Duration.zero, 5));
      expect(result.prompt, same(generation.prompt));
    });

    test('TextOnlyProfile: a think tag split across deltas never shows, and the answer after it streams', () async {
      final chatml = ScriptedEngine(chatTemplate: _chatml, metadata: const {'general.architecture': 'llama'});
      await chatml.load(modelFile.path);
      final model = _attach(chatml);
      expect(model.profile, isA<TextOnlyProfile>());
      chatml.outputs.add(' <think>\nhmm\n</think>\n\nIt is sunny today.');
      final generation = model.generate(_turn('Weather?'));
      final text = await generation.text.toList();
      final result = await generation.result;
      expect(text.first, isNot(startsWith('<')), reason: 'the first raw delta is " <think"');
      expect((text.join(), result.text, result.reasoning), ('It is sunny today.', 'It is sunny today.', 'hmm'));
    });

    test('a tool call shows no text and comes back parsed with typed arguments', () async {
      final model = _attach(engine);
      const call = ToolCall('get_weather', {'city': 'Rome', 'days': 2});
      engine.outputs.add(const QwenXmlToolFormat().render(call));
      final generation = model.generate(_turn('Weather in Rome for two days?'), tools: toyTools);
      expect(await generation.text.toList(), isEmpty);
      final result = await generation.result;
      expect(result.toolCalls, [call]);
      expect((result.text, result.parseError), ('', null));
      engine.outputs.add('Let me check.\n${const QwenXmlToolFormat().render(call)}');
      final mixed = model.generate(_turn('And tomorrow?'), tools: toyTools);
      expect((await mixed.text.toList()).join(), 'Let me check.');
      expect((await mixed.result).toolCalls, [call]);
    });

    test('the engine gets the profile\'s stop, grammar and preserved tokens with the sampling', () async {
      final model = _attach(engine);
      engine.outputs.addAll(['a', 'b', 'c', '{}']);
      final auto = model.generate(_turn('x'), tools: toyTools);
      await auto.result;
      expect(engine.options.last, auto.prompt.options(const SamplingOptions()));
      expect(engine.options.last.grammar!.triggers, [const GrammarTrigger.word('<tool_call>')]);
      await model.generate(_turn('x'), tools: toyTools, toolMode: ToolMode.required).result;
      expect(engine.options.last.grammar!.isLazy, isFalse);
      expect(engine.options.last.stop, ['<|im_end|>']);
      const sampling = SamplingOptions(maxTokens: 256);
      await model.generate(_turn('x'), tools: toyTools, toolMode: ToolMode.none, sampling: sampling).result;
      expect((engine.options.last.grammar, engine.options.last.sampling), (null, sampling));
      const schema = {'type': 'object'};
      await model.generate(_turn('x'), responseSchema: schema).result;
      expect(engine.options.last.grammar, Grammar(jsonSchemaGrammar(schema)));
      expect(engine.prompts.last, model.render(_turn('x')));
    });

    test('complete returns the result', () async {
      final model = _attach(engine);
      engine.outputs.add('Fine.');
      final result = await model.complete(_turn('How are you?'));
      expect((result.text, engine.options.last.grammar), ('Fine.', null));
    });

    test('once the visible text stops extending what was sent, nothing more is sent', () async {
      final shown = ['Hel', 'Hello', 'Help!', 'Help! more'];
      var i = 0;
      final model = _attach(engine, profile: _StreamingProfile((_) => shown[i++]));
      engine.outputs.add('x' * 28);
      final generation = model.generate(_turn('x'));
      expect(await generation.text.toList(), ['Hel', 'lo']);
      expect((await generation.result).raw, 'x' * 28);
      expect(engine.options.last.sampling, const SamplingOptions(maxTokens: 64), reason: 'the profile\'s sampling');
    });

    test('nothing is sent while the visible text is null', () async {
      final model = _attach(engine, profile: _StreamingProfile((raw) => raw.length < 14 ? null : raw));
      engine.outputs.add('abcdefghijklmnopq');
      expect(await model.generate(_turn('x')).text.toList(), ['abcdefghijklmn', 'opq']);
    });

    test('cancel mid-stream: the engine stops, the result is cancelled with the text so far', () async {
      final model = _attach(engine);
      engine.outputs.add('A long answer that goes on and on for a while.');
      final generation = model.generate(_turn('Tell me'));
      final pieces = <String>[];
      await for (final piece in generation.text) {
        pieces.add(piece);
        generation.cancel();
      }
      final result = await generation.result;
      expect(result.finishReason, FinishReason.cancelled);
      expect(result.raw.length, lessThan('A long answer that goes on and on for a while.'.length));
      expect(pieces, isNotEmpty);
    });

    test('a failing generation fails the text stream and the result; unobserved, it raises nothing', () async {
      final model = _attach(engine);
      engine.outputs.add('Some text before the failure.');
      engine.throwAfterDeltas = (1, StateError('native failure'));
      final generation = model.generate(_turn('x'));
      await expectLater(generation.text.toList(), throwsA(isA<GenerationException>()));
      await expectLater(generation.result, throwsA(isA<GenerationException>()));
      engine.outputs.add('ignored');
      engine.throwAfterDeltas = (0, StateError('again'));
      model.generate(_turn('y'));
      await Future<void>.delayed(Duration.zero);
    });
  });

  group('prefix state', () {
    late FilePrefixStateStore store;

    setUp(() => store = FilePrefixStateStore('${tmp.path}/states'));

    test('preparePrefix needs a store', () {
      expect(() => _attach(engine).preparePrefix(systemPrompt: _system), throwsStateError);
    });

    test('built the first time (onBuild first), restored by the next model on the same file', () async {
      var builds = 0;
      final model = _attach(engine, prefixStore: store);
      final first = await model.preparePrefix(systemPrompt: _system, tools: toyTools, onBuild: () => builds++);
      expect((first, builds, engine.saves, engine.loads), (PrefixPreparation.built, 1, 1, 0));
      final prefix = model.stablePrefix(systemPrompt: _system, tools: toyTools)!;
      expect(File(Directory(store.directory).listSync().single.path).readAsStringSync(), prefix);
      final again = _attach(engine, prefixStore: store);
      final second = await again.preparePrefix(systemPrompt: _system, tools: toyTools, onBuild: () => builds++);
      expect((second, builds, engine.saves, engine.loads), (PrefixPreparation.restored, 1, 1, 1));
    });

    test('an identity given to attach or load keys the states instead of the file, which need not exist', () async {
      final missing = ScriptedEngine();
      await missing.load('${tmp.path}/no-such-model.gguf');
      const identity = ModelIdentity.fixed('scripted.gguf', sizeBytes: 7, modifiedMs: 9);
      final model = ChatModel.attach(missing, prefixStore: store, identity: identity, log: (_) {});
      expect(await model.preparePrefix(systemPrompt: _system, tools: toyTools), PrefixPreparation.built);
      final prefix = model.stablePrefix(systemPrompt: _system, tools: toyTools)!;
      final key = PrefixKey.of(missing.info!, identity, prefix);
      expect(await store.find(key), isNotNull);
      final loaded = await ChatModel.load(
        '${tmp.path}/no-such-model.gguf',
        engine: () => missing,
        prefixStore: store,
        identity: identity,
        log: (_) {},
      );
      expect(await loaded.preparePrefix(systemPrompt: _system, tools: toyTools), PrefixPreparation.restored);
      await expectLater(
        ChatModel.attach(missing, prefixStore: store, log: (_) {}).preparePrefix(systemPrompt: _system),
        throwsA(isA<FileSystemException>()),
        reason: 'without an identity the file itself is read',
      );
    });

    test('before each generation the prefix is restored when the context moved; the first needs none', () async {
      final model = _attach(engine, prefixStore: store);
      await model.preparePrefix(systemPrompt: _system, tools: toyTools);
      engine.outputs.addAll(['one', 'two', 'three', 'four']);
      final first = await model.complete(_turn('1'), tools: toyTools);
      expect((first.restore, engine.loads), (Duration.zero, 0));
      final second = await model.complete(_turn('2'), tools: toyTools);
      expect(second.restore, greaterThan(Duration.zero));
      expect(engine.loads, 1);
      await engine.generate('a direct call').result;
      await model.complete(_turn('3'), tools: toyTools);
      expect(engine.loads, 2);
      expect(engine.prompts.last, startsWith(model.stablePrefix(systemPrompt: _system, tools: toyTools)!));
    });

    test('a direct engine call between the preparation and the first turn forces a restore', () async {
      final model = _attach(engine, prefixStore: store);
      await model.preparePrefix(systemPrompt: _system, tools: toyTools);
      engine.outputs.addAll(['direct', 'one']);
      await engine.generate('someone else\'s prompt').result;
      final first = await model.complete(_turn('1'), tools: toyTools);
      expect(first.restore, greaterThan(Duration.zero));
      expect((engine.loads, first.raw), (1, 'one'));
    });

    test('generations started together restore in turn, each after the previous one', () async {
      final model = _attach(engine, prefixStore: store);
      await model.preparePrefix(systemPrompt: _system, tools: toyTools);
      engine.outputs.addAll(['one', 'two']);
      final a = model.generate(_turn('a'), tools: toyTools);
      final b = model.generate(_turn('b'), tools: toyTools);
      final results = await Future.wait([a.result, b.result]);
      expect([for (final r in results) r.raw], ['one', 'two']);
      expect((results[0].restore, engine.loads), (Duration.zero, 1));
      expect(results[1].restore, greaterThan(Duration.zero));
    });

    test('a prompt that does not start with the prepared prefix restores nothing', () async {
      final model = _attach(engine, prefixStore: store);
      await model.preparePrefix(systemPrompt: _system, tools: toyTools);
      engine.outputs.addAll(['one', 'two']);
      await model.complete(_turn('1'), tools: toyTools);
      final other = await model.complete(const [ChatMessage.system('Other.'), ChatMessage.user('x')]);
      expect((other.restore, engine.loads), (Duration.zero, 0));
    });

    test('a state gone before a turn is built again; one that fails to load is removed and built again', () async {
      final model = _attach(engine, prefixStore: store);
      await model.preparePrefix(systemPrompt: _system, tools: toyTools);
      engine.outputs.addAll(['one', 'two', 'three']);
      await model.complete(_turn('1'), tools: toyTools);
      for (final file in Directory(store.directory).listSync()) {
        file.deleteSync();
      }
      final rebuilt = await model.complete(_turn('2'), tools: toyTools);
      expect((rebuilt.raw, engine.saves, engine.loads), ('two', 2, 0));
      engine.failNextLoadState = 'corrupt';
      final recovered = await model.complete(_turn('3'), tools: toyTools);
      expect((recovered.raw, engine.saves, engine.loads), ('three', 3, 1));
      expect(Directory(store.directory).listSync(), hasLength(1));
    });

    test('cancelled while the prefix is restored: the generation never starts', () async {
      final model = _attach(engine, prefixStore: store);
      await model.preparePrefix(systemPrompt: _system, tools: toyTools);
      final gate = Completer<void>();
      engine
        ..gate = gate
        ..outputs.add('direct');
      final direct = engine.generate('a direct call');
      final generation = model.generate(_turn('x'), tools: toyTools);
      await Future<void>.delayed(Duration.zero);
      generation.cancel();
      engine.gate = null;
      gate.complete();
      await direct.result;
      final result = await generation.result;
      expect((result.finishReason, result.raw, result.text), (FinishReason.cancelled, '', ''));
      expect(engine.prompts, ['a direct call']);
      expect(engine.loads, 1, reason: 'the restore had started');
      expect(await generation.text.toList(), isEmpty);
    });

    test('unsupported: an engine that cannot save states, a model that can rewind', () async {
      final plain = ScriptedEngine(chatTemplate: template4b, supportsStatePersistence: false);
      await plain.load(modelFile.path);
      final model = _attach(plain, prefixStore: store);
      expect(await model.preparePrefix(systemPrompt: _system), PrefixPreparation.unsupported);
      plain.outputs.addAll(['a', 'b']);
      await model.complete(_turn('1'));
      expect((await model.complete(_turn('2'))).restore, Duration.zero);
      expect((plain.saves, plain.loads), (0, 0));
      final rewinding = ScriptedEngine(chatTemplate: template4b, metadata: const {'general.architecture': 'qwen3'});
      await rewinding.load(modelFile.path);
      expect(
        await _attach(rewinding, prefixStore: store).preparePrefix(systemPrompt: _system),
        PrefixPreparation.unsupported,
      );
    });

    test('no store on a model that cannot rewind: logged once, then every call prefills in full', () async {
      final logs = <String>[];
      final model = ChatModel.attach(engine, log: logs.add);
      engine.outputs.addAll(['a', 'b']);
      await model.complete(_turn('1'));
      await model.complete(_turn('2'));
      expect(logs, hasLength(1));
      expect(logs.single, allOf(contains('cannot rewind'), contains('prefixStore'), contains('qwen35')));
      expect(engine.loads, 0);
      final quiet = <String>[];
      final withStore = ChatModel.attach(engine, prefixStore: store, log: quiet.add);
      engine.outputs.add('c');
      await withStore.complete(_turn('3'));
      final rewinding = ScriptedEngine(chatTemplate: template4b, metadata: const {'general.architecture': 'qwen3'});
      await rewinding.load(modelFile.path);
      rewinding.outputs.add('d');
      await ChatModel.attach(rewinding, log: quiet.add).complete(_turn('4'));
      expect(quiet, isEmpty);
    });
  });
}
