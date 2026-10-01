/// li_chat's calculator: arithmetic with + - * / ^ (or **) and parentheses.
library;

import 'dart:math' as math;

/// The value of [expression]: sums of products of powers of numbers, signs and parentheses. Throws [FormatException]
/// for a malformed expression, a division by zero or a result that is not a finite number (2^2000, (0-8)^(1/3)).
double calculate(String expression) {
  final value = _Arithmetic(expression).evaluate();
  if (!value.isFinite) throw FormatException('the result is not a finite number', expression);
  return value;
}

/// A recursive-descent evaluator.
final class _Arithmetic {
  _Arithmetic(this.text);

  final String text;
  int _at = 0;

  double evaluate() {
    final value = _sum();
    _skipSpaces();
    if (_at < text.length) throw FormatException('unexpected "${text[_at]}"', text, _at);
    return value;
  }

  double _sum() {
    var value = _product();
    while (true) {
      if (_take('+')) {
        value += _product();
      } else if (_take('-')) {
        value -= _product();
      } else {
        return value;
      }
    }
  }

  double _product() {
    var value = _power();
    while (true) {
      if (!_ahead('**') && _take('*')) {
        value *= _power();
      } else if (_take('/')) {
        final divisor = _power();
        if (divisor == 0) throw FormatException('division by zero', text, _at);
        value /= divisor;
      } else {
        return value;
      }
    }
  }

  double _power() {
    final base = _unary();
    return _take('^') || _take('**') ? math.pow(base, _power()).toDouble() : base;
  }

  double _unary() {
    if (_take('-')) return -_unary();
    if (_take('+')) return _unary();
    if (_take('(')) {
      final value = _sum();
      if (!_take(')')) throw FormatException('missing ")"', text, _at);
      return value;
    }
    _skipSpaces();
    final match = RegExp(r'\d+(\.\d+)?|\.\d+').matchAsPrefix(text, _at);
    if (match == null) throw FormatException('a number expected', text, _at);
    _at = match.end;
    return double.parse(match[0]!);
  }

  /// Whether [symbol] comes next, after spaces (nothing is read).
  bool _ahead(String symbol) {
    _skipSpaces();
    return text.startsWith(symbol, _at);
  }

  bool _take(String symbol) {
    if (!_ahead(symbol)) return false;
    _at += symbol.length;
    return true;
  }

  void _skipSpaces() {
    while (_at < text.length && text[_at].trim().isEmpty) {
      _at++;
    }
  }
}
