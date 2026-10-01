/// JSON Schema `pattern`s as GBNF, for the subset a grammar can express exactly. Internal.
library;

/// A GBNF body matching exactly the strings [pattern] matches, or null when the pattern is not in the subset.
///
/// The subset: a pattern anchored at both ends (`^…$`, else JSON Schema would search it anywhere), literals and
/// escapes (`\d \w \s \D \W \S \n \t \r \f \v \0 \xHH \uHHHH \u{…}`, escaped punctuation), `.`, classes with
/// ranges and negation, groups (`(…)`, `(?:…)`, `(?<name>…)`), alternation inside a group, and the quantifiers
/// `? * + {m} {m,} {m,n}` (a lazy `?` after them changes nothing here). A bound above [maxRepetition] is dropped
/// (the validator checks it). With [xml] (a value inside `<parameter>`), `.` and negated classes also exclude `<`,
/// so a value cannot close its parameter. With [json] (the content of a JSON string), they also exclude `"`, `\` and
/// control characters, and a pattern that names one of them is not in the subset: the body matches the raw
/// characters between the quotes.
///
/// A repeated group that holds a repetition or another group becomes a rule of its own, named by [defineGroup]
/// (given the rule's body): llama.cpp refuses to repeat a group whose inner rules times the bound reach 2000, and a
/// rule reference counts as one. [defineGroup] is called only when the pattern is in the subset.
String? regexBody(
  String pattern, {
  required bool xml,
  bool json = false,
  required int maxRepetition,
  required String Function(String body) defineGroup,
}) {
  final chars = pattern.runes.toList();
  if (chars.length < 2 || chars.first != _caret || chars.last != _dollar) return null;
  if (chars.length >= 3 && chars[chars.length - 2] == _backslash && !_escapedBackslashBefore(chars, chars.length - 2)) {
    return null; // the final `$` is escaped: not an anchor
  }
  final parser = _Parser(
    chars.sublist(1, chars.length - 1),
    excluded: [
      if (xml) (0x3C, 0x3C),
      if (json) ...[(0x00, 0x1F), (0x22, 0x22), (0x5C, 0x5C)],
    ],
  );
  final List<List<_Quantified>> alternatives;
  try {
    alternatives = parser.parseAlternatives();
    if (!parser.atEnd) return null;
  } on _Unsupported {
    return null;
  }
  // `^a|b$` means (^a)|(b$), not ^(a|b)$.
  if (alternatives.length != 1) return null;
  if (json && !_jsonSafe(alternatives)) return null;
  return _Renderer(maxRepetition, defineGroup).sequence(alternatives.single);
}

/// Whether no literal or positive class of [alternatives] names a character a JSON string escapes (negated classes
/// already exclude them).
bool _jsonSafe(List<List<_Quantified>> alternatives) {
  bool safe(_Node node) => switch (node) {
    _Literal(:final char) => !_escapedInJson((char, char)),
    _Class(negated: true) => true,
    _Class(:final ranges) => !ranges.any(_escapedInJson),
    _Group(:final alternatives) => _jsonSafe(alternatives),
  };
  return alternatives.every((sequence) => sequence.every((item) => safe(item.node)));
}

/// Whether [range] holds a control character, `"` or `\`.
bool _escapedInJson((int, int) range) {
  final (lo, hi) = range;
  return lo <= 0x1F || (lo <= 0x22 && hi >= 0x22) || (lo <= 0x5C && hi >= 0x5C);
}

const int _caret = 0x5E, _dollar = 0x24, _backslash = 0x5C;

bool _escapedBackslashBefore(List<int> chars, int index) {
  var count = 0;
  for (var i = index - 1; i >= 0 && chars[i] == _backslash; i--) {
    count++;
  }
  return count.isOdd;
}

final class _Unsupported implements Exception {
  const _Unsupported();
}

sealed class _Node {}

final class _Literal extends _Node {
  _Literal(this.char);

  final int char;
}

final class _Class extends _Node {
  _Class(this.ranges, {required this.negated});

  final List<(int, int)> ranges;
  final bool negated;
}

final class _Group extends _Node {
  _Group(this.alternatives);

  final List<List<_Quantified>> alternatives;
}

final class _Quantified {
  _Quantified(this.node, [this.min = 1, this.max = 1]);

