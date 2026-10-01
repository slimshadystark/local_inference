// The value rules of the grammar builder, checked by the
// language they admit (GbnfRecognizer): integer ranges, strings, patterns, dates, unions, JSON values.
import 'dart:convert';

import 'package:local_inference/local_inference.dart';
import 'package:local_inference/testing.dart';
import 'package:test/test.dart';

import 'support/llama_grammars.dart';

/// The grammar of one tool `t` with one parameter `v` of [schema].
String _grammarOf(Map<String, Object?> schema, [GrammarOptions options = const GrammarOptions()]) =>
    const QwenXmlToolFormat().grammar([
      ToolSpec(
        name: 't',
        description: 'd',
        parameters: {
          'type': 'object',
          'properties': {'v': schema},
          'required': ['v'],
        },
      ),
    ], options);

/// Whether the grammar of [schema] admits a call with the parameter text [value].
bool Function(String value) _admits(Map<String, Object?> schema, [GrammarOptions options = const GrammarOptions()]) {
  final recognizer = GbnfRecognizer(_grammarOf(schema, options));
  return (value) =>
      recognizer.accepts('<tool_call>\n<function=t>\n<parameter=v>\n$value\n</parameter>\n</function>\n</tool_call>');
}

void main() {
  group('integers', () {
    test('0 ≤ min ≤ max ≤ 9 gives today\'s [min-max]; 1..12 gives [1-9] | "1" [0-2]; open ranges today\'s text', () {
      expect(_grammarOf({'type': 'integer', 'minimum': 1, 'maximum': 8}), contains('param-t-v-value ::= [1-8]\n'));
      expect(_grammarOf({'type': 'integer', 'minimum': 5, 'maximum': 5}), contains('param-t-v-value ::= [5-5]\n'));
      expect(
        _grammarOf({'type': 'integer', 'minimum': 1, 'maximum': 12}),
        contains('param-t-v-value ::= [1-9] | "1" [0-2]\n'),
      );
      expect(_grammarOf({'type': 'integer'}), contains('param-t-v-value ::= "-"? [0-9]+\n'));
      expect(_grammarOf({'type': 'integer', 'minimum': 0}), contains('param-t-v-value ::= "-"? [0-9]+\n'));
      expect(
        _grammarOf({'type': 'integer', 'minimum': 0, 'maximum': 100}),
        contains('param-t-v-value ::= [0-9] | [1-9] [0-9] | "100"\n'),
      );
    });

    final ranges = [
      (1, 8),
      (0, 9),
      (0, 0),
      (1, 12),
      (0, 100),
      (7, 1234),
      (95, 105),
      (10, 19),
      (-5, 5),
      (-12, -3),
      (-100, -100),
      (-1, 0),
      (123, 45678),
      (1000, 1999),
      (98, 1002),
      // A one-digit middle band between a low and a high part: 15..35 is "1" [5-9] | "2" [0-9] | "3" [0-5].
      (15, 35),
      (150, 350),
      (-35, -15),
      (1050, 3050),
    ];
    for (final (lo, hi) in ranges) {
      test('[$lo, $hi] admits exactly its numbers, written without leading zeros', () {
        final admits = _admits({'type': 'integer', 'minimum': lo, 'maximum': hi});
        final span = hi - lo;
        final from = lo - (span < 50 ? 50 : 20);
        final to = hi + (span < 50 ? 50 : 20);
        final samples = {for (var n = from; n <= to; n++) n};
        if (span > 200) samples.addAll([for (var n = lo; n <= hi; n += (span ~/ 97) + 1) n]);
        for (final n in samples) {
          expect(admits('$n'), lo <= n && n <= hi, reason: '$n');
        }
        for (final text in ['0$lo', '+$lo', '', '-0', ' $lo', '$lo.0']) {
          expect(admits(text), isFalse, reason: text);
        }
      });
    }

    test('exclusive and fractional bounds become the inclusive integer range', () {
      final admits = _admits({'type': 'integer', 'exclusiveMinimum': 0, 'exclusiveMaximum': 4});
      expect([for (var n = -1; n <= 5; n++) admits('$n')], [false, false, true, true, true, false, false]);
      final draft4 = _admits({'type': 'integer', 'minimum': 0.5, 'maximum': 3, 'exclusiveMaximum': true});
      expect([for (var n = 0; n <= 3; n++) draft4('$n')], [false, true, true, false]);
    });
  });

  group('strings in a parameter', () {
    test('multiLine (the default): any text, several lines, but never </', () {
      final admits = _admits({'type': 'string'});
      for (final text in ['a', 'two\nlines', 'a < b', 'a<b<c', 'x <<y', 'ends with <', '1/2 <3', '/<a']) {
        expect(admits(text), isTrue, reason: text);
      }
      for (final text in ['a</b', '</parameter>', '</', 'x<</y', '', '<']) {
        expect(admits(text), isFalse, reason: text);
      }
    });

    test('singleLine: one line with no < or >', () {
      final admits = _admits({'type': 'string'}, const GrammarOptions(strings: StringValues.singleLine));
      expect(admits('Ufficio tecnico, via Roma 1'), isTrue);
      for (final text in ['a\nb', 'a<b', 'a>b', '']) {
        expect(admits(text), isFalse, reason: text);
      }
    });

    test('enum and const are literal alternatives; non-strings as their JSON text', () {
      final enumAdmits = _admits({
        'type': 'string',
        'enum': ['upcoming', 'past', 'a "quoted" \\ one'],
      });
      expect(enumAdmits('past'), isTrue);
      expect(enumAdmits('a "quoted" \\ one'), isTrue);
      expect(enumAdmits('pas'), isFalse);
      final numbers = _admits({
        'enum': [1, 2.5, true, null],
      });
      expect(
        [numbers('1'), numbers('2.5'), numbers('true'), numbers('null'), numbers('2')],
        [true, true, true, true, false],
      );
      expect(_admits({'const': 'only'})('only'), isTrue);
      expect(_admits({'const': 'only'})('other'), isFalse);
    });

    test('number and boolean keep today\'s texts', () {
      expect(_grammarOf({'type': 'number'}), contains(r'param-t-v-value ::= "-"? [0-9]+ ("." [0-9]+)?'));
      expect(_grammarOf({'type': 'boolean'}), contains('param-t-v-value ::= "true" | "false"'));
    });
  });

  group('patterns and formats', () {
    test('an anchored pattern in the subset is the grammar of its language', () {
      final month = _admits({'type': 'string', 'pattern': r'^[0-9]{4}-[0-9]{2}$'});
      expect(month('2026-09'), isTrue);
      expect(month('2026-9'), isFalse);
      expect(month('2026-09x'), isFalse);
      final complex = _admits({'type': 'string', 'pattern': r'^(?:ab|c\d)+x?[^a-c<]{2}\.$'});
      expect(complex('abc7xzz.'), isTrue);
      expect(complex('abab99.'), isTrue);
      expect(complex('ab.'), isFalse);
      expect(complex('abaa.'), isFalse, reason: 'a is outside [^a-c]');
      expect(complex('ab<<.'), isFalse);
      final words = _admits({'type': 'string', 'pattern': r'^\w+( \w+)*$'});
      expect(words('hello big world'), isTrue);
      expect(words('hello  world'), isFalse);
    });

    test('inside a parameter, . and negated classes exclude < (no </ can close the value)', () {
      final any = _admits({'type': 'string', 'pattern': r'^.+$'});
      expect(any('a b/c'), isTrue);
      expect(any('a</b'), isFalse);
      expect(any('line\nbreak'), isFalse);
    });

    test('a pattern outside the subset, or not anchored, falls back to the string rule (the validator checks it)', () {
      for (final pattern in [r'^(?=a)b$', r'abc', r'^a$|^b$', r'^(a)\1$', r'^\bword$', r'^a|b$', r'^x\$']) {
        expect(
          _grammarOf({'type': 'string', 'pattern': pattern}),
          contains(r'param-t-v ::= "<parameter=v>\n" xml-text "\n</parameter>\n"'),
          reason: pattern,
        );
      }
    });

    test('class characters llama.cpp has no escape for (^, -) are written in hex, in a parameter and in JSON', () {
      final cases = {
        edgePatterns['caret']!: (['a', '^'], ['b', '^^', '']),
        edgePatterns['not-word']!: (['!?', '-^ '], ['a', '_', '']),
        edgePatterns['slug']!: (['a-b-9', '-'], ['A', 'a_b', '']),
        edgePatterns['signed']!: (['-12', '+3', '7'], ['--1', '1-', '']),
      };
      for (final MapEntry(key: pattern, value: (good, bad)) in cases.entries) {
        final grammar = _grammarOf({'type': 'string', 'pattern': pattern});
        expect(grammar, isNot(contains(r'\^')), reason: pattern);
        expect(grammar, isNot(contains(r'\-')), reason: pattern);
        final admits = _admits({'type': 'string', 'pattern': pattern});
        final json = GbnfRecognizer(jsonSchemaGrammar({'type': 'string', 'pattern': pattern}));
        for (final text in good) {
          expect(admits(text), isTrue, reason: '$pattern: $text');
          expect(json.accepts(jsonEncode(text)), isTrue, reason: '$pattern, JSON: $text');
        }
        for (final text in bad) {
          expect(admits(text), isFalse, reason: '$pattern: $text');
          expect(json.accepts(jsonEncode(text)), isFalse, reason: '$pattern, JSON: $text');
        }
      }
    });

    test('a repeated group with inner rules becomes a rule of its own (llama.cpp caps rules x bound)', () {
      final pattern = edgePatterns['words']!;
      final grammar = _grammarOf({'type': 'string', 'pattern': pattern});
      expect(
        grammar,
        contains('param-t-v-value-group ::= [a-z]{1,40} " "\nparam-t-v-value ::= param-t-v-value-group{1,60}\n'),
      );
      final admits = _admits({'type': 'string', 'pattern': pattern});
      expect([admits('ab cd '), admits('ab cd'), admits('${'x' * 41} ')], [true, false, false]);
      expect(
        _grammarOf({'type': 'string', 'pattern': r'^(ab|c.){2,3}$'}),
        contains('param-t-v-value ::= ("ab" | "c" [^\\n<]){2,3}\n'),
        reason: 'a group of single literals and classes synthesizes no rule: it stays inline',
      );
      final json = jsonSchemaGrammar({'type': 'string', 'pattern': r'^(a[0-9]{2}-)+(b(c)?)*$'});
      expect(json.split('\n'), [
        r'root ::= "\"" (root-group+ root-group-2*) "\""',
        'root-group ::= "a" [0-9]{2} "-"',
        'root-group-2 ::= "b" ("c")?',
      ]);
      final recognizer = GbnfRecognizer(json);
      expect([recognizer.accepts('"a12-a34-bcb"'), recognizer.accepts('"a1-"')], [true, false]);
    });

    test('an open repetition drops the empty alternatives of its group: llama.cpp takes (a|)* for left recursion', () {
      String value(String pattern) => _grammarOf({
        'type': 'string',
        'pattern': pattern,
      }).split('\n').firstWhere((line) => line.startsWith('param-t-v-value ::= '));
      expect(value(r'^(a|)*b$'), 'param-t-v-value ::= ("a")* "b"');
      expect(value(r'^x(|a|b)+$'), 'param-t-v-value ::= "x" ("a" | "b")*');
      expect(value(r'^x(|a+)*$'), 'param-t-v-value ::= "x" param-t-v-value-group*');
      expect(_grammarOf({'type': 'string', 'pattern': r'^x(|a+)*$'}), contains('\nparam-t-v-value-group ::= "a"+\n'));
      expect(value(r'^()*x$'), 'param-t-v-value ::= "x"');
      expect(value(r'^(a|){0,3}$'), 'param-t-v-value ::= ("a" | ""){0,3}', reason: 'a bounded repetition is no loop');
      final admits = _admits({'type': 'string', 'pattern': r'^x(|a|b)+$'});
      expect([admits('x'), admits('xab'), admits('xc')], [true, true, false]);
    });

    test('maxRepetition runs from 1 to 1999: llama.cpp refuses a bound of 2000', () {
      for (final bad in [0, 2000]) {
        final options = GrammarOptions(maxRepetition: bad);
        expect(() => _grammarOf({'type': 'string'}, options), throwsArgumentError, reason: '$bad');
        expect(() => jsonSchemaGrammar({'type': 'string'}, options), throwsArgumentError, reason: '$bad');
      }
      final wide = _grammarOf({'type': 'string', 'pattern': r'^a{0,1999}$'}, const GrammarOptions(maxRepetition: 1999));
      expect(wide, contains('param-t-v-value ::= "a"{0,1999}\n'));
      GbnfRecognizer(wide);
    });

    test('the builder grammars of test/support/llama_grammars.dart parse as llama.cpp parses them', () {
      for (final MapEntry(key: name, value: grammar) in builderGrammars().entries) {
        expect(() => GbnfRecognizer(grammar), returnsNormally, reason: name);
      }
    });

    test('a repetition above maxRepetition is dropped from the grammar', () {
      expect(
        _grammarOf({'type': 'string', 'pattern': r'^a{2,100}b{3}$'}),
        contains(r'param-t-v-value ::= "a"{2,} "b"{3}'),
      );
      expect(
        _grammarOf({'type': 'string', 'pattern': r'^a{2,100}$'}, const GrammarOptions(maxRepetition: 200)),
        contains(r'param-t-v-value ::= "a"{2,100}'),
      );
      expect(_grammarOf({'type': 'string', 'pattern': r'^a{80}$'}), contains(r'param-t-v-value ::= "a"+'));
    });

    test('format date and date-time use the shared ISO rules', () {
      final date = _admits({'type': 'string', 'format': 'date'});
      expect(date('2026-09-04'), isTrue);
      expect(date('2026-13-01'), isFalse);
      expect(date('2026-9-4'), isFalse);
      final dateTime = _admits({'type': 'string', 'format': 'date-time'});
      for (final text in ['2026-09-04T10:30:00Z', '2026-09-04T23:59:59.123+02:00', '2026-09-04T00:00:00-05:30']) {
        expect(dateTime(text), isTrue, reason: text);
      }
      for (final text in ['2026-09-04 10:30:00Z', '2026-09-04T24:00:00Z', '2026-09-04T10:30Z']) {
        expect(dateTime(text), isFalse, reason: text);
      }
    });
  });

  group('unions', () {
    test('anyOf, oneOf and type lists are the union of their branches', () {
      final admits = _admits({
        'anyOf': [
          {
            'type': 'string',
            'enum': ['today', 'this_week'],
          },
          {'type': 'string', 'pattern': r'^[0-9]{4}-[0-9]{2}$'},
          {'type': 'integer', 'minimum': 1, 'maximum': 12},
        ],
      });
      for (final text in ['today', '2026-09', '12']) {
        expect(admits(text), isTrue, reason: text);
      }
      for (final text in ['yesterday', '2026-9', '13']) {
        expect(admits(text), isFalse, reason: text);
      }
      final oneOf = _admits({
        'oneOf': [
          {'type': 'boolean'},
          {'type': 'null'},
        ],
      });
      expect([oneOf('true'), oneOf('null'), oneOf('0')], [true, true, false]);
      final typeList = _admits({
        'type': ['integer', 'null'],
        'minimum': 1,
        'maximum': 3,
      });
      expect([typeList('2'), typeList('null'), typeList('4')], [true, true, false]);
    });
  });

  group('JSON values in a parameter', () {
    final when = {
      'type': 'object',
      'properties': {
        'date': {'type': 'string', 'format': 'date'},
        'hour': {'type': 'integer', 'minimum': 0, 'maximum': 23},
        'note': {'type': 'string'},
      },
      'required': ['date'],
    };

    test('an object: required properties first, optional ones in order, as json.dumps writes them', () {
      final admits = _admits(when);
      for (final value in [
        {'date': '2026-09-04'},
        {'date': '2026-09-04', 'hour': 9},
        {'date': '2026-09-04', 'note': 'x < y, a "quote" and è'},
        {'date': '2026-09-04', 'hour': 23, 'note': ''},
      ]) {
        expect(admits(pythonJson(value)), isTrue, reason: pythonJson(value));
      }
      expect(admits(jsonEncode({'date': '2026-09-04', 'hour': 9})), isFalse, reason: 'compact separators');
      expect(admits(pythonJson({'hour': 9, 'date': '2026-09-04'})), isFalse, reason: 'order');
      expect(admits(pythonJson({'hour': 9})), isFalse, reason: 'required date');
      expect(admits(pythonJson({'date': '2026-09-04', 'hour': 24})), isFalse);
      expect(admits(pythonJson({'date': '2026-09-04', 'note': 'a</b'})), isFalse, reason: 'no </ in a parameter');
      expect(admits(pythonJson({'date': '2026-09-04', 'extra': 1})), isFalse);
    });

    test('arrays: items, minItems and maxItems', () {
      final admits = _admits({
        'type': 'array',
        'items': {
          'type': 'string',
          'enum': ['work', 'home'],
        },
        'maxItems': 2,
      });
      expect(admits('[]'), isTrue);
      expect(admits(pythonJson(['work'])), isTrue);
      expect(admits(pythonJson(['work', 'home'])), isTrue);
      expect(admits(pythonJson(['work', 'home', 'work'])), isFalse);
      expect(admits(pythonJson(['play'])), isFalse);
      final atLeastTwo = _admits({
        'type': 'array',
        'items': {'type': 'integer'},
        'minItems': 2,
      });
      expect([atLeastTwo('[1]'), atLeastTwo('[1, 2]'), atLeastTwo('[1, 2, -30]')], [false, true, true]);
      final any = _admits({'type': 'array'});
      expect(
        any(
          pythonJson([
            1,
            'a',
            null,
            true,
            2.5,
            {'k': []},
          ]),
        ),
        isTrue,
      );
    });

    test('free-form objects and values, and additionalProperties', () {
      final object = _admits({'type': 'object'});
      expect(
        object(
          pythonJson({
            'a': [
              1,
              {'b': 'c'},
            ],
            'd': null,
          }),
        ),
        isTrue,
      );
      expect(object('[]'), isFalse);
      final extra = _admits({
        'type': 'object',
        'properties': {
          'id': {'type': 'integer'},
        },
        'required': ['id'],
        'additionalProperties': {'type': 'boolean'},
      });
      expect(extra(pythonJson({'id': 1, 'x': true, 'y': false})), isTrue);
      expect(extra(pythonJson({'id': 1, 'x': 3})), isFalse);
    });

    test(r'local $refs become named rules and may recurse', () {
      final grammar = const QwenXmlToolFormat().grammar([
        const ToolSpec(
          name: 't',
          description: 'd',
          parameters: {
            'type': 'object',
            'properties': {
              'tree': {r'$ref': r'#/$defs/node'},
            },
            r'$defs': {
              'node': {
                'type': 'object',
                'properties': {
                  'label': {'type': 'string'},
                  'children': {
                    'type': 'array',
                    'items': {r'$ref': r'#/$defs/node'},
                  },
                },
                'required': ['label'],
              },
            },
          },
        ),
      ]);
      expect(grammar, contains('xdef-node ::= '));
      final recognizer = GbnfRecognizer(grammar);
      final tree = {
        'label': 'root',
        'children': [
          {'label': 'a'},
          {
            'label': 'b',
            'children': [
              {'label': 'c'},
            ],
          },
        ],
      };
      String call(String value) =>
          '<tool_call>\n<function=t>\n<parameter=tree>\n$value\n</parameter>\n</function>\n</tool_call>';
      expect(recognizer.accepts(call(pythonJson(tree))), isTrue);
      expect(recognizer.accepts(call(pythonJson({'children': []}))), isFalse);
    });

    test(r'a chain of $refs to a scalar is that scalar in the parameter; a loop with no value is refused', () {
      ToolSpec tool(Map<String, Object?> defs) => ToolSpec(
        name: 't',
        description: 'd',
        parameters: {
          'type': 'object',
          'properties': {
            'v': {r'$ref': r'#/$defs/a'},
          },
          r'$defs': defs,
        },
      );
      final chain = GbnfRecognizer(
        const QwenXmlToolFormat().grammar([
          tool({
            'a': {r'$ref': r'#/$defs/b'},
            'b': {'type': 'integer', 'minimum': 1, 'maximum': 3},
          }),
        ]),
      );
      String call(String value) =>
          '<tool_call>\n<function=t>\n<parameter=v>\n$value\n</parameter>\n</function>\n</tool_call>';
      expect([chain.accepts(call('2')), chain.accepts(call('4'))], [true, false]);
      // A $ref back to itself before any character: llama.cpp would refuse the left recursion, the validator
      // refuses the schema; a union branch leading back to the union used to overflow the stack.
      for (final defs in [
        {
          'a': {r'$ref': r'#/$defs/b'},
          'b': {r'$ref': r'#/$defs/a'},
        },
        {
          'a': {
            'anyOf': [
              {r'$ref': r'#/$defs/a'},
              {'type': 'string'},
            ],
          },
        },
      ]) {
        expect(() => const QwenXmlToolFormat().grammar([tool(defs)]), throwsArgumentError, reason: '$defs');
        expect(() => validateArguments(tool(defs).parameters, {'v': 'x'}), throwsArgumentError, reason: '$defs');
      }
      expect(
        () => jsonSchemaGrammar({
          r'$ref': r'#/$defs/a',
          r'$defs': {
            'a': {
              'oneOf': [
                {'type': 'null'},
                {r'$ref': r'#/$defs/a'},
              ],
            },
          },
        }),
        throwsArgumentError,
      );
      // After a character (inside an object or an array) a $ref may come back to itself.
      final nested = GbnfRecognizer(
        const QwenXmlToolFormat().grammar([
          tool({
            'a': {
              'anyOf': [
                {
                  'type': 'object',
                  'properties': {
                    'x': {r'$ref': r'#/$defs/a'},
                  },
                },
                {
                  'type': 'array',
                  'items': {r'$ref': r'#/$defs/a'},
                },
                {'type': 'string'},
              ],
            },
          }),
        ]),
      );
      for (final value in ['plain text', '{"x": {"x": ["deep"]}}', '[{}, ["a", "b"]]']) {
        expect(nested.accepts(call(value)), isTrue, reason: value);
      }
    });
  });

  group('jsonSchemaGrammar (structured responses)', () {
    final schema = {
      'type': 'object',
      'properties': {
        'name': {'type': 'string', 'minLength': 1, 'maxLength': 20},
        'age': {'type': 'integer', 'minimum': 0, 'maximum': 130},
        'tags': {
          'type': 'array',
          'items': {'type': 'string'},
        },
        'kind': {
          'enum': ['a', 'b'],
        },
        'score': {'type': 'number'},
        'ok': {'type': 'boolean'},
        'nothing': {'type': 'null'},
      },
      'required': ['name', 'kind'],
    };

    test('root first; the JSON rules accept pythonJson output of valid values', () {
      final grammar = jsonSchemaGrammar(schema);
      expect(grammar, startsWith('root ::= "{" root-name-kv ", " root-kind-kv '));
      final recognizer = GbnfRecognizer(grammar);
      for (final value in [
        {'name': 'Ada', 'kind': 'a'},
        {'name': 'Ada', 'kind': 'b', 'age': 36, 'tags': []},
        {
          'name': 'x "y" \\ z\n\u0001',
          'kind': 'a',
          'age': 0,
          'tags': ['<b>', '</i>'],
          'score': -1.5e-7,
          'ok': false,
          'nothing': null,
        },
        {'name': 'big', 'kind': 'a', 'score': 1e20},
        {'name': 'è日本', 'kind': 'b', 'score': 2.0},
      ]) {
        expect(recognizer.accepts(pythonJson(value)), isTrue, reason: pythonJson(value));
      }
      for (final value in [
        {'name': '', 'kind': 'a'},
        {'name': 'x' * 21, 'kind': 'a'},
        {'name': 'Ada'},
        {'name': 'Ada', 'kind': 'c'},
        {'name': 'Ada', 'kind': 'a', 'age': 131},
      ]) {
        expect(recognizer.accepts(pythonJson(value)), isFalse, reason: pythonJson(value));
      }
      expect(recognizer.accepts(jsonEncode({'name': 'Ada', 'kind': 'a'})), isFalse, reason: 'compact separators');
    });

    test('other roots: an array, a scalar, anything', () {
      expect(
        GbnfRecognizer(
          jsonSchemaGrammar({
            'type': 'array',
            'items': {'type': 'integer'},
          }),
        ).accepts('[1, 2, 3]'),
        isTrue,
      );
      expect(GbnfRecognizer(jsonSchemaGrammar({'type': 'string'})).accepts('"hi"'), isTrue);
      expect(jsonSchemaGrammar({}), startsWith('root ::= json-value\n'));
      final anything = GbnfRecognizer(jsonSchemaGrammar({}));
      expect(
        anything.accepts(
          pythonJson({
            'a': [1, 2.5, 'x', null, true],
          }),
        ),
        isTrue,
      );
    });

    test('custom value rules apply in the json context; their shared rules come after the rules', () {
      final grammar = jsonSchemaGrammar({
        'type': 'object',
        'properties': {
          'code': {'type': 'string', 'x-kind': 'code'},
        },
      }, const GrammarOptions(valueRules: [_QuotedCodeRule()]));
      expect(grammar, contains(r'root-code-kv ::= "\"code\": " root-code'));
      expect(grammar, contains('root-code ::= "\\"" code-chars "\\""'));
      expect(grammar.split('\n').last, 'code-chars ::= [A-Z]+');
      expect(GbnfRecognizer(grammar).accepts('{"code": "ABC"}'), isTrue);
    });
  });
}

final class _QuotedCodeRule implements ValueRule {
  const _QuotedCodeRule();

  @override
  String? build(Map<String, Object?> schema, GbnfRules rules, ValueContext context) =>
      schema['x-kind'] == 'code' && context == ValueContext.json ? r'"\"" code-chars "\""' : null;

  @override
  List<String> get sharedRules => const ['code-chars ::= [A-Z]+'];
}
