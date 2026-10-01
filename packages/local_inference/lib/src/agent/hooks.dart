/// The host's step before the model call of a user message.
library;

import 'package:meta/meta.dart';

import 'state.dart';

/// Runs before the model call of a user message (not before an answer to a question or an offer): retrieval,
/// input checks, the host's own pre-turn step. Null lets the turn go on unchanged.
typedef TurnHook = Future<TurnDirective?> Function(TurnRequest request);

/// What a [TurnHook] is told.
@immutable
final class TurnRequest {
  const TurnRequest({required this.text, this.window = const [], required this.today});

  /// The user's message, trimmed.
  final String text;

  /// The history exchanges the prompt will carry.
  final List<HistoryEntry> window;

  /// The conversation's day.
  final DateTime today;
}

/// What a [TurnHook] asks for.
@immutable
sealed class TurnDirective {
  const TurnDirective();

  /// Answer with [text] (written by the app) and call no model.
  const factory TurnDirective.answer(String text) = AnswerDirective;

  /// Add [context] to the newest user message, after the context line (one paragraph each).
  const factory TurnDirective.addContext(List<String> context) = ContextDirective;
}

/// [TurnDirective.answer].
final class AnswerDirective extends TurnDirective {
  const AnswerDirective(this.text);

  /// The reply.
  final String text;
}

/// [TurnDirective.addContext].
final class ContextDirective extends TurnDirective {
  const ContextDirective(this.context);

  /// The paragraphs added.
  final List<String> context;
}
