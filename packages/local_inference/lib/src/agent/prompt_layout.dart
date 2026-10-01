/// The messages of a turn's prompt: the system prompt, a window of the history, the newest user message.
library;

import 'package:meta/meta.dart';

import '../model/chat_message.dart';
import 'state.dart';

/// How a turn's prompt is laid out:
///
///     system prompt (+ the tool block the template adds)   <- the saved prefix
///     the last exchanges of the history as plain user / assistant text
///     one user message: the context line, extra context, the new text
///
/// The history holds what the user wrote and what the app showed, never tool calls or tool results.
@immutable
final class PromptLayout {
  const PromptLayout({
    required this.systemPrompt,
    this.contextLine,
    this.historyWindow = 3,
    this.historyCharBudget = 1600,
  });

  /// The system prompt.
  final String systemPrompt;

  /// The first line of the newest user message (the date), from the conversation's day; null for none.
  final String Function(DateTime today)? contextLine;

  /// Most exchanges kept.
  final int historyWindow;

  /// Most characters (user and assistant texts) of the kept exchanges; the newest one is always kept.
  final int historyCharBudget;

  /// The exchanges that go into the prompt: the last [historyWindow], dropping the oldest while they exceed
  /// [historyCharBudget]; the newest is kept whatever its size (it holds the list a follow-up refers to).
  List<HistoryEntry> window(List<HistoryEntry> history) {
    final kept = <HistoryEntry>[];
    var chars = 0;
    for (final entry in history.reversed) {
      if (kept.length >= historyWindow) break;
      final size = entry.user.length + entry.assistant.length;
      if (kept.isNotEmpty && chars + size > historyCharBudget) break;
      kept.insert(0, entry);
      chars += size;
    }
    return kept;
  }

  /// The system prompt, the [window] of [history] as user and assistant messages, then one user message: the
  /// [contextLine] of [today], each of [extraContext] and the trimmed [text] (`' '` when empty), separated by blank
  /// lines.
  List<ChatMessage> messages(
    String text, {
    List<HistoryEntry> history = const [],
    required DateTime today,
    List<String> extraContext = const [],
  }) {
    final trimmed = text.trim();
    final line = contextLine?.call(today);
    final newest = [
      ?line,
      for (final extra in extraContext)
        if (extra.isNotEmpty) extra,
      trimmed.isEmpty ? ' ' : trimmed,
    ].join('\n\n');
    return [
      ChatMessage.system(systemPrompt),
      for (final entry in window(history)) ...[ChatMessage.user(entry.user), ChatMessage.assistant(entry.assistant)],
      ChatMessage.user(newest),
    ];
  }

  @override
  String toString() => 'PromptLayout(${systemPrompt.length} chars, window $historyWindow/$historyCharBudget)';
}