  final _Node node;
  final int min;
  final int? max;

  bool get isSingle => min == 1 && max == 1;
}

const int _maxCodePoint = 0x10FFFF;
const List<(int, int)> _digits = [(0x30, 0x39)];
const List<(int, int)> _word = [(0x30, 0x39), (0x41, 0x5A), (0x5F, 0x5F), (0x61, 0x7A)];
const List<(int, int)> _space = [(0x09, 0x0D), (0x20, 0x20)];

List<(int, int)> _complement(List<(int, int)> ranges) {
  final sorted = [...ranges]..sort((a, b) => a.$1.compareTo(b.$1));
  final out = <(int, int)>[];
  var next = 0;
  for (final (lo, hi) in sorted) {
    if (lo > next) out.add((next, lo - 1));
    if (hi + 1 > next) next = hi + 1;
  }
  if (next <= _maxCodePoint) out.add((next, _maxCodePoint));
  return out;
}

final class _Parser {
  _Parser(this.chars, {required this.excluded});

  final List<int> chars;

  /// Characters that `.`, negated classes and `\D \W \S` never match here.
  final List<(int, int)> excluded;
  int pos = 0;

  bool get atEnd => pos >= chars.length;

  int get _peek => chars[pos];

  List<List<_Quantified>> parseAlternatives() {
    final alternatives = [parseSequence()];
    while (!atEnd && _peek == 0x7C) {
      pos++;
      alternatives.add(parseSequence());
    }
    return alternatives;
  }

  List<_Quantified> parseSequence() {
    final items = <_Quantified>[];
    while (!atEnd && _peek != 0x7C && _peek != 0x29) {
      final atom = _parseAtom();
      items.add(_parseQuantifier(atom));
    }
    return items;
  }

  _Node _parseAtom() {
    final c = chars[pos++];
    switch (c) {
      case 0x28: // (
        if (!atEnd && _peek == 0x3F) {
          // (?:…) or (?<name>…); lookarounds are not in the subset.
          if (pos + 1 < chars.length && chars[pos + 1] == 0x3A) {
            pos += 2;
          } else if (pos + 1 < chars.length &&
              chars[pos + 1] == 0x3C &&
              pos + 2 < chars.length &&
              chars[pos + 2] != 0x3D &&
              chars[pos + 2] != 0x21) {
            pos += 2;
            while (!atEnd && _peek != 0x3E) {
              pos++;
            }
            if (atEnd) throw const _Unsupported();
            pos++;
          } else {
            throw const _Unsupported();
          }
        }
        final alternatives = parseAlternatives();
        if (atEnd || _peek != 0x29) throw const _Unsupported();
        pos++;
        return _Group(alternatives);
      case 0x5B: // [
        return _parseClass();
      case 0x2E: // .
        return _Class([(0x0A, 0x0A), ...excluded], negated: true);
      case 0x5C: // \
        return _parseEscape(inClass: false);
      case 0x2A || 0x2B || 0x3F || 0x7B || 0x5E || 0x24 || 0x29 || 0x5D || 0x7D:
        // A quantifier with nothing to repeat, an inner anchor, a stray bracket: not in the subset.
        throw const _Unsupported();
      default:
        return _Literal(c);
    }
  }

  _Node _parseEscape({required bool inClass}) {
    if (atEnd) throw const _Unsupported();
    final c = chars[pos++];
    List<(int, int)>? set;
    var negated = false;
    switch (c) {
      case 0x64: // d
        set = _digits;
      case 0x44: // D
        set = _digits;
        negated = true;
      case 0x77: // w
        set = _word;
      case 0x57: // W
        set = _word;
        negated = true;
      case 0x73: // s
        set = _space;
      case 0x53: // S
        set = _space;
        negated = true;
      case 0x6E:
        return _Literal(0x0A);
      case 0x74:
        return _Literal(0x09);
      case 0x72:
        return _Literal(0x0D);
      case 0x66:
        return _Literal(0x0C);
      case 0x76:
        return _Literal(0x0B);
      case 0x30:
        if (!atEnd && _isDigit(_peek)) throw const _Unsupported();
        return _Literal(0);
      case 0x78: // xHH
        return _Literal(_hex(2));
      case 0x75: // uHHHH or u{…}
        if (!atEnd && _peek == 0x7B) {
          pos++;
          final start = pos;
          while (!atEnd && _peek != 0x7D) {
            pos++;
          }
          if (atEnd || pos == start) throw const _Unsupported();
          final value = int.tryParse(String.fromCharCodes(chars, start, pos), radix: 16);
          pos++;
          if (value == null || value > _maxCodePoint) throw const _Unsupported();
          return _Literal(value);
        }
        return _Literal(_hex(4));
      case 0x62 when inClass: // [\b] is a backspace
        return _Literal(0x08);
      default:
        // Escaped punctuation is the character itself; a letter or digit escape is something else (\b, \1, \p…).
        if (_isDigit(c) || _isLetter(c)) throw const _Unsupported();
        return _Literal(c);
    }
    // \D, \W and \S exclude what `.` excludes.
    final ranges = negated ? _complement([...set, ...excluded]) : set;
    return _Class(ranges, negated: false);
  }

