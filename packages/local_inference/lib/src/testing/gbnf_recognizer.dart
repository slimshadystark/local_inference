/// A GBNF interpreter for tests: which strings a grammar admits, with no llama.cpp.
library;

import 'dart:math' as math;

/// Parses a GBNF grammar with llama.cpp's syntax (llama-grammar.cpp at llama.cpp v0.4.0) and tells whether it
/// admits a string.
///
/// Supported: rules `name ::= …` (names of letters, digits and `-`), literals `"…"`, character classes `[…]` and
/// `[^…]` with ranges, `.`, groups, alternation, the quantifiers `? * + {m} {m,} {m,n}`, rule references and `#`
/// comments; escapes `\n \r \t \\ \" \[ \] \- \xHH \uHHHH \UHHHHHHHH`, as llama.cpp's parse_char reads them (any
/// other escape is an error there, so it is one here). A newline ends a rule except inside a group or after `|`.
///
/// Repetitions follow llama.cpp's limits (handle_repetitions): a `{m,n}` maximum above 2000 means no maximum; a
/// minimum above 2000 is an error, and so is a repetition whose bound (the maximum, else the minimum) times the
/// rules its item synthesizes reaches 2000. A group synthesizes one rule, plus every rule its content does: a nested
/// group, the helper rules of a repetition (n - m for `{m,n}`, one for an open one), a rule name met for the first
/// time. A rule reference synthesizes none.
///
/// Construction throws [FormatException] on a syntax error, a rule defined twice, a reference to an undefined rule,
/// a missing root, a repetition llama.cpp refuses or left recursion, which llama.cpp refuses too: a rule that can
/// reach itself before any character, or an open repetition (`*`, `+`, `{m,}`) of an item that llama.cpp takes to
/// be possibly empty (a group or a rule with an alternative that writes nothing, a repetition with no minimum).
final class GbnfRecognizer {
  GbnfRecognizer(String grammar, {this.root = 'root'}) : _rules = _Parser(grammar).parse() {
    for (final entry in _rules.entries) {
      for (final name in _references(entry.value)) {
        if (!_rules.containsKey(name)) throw FormatException('rule ${entry.key} uses the undefined rule $name');
      }
    }
    if (!_rules.containsKey(root)) throw FormatException('no rule named $root');
    _checkLeftRecursion();
  }

  /// The start rule.
  final String root;

  final Map<String, _Expr> _rules;

  /// The names of the rules, in definition order.
  Iterable<String> get ruleNames => _rules.keys;

  /// Whether [rule] (default: [root]) derives exactly [text].
  bool accepts(String text, {String? rule}) {
    final start = rule ?? root;
    if (!_rules.containsKey(start)) throw ArgumentError.value(start, 'rule', 'is not defined');
    final run = _Run(_rules, text.runes.toList());
    return run.rule(start, 0).contains(run.input.length);
  }

  void _checkLeftRecursion() {
    final nullable = <String>{};
    var changed = true;
    while (changed) {
      changed = false;
      for (final entry in _rules.entries) {
        if (!nullable.contains(entry.key) && _nullable(entry.value, nullable)) {
          nullable.add(entry.key);
          changed = true;
        }
      }
    }
    final firsts = {for (final entry in _rules.entries) entry.key: _leftRefs(entry.value, nullable)};
    for (final name in _rules.keys) {
      final seen = <String>{};
      final stack = [...firsts[name]!];
      while (stack.isNotEmpty) {
        final next = stack.removeLast();
        if (next == name) throw FormatException('left recursion in rule $name');
        if (seen.add(next)) stack.addAll(firsts[next] ?? const {});
      }
    }
  }
}

sealed class _Expr {}

final class _Literal extends _Expr {
  _Literal(this.chars);

  final List<int> chars;
}

final class _Chars extends _Expr {
  _Chars(this.ranges, {required this.negated});

  final List<(int, int)> ranges;
  final bool negated;

  bool matches(int c) => ranges.any((r) => c >= r.$1 && c <= r.$2) != negated;
}

final class _Ref extends _Expr {
  _Ref(this.name);

  final String name;
}

final class _Sequence extends _Expr {
  _Sequence(this.items);

  final List<_Expr> items;
}

final class _Choice extends _Expr {
  _Choice(this.options);

  final List<_Expr> options;
}

final class _Repeat extends _Expr {
  _Repeat(this.item, this.min, this.max);

  final _Expr item;
  final int min;
  final int? max;
}

