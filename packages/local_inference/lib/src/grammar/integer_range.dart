/// Integer ranges as exact GBNF digit patterns. Internal.
library;

/// Bounds beyond this magnitude are left to the open integer rule.
const int _limit = 1000000000000000000; // 10^18

/// A GBNF body that matches exactly the decimal integers from [min] to [max]: no leading zeros, `-` before a
/// negative number, `0` for zero. 0 ≤ min ≤ max ≤ 9 gives `[min-max]` (`[1-8]`); 1..12 gives `[1-9] | "1" [0-2]`.
/// Null when [min] > [max] or a bound's magnitude reaches 10^18.
String? integerRangeBody(int min, int max) {
  if (min > max || min <= -_limit || max >= _limit) return null;
  if (min >= 0 && max <= 9) return '[$min-$max]';
  final alternatives = <String>[];
  if (min < 0) {
    // -k for k in [a, b]
    final negative = _nonNegative(max < 0 ? -max : 1, -min);
    alternatives.add(negative.length == 1 ? '"-" ${negative.single}' : '"-" (${negative.join(' | ')})');
  }
  if (max >= 0) alternatives.addAll(_nonNegative(min < 0 ? 0 : min, max));
  return alternatives.join(' | ');
}

/// Alternatives for [lo]..[hi], 0 ≤ lo ≤ hi, grouped by number of digits.
List<String> _nonNegative(int lo, int hi) {
  final alternatives = <String>[];
  for (var digits = '$lo'.length; digits <= '$hi'.length; digits++) {
    final first = digits == 1 ? 0 : _pow10(digits - 1);
    final a = lo > first ? lo : first;
    final last = _pow10(digits) - 1;
    final b = hi < last ? hi : last;
    if (a > b) continue;
    alternatives.addAll([for (final tokens in _sameLength('$a', '$b')) _render(tokens)]);
  }
  return alternatives;
}

int _pow10(int n) {
  var value = 1;
  for (var i = 0; i < n; i++) {
    value *= 10;
  }
  return value;
}

/// Token sequences matching the numbers from [a] to [b], two digit strings of the same length with a ≤ b. A token
/// is a digit string (a literal) or a [_Class].
List<List<Object>> _sameLength(String a, String b) {
  if (a == b || a.length == 1) {
    final single = <Object>[a == b ? a : _Class(a, b)];
    return [single];
  }
  final rest = a.length - 1;
  if (a[0] == b[0]) {
    return [
      for (final tail in _sameLength(a.substring(1), b.substring(1))) [a[0], ...tail],
    ];
  }
  final lowFull = a.substring(1) == '0' * rest;
  final highFull = b.substring(1) == '9' * rest;
  var low = int.parse(a[0]);
  var high = int.parse(b[0]);
  final out = <List<Object>>[];
  if (!lowFull) {
    for (final tail in _sameLength(a.substring(1), '9' * rest)) {
      out.add([a[0], ...tail]);
    }
    low++;
  }
  final highPart = <List<Object>>[];
  if (!highFull) {
    for (final tail in _sameLength('0' * rest, b.substring(1))) {
      highPart.add([b[0], ...tail]);
    }
    high--;
  }
  if (low <= high) out.add([low == high ? '$low' : _Class('$low', '$high'), _AnyDigits(rest)]);
  return [...out, ...highPart];
}

/// `[lo-hi]`: one digit.
final class _Class {
  const _Class(this.lo, this.hi);

  final String lo, hi;

  @override
  String toString() => '[$lo-$hi]';
}

/// [count] digits, any.
final class _AnyDigits {
  const _AnyDigits(this.count);

  final int count;

  @override
  String toString() => count == 1 ? '[0-9]' : '[0-9]{$count}';
}

/// Tokens as a GBNF sequence, adjacent literal digits merged into one literal.
String _render(List<Object> tokens) {
  final parts = <String>[];
  final digits = StringBuffer();
  void flush() {
    if (digits.isNotEmpty) parts.add('"$digits"');
    digits.clear();
  }

  for (final token in tokens) {
    if (token is String) {
      digits.write(token);
    } else {
      flush();
      parts.add('$token');
    }
  }
  flush();
  return parts.join(' ');
}