  int _hex(int digits) {
    if (pos + digits > chars.length) throw const _Unsupported();
    final value = int.tryParse(String.fromCharCodes(chars, pos, pos + digits), radix: 16);
    if (value == null) throw const _Unsupported();
    pos += digits;
    return value;
  }

  _Class _parseClass() {
    var negated = false;
    if (!atEnd && _peek == _caret) {
      negated = true;
      pos++;
    }
    final ranges = <(int, int)>[];
    var first = true;
    while (true) {
      if (atEnd) throw const _Unsupported();
      if (_peek == 0x5D && !first) break;
      if (_peek == 0x5D) throw const _Unsupported(); // `[]` and `[^]`
      first = false;
      final lo = _classMember();
      if (lo is _Class) {
        ranges.addAll(lo.ranges);
        continue;
      }
      final low = (lo as _Literal).char;
      if (pos + 1 < chars.length && _peek == 0x2D && chars[pos + 1] != 0x5D) {
        pos++;
        final hi = _classMember();
        if (hi is! _Literal || hi.char < low) throw const _Unsupported();
        ranges.add((low, hi.char));
      } else {
        ranges.add((low, low));
      }
    }
    pos++;
    if (negated) ranges.addAll(excluded);
    return _Class(ranges, negated: negated);
  }

  _Node _classMember() {
    final c = chars[pos++];
    if (c == _backslash) return _parseEscape(inClass: true);
    if (c == 0x5B && !atEnd && _peek == 0x3A) throw const _Unsupported(); // [:alpha:]
    return _Literal(c);
  }

  _Quantified _parseQuantifier(_Node atom) {
    if (atEnd) return _Quantified(atom);
    int min;
    int? max;
    switch (_peek) {
      case 0x3F:
        (min, max) = (0, 1);
        pos++;
      case 0x2A:
        (min, max) = (0, null);
        pos++;
      case 0x2B:
        (min, max) = (1, null);
        pos++;
      case 0x7B:
        final close = chars.indexOf(0x7D, pos);
        if (close < 0) throw const _Unsupported();
        final body = String.fromCharCodes(chars, pos + 1, close);
        final match = RegExp(r'^(\d+)(,(\d*))?$').firstMatch(body);
        if (match == null) throw const _Unsupported();
        min = int.parse(match.group(1)!);
        max = match.group(2) == null
            ? min
            : match.group(3)!.isEmpty
            ? null
            : int.parse(match.group(3)!);
        if (max != null && max < min) throw const _Unsupported();
        pos = close + 1;
      default:
        return _Quantified(atom);
    }
    if (!atEnd && _peek == 0x3F) pos++; // lazy: same language
    if (!atEnd && (_peek == 0x2A || _peek == 0x2B || _peek == 0x3F || _peek == 0x7B)) throw const _Unsupported();
    return _Quantified(atom, min, max);
  }

  static bool _isDigit(int c) => c >= 0x30 && c <= 0x39;

  static bool _isLetter(int c) => (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A);
}

/// Writes parsed patterns as GBNF.
final class _Renderer {
  _Renderer(this.maxRepetition, this.defineGroup);

  final int maxRepetition;
  final String Function(String body) defineGroup;