Iterable<String> _references(_Expr expr) sync* {
  switch (expr) {
    case _Ref(:final name):
      yield name;
    case _Sequence(:final items):
      for (final item in items) {
        yield* _references(item);
      }
    case _Choice(:final options):
      for (final option in options) {
        yield* _references(option);
      }
    case _Repeat(:final item):
      yield* _references(item);
    case _Literal() || _Chars():
      break;
  }
}

bool _nullable(_Expr expr, Set<String> nullableRules) => switch (expr) {
  _Literal(:final chars) => chars.isEmpty,
  _Chars() => false,
  _Ref(:final name) => nullableRules.contains(name),
  _Sequence(:final items) => items.every((item) => _nullable(item, nullableRules)),
  _Choice(:final options) => options.any((option) => _nullable(option, nullableRules)),
  _Repeat(:final item, :final min) => min == 0 || _nullable(item, nullableRules),
};

/// The rules that can start a derivation of [expr] before any character is read.
Set<String> _leftRefs(_Expr expr, Set<String> nullableRules) {
  switch (expr) {
    case _Ref(:final name):
      return {name};
    case _Sequence(:final items):
      final out = <String>{};
      for (final item in items) {
        out.addAll(_leftRefs(item, nullableRules));
        if (!_nullable(item, nullableRules)) break;
      }
      return out;
    case _Choice(:final options):
      return {for (final option in options) ..._leftRefs(option, nullableRules)};
    case _Repeat(:final item):
      return _leftRefs(item, nullableRules);
    case _Literal() || _Chars():
      return const {};
  }
}

/// One recognition: every end position each rule reaches from each start position, memoized.
final class _Run {
  _Run(this.rules, this.input);

  final Map<String, _Expr> rules;
  final List<int> input;
  final Map<(String, int), Set<int>> _memo = {};

  Set<int> rule(String name, int pos) {
    final key = (name, pos);
    final known = _memo[key];
    if (known != null) return known;
    _memo[key] = const {}; // a rule met again at the same position (left recursion) matches nothing there
    final result = match(rules[name]!, pos);
    _memo[key] = result;
    return result;
  }

  Set<int> match(_Expr expr, int pos) {
    switch (expr) {
      case _Literal(:final chars):
        if (pos + chars.length > input.length) return const {};
        for (var i = 0; i < chars.length; i++) {
          if (input[pos + i] != chars[i]) return const {};
        }
        return {pos + chars.length};
      case _Chars():
        return pos < input.length && expr.matches(input[pos]) ? {pos + 1} : const {};
      case _Ref(:final name):
        return rule(name, pos);
      case _Sequence(:final items):
        var positions = {pos};
        for (final item in items) {
          positions = {for (final p in positions) ...match(item, p)};
          if (positions.isEmpty) break;
        }
        return positions;
      case _Choice(:final options):
        return {for (final option in options) ...match(option, pos)};
      case _Repeat(:final item, :final min, :final max):
        final out = <int>{if (min == 0) pos};
        var frontier = {pos};
        final settled = <int>{};
        for (var count = 1; max == null || count <= max; count++) {
          final next = {for (final p in frontier) ...match(item, p)};
          if (count >= min) {
            out.addAll(next);
            if (max == null) {
              next.removeAll(settled);
              settled.addAll(next);
            }
          }
          if (next.isEmpty) break;
          frontier = next;
        }
        return out;
    }
  }
}

final class _Parser {
  _Parser(String source) : chars = source.runes.toList();

  final List<int> chars;
  int pos = 0;

  /// MAX_REPETITION_THRESHOLD of llama-grammar.cpp.
  static const int _repetitionLimit = 2000;

  /// llama.cpp's symbol table: the rule names met so far (defined or referenced), and the rules it synthesized
  /// (groups and repetition helpers).
  final Set<String> _names = {};
  int _synthesized = 0;

  int get _symbols => _names.length + _synthesized;

  /// Whether each rule has an alternative that writes no symbol (rules_may_be_empty of
  /// llama_grammar_detect_left_recursion).
  final Map<String, bool> _mayBeEmpty = {};

  /// The open repetitions (`*`, `+`, `{m,}`) whose item writes only references, with their names and position:
  /// llama.cpp's helper rule `R ::= item R | ` is left-recursive when every rule named may be empty.
  final List<(Set<String>, int)> _openRepeats = [];

  bool get _end => pos >= chars.length;

  int get _peek => chars[pos];

