/// How the tool-call grammar is built: string shapes, parameter order, value rules and size limits.
library;

import 'package:meta/meta.dart';

import 'gbnf_rules.dart';

/// How free-text string values may look inside a tool call's XML envelope.
enum StringValues {
  /// One line with no `<` or `>`: `text-line ::= [^<>\n]+`.
  singleLine,

  /// Any text that never contains `</`, so no value can close `</parameter>` early:
  /// `xml-text ::= ([^<] | "<"+ [^</])+ "<"*`.
  multiLine,
}

/// In which order the grammar lets a tool call list its parameters. Every order admits each parameter at most once
/// and requires the required ones, except [free].
enum ParameterOrder {
  /// [permutations] up to 3 parameters, [anyOrderOnce] up to [GrammarOptions.exactOrderLimit], [free] above.
  auto,

  /// One alternative per ordering of all parameters, the optional ones marked `?`: any order. n! alternatives.
  permutations,

  /// The same language as [permutations] as a subset automaton: one rule per set of parameters already written.
  anyOrderOnce,

  /// The declaration order only.
  declared,

  /// Any parameters, in any order, any number of times: the parser lists repeats (`ParsedOutput.repeatedParameters`),
  /// the validator checks the rest.
  free,
}

/// Where a value is written.
enum ValueContext {
  /// The text between `<parameter=NAME>\n` and `\n</parameter>`: strings raw, other values as JSON.
  xmlParameter,

  /// Inside a JSON value (an object's property, an array's item, a structured response).
  json,
}

/// A custom rule for some values: the builder asks every installed rule, in order, before its own rules.
abstract interface class ValueRule {
  /// The GBNF body of the value [schema] may take in [context], or null to leave it to the next rule (and in the
  /// end to the built-in rules). [rules] defines any helper rule the body needs and escapes literals.
  String? build(Map<String, Object?> schema, GbnfRules rules, ValueContext context);

  /// Complete rule lines (`name ::= body`) the bodies may reference. They are added to every grammar the rule is
  /// installed in, after the rules of the tools, used or not.
  List<String> get sharedRules;
}

/// The options of the tool-call grammar. The defaults suit any model: multi-line strings, [ParameterOrder.auto],
/// one call.
@immutable
final class GrammarOptions {
  const GrammarOptions({
    this.strings = StringValues.multiLine,
    this.order = ParameterOrder.auto,
    this.valueRules = const [],
    this.maxCalls = 1,
    this.maxRepetition = 64,
    this.exactOrderLimit = 8,
    this.maxRules = 2000,
  });

  /// How free-text strings may look.
  final StringValues strings;

  /// How parameters may be ordered.
  final ParameterOrder order;

  /// Custom value rules, asked in order; the first body wins.
  final List<ValueRule> valueRules;

  /// Tool calls per answer, at least 1; more than one are separated by a newline.
  final int maxCalls;

  /// The largest bounded repetition written (`{m,n}`); a larger bound is left out of the grammar and checked by the
  /// validator. From 1 to 1999: llama.cpp v0.4.0 refuses a bound of 2000, and a grammar built with another value
  /// throws [ArgumentError].
  final int maxRepetition;

  /// [ParameterOrder.auto] uses [ParameterOrder.anyOrderOnce] up to this many parameters, [ParameterOrder.free]
  /// above.
  final int exactOrderLimit;

  /// Above this many rules (or 64 KB of text) the tools with the most parameters fall back to
  /// [ParameterOrder.free], until the grammar fits or every tool is free.
  final int maxRules;

  /// The largest grammar text, in characters, before tools fall back to [ParameterOrder.free].
  static const int maxTextLength = 64 * 1024;

  @override
  bool operator ==(Object other) =>
      other is GrammarOptions &&
      other.strings == strings &&
      other.order == order &&
      _listEquals(other.valueRules, valueRules) &&
      other.maxCalls == maxCalls &&
      other.maxRepetition == maxRepetition &&
      other.exactOrderLimit == exactOrderLimit &&
      other.maxRules == maxRules;

  @override
  int get hashCode =>
      Object.hash(strings, order, Object.hashAll(valueRules), maxCalls, maxRepetition, exactOrderLimit, maxRules);

  @override
  String toString() =>
      'GrammarOptions(strings: ${strings.name}, order: ${order.name}, valueRules: $valueRules, maxCalls: $maxCalls, '
      'maxRepetition: $maxRepetition, exactOrderLimit: $exactOrderLimit, maxRules: $maxRules)';
}

bool _listEquals<T>(List<T> a, List<T> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