  String sequence(List<_Quantified> items) {
    if (items.isEmpty) return '""';
    final parts = <String>[];
    final run = <int>[];
    void flush() {
      if (run.isNotEmpty) parts.add('"${run.map(_literalChar).join()}"');
      run.clear();
    }

    for (var item in items) {
      var node = item.node;
      if (node is _Literal && item.isSingle) {
        run.add(node.char);
        continue;
      }
      flush();
      final open = item.max == null || item.max! > maxRepetition;
      if (node is _Group && open && node.alternatives.any((sequence) => sequence.isEmpty)) {
        // llama.cpp takes an open repetition of a group with an empty alternative for left recursion; (X|)* = X*.
        final rest = [
          for (final sequence in node.alternatives)
            if (sequence.isNotEmpty) sequence,
        ];
        if (rest.isEmpty) continue;
        node = _Group(rest);
        item = _Quantified(node, 0, null);
      }
      // A repeated group with inner rules goes through a rule reference, which llama.cpp counts as one rule.
      final atom = node is _Group && !item.isSingle && !_isFlat(node) ? defineGroup(_alternatives(node)) : _atom(node);
      parts.add(repetition(atom, item.min, item.max, maxRepetition));
    }
    flush();
    return parts.isEmpty ? '""' : parts.join(' ');
  }

  String _atom(_Node node) => switch (node) {
    _Literal(:final char) => '"${_literalChar(char)}"',
    _Class(:final ranges, :final negated) => '[${negated ? '^' : ''}${ranges.map(_classRange).join()}]',
    _Group() => '(${_alternatives(node)})',
  };

  String _alternatives(_Group group) => group.alternatives.map(sequence).join(' | ');

  /// Whether [group] holds only single literals and classes: llama.cpp synthesizes no rule inside it.
  static bool _isFlat(_Group group) =>
      group.alternatives.every((items) => items.every((item) => item.isSingle && item.node is! _Group));
}

/// Throws [ArgumentError] unless [maxRepetition] is a bound llama.cpp v0.4.0 repeats a single item by: 1 to 1999
/// (it refuses 2000 or more).
void checkMaxRepetition(int maxRepetition) {
  if (maxRepetition < 1 || maxRepetition >= 2000) {
    throw ArgumentError.value(maxRepetition, 'maxRepetition', 'must be from 1 to 1999 (llama.cpp refuses 2000)');
  }
}

/// [atom] repeated [min] to [max] times (null: no upper bound) in GBNF. A bound above [maxRepetition] is dropped:
/// an upper bound becomes none, a lower bound becomes 1 (or 0).
String repetition(String atom, int min, int? max, int maxRepetition) {
  if (max != null && max > maxRepetition) max = null;
  if (min > maxRepetition) min = 1;
  return switch ((min, max)) {
    (1, 1) => atom,
    (0, 1) => '$atom?',
    (0, null) => '$atom*',
    (1, null) => '$atom+',
    (final m, null) => '$atom{$m,}',
    (final m, final int n) when m == n => '$atom{$m}',
    (final m, final int n) => '$atom{$m,$n}',
  };
}

String _literalChar(int c) => switch (c) {
  0x5C => r'\\',
  0x22 => r'\"',
  0x0A => r'\n',
  0x0D => r'\r',
  0x09 => r'\t',
  < 0x20 || 0x7F => '\\x${c.toRadixString(16).padLeft(2, '0').toUpperCase()}',
  _ => String.fromCharCode(c),
};

String _classRange((int, int) range) {
  final (lo, hi) = range;
  return lo == hi ? _classChar(lo) : '${_classChar(lo)}-${_classChar(hi)}';
}

/// One character inside `[…]`. llama.cpp's parse_char knows the escapes x u U t r n \ " [ ] - and no other, so
/// `^` (a negation when first) is written in hex, and so is `-` (a range between two characters).
String _classChar(int c) => switch (c) {
  0x5C => r'\\',
  0x5D => r'\]',
  0x5B => r'\[',
  0x5E => r'\x5E',
  0x2D => r'\x2D',
  0x0A => r'\n',
  0x0D => r'\r',
  0x09 => r'\t',
  < 0x20 || 0x7F => '\\x${c.toRadixString(16).padLeft(2, '0').toUpperCase()}',
  > 0xFFFF => '\\U${c.toRadixString(16).padLeft(8, '0').toUpperCase()}',
  _ => String.fromCharCode(c),
};