  Map<String, _Expr> parse() {
    final rules = <String, _Expr>{};
    _space(newlines: true);
    while (!_end) {
      final name = _name();
      _names.add(name);
      _space(newlines: false);
      _expect('::=');
      _space(newlines: true);
      final (body, mayBeEmpty) = _alternatives(nested: false);
      if (rules.containsKey(name)) _fail('rule $name defined twice');
      rules[name] = body;
      _mayBeEmpty[name] = mayBeEmpty;
      _space(newlines: false);
      if (!_end && _peek != 0x0A && _peek != 0x0D) _fail('unexpected ${String.fromCharCode(_peek)}');
      _space(newlines: true);
    }
    for (final (names, at) in _openRepeats) {
      if (names.every((name) => _mayBeEmpty[name] ?? false)) {
        pos = at;
        _fail('an open repetition of an item that may be empty: left recursion to llama.cpp');
      }
    }
    return rules;
  }

  /// The alternatives at [pos], and whether one of them writes no symbol.
  (_Expr, bool) _alternatives({required bool nested}) {
    final (first, firstEmpty) = _sequence(nested: nested);
    final options = [first];
    var anyEmpty = firstEmpty;
    while (!_end && _peek == 0x7C) {
      pos++;
      _space(newlines: true);
      final (option, empty) = _sequence(nested: nested);
      options.add(option);
      anyEmpty = anyEmpty || empty;
    }
    return (options.length == 1 ? options.single : _Choice(options), anyEmpty);
  }

  /// The sequence at [pos], and whether it writes no symbol (only empty literals).
  (_Expr, bool) _sequence({required bool nested}) {
    final items = <_Expr>[];
    var empty = true;
    // n_prev_rules of parse_sequence: the rules the last item synthesized, times the bounds applied to it.
    var synthesizedByLast = 1;
    // The last item wrote no symbol (an empty literal): llama.cpp has nothing to repeat after it.
    var lastWroteNothing = false;
    // When the last item writes only references: the rules named that decide whether they may be empty (none: they
    // may). Null when it writes a character.
    Set<String>? lastRefs;
    while (!_end) {
      final c = _peek;
      if (c == 0x22) {
        final literal = _literal();
        items.add(literal);
        synthesizedByLast = 1;
        lastWroteNothing = literal.chars.isEmpty;
        lastRefs = null;
        if (!lastWroteNothing) empty = false;
      } else if (c == 0x5B) {
        items.add(_class());
        synthesizedByLast = 1;
        (lastWroteNothing, lastRefs, empty) = (false, null, false);
      } else if (c == 0x28) {
        pos++;
        final before = _symbols;
        _synthesized++;
        _space(newlines: true);
        final (group, groupMayBeEmpty) = _alternatives(nested: true);
        items.add(group);
        _space(newlines: true);
        _expect(')');
        synthesizedByLast = math.max(1, _symbols - before);
        (lastWroteNothing, lastRefs, empty) = (false, groupMayBeEmpty ? const {} : null, false);
      } else if (c == 0x2E) {
        pos++;
        items.add(_Chars(const [], negated: true));
        synthesizedByLast = 1;
        (lastWroteNothing, lastRefs, empty) = (false, null, false);
      } else if (_isWordChar(c)) {
        final name = _name();
        _names.add(name);
        items.add(_Ref(name));
        synthesizedByLast = 1;
        (lastWroteNothing, lastRefs, empty) = (false, {name}, false);
      } else if (c == 0x2A || c == 0x2B || c == 0x3F || c == 0x7B) {
        if (items.isEmpty || lastWroteNothing) _fail('a quantifier with nothing before it');
        final at = pos;
        final (min, max) = _quantifier(nested: nested);
        // handle_repetitions (llama-grammar.cpp:463-528 at llama.cpp v0.4.0).
        final bound = max != null && max > 0 ? max : (min > 0 ? min : 1);
        if (synthesizedByLast * bound >= _repetitionLimit) {
          _fail(
            '$synthesizedByLast synthesized rules repeated $bound times: llama.cpp refuses $_repetitionLimit or more',
          );
        }
        _synthesized += max == null ? 1 : max - min;
        synthesizedByLast *= bound;
        if (max == null && lastRefs != null) _openRepeats.add((lastRefs, at));
        // With no minimum the item becomes a reference to a helper rule that may be empty.
        if (min == 0) lastRefs = const {};
        items.add(_Repeat(items.removeLast(), min, max));
      } else {
        break;
      }
      _space(newlines: nested);
    }
    return (items.length == 1 ? items.single : _Sequence(items), empty);
  }

