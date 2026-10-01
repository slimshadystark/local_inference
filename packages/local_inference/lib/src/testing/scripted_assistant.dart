/// An assistant over a scripted engine, for testing an assistant's configuration without a model.
library;

import 'dart:async';
import 'dart:convert';

import '../agent/assistant.dart';
import '../agent/config.dart';
import '../engine/generation.dart';
import '../engine/options.dart';
import '../model/chat_message.dart';
import '../model/model_profile.dart';
import '../model/prefix/model_identity.dart';
import '../model/prefix/prefix_state_store.dart';
import '../model/qwen_xml_format.dart';
import '../model/tool_call.dart';
import 'gbnf_recognizer.dart';
import 'memory_prefix_store.dart';
import 'qwen35_template.dart';
import 'scripted_engine.dart';

/// What the scripted model answers to one generation.
sealed class ScriptedTurn {
  const ScriptedTurn();

  /// A plain answer.
  const factory ScriptedTurn.text(String text) = ScriptedText;

  /// A call of [name] with [arguments], in the Qwen3.5 XML envelope (the default template's). A model of another
  /// family (`LlamadartFamilyProfile`) writes its own syntax: script its calls with [ScriptedTurn.text], for example
  /// `<|tool_call>call:add{a:2,b:3}<tool_call|>` for Gemma 4 (`scriptedAssistant` refuses a [ScriptedTurn.toolCall]
  /// its profile does not read).
  const factory ScriptedTurn.toolCall(String name, [Map<String, Object?> arguments]) = ScriptedToolCall;

  /// The raw output of the generation.
  String get output;
}

/// [ScriptedTurn.text].
final class ScriptedText extends ScriptedTurn {
  const ScriptedText(this.text);

  /// The answer.
  final String text;

  @override
  String get output => text;
}

/// [ScriptedTurn.toolCall].
final class ScriptedToolCall extends ScriptedTurn {
  const ScriptedToolCall(this.name, [this.arguments = const {}]);

  /// The tool.
  final String name;

  /// Its arguments.
  final Map<String, Object?> arguments;

  @override
  String get output => const QwenXmlToolFormat().render(ToolCall(name, arguments));
}

/// A scripted output the generation's grammar does not admit: the real model could not have written it. It fails
/// the generation and is reported to the zone of the generate call, so the test fails.
final class ScriptRejectedByGrammar extends Error {
  ScriptRejectedByGrammar(this.message);

  /// Which output, and the part the grammar held.
  final String message;

  @override
  String toString() => 'ScriptRejectedByGrammar: $message';
}

/// An [Assistant] with [config] on a [ScriptedEngine] whose outputs are [script], its model loaded (from no file:
/// `ModelIdentity.fixed('scripted.gguf')`). Add more outputs to the engine's `outputs` as the test goes.
///
/// With [validateAgainstGrammar], every generation with a grammar checks its output first: the part from the lazy
/// grammar's trigger on (the whole output for an eager grammar) must be admitted by the grammar ([GbnfRecognizer]),
/// else it fails with [ScriptRejectedByGrammar]. The engine saves prefix states only with a [prefixStore] (else the
/// model prefills every prompt, and no file is written). Throws [StateError] when the model does not load (a
/// [chatTemplate] the config's profile refuses), and [ArgumentError] for a [ScriptedTurn.toolCall] of [script] that
/// the model's profile does not read back as that call (a family other than Qwen3.5's: script it as text).
Future<(Assistant, ScriptedEngine)> scriptedAssistant(
  AssistantConfig config, {
  List<ScriptedTurn> script = const [],
  bool validateAgainstGrammar = true,
  String chatTemplate = qwen35ChatTemplate,
  PrefixStateStore? prefixStore,
  DateTime Function()? wallClock,
}) async {
  final persistence = prefixStore != null;
  final engine = validateAgainstGrammar
      ? _GrammarCheckingEngine(chatTemplate: chatTemplate, supportsStatePersistence: persistence)
      : ScriptedEngine(chatTemplate: chatTemplate, supportsStatePersistence: persistence);
  engine.outputs.addAll([for (final turn in script) turn.output]);
  final assistant = Assistant(
    config,
    engine: () => engine,
    prefixStore: prefixStore ?? InMemoryPrefixStateStore(),
    wallClock: wallClock,
  );
  const file = 'scripted.gguf';
  if (!await assistant.loadModel(file, identity: const ModelIdentity.fixed(file))) {
    final error = assistant.state.loadError;
    await assistant.dispose();
    throw StateError('the scripted model did not load: $error');
  }
  final model = assistant.model!;
  if (model.profile is! Qwen35Profile) {
    final specs = config.toolkit.specs;
    final prompt = model.profile.prepare(model.info, const [ChatMessage.user('.')], tools: specs);
    for (final turn in script.whereType<ScriptedToolCall>()) {
      final read = model.profile.parse(turn.output, specs, prompt).toolCalls;
      if (read.length != 1 || read.single.name != turn.name) {
        await assistant.dispose();
        throw ArgumentError.value(
          turn.name,
          'script',
          "${model.profile} does not read ScriptedTurn.toolCall's Qwen3.5 XML envelope: script the call as "
              "ScriptedTurn.text in the family's own syntax",
        );
      }
    }
  }
  return (assistant, engine);
}

/// A [ScriptedEngine] that checks each output against the generation's grammar.
final class _GrammarCheckingEngine extends ScriptedEngine {
  _GrammarCheckingEngine({required super.chatTemplate, required super.supportsStatePersistence});

  final Map<String, GbnfRecognizer> _recognizers = {};

  @override
  Generation generate(String prompt, [GenerationOptions options = const GenerationOptions()]) {
    final grammar = options.grammar;
    if (grammar != null && outputs.isNotEmpty) {
      final output = outputs.first;
      final held = _held(output, grammar);
      if (held != null && !(_recognizers[grammar.gbnf] ??= GbnfRecognizer(grammar.gbnf)).accepts(held)) {
        final error = ScriptRejectedByGrammar(
          'generation ${prompts.length + 1}: the grammar does not admit ${jsonEncode(held)}',
        );
        Zone.current.handleUncaughtError(error, StackTrace.current);
        throwAfterDeltas = (0, error);
      }
    }
    return super.generate(prompt, options);
  }

  /// The part of [output] the grammar holds: all of it for an eager grammar, else from the first trigger on (null
  /// when no trigger occurs).
  static String? _held(String output, Grammar grammar) {
    if (!grammar.isLazy) return output;
    int? start;
    for (final trigger in grammar.triggers) {
      final at = switch (trigger) {
        GrammarWordTrigger(:final word) => output.indexOf(word),
        GrammarTokenTrigger(:final text) => output.indexOf(text),
        GrammarPatternTrigger(:final regex) => RegExp(regex).firstMatch(output)?.start ?? -1,
        GrammarPatternFullTrigger(:final regex) => RegExp('^(?:$regex)\$').hasMatch(output) ? 0 : -1,
      };
      if (at >= 0 && (start == null || at < start)) start = at;
    }
    return start == null ? null : output.substring(start);
  }
}
