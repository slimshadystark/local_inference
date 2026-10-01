// li_chat's calculator (lib/calculator.dart).
import 'package:li_chat/calculator.dart';
import 'package:test/test.dart';

void main() {
  test('sums, products, powers (^ or **, right-associative), signs and parentheses', () {
    expect(calculate('12.5 * 4 + 3'), 53);
    expect(calculate('(2 + 3) * 4.5'), 22.5);
    expect(calculate('2 ^ 3 ^ 2'), 512);
    expect(calculate('2**10'), 1024);
    expect(calculate('2 * -3'), -6);
    expect(calculate('-(1 - 4) / .5'), 6);
  });

  test('a malformed expression, a division by zero or a result that is not a finite number is a FormatException', () {
    for (final expression in ['2 +', '(1', '1 / 0', '2^2000', '0^-1', '(0-8)^(1/3)', '2 x 3', '']) {
      expect(() => calculate(expression), throwsFormatException, reason: expression);
    }
  });
}