  /// The bounds of the quantifier at [pos]; null: no maximum. A `{m,n}` maximum above 2000 is none, a minimum above
  /// 2000 an error (llama-grammar.cpp:652-657).
  (int, int?) _quantifier({required bool nested}) {
    final c = chars[pos++];
    switch (c) {
      case 0x2A:
        return (0, null);
      case 0x2B:
        return (1, null);
      case 0x3F:
        return (0, 1);
    }
    _space(newlines: nested);
    final min = _int();
    _space(newlines: nested);
    int? max = min;
    if (!_end && _peek == 0x2C) {
      pos++;
      _space(newlines: nested);
      max = !_end && _isDigit(_peek) ? _int() : null;
      _space(newlines: nested);
    }
    _expect('}');
    if (min > _repetitionLimit) _fail('a minimum of $min repetitions: llama.cpp allows $_repetitionLimit at most');
    if (max != null && max > _repetitionLimit) max = null;
    // llama.cpp does not check this one: its helper-rule count underflows.
    if (max != null && max < min) _fail('{$min,$max}: the maximum is below the minimum');
    return (min, max);
  }

  int _int() {
    final start = pos;
    while (!_end && _isDigit(_peek)) {
      pos++;
    }
    if (pos == start) _fail('expected a number');
    return int.parse(String.fromCharCodes(chars, start, pos));
  }

  _Literal _literal() {
    pos++;
    final out = <int>[];
    while (true) {
      if (_end) _fail('unterminated literal');
      if (_peek == 0x22) break;
      out.add(_char());
    }
    pos++;
    return _Literal(out);
  }

  _Chars _class() {
    pos++;
    var negated = false;
    if (!_end && _peek == 0x5E) {
      negated = true;
      pos++;
    }
    final ranges = <(int, int)>[];
    while (true) {
      if (_end) _fail('unterminated character class');
      if (_peek == 0x5D) break;
      final low = _char();
      if (pos + 1 < chars.length && _peek == 0x2D && chars[pos + 1] != 0x5D) {
        pos++;
        final high = _char();
        if (high < low) _fail('empty range');
        ranges.add((low, high));
      } else {
        ranges.add((low, low));
      }
    }
    pos++;
    return _Chars(ranges, negated: negated);
  }

  /// One character of a literal or a class, with llama.cpp's escapes (parse_char).
  int _char() {
    final c = chars[pos++];
    if (c != 0x5C) return c;
    if (_end) _fail('unterminated escape');
    final e = chars[pos++];
    switch (e) {
      case 0x78:
        return _hex(2);
      case 0x75:
        return _hex(4);
      case 0x55:
        return _hex(8);
      case 0x74:
        return 0x09;
      case 0x72:
        return 0x0D;
      case 0x6E:
        return 0x0A;
      case 0x5C || 0x22 || 0x5B || 0x5D || 0x2D:
        return e;
      default:
        _fail('unknown escape \\${String.fromCharCode(e)} (llama.cpp rejects it)');
    }
  }

  int _hex(int digits) {
    if (pos + digits > chars.length) _fail('short hex escape');
    final value = int.tryParse(String.fromCharCodes(chars, pos, pos + digits), radix: 16);
    if (value == null) _fail('bad hex escape');
    pos += digits;
    return value;
  }

  String _name() {
    final start = pos;
    while (!_end && _isWordChar(_peek)) {
      pos++;
    }
    if (pos == start) _fail('expected a rule name');
    return String.fromCharCodes(chars, start, pos);
  }

  void _expect(String text) {
    for (final c in text.runes) {
      if (_end || _peek != c) _fail('expected "$text"');
      pos++;
    }
  }

  /// Skips spaces, tabs and comments; newlines too when [newlines].
  void _space({required bool newlines}) {
    while (!_end) {
      final c = _peek;
      if (c == 0x20 || c == 0x09 || (newlines && (c == 0x0A || c == 0x0D))) {
        pos++;
      } else if (c == 0x23) {
        while (!_end && _peek != 0x0A && _peek != 0x0D) {
          pos++;
        }
      } else {
        break;
      }
    }
  }

  Never _fail(String message) {
    final line = String.fromCharCodes(chars.take(pos)).split('\n').length;
    throw FormatException('GBNF line $line: $message', String.fromCharCodes(chars), pos);
  }

  static bool _isDigit(int c) => c >= 0x30 && c <= 0x39;

  static bool _isWordChar(int c) =>
      (c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A) || c == 0x2D || (c >= 0x30 && c <= 0x39);
}
