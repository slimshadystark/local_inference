// li_chat: a terminal chat with a GGUF model through local_inference, with two tools (the time and a calculator).
// The model writes the replies from the tool results (ModelWrittenReplies, the default). See README.md.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:li_chat/calculator.dart';
import 'package:local_inference/local_inference.dart';

const String liChatVersion = '0.1.0';

const String _usage = '''
li_chat: chat with a GGUF model on this computer, with two tools (the time and a calculator).

Usage:
  li_chat --model <model.gguf> [--system <prompt>] [--max-tokens <n>] [--no-tools]
  li_chat --version
  li_chat --help

--no-tools chats without the tools, for a model whose family has no tool-call format. In the chat, /new starts a new
conversation and /quit (or the end of the input) leaves.''';

const String _defaultSystem =
    'You are a helpful assistant. Answer briefly. Use the tools for the current time and for arithmetic.';

Future<void> main(List<String> args) async {
  String? model;
  var system = _defaultSystem;
  var maxTokens = 512;
  var tools = true;
  final rest = [...args];
  String valueOf(String flag) => rest.isEmpty ? _fail('$flag needs a value') : rest.removeAt(0);
  while (rest.isNotEmpty) {
    final arg = rest.removeAt(0);
    switch (arg) {
      case '--version':
        stdout.writeln(
          'li_chat $liChatVersion (local_inference $localInferenceVersion, ${LlamadartEngine.defaultRuntime.id})',
        );
        return;
      case '-h' || '--help':
        stdout.writeln(_usage);
        return;
      case '--model':
        model = valueOf(arg);
      case '--system':
        system = valueOf(arg);
      case '--max-tokens':
        maxTokens = int.tryParse(valueOf(arg)) ?? _fail('--max-tokens needs a number');
      case '--no-tools':
        tools = false;
      default:
        _fail('unknown argument $arg');
    }
  }
  if (model == null) _fail('--model is missing');
  if (!File(model).existsSync()) _fail('no file $model');

  final assistant = Assistant(
    AssistantConfig.basic(
      systemPrompt: system,
      tools: tools ? [_time, _calculator] : const [],
    ).copyWith(sampling: SamplingOptions(maxTokens: maxTokens)),
    engine: () => LlamadartEngine(logLevel: EngineLogLevel.error),
    prefixStore: FilePrefixStateStore.temporary(),
  );
  try {
    stdout.writeln('Loading $model ...');
    if (!await assistant.loadModel(model)) {
      final error = assistant.state.loadError;
      // TextOnlyProfile's refusal of tools: the model has a template, but no tool-call format local_inference knows.
      final noToolFormat = error is UnsupportedModelException && error.message.contains('no tool-call format');
      final hint = tools && noToolFormat ? ' (--no-tools chats without the tools)' : '';
      stderr.writeln('li_chat: $error$hint');
      exitCode = 1;
      return;
    }
    final info = assistant.state.info!;
    stdout.writeln('${info.architecture} on ${info.backend}, ${assistant.model!.profile}. /new, /quit');
    await _chat(assistant);
  } finally {
    await assistant.dispose();
  }
}

/// The read-reply loop: each line is a turn; the reply streams as the model writes it, tool calls on their own lines.
Future<void> _chat(Assistant assistant) async {
  final input = StreamIterator(stdin.transform(utf8.decoder).transform(const LineSplitter()));
  try {
    while (true) {
      stdout.write('\n> ');
      if (!await input.moveNext()) break;
      final line = input.current.trim();
      if (line.isEmpty) continue;
      if (line == '/quit') break;
      if (line == '/new') {
        assistant.newConversation();
        stdout.writeln('(a new conversation)');
        continue;
      }
      final turn = assistant.sendStreaming(line);
      // Both streams end before the outcome; a finished tool call prints as it ends.
      await Future.wait([
        turn.text.forEach(stdout.write),
        turn.events.forEach((event) {
          if (event case ToolFinishedEvent(:final outcome)) {
            // As the model reads it (JSON has no Infinity or NaN; this encoder writes them as Python does).
            stdout.writeln('[${outcome.call} -> ${encodeToolResult(outcome)}]');
          }
        }),
      ]);
      final outcome = await turn.outcome;
      if (outcome.error != null) stderr.writeln('\nli_chat: ${outcome.error}');
      stdout.writeln();
    }
  } finally {
    await input.cancel();
  }
}

/// The date and time of this computer.
final AssistantTool _time = AssistantTool(
  name: 'get_time',
  description: 'The current date, time and time zone of this computer.',
  statusLabel: 'Reading the clock...',
  run: (call, context) {
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    return ToolResult.ok({
      'date': '${now.year}-${two(now.month)}-${two(now.day)}',
      'time': '${two(now.hour)}:${two(now.minute)}',
      'weekday': const ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'][now.weekday - 1],
      'timezone': now.timeZoneName,
    });
  },
);

/// A calculator: + - * / ^ and parentheses (lib/calculator.dart).
final AssistantTool _calculator = AssistantTool(
  name: 'calculate',
  description: 'Evaluates an arithmetic expression with + - * / ^ and parentheses, for example (2 + 3) * 4.5.',
  parameters: ToolSchema.object(
    {'expression': ToolSchema.string(description: 'The expression to evaluate.')},
    required: ['expression'],
  ),
  statusLabel: 'Calculating...',
  run: (call, context) {
    final expression = call.string('expression') ?? '';
    try {
      final value = calculate(expression);
      return ToolResult.ok({
        'expression': expression,
        'result': value == value.truncateToDouble() && value.abs() < 1e15 ? value.toInt() : value,
      });
    } on FormatException catch (e) {
      return ToolResult.error('bad_expression', e.message);
    }
  },
);

Never _fail(String message) {
  stderr.writeln('li_chat: $message\n\n$_usage');
  exit(64);
}
