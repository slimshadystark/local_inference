/// Who writes the reply after a tool call: the app ([AppWrittenReplies]) or the model ([ModelWrittenReplies]).
library;

import 'package:meta/meta.dart';

import '../model/python_json.dart';
import '../model/tool_call.dart';
import 'tool_result.dart';

/// How the reply after a tool call is written.
@immutable
sealed class ReplyStrategy {
  const ReplyStrategy();
}

/// The app writes every reply after a call, with [writer]: one model call per user message. For models fine-tuned to
/// call tools that never saw a tool result.
final class AppWrittenReplies extends ReplyStrategy {
  const AppWrittenReplies(this.writer);

  /// Writes the replies.
  final ReplyWriter writer;
}

/// The standard loop: the model's calls and their results (`assistant(toolCalls)` then `tool(result)` messages) go
/// back to the model, which writes the answer. The history keeps (user, final answer) only.
///
/// After [maxToolRounds] rounds of calls the model answers without tools. Each result is encoded by [encodeResult]
/// and cut to [maxResultChars] characters. A call with invalid arguments or an unknown tool is reported to the model
/// as a failure. A call that asks first ends the turn with its question; the calls after it in the same answer do
/// not run, and the model gets a `not_run` failure for each with the asking call's result. Once a call has run, an
/// answer of the model that is stopped or fails keeps the text written so far, else shows `AssistantStrings.done`
/// (`toolFailed` for a failed call); either way it joins the history, so the next prompts carry what ran. There are
/// no offers or follow-ups, and a recorded action is answered with `AssistantStrings.done` (or `toolFailed`) unless
/// it brings its own text.
final class ModelWrittenReplies extends ReplyStrategy {
  const ModelWrittenReplies({this.maxToolRounds = 2, this.maxResultChars = 2000, this.encodeResult = encodeToolResult});

  /// Rounds of calls before the model must answer in text.
  final int maxToolRounds;

  /// A longer tool message is cut to this many characters, then `…` is added.
  final int maxResultChars;

  /// The text of a result for the model.
  final String Function(ToolOutcome outcome) encodeResult;
}

/// A success's payload, or `{'error': message, 'code': code}` for a failure, as Python-style JSON (values that are
/// not JSON are written as their text).
String encodeToolResult(ToolOutcome outcome) => pythonJson(
  _jsonSafe(switch (outcome.result) {
    ToolSuccess(:final payload) => payload,
    ToolFailure(:final message, :final code) => {'error': message, 'code': code},
  }),
);

Object? _jsonSafe(Object? value) => switch (value) {
  null || bool() || num() || String() => value,
  final Map<Object?, Object?> map => {for (final entry in map.entries) '${entry.key}': _jsonSafe(entry.value)},
  final Iterable<Object?> list => [for (final item in list) _jsonSafe(item)],
  _ => '$value',
};

/// Writes the app's reply to an executed call.
abstract interface class ReplyWriter {
  /// The reply to [outcome].
  ToolReply write(ToolOutcome outcome);
}

/// A reply written by the app: [text] goes into the history, [display] into the bubble.
@immutable
final class ToolReply {
  const ToolReply({required this.text, String? display, this.followUp, this.offer}) : _display = display;

  /// A numbered list with an optional closing sentence:
  /// text `'header: 1. a; 2. b. footer'`, display `'header:\n1. a\n2. b\n\nfooter'`; with no items, text
  /// `'header footer'` and display `'header\n\nfooter'`.
  factory ToolReply.numbered({
    required String header,
    List<String> items = const [],
    String? footer,
    ToolCall? followUp,
    ToolCall? offer,
  }) {
    final numbered = [for (final (i, item) in items.indexed) '${i + 1}. $item'];
    final body = items.isEmpty ? header : '$header: ${numbered.join('; ')}.';
    final display = items.isEmpty
        ? (footer == null ? header : '$header\n\n$footer')
        : '$header:\n${numbered.join('\n')}${footer == null ? '' : '\n\n$footer'}';
    return ToolReply(text: footer == null ? body : '$body $footer', display: display, followUp: followUp, offer: offer);
  }

  /// The reply as the history keeps it (one paragraph).
  final String text;

  final String? _display;

  /// The reply as the bubble shows it; [text] when not given.
  String get display => _display ?? text;

  /// A call to run once, right away, after this one (a list shown again): its reply follows this one (texts joined by
  /// a space, displays by a blank line) and its offer replaces this one's.
  final ToolCall? followUp;

  /// A call the reply's closing question offers ("Do you want to see the slots?"): the next yes runs it without the
  /// model, a no answers `AssistantStrings.offerDeclined`, any other message drops it.
  final ToolCall? offer;

  @override
  String toString() =>
      'ToolReply(${text.length} chars${followUp == null ? '' : ', followUp'}'
      '${offer == null ? '' : ', offer'})';
}
