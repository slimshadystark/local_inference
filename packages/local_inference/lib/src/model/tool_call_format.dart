/// How a model family writes tool calls.
library;

import '../engine/options.dart';
import '../grammar/grammar_options.dart';
import 'tool_call.dart';
import 'tool_spec.dart';

/// A model's answer, parsed.
final class ParsedOutput {
  const ParsedOutput({
    required this.text,
    this.toolCalls = const [],
    this.reasoning,
    this.error,
    this.repeatedParameters = const [],
  });

  /// The plain text outside the tool calls and the reasoning, trimmed.
  final String text;

  /// The tool calls, in order.
  final List<ToolCall> toolCalls;

  /// The reasoning (a think block), when there was some.
  final String? reasoning;

  /// Set when a tool call was malformed (and left out of [toolCalls]).
  final String? error;

  /// The parameters a tool call wrote again, as `<tool>.<parameter>`, once per value replaced: the last value is the
  /// one kept. A grammar with `ParameterOrder.free` admits repeats; [error] does not report them.
  final List<String> repeatedParameters;

  /// Whether the answer called a tool.
  bool get hasToolCalls => toolCalls.isNotEmpty;

  @override
  String toString() =>
      'ParsedOutput(${text.length} chars, calls: $toolCalls${reasoning == null ? '' : ', reasoning'}'
      '${error == null ? '' : ', error: $error'}'
      '${repeatedParameters.isEmpty ? '' : ', repeated: $repeatedParameters'})';
}

/// The envelope one model family writes tool calls in: its grammar, its parser and its streaming rule.
abstract interface class ToolCallFormat {
  /// What switches a lazy tool-call grammar on.
  List<GrammarTrigger> get triggers;

  /// Special strings kept as one token each while the grammar constrains the output.
  List<String> get preservedTokens;

  /// The GBNF grammar of a call to one of [tools].
  String grammar(List<ToolSpec> tools, [GrammarOptions options = const GrammarOptions()]);

  /// [raw] (a complete answer) split into text, typed tool calls and reasoning; arguments are typed from each tool's
  /// [ToolSpec.parameters].
  ParsedOutput parse(String raw, List<ToolSpec> tools);

  /// The part of a partial answer that is plain text to show, or null while nothing should be shown.
  String? visibleText(String partialRaw);

  /// [call] as a model writes it (for scripted tests).
  String render(ToolCall call);
}
