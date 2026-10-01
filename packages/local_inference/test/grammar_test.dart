// The tool-call grammar builder: emission order, the permutation text of the old builder (support/old_grammar.dart),
// the parameter orders' languages, the size guard and the rule table.
import 'package:local_inference/local_inference.dart';
import 'package:local_inference/testing.dart';
import 'package:test/test.dart';

import 'support/old_grammar.dart';

/// What the old builder assumed of every anyOf (a period: a name, a month or a date range), as a value rule.
final class _PeriodLikeRule implements ValueRule {
  const _PeriodLikeRule();

  @override
  String? build(Map<String, Object?> schema, GbnfRules rules, ValueContext context) {
    final anyOf = schema['anyOf'];
    if (anyOf is! List) return null;
    return [
      for (final option in anyOf.cast<Map<Object?, Object?>>())
        if (option['enum'] case final List<Object?> values)
          for (final value in values) rules.literal('$value')
        else if (option['pattern'] == r'^[0-9]{4}-[0-9]{2}$')
          'period-month'
        else if ('${option['pattern']}'.contains(r'\.\.'))
          'period-range'
        else
          'text-line',
    ].join(' | ');
  }

  @override
  List<String> get sharedRules => oldSharedRules.sublist(0, 3);
}

const GrammarOptions _oldOptions = GrammarOptions(
  strings: StringValues.singleLine,
  order: ParameterOrder.permutations,
  valueRules: [_PeriodLikeRule()],
);

/// A tool with [properties] (name → schema), [required] among them.
ToolSpec _tool(String name, Map<String, Map<String, Object?>> properties, [List<String> required = const []]) =>
    ToolSpec(
      name: name,
      description: 'Tool $name.',
      parameters: {'type': 'object', 'properties': properties, if (required.isNotEmpty) 'required': required},
    );

Map<String, Object?> _enum(List<String> values) => {'type': 'string', 'enum': values};

const Map<String, Object?> _period = {
  'anyOf': [
    {
      'type': 'string',
      'enum': ['today', 'next_week'],
    },
    {'type': 'string', 'pattern': r'^[0-9]{4}-[0-9]{2}$'},
    {'type': 'string', 'pattern': r'^[0-9]{4}-[0-9]{2}-[0-9]{2}\.\.[0-9]{4}-[0-9]{2}-[0-9]{2}$'},
  ],
};

/// A call of [tool] with [parameters] (name → value text) in that order.
String _call(String tool, List<(String, String)> parameters) =>
    '<tool_call>\n<function=$tool>\n${[for (final (k, v) in parameters) '<parameter=$k>\n$v\n</parameter>\n'].join()}'
    '</function>\n</tool_call>';

/// Every sequence of [items] of length 0 to [maxLength] that writes at most [repeats] items again (null: any).
List<List<String>> _words(List<String> items, {required int maxLength, int? repeats}) {
  final out = <List<String>>[];
  void extend(List<String> prefix, int repeated) {
    out.add(prefix);
    if (prefix.length == maxLength) return;
    for (final item in items) {
      final again = prefix.contains(item) ? 1 : 0;
      if (repeats != null && repeated + again > repeats) continue;
      extend([...prefix, item], repeated + again);
    }
  }

  extend([], 0);
  return out;
}

