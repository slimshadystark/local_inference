/// Checks and rewrites of the model's plain answers.
library;

import 'dart:async';
import 'dart:convert';

import 'package:meta/meta.dart';

import 'state.dart';
import 'tool_result.dart';

/// Checks a plain answer of the model before it is shown; a verdict replaces it. Guards run on the model's plain
/// answers only: never on streamed text still growing, on app-written replies or on an interrupted answer.
abstract interface class OutputGuard {
  /// A verdict when [answer] must not be shown, null when it may.
  FutureOr<GuardVerdict?> check(String answer, GuardContext context);
}

/// What a guard decided: the text shown instead, and a note for the item's details (`[guard] <note>`).
@immutable
final class GuardVerdict {
  const GuardVerdict(this.replacement, {required this.note});

  /// The text shown instead of the answer.
  final String replacement;

  /// Why, for the details line.
  final String note;

  @override
  String toString() => 'GuardVerdict($note)';
}

/// What a guard may compare an answer with.
@immutable
final class GuardContext {
  const GuardContext({required this.userText, this.window = const [], this.toolOutcomes = const []});

  /// The user's message.
  final String userText;

  /// The history exchanges of the turn's prompt.
  final List<HistoryEntry> window;

  /// The calls the model saw the results of in this turn (`ModelWrittenReplies`); empty otherwise.
  final List<ToolOutcome> toolOutcomes;

  /// Everything the model was told: each exchange of [window] as `user\nassistant`, then [userText], then each
  /// outcome's result as JSON, one per line.
  String get text => [
    for (final entry in window) '${entry.user}\n${entry.assistant}',
    userText,
    for (final outcome in toolOutcomes) jsonEncode(outcome.result.toJson(), toEncodable: (value) => '$value'),
  ].join('\n');
}

/// Regular expressions of the facts a [NumericFactsGuard] looks for, each with its case sensitivity, and how a fact
/// is normalized before it is looked up.
@immutable
final class FactPatterns {
  const FactPatterns(this.patterns, {this.normalize = normalizeFact});

  /// The patterns.
  final List<({String source, bool caseSensitive})> patterns;

  /// The form a fact is compared in; applied to the context too.
  final String Function(String text) normalize;

  /// Amounts in euro, dates (`18/09`, `18/09/2026`), times (`10:30`, `10.30`), numbers of 5 digits or more, and
  /// protocol numbers (`2026/123`); the euro amounts in any case (`10 EURO`).
  static const FactPatterns european = FactPatterns([
    (source: r'\d{1,3}(?:\.\d{3})*(?:,\d{1,2})?\s?(?:€|euro\b)', caseSensitive: false),
    (source: r'€\s?\d{1,3}(?:\.\d{3})*(?:,\d{1,2})?', caseSensitive: true),
    (source: r'\b\d{1,2}/\d{1,2}(?:/\d{2,4})?\b', caseSensitive: true),
    (source: r'\b\d{1,2}[:.]\d{2}\b', caseSensitive: true),
    (source: r'\b\d{5,}\b', caseSensitive: true),
    (source: r'\b\d{4}/\d{3,}\b', caseSensitive: true),
  ]);

  static final Map<(String, bool), RegExp> _compiled = {};

  /// The facts [text] states, normalized, without repeats, sorted.
  List<String> extract(String text) {
    final facts = <String>{};
    for (final pattern in patterns) {
      final regex = _compiled[(pattern.source, pattern.caseSensitive)] ??= RegExp(
        pattern.source,
        caseSensitive: pattern.caseSensitive,
      );
      for (final match in regex.allMatches(text)) {
        facts.add(normalize(match.group(0)!));
      }
    }
    return facts.toList()..sort();
  }

  /// The facts of [text] that do not appear in [context] (both normalized); none for an empty [text].
  List<String> invented(String text, String context) {
    if (text.isEmpty) return const [];
    final known = normalize(context);
    return [
      for (final fact in extract(text))
        if (!known.contains(fact)) fact,
    ];
  }
}

final RegExp _spaces = RegExp(r'\s+');

/// A fact as [FactPatterns] compares it: whitespace removed, lower-cased, `euro` written `€`.
String normalizeFact(String text) => text.replaceAll(_spaces, '').toLowerCase().replaceAll('euro', '€');

/// Replaces a plain answer that states a number (an amount, a date, a time, a code) found nowhere in what the model
/// was told: no tool returned it, so it was invented. The details line is `[guard] <note>: <facts>`.
@immutable
final class NumericFactsGuard implements OutputGuard {
  const NumericFactsGuard({
    required this.replacement,
    this.patterns = FactPatterns.european,
    this.note = 'unverified facts',
  });

  /// The text shown instead.
  final String replacement;

  /// What counts as a fact.
  final FactPatterns patterns;

  /// The details note, before the facts.
  final String note;

  @override
  GuardVerdict? check(String answer, GuardContext context) {
    final invented = patterns.invented(answer, context.text);
    return invented.isEmpty ? null : GuardVerdict(replacement, note: '$note: ${invented.join(', ')}');
  }
}

/// Rewrites the model's text before it is shown: its streamed visible text and its plain answers, never app-written
/// replies.
typedef OutputRewriter = String Function(String text);

/// An [OutputRewriter] that replaces each pair's first text with its second, in order (`replaceAll`).
@immutable
final class ReplaceText {
  const ReplaceText(this.pairs);

  /// `(from, to)` pairs, applied in order.
  final List<(String, String)> pairs;

  /// [text] with every pair applied.
  String call(String text) {
    var out = text;
    for (final (from, to) in pairs) {
      out = out.replaceAll(from, to);
    }
    return out;
  }
}
