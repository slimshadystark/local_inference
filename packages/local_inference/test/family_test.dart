// The model-family tests, one GGUF per run; run them once per model to fill the compatibility table of the README:
//
//   (cd packages/local_inference && LI_TEST_MODEL=/abs/model.gguf LI_TEST_REPORT=/abs/report.json dart test -t family)
//
// Plain chat (visible text only, no markup, no reasoning with the profile's default), the grammars of the model's
// profile admitted by llama.cpp, a string argument with a comma, a colon, quotes and a line break read verbatim, the
// prefix path (on a recurrent model the prefix state restored before each call; on the others no restore, the runtime
// reusing the prefix), and two tool rounds with the default ModelWrittenReplies (a toy toolkit: get_time, add), the
// second one asking for text before the call. The measured numbers (prefill and decode tok/s, the time of the tool
// round) and what each check found go to the JSON report at LI_TEST_REPORT. Skipped unless LI_TEST_MODEL is set; a
// model without a chat template is recorded and its checks skipped. The groups run one after the other, so one model is
// in memory at a time.
@Tags(['family'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:local_inference/local_inference.dart';
import 'package:test/test.dart';

final String? _model = Platform.environment['LI_TEST_MODEL'];
final _Report _report = _Report(Platform.environment['LI_TEST_REPORT']);

const String _system = 'You are a helpful assistant. Answer briefly.';

/// About 250 words to summarize: a prompt long enough to measure prefill.
const String _passage =
    'The lighthouse at the end of the harbour was built in 1874, after two fishing boats were lost on the rocks '
    'in a winter storm. For almost a century a keeper lived in the small house at its foot, climbing the spiral '
    'stairs every evening to light the lamp and every morning to clean the lens. The lens, made in Paris, weighed '
    'more than a tonne and floated on a bath of mercury, so that a single man could turn it by hand when the '
    'clockwork failed. In 1962 the light was electrified and the last keeper retired to a village inland, where '
    'he wrote a short book about the ships he had seen pass. Today the tower belongs to the town. Volunteers open '
    'it to visitors on summer weekends, and a small museum in the keeper\'s house shows the old lamp, the logbooks '
    'and a model of the harbour as it looked before the breakwater was extended. The light still works: it flashes '
    'white every ten seconds and can be seen from twenty kilometres away on a clear night. Fishermen say that '
    'they trust it more than any satellite, because it has never once gone dark, not even during the great '
    'storm of 1987, when the power failed across the whole coast and the backup generator kept it turning until '
    'morning.';

/// The toy toolkit's specs.
final ToolSpec _getTime = ToolSpec(
  name: 'get_time',
  description: 'The current time in a time zone.',
  parameters: ToolSchema.object({'timezone': ToolSchema.string(description: 'An IANA time zone, e.g. Europe/Rome.')}),
);

final ToolSpec _add = ToolSpec(
  name: 'add',
  description: 'Adds two integers.',
  parameters: ToolSchema.object({'a': ToolSchema.integer(), 'b': ToolSchema.integer()}, required: ['a', 'b']),
);

final List<ToolSpec> _specs = [_getTime, _add];

final ToolSpec _saveNote = ToolSpec(
  name: 'save_note',
  description: 'Saves a note with the given text.',
  parameters: ToolSchema.object({'text': ToolSchema.string(description: 'The text of the note.')}, required: ['text']),
);

/// The note the string check asks for: a comma, a colon, quotes and a line break.
const String _noteText = 'Call Anna, time: 5pm.\nShe said "hi".';

/// Chat and tool-call markup of the model families: special-token brackets and the envelopes' tags.
final RegExp _markup = RegExp(
  r'<\||\|>|</?(?:tool_call|tool_response|think|function|parameter)\b|\[TOOL_CALLS\]|<(?:start|end)_of_turn>',
);

void main() {
  final skip = _model == null ? 'set LI_TEST_MODEL to a GGUF to run the model-family tests' : false;

  group('model family of LI_TEST_MODEL', skip: skip, timeout: const Timeout(Duration(minutes: 10)), () {
    late Directory tmp;
    late LlamadartEngine engine;
    ChatModel? model;
    String? notChat;
    var tools = const <ToolSpec>[];

    setUpAll(() async {
      tmp = Directory.systemTemp.createTempSync('li_family_test');
      final file = File(_model!);
      _report.set('model', file.uri.pathSegments.last);
      _report.set('path', file.path);
      _report.set('bytes', file.lengthSync());
      _report.set('date', DateTime.now().toIso8601String());
      engine = LlamadartEngine(log: (_) {});
      final EngineInfo info;
      try {
        info = await engine.load(file.path);
      } catch (e) {
        _report.set('error', '$e');
        rethrow;
      }
      _report.set('runtime', info.runtime.id);
      _report.set('backend', info.backend);
      _report.set('architecture', info.architecture);
      _report.set('recurrent', info.isRecurrent);
      _report.set('chatFormat', info.runtimeDetails['llamadart.chat_format']);
      _report.set('templateSha256', info.chatTemplateSha256);
      if (info.chatTemplate == null) {
        notChat = 'no chat template: not a chat model';
        _report.set('skipped', notChat);
        return;
      }
      final chat = model = ChatModel.attach(
        engine,
        prefixStore: FilePrefixStateStore('${tmp.path}/states'),
        log: (_) {},
      );
      final profile = chat.profile;
      _report.set('profile', '$profile');
      _report.set('family', profile is LlamadartFamilyProfile ? profile.family : profile.id);
      _report.set('canRewind', profile.canRewind(info));
      try {
        chat.prepare(_turn('What time is it?'), tools: _specs);
        tools = _specs;
      } on UnsupportedModelException catch (e) {
        _report.set('toolsError', '$e');
      }
      _report.set('tools', tools.isNotEmpty);
      // The first decode compiles the GPU kernels: not part of what is measured.
      await engine
          .generate(chat.render(_turn('Hi')), const GenerationOptions(sampling: SamplingOptions(maxTokens: 1)))
          .result;
    });

    tearDownAll(() async {
      await engine.dispose();
      tmp.deleteSync(recursive: true);
    });

    test('plain chat: the visible text only, no markup; prefill and decode measured', () async {
      if (notChat != null) return markTestSkipped(notChat!);
      final section = _report.section('plainChat');
      final generation = model!.generate(
        _turn('Summarize this text in two sentences.\n\n$_passage'),
        sampling: const SamplingOptions(maxTokens: 96),
      );
      final visible = (await generation.text.toList()).join();
      final result = await generation.result;
      final stats = result.stats;
      section
        ..['text'] = result.text
        ..['reasoning'] = result.reasoning
        ..['finishReason'] = result.finishReason.name
        ..['stats'] = _stats(stats);
      // Prefill over the time to the first token: on Metal the engine's own prefill time is the asynchronous submit
      // of the work, not its end. Decode: the tokens after the first over the wall clock after it.
      _report.set(
        'prefillTokensPerSecond',
        _rate(stats.timeToFirstTokenMs > 0 ? stats.prefillTokens * 1000 / stats.timeToFirstTokenMs : 0),
      );
      _report.set('decodeTokensPerSecond', _rate(stats.decodeTokensPerSecond));
      printOnFailure('raw: ${result.raw}');
      expect(result.text, isNotEmpty);
      expect(visible, result.text, reason: 'the streamed text is the parsed one');
      expect(_markup.hasMatch(visible), isFalse, reason: visible);
      expect(result.hasToolCalls, isFalse);
      expect(result.reasoning, isNull, reason: "thinking is off with the profile's default");
      expect(stats.prefillTokens, greaterThan(200));
      section['ok'] = true;
      _report.save();
    });

    test('grammars: llama.cpp admits the auto and required ones; a required call parses and validates', () async {
      if (notChat != null) return markTestSkipped(notChat!);
      if (tools.isEmpty) return markTestSkipped('the profile has no tool calls');
      final section = _report.section('grammar');
      final messages = _turn('Use the add tool to add 17 and 25.');
      for (final mode in [ToolMode.auto, ToolMode.required]) {
        final prepared = model!.prepare(messages, tools: tools, toolMode: mode);
        final grammar = prepared.grammar;
        section[mode.name] = grammar == null ? 'none' : (grammar.isLazy ? 'lazy' : 'eager');
        _report.save();
        if (grammar == null) continue;
        try {
          await engine.generate(prepared.prompt, prepared.options(const SamplingOptions(maxTokens: 1))).result;
        } on GenerationException catch (e) {
          fail('${mode.name}: llama.cpp refused the grammar ($e)');
        }
      }
      section['admitted'] = true;
      if (section['required'] != 'eager') {
        section['ok'] = true;
        _report.save();
        return;
      }
      _report.save();
      // Room for the whitespace a grammar admits between keys (LFM2's JSON list, before the id it requires).
      final result = await model!.complete(
        messages,
        tools: tools,
        toolMode: ToolMode.required,
        sampling: const SamplingOptions(maxTokens: 192),
      );
      printOnFailure('raw: ${result.raw}');
      section['requiredCall'] = [for (final call in result.toolCalls) '$call'];
      _report.save();
      expect(result.hasToolCalls, isTrue);
      final call = result.toolCalls.first;
      final spec = tools.where((tool) => tool.name == call.name).firstOrNull;
      expect(spec, isNotNull, reason: '$call');
      expect(validateArguments(spec!.parameters, call.arguments), isEmpty, reason: '$call');
      section['ok'] = true;
      _report.save();
    });

    test('a string argument with a comma, a colon, quotes and a line break is read verbatim: in ToolMode.auto (the '
        "model's own syntax) when the model calls, in ToolMode.required always", () async {
      if (notChat != null) return markTestSkipped(notChat!);
      if (tools.isEmpty) return markTestSkipped('the profile has no tool calls');
      final section = _report.section('strings');
      final messages = _turn('Save a note with exactly this text, on two lines:\n$_noteText');
      final modes = [ToolMode.auto, if (_report.value('grammar', 'required') == 'eager') ToolMode.required];
      for (final mode in modes) {
        final result = await model!.complete(
          messages,
          tools: [_saveNote],
          toolMode: mode,
          sampling: const SamplingOptions(maxTokens: 192),
        );
        final text = result.toolCalls.isEmpty ? null : result.toolCalls.first.string('text');
        section[mode.name] = {
          'raw': result.raw,
          'called': result.hasToolCalls,
          'text': text,
          'exact': text == _noteText,
          'parseError': result.parseError,
        };
        _report.save();
        printOnFailure('${mode.name} raw: ${result.raw}');
        expect(result.parseError, isNull, reason: mode.name);
        if (mode == ToolMode.auto && !result.hasToolCalls) continue;
        expect(result.toolCalls.first.name, 'save_note', reason: mode.name);
        expect(text, allOf(contains('Anna'), contains('5pm'), contains('hi')), reason: mode.name);
        expect(text, isNot(anyOf(contains(r'\"'), contains(r'\n'))), reason: '${mode.name}: escapes left in');
      }
      section['ok'] = true;
      _report.save();
    });

    test('the prefix path: on a recurrent model the saved prefix is restored before each call; on the others no '
        'restore, the runtime reusing the prefix', () async {
      if (notChat != null) return markTestSkipped(notChat!);
      final chat = model!;
      final section = _report.section('prefix');
      if (chat.profile.canRewind(chat.info)) {
        section['applies'] = false;
        final preparation = await chat.preparePrefix(systemPrompt: _system, tools: tools);
        section['preparation'] = preparation.name;
        final calls = <Map<String, Object?>>[];
        section['calls'] = calls;
        _report.save();
        expect(preparation, PrefixPreparation.unsupported);
        for (final (i, question) in ['What is the capital of France?', 'Name a colour.', 'Say hello.'].indexed) {
          final result = await chat.complete(
            _turn(question),
            tools: tools,
            toolMode: ToolMode.none,
            sampling: const SamplingOptions(maxTokens: 16),
          );
          calls.add({'restoreMs': result.restore.inMilliseconds, ..._stats(result.stats)});
          _report.save();
          expect(result.restore, Duration.zero, reason: 'call ${i + 1}');
          if (i > 0) {
            expect(result.stats.prefillTokens, lessThan(result.stats.promptTokens), reason: 'call ${i + 1}: reused');
          }
        }
        section['ok'] = true;
        _report.save();
        return;
      }
      section['applies'] = true;
      final prepared = await chat.preparePrefix(systemPrompt: _system, tools: tools);
      section['preparation'] = prepared.name;
      _report.save();
      expect(prepared, PrefixPreparation.built);
      final prefix = chat.stablePrefix(systemPrompt: _system, tools: tools)!;
      final prefixTokens = await engine.countTokens(prefix);
      section['prefixTokens'] = prefixTokens;
      final calls = <Map<String, Object?>>[];
      section['calls'] = calls;
      // The first call finds the context at the prefix the build left; the next ones restore it.
      final questions = ['What is the capital of France?', 'Name a colour.', 'Say hello.'];
      for (final (i, question) in questions.indexed) {
        final result = await chat.complete(
          _turn(question),
          tools: tools,
          toolMode: ToolMode.none,
          sampling: const SamplingOptions(maxTokens: 16),
        );
        calls.add({'restoreMs': result.restore.inMilliseconds, ..._stats(result.stats)});
        _report.save();
        if (i > 0) expect(result.restore, greaterThan(Duration.zero), reason: 'call ${i + 1}: the context moved');
        expect(result.prompt.prompt, startsWith(prefix));
        expect(result.stats.prefillTokens, result.stats.promptTokens - prefixTokens, reason: 'call ${i + 1}');
      }
      section['ok'] = true;
      _report.save();
    });
  });

  group(
    'one tool round with ModelWrittenReplies on LI_TEST_MODEL',
    skip: skip,
    timeout: const Timeout(Duration(minutes: 10)),
    () {
      late Directory tmp;
      late Assistant assistant;
      final ran = <ToolCall>[];
      String? notReady;

      setUpAll(() async {
        tmp = Directory.systemTemp.createTempSync('li_family_round');
        assistant = Assistant(
          AssistantConfig.basic(
            systemPrompt: _system,
            tools: [
              AssistantTool(
                name: _getTime.name,
                description: _getTime.description,
                parameters: _getTime.parameters,
                run: (call, context) {
                  ran.add(call);
                  return ToolResult.ok({'timezone': call.string('timezone') ?? 'UTC', 'time': '14:30'});
                },
              ),
              AssistantTool(
                name: _add.name,
                description: _add.description,
                parameters: _add.parameters,
                run: (call, context) {
                  ran.add(call);
                  return ToolResult.ok({'sum': (call.integer('a') ?? 0) + (call.integer('b') ?? 0)});
                },
              ),
            ],
          ).copyWith(sampling: const SamplingOptions(maxTokens: 128)),
          engine: () => LlamadartEngine(log: (_) {}),
          prefixStore: FilePrefixStateStore('${tmp.path}/states'),
        );
        if (!await assistant.loadModel(_model!)) notReady = '${assistant.state.loadError}';
      });

      tearDownAll(() async {
        await assistant.dispose();
        tmp.deleteSync(recursive: true);
      });

      test('the model calls get_time, the result goes back, the model writes the answer; the round is timed', () async {
        final section = _report.section('toolRound');
        if (notReady != null) {
          section['skipped'] = notReady;
          _report.save();
          return markTestSkipped('the assistant did not load the model: $notReady');
        }
        // A question the model cannot answer without the tool.
        final watch = Stopwatch()..start();
        final outcome = await assistant.send('What time is it in Tokyo right now? Use the get_time tool.');
        final seconds = watch.elapsedMilliseconds / 1000;
        final reply = outcome.items.last;
        section
          ..['seconds'] = seconds
          ..['calls'] = [for (final call in ran) '$call']
          ..['reply'] = outcome.reply
          ..['generations'] = reply.details?.split('\n').where((line) => line.startsWith('restore ')).length
          ..['mentionsResult'] = outcome.reply.contains('14:30');
        _report.save();
        printOnFailure('${reply.details}');
        expect((outcome.accepted, outcome.error), (true, null));
        expect(ran.map((call) => call.name), contains('get_time'));
        expect(reply.details, contains('[tool] get_time '));
        expect(section['generations'], greaterThanOrEqualTo(2), reason: 'the model answered from the result');
        expect(outcome.reply, isNotEmpty);
        expect(_markup.hasMatch(outcome.reply), isFalse, reason: outcome.reply);
        expect(section['mentionsResult'], isTrue, reason: 'the reply quotes the tool result: ${outcome.reply}');
        expect(assistant.history.single.assistant, outcome.reply);
        section['ok'] = true;
        _report.save();
      });

      test('a round where the model writes text before its call: the reply is written from the result', () async {
        final section = _report.section('textFirstRound');
        if (notReady != null) {
          section['skipped'] = notReady;
          _report.save();
          return markTestSkipped('the assistant did not load the model: $notReady');
        }
        assistant.newConversation();
        ran.clear();
        final watch = Stopwatch()..start();
        final outcome = await assistant.send(
          'Explain what a time zone is in one sentence, then call get_time for Europe/Rome.',
        );
        final reply = outcome.items.last;
        section
          ..['seconds'] = watch.elapsedMilliseconds / 1000
          ..['calls'] = [for (final call in ran) '$call']
          ..['reply'] = outcome.reply
          ..['details'] = reply.details
          ..['mentionsResult'] = outcome.reply.contains('14:30');
        _report.save();
        printOnFailure('${reply.details}');
        expect((outcome.accepted, outcome.error), (true, null));
        if (ran.isEmpty) {
          section['ok'] = true;
          _report.save();
          return markTestSkipped('the model answered without calling get_time');
        }
        expect(outcome.reply, isNot(AssistantStrings.english.notUnderstood), reason: 'the answer after the result');
        expect(outcome.reply, isNotEmpty);
        expect(_markup.hasMatch(outcome.reply), isFalse, reason: outcome.reply);
        section['ok'] = true;
        _report.save();
      });
    },
  );
}

List<ChatMessage> _turn(String user) => [const ChatMessage.system(_system), ChatMessage.user(user)];

Map<String, Object?> _stats(GenerationStats stats) => {
  'promptTokens': stats.promptTokens,
  'prefillTokens': stats.prefillTokens,
  'prefillMs': stats.prefillMs.round(),
  'ttftMs': stats.timeToFirstTokenMs.round(),
  'decodeTokens': stats.decodeTokens,
  'decodeMs': stats.decodeMs.round(),
};

/// [perSecond] to one decimal.
double _rate(double perSecond) => (perSecond * 10).roundToDouble() / 10;

/// The JSON report at LI_TEST_REPORT, written again after each change (a failed check leaves what it found).
final class _Report {
  _Report(this.path);

  final String? path;
  final Map<String, Object?> _data = {};

  void set(String key, Object? value) {
    _data[key] = value;
    save();
  }

  /// A section of the report, `ok: false` until its check passes.
  Map<String, Object?> section(String key) {
    final section = <String, Object?>{'ok': false};
    set(key, section);
    return section;
  }

  /// The [key] of [section]; null when either is missing.
  Object? value(String section, String key) => switch (_data[section]) {
    final Map<String, Object?> values => values[key],
    _ => null,
  };

  void save() {
    final file = path;
    if (file != null) File(file).writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(_data)}\n');
  }
}