void main() {
  group('the old builder is the oracle on the domain it knew', () {
    final period = _tool(
      'list_booking_slots',
      {
        'office_number': {'type': 'integer', 'minimum': 1, 'maximum': 8},
        'period': _period,
      },
      ['office_number'],
    );
    final cases = {
      'no parameters': [_tool('get_profile', {})],
      'one optional enum': [
        _tool('list_appointments', {
          'scope': _enum(['upcoming', 'past', 'all']),
        }),
      ],
      'one required string': [
        _tool(
          'search',
          {
            'query': {'type': 'string'},
          },
          ['query'],
        ),
      ],
      'required integer and optional period': [period],
      'three parameters, one required': [
        _tool(
          'open_item',
          {
            'collection': _enum(['a', 'b"c', 'd\\e']),
            'item_number': {'type': 'integer', 'minimum': 1, 'maximum': 8},
            'note': {'type': 'string'},
          },
          ['item_number'],
        ),
      ],
      'three required, number and boolean': [
        _tool(
          't-x.y',
          {
            'a': {'type': 'number'},
            'b': {'type': 'boolean'},
            'c': {'type': 'integer'},
          },
          ['a', 'b', 'c'],
        ),
      ],
      'three optional': [
        _tool('three', {
          'x': {'type': 'string'},
          'y': {'type': 'integer', 'minimum': 0, 'maximum': 9},
          'z': _enum(['1']),
        }),
      ],
      'several tools': [
        _tool('get_profile', {}),
        period,
        _tool(
          'book',
          {
            'slot_number': {'type': 'integer', 'minimum': 1, 'maximum': 8},
          },
          ['slot_number'],
        ),
      ],
    };
    for (final MapEntry(key: name, value: tools) in cases.entries) {
      test(name, () {
        final built = const QwenXmlToolFormat().grammar(tools, _oldOptions);
        expect(built, oldToolCallGrammar([for (final tool in tools) tool.declaration]));
        GbnfRecognizer(built);
      });
    }

    test('ParameterOrder.auto writes the same permutations for up to 3 parameters', () {
      final tools = cases['three parameters, one required']!;
      expect(
        const QwenXmlToolFormat().grammar(
          tools,
          const GrammarOptions(strings: StringValues.singleLine, valueRules: [_PeriodLikeRule()]),
        ),
        oldToolCallGrammar([for (final tool in tools) tool.declaration]),
      );
    });
  });

  group('emission order', () {
    test('root first; per tool each value rule before its param rule, then the call; shared rules last', () {
      final grammar = const QwenXmlToolFormat().grammar([
        _tool(
          'a',
          {
            'kind': _enum(['x', 'y']),
            'text': {'type': 'string'},
            'n': {'type': 'integer', 'minimum': 1, 'maximum': 3},
          },
          ['kind'],
        ),
        _tool('b', {
          'when': {
            'type': 'object',
            'properties': {
              'day': {'type': 'string', 'format': 'date'},
            },
            'required': ['day'],
          },
        }),
      ], const GrammarOptions(valueRules: [_PeriodLikeRule()]));
      final names = [for (final line in grammar.split('\n')) line.split(' ::= ').first];
      expect(names, [
        'root',
        'param-a-kind-value',
        'param-a-kind',
        'param-a-text',
        'param-a-n-value',
        'param-a-n',
        'call-a',
        'param-b-when-value-day',
        'param-b-when-value-day-kv',
        'param-b-when-value',
        'param-b-when',
        'call-b',
        'period-month',
        'period-day',
        'period-range',
        'xml-text',
        'iso-date',
      ]);
      expect(grammar, contains(r'param-a-text ::= "<parameter=text>\n" xml-text "\n</parameter>\n"'));
      GbnfRecognizer(grammar);
    });

    test('anyOrderOnce: the automaton rules come after the params and before the call', () {
      final grammar = const QwenXmlToolFormat().grammar([
        _tool(
          't',
          {
            for (final k in ['a', 'b', 'c', 'd']) k: {'type': 'boolean'},
          },
          ['a'],
        ),
      ]);
      final names = [for (final line in grammar.split('\n')) line.split(' ::= ').first];
      expect(names.sublist(0, 9), [
        'root',
        'param-t-a-value',
        'param-t-a',
        'param-t-b-value',
        'param-t-b',
        'param-t-c-value',
        'param-t-c',
        'param-t-d-value',
        'param-t-d',
      ]);
      expect(names.sublist(9, 25), [for (final mask in _bySize(4)) 'args-t-$mask']);
      expect(names[25], 'call-t');
      expect(grammar, contains(r'call-t ::= "<function=t>\n" (args-t-0) "</function>\n"'));
      expect(
        grammar,
        contains(
          'args-t-0 ::= param-t-a args-t-1 | param-t-b args-t-2 | param-t-c args-t-4 | '
          'param-t-d args-t-8\n',
        ),
      );
      expect(grammar, contains('args-t-1 ::= param-t-b args-t-3 | param-t-c args-t-5 | param-t-d args-t-9 | ""\n'));
      expect(grammar, contains('args-t-15 ::= ""\n'));
    });

    test('maxCalls above 1: root repeats a tc rule, separated by newlines', () {
      final grammar = const QwenXmlToolFormat().grammar([_tool('t', {})], const GrammarOptions(maxCalls: 3));
      expect(grammar.split('\n').take(2), [
        r'root ::= tc ("\n" tc){0,2}',
        r'tc ::= "<tool_call>\n" (call-t) "</tool_call>"',
      ]);
      final recognizer = GbnfRecognizer(grammar);
      final one = _call('t', []);
      expect(recognizer.accepts(one), isTrue);
      expect(recognizer.accepts('$one\n$one\n$one'), isTrue);
      expect(recognizer.accepts('$one\n$one\n$one\n$one'), isFalse);
      expect(recognizer.accepts('$one$one'), isFalse);
      final single = GbnfRecognizer(const QwenXmlToolFormat().grammar([_tool('t', {})]));
      expect(single.accepts('$one\n$one'), isFalse);
    });
  });

  group('parameter orders: their languages', () {
    ToolSpec booleans(int n, Set<int> required) => _tool(
      't',
      {
        for (var i = 0; i < n; i++) 'p$i': {'type': 'boolean'},
      },
      [for (final i in required) 'p$i'],
    );

    String callOf(List<String> keys) => _call('t', [for (final k in keys) (k, 'true')]);

    final requiredSets = {
      0: [<int>{}],
      1: [
        <int>{},
        {0},
      ],
      2: [
        <int>{},
        {1},
        {0, 1},
      ],
      3: [
        <int>{},
        {0},
        {0, 2},
        {0, 1, 2},
      ],
      4: [
        <int>{},
        {3},
        {0, 1, 2, 3},
      ],
      5: [
        <int>{1, 3},
      ],
      6: [
        <int>{},
        {0, 5},
      ],
    };
    for (final MapEntry(key: n, value: sets) in requiredSets.entries) {
      for (final required in sets) {
        test('anyOrderOnce = permutations = any order, each once, the required present (n = $n, required '
            '$required)', () {
          final tool = booleans(n, required);
          GbnfRecognizer grammar(ParameterOrder order) =>
              GbnfRecognizer(const QwenXmlToolFormat().grammar([tool], GrammarOptions(order: order)));
          final permutations = grammar(ParameterOrder.permutations);
          final automaton = grammar(ParameterOrder.anyOrderOnce);
          final keys = [for (var i = 0; i < n; i++) 'p$i'];
          // Every word of up to n + 1 parameters (one past the automaton's last state); for n = 6 (335k words) the
          // words that write at most one parameter twice: every valid call and every call with one repeat. The n!
          // alternatives of permutations are slow to recognize: from n = 5 they see the words with at most one
          // repeat, at n = 6 those with a repeat only up to 3 parameters.
          for (final candidate in _words(keys, maxLength: n + 1, repeats: n < 6 ? null : 1)) {
            final repeats = candidate.length - candidate.toSet().length;
            final expected = repeats == 0 && required.every((i) => candidate.contains('p$i'));
            final text = callOf(candidate);
            expect(automaton.accepts(text), expected, reason: 'anyOrderOnce: $candidate');
            if (n < 5 || repeats == 0 || (repeats == 1 && (n < 6 || candidate.length <= 3))) {
              expect(permutations.accepts(text), expected, reason: 'permutations: $candidate');
            }
          }
        });
      }
    }

    test('declared: the declaration order only, optional parameters skippable', () {
      final recognizer = GbnfRecognizer(
        const QwenXmlToolFormat().grammar([
          booleans(3, {1}),
        ], const GrammarOptions(order: ParameterOrder.declared)),
      );
      expect(recognizer.accepts(callOf(['p0', 'p1', 'p2'])), isTrue);
      expect(recognizer.accepts(callOf(['p1'])), isTrue);
      expect(recognizer.accepts(callOf(['p1', 'p2'])), isTrue);
      expect(recognizer.accepts(callOf(['p1', 'p0'])), isFalse);
      expect(recognizer.accepts(callOf(['p0', 'p2'])), isFalse);
    });

    test('free: any parameters, any order, repeats and missing required ones included', () {
      final grammar = const QwenXmlToolFormat().grammar([
        booleans(3, {0}),
      ], const GrammarOptions(order: ParameterOrder.free));
      expect(
        grammar,
        contains(r'call-t ::= "<function=t>\n" ((param-t-p0 | param-t-p1 | param-t-p2)*) "</function>\n"'),
      );
      final recognizer = GbnfRecognizer(grammar);
      for (final keys in [
        <String>[],
        ['p2', 'p2'],
        ['p1', 'p0', 'p1', 'p0'],
      ]) {
        expect(recognizer.accepts(callOf(keys)), isTrue, reason: '$keys');
      }
    });

    test('auto: permutations up to 3 parameters, the automaton up to exactOrderLimit, free above', () {
      String grammarOf(int n, {int limit = 8}) =>
          const QwenXmlToolFormat().grammar([booleans(n, {})], GrammarOptions(exactOrderLimit: limit));
      expect(grammarOf(3), contains('param-t-p0? param-t-p1? param-t-p2? | '));
      expect(grammarOf(4), contains('(args-t-0)'));
      expect(grammarOf(8), contains('(args-t-0)'));
      expect(grammarOf(9), contains('((param-t-p0 | '));
      expect(grammarOf(5, limit: 4), contains('((param-t-p0 | '));
      expect(grammarOf(3, limit: 2), contains('param-t-p0? param-t-p1? param-t-p2? | '));
    });
  });

  group('size guard', () {
    ToolSpec wide(String name, int n) => _tool(name, {
      for (var i = 0; i < n; i++) 'p$i': {'type': 'boolean'},
    });

    test('above maxRules the tools with the most parameters fall back to free, until the grammar fits', () {
      final tools = [wide('big', 8), wide('mid', 6), wide('small', 2)];
      final unlimited = const QwenXmlToolFormat().grammar(tools);
      expect('\n'.allMatches(unlimited).length + 1, greaterThan(300));
      final guarded = const QwenXmlToolFormat().grammar(tools, const GrammarOptions(maxRules: 120));
      final lines = guarded.split('\n');
      expect(lines.length, lessThanOrEqualTo(120));
      expect(guarded, contains(r'call-big ::= "<function=big>\n" ((param-big-p0 | '));
      expect(guarded, contains('args-mid-0 ::= '), reason: 'the 6-parameter tool keeps its automaton');
      expect(guarded, contains('param-small-p0? param-small-p1? | param-small-p1? param-small-p0?'));
      final tight = const QwenXmlToolFormat().grammar(tools, const GrammarOptions(maxRules: 40));
      expect(tight, contains(r'call-mid ::= "<function=mid>\n" ((param-mid-p0 | '));
      expect(tight, contains('param-small-p0? param-small-p1?'), reason: 'fits once the two larger tools are free');
      GbnfRecognizer(guarded);
      GbnfRecognizer(tight);
    });

    test('an order that alone exceeds the limits is free from the start (no factorial blow-up)', () {
      final twelve = wide('t', 12);
      final watch = Stopwatch()..start();
      final permutations = const QwenXmlToolFormat().grammar([
        twelve,
      ], const GrammarOptions(order: ParameterOrder.permutations));
      final automaton = const QwenXmlToolFormat().grammar([
        twelve,
      ], const GrammarOptions(order: ParameterOrder.anyOrderOnce));
      expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
      expect(permutations, contains('((param-t-p0 | '));
      expect(automaton, contains('((param-t-p0 | '));
      expect(permutations.length, lessThan(GrammarOptions.maxTextLength));
    });

    test('when every tool is free and it still does not fit, the free grammar is returned', () {
      final grammar = const QwenXmlToolFormat().grammar([wide('t', 5)], const GrammarOptions(maxRules: 3));
      expect(grammar, contains('((param-t-p0 | '));
    });
  });

  group('GbnfRules', () {
    test('define keeps creation order and makes names unique; an identical rule is not added twice', () {
      final rules = GbnfRules();
      expect(rules.define('a', '"x"'), 'a');
      expect(rules.define('a', '"x"'), 'a');
      expect(rules.define('a', '"y"'), 'a-2');
      expect(rules.define('a', '"z"'), 'a-3');
      expect(rules.define('a', '"y"'), 'a-2');
      expect(rules.define('root', '"r"'), 'root-2', reason: 'root is the grammar\'s own');
      expect(() => rules.define('a_b', '"x"'), throwsArgumentError);
      expect(() => rules.define('', '"x"'), throwsArgumentError);
    });

    test('literal escapes backslash, double quote and newline only', () {
      final rules = GbnfRules();
      expect(rules.literal('a"b\\c\nd\te'), '"a\\"b\\\\c\\nd\te"');
      expect(rules.literal('<parameter=x>\n'), r'"<parameter=x>\n"');
    });

    test('ruleId turns everything but ASCII letters and digits into -', () {
      expect(GbnfRules.ruleId('list_booking-slots.v2 è'), 'list-booking-slots-v2--');
    });
  });

  group('value rules installed by the host', () {
    test('asked first, in order; the first body wins; their shared rules come even when unused', () {
      final grammar = const QwenXmlToolFormat().grammar([
        _tool('t', {
          'code': {'type': 'string', 'x-kind': 'code'},
          'text': {'type': 'string'},
        }),
      ], const GrammarOptions(valueRules: [_CodeRule('first'), _CodeRule('second'), _UnusedRule()]));
      expect(grammar, contains('param-t-code-value ::= "first"\n'));
      expect(grammar, isNot(contains('"second"')));
      expect(grammar.split('\n').sublist(grammar.split('\n').length - 2), [
        'unused ::= "u"',
        'xml-text ::= ([^<] | "<"+ [^</])+ "<"*',
      ]);
    });

    test('nested JSON values ask them in the json context', () {
      final grammar = const QwenXmlToolFormat().grammar([
        _tool('t', {
          'obj': {
            'type': 'object',
            'properties': {
              'code': {'type': 'string', 'x-kind': 'code'},
            },
          },
        }),
      ], const GrammarOptions(valueRules: [_CodeRule('c', onlyJson: true)]));
      expect(grammar, contains(r'param-t-obj-value-code-kv ::= "\"code\": " param-t-obj-value-code'));
      expect(grammar, contains('param-t-obj-value-code ::= "\\"c\\""'));
    });
  });

  test('bad input: no tools, two tools with one name, maxCalls below 1', () {
    expect(() => const QwenXmlToolFormat().grammar([]), throwsArgumentError);
    expect(() => const QwenXmlToolFormat().grammar([_tool('t', {}), _tool('t', {})]), throwsArgumentError);
    expect(
      () => const QwenXmlToolFormat().grammar([_tool('t', {})], const GrammarOptions(maxCalls: 0)),
      throwsArgumentError,
    );
  });
}

/// Masks of n bits, fewer bits first, then by value.
List<int> _bySize(int n) {
  int bits(int m) => m.toRadixString(2).replaceAll('0', '').length;
  return [for (var m = 0; m < 1 << n; m++) m]..sort((a, b) {
    final bySize = bits(a).compareTo(bits(b));
    return bySize != 0 ? bySize : a.compareTo(b);
  });
}

/// A literal for strings marked `x-kind: code`.
final class _CodeRule implements ValueRule {
  const _CodeRule(this.value, {this.onlyJson = false});

  final String value;
  final bool onlyJson;

  @override
  String? build(Map<String, Object?> schema, GbnfRules rules, ValueContext context) {
    if (schema['x-kind'] != 'code') return null;
    if (onlyJson && context != ValueContext.json) return null;
    return rules.literal(context == ValueContext.json ? '"$value"' : value);
  }

  @override
  List<String> get sharedRules => const [];
}

final class _UnusedRule implements ValueRule {
  const _UnusedRule();

  @override
  String? build(Map<String, Object?> schema, GbnfRules rules, ValueContext context) => null;

  @override
  List<String> get sharedRules => const ['unused ::= "u"'];
}
