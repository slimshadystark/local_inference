// The GBNF recognizer of the testing kit: llama.cpp's grammar syntax, and the strings a grammar admits.
import 'package:local_inference/testing.dart';
import 'package:test/test.dart';

import 'support/llama_grammars.dart';

void main() {
  test('literals, classes, ranges, negation, any character, groups, alternation and rule references', () {
    final g = GbnfRecognizer(r'''
root ::= "ab" [x-z] [^0-9] . ("c" | d)
d ::= "dd"
''');
    expect(g.accepts('abx!?c'), isTrue);
    expect(g.accepts('abzq\ndd'), isTrue);
    expect(g.accepts('abw!?c'), isFalse);
    expect(g.accepts('abx5?c'), isFalse);
    expect(g.accepts('abx!?'), isFalse);
    expect(g.ruleNames, ['root', 'd']);
  });

  test('quantifiers ? * + {m} {m,} {m,n}', () {
    final g = GbnfRecognizer(r'root ::= "a"? "b"* "c"+ "d"{2} "e"{1,} "f"{0,2}');
    expect(g.accepts('cddeff'), isTrue);
    expect(g.accepts('abbbccddeee'), isTrue);
    expect(g.accepts('ddeff'), isFalse);
    expect(g.accepts('cdeff'), isFalse);
    expect(g.accepts('cddfff'), isFalse);
    expect(g.accepts('cddefff'), isFalse);
  });

  test("llama.cpp's escapes, in literals and classes", () {
    final g = GbnfRecognizer(r'root ::= "\n\t\r\\\"\[\]\-\x41\u00e8\U0001F600" [\x00-\x1F\]\\\-]');
    expect(g.accepts('\n\t\r\\"[]-Aè😀\u0001'), isTrue);
    expect(g.accepts('\n\t\r\\"[]-Aè😀]'), isTrue);
    expect(g.accepts('\n\t\r\\"[]-Aè😀-'), isTrue);
    expect(g.accepts('\n\t\r\\"[]-Aè😀a'), isFalse);
  });

  test('a class: ^ first negates, - between two characters is a range, - before ] is itself', () {
    final g = GbnfRecognizer(r'root ::= [a^-] [^^]');
    expect(g.accepts('^x'), isTrue);
    expect(g.accepts('-x'), isTrue);
    expect(g.accepts('a^'), isFalse);
    expect(g.accepts('bx'), isFalse);
  });

  test('comments, blank lines, and rules continued inside groups or after |', () {
    final g = GbnfRecognizer('''
# a comment
root ::= (
  "a"   # first
  | "b"
) tail

tail ::= "x" |
  "y"
''');
    expect(g.accepts('ax'), isTrue);
    expect(g.accepts('by'), isTrue);
    expect(g.accepts('a'), isFalse);
  });

  test('recursion (not left recursion) and ambiguity', () {
    final g = GbnfRecognizer(r'''
root ::= "(" root ")" | "" | root2
root2 ::= "x"* "x"*
''');
    expect(g.accepts('((()))'), isTrue);
    expect(g.accepts('((xx))'), isTrue);
    expect(g.accepts('(()'), isFalse);
  });

  test('another start rule', () {
    final g = GbnfRecognizer('root ::= a\na ::= "a"+\nb ::= "b"');
    expect(g.accepts('b', rule: 'b'), isTrue);
    expect(g.accepts('aaa', rule: 'a'), isTrue);
    expect(() => g.accepts('b', rule: 'c'), throwsArgumentError);
  });

  test('rejects what llama.cpp rejects', () {
    for (final grammar in [
      r'root ::= "\^"', // unknown escape
      r'root ::= [\^a]',
      r'root ::= "a',
      r'root ::= [a-',
      'root ::= undefined',
      'root ::= "a"\nroot ::= "b"',
      'start ::= "a"',
      'root ::= root "a"', // left recursion
      'root ::= x "a"\nx ::= "b"? root',
      'root ::= "a"{2001}',
      'root ::= "a"{3,2}',
      'root ::= * "a"',
      'root = "a"',
      'root ::= "a" )',
    ]) {
      expect(() => GbnfRecognizer(grammar), throwsFormatException, reason: grammar);
    }
  });

  group("agrees with llama.cpp's parser at its edges (model_test.dart checks the runtime)", () {
    for (final (name, grammar, accepted) in llamaCppGrammars) {
      test(name, () {
        if (accepted) {
          GbnfRecognizer(grammar);
        } else {
          expect(() => GbnfRecognizer(grammar), throwsFormatException);
        }
      });
    }
  });

  test('repetitions: a maximum above 2000 is none, bounds in braces may have spaces', () {
    final open = GbnfRecognizer(r'root ::= "a"{0,5000}');
    expect(open.accepts('a' * 5001), isTrue);
    final spaced = GbnfRecognizer(r'root ::= ("a" "b"){ 1 , 2 }');
    expect([spaced.accepts('ab'), spaced.accepts('abab'), spaced.accepts('ababab')], [true, true, false]);
  });
}
