// validateArguments: the grammar admits a superset, the validator is exact.
import 'package:local_inference/local_inference.dart';
import 'package:test/test.dart';

List<String> _check(Map<String, Object?> property, Object? value) => validateArguments(
  {
    'type': 'object',
    'properties': {'v': property},
  },
  {'v': value},
);

void main() {
  test('valid arguments give no problems', () {
    final schema = {
      'type': 'object',
      'properties': {
        'n': {'type': 'integer', 'minimum': 1, 'maximum': 8},
        's': {'type': 'string'},
      },
      'required': ['n'],
      'additionalProperties': false,
    };
    expect(validateArguments(schema, {'n': 2, 's': 'x'}), isEmpty);
    expect(validateArguments(schema, {'n': 2}), isEmpty);
  });

  test('type: a name or a list; integer takes whole doubles; problems name the path and both kinds', () {
    expect(_check({'type': 'integer'}, 'x'), ['v: expected an integer, got a string']);
    expect(_check({'type': 'integer'}, 2.0), isEmpty);
    expect(_check({'type': 'integer'}, 2.5), ['v: expected an integer, got a number']);
    expect(_check({'type': 'number'}, 2), isEmpty);
    expect(_check({'type': 'boolean'}, 'true'), ['v: expected a boolean, got a string']);
    expect(_check({'type': 'object'}, [1]), ['v: expected an object, got an array']);
    expect(_check({'type': 'array'}, {}), ['v: expected an array, got an object']);
    expect(_check({'type': 'null'}, 0), ['v: expected null, got an integer']);
    expect(
      _check({
        'type': ['string', 'null'],
      }, null),
      isEmpty,
    );
    expect(
      _check({
        'type': ['string', 'null'],
      }, 1),
      ['v: expected a string or null, got an integer'],
    );
  });

  test('enum and const, compared as JSON values', () {
    expect(
      _check({
        'enum': ['upcoming', 'past'],
      }, 'past'),
      isEmpty,
    );
    expect(
      _check({
        'enum': ['upcoming', 'past'],
      }, 'all'),
      ['v: "all" is not one of "upcoming", "past"'],
    );
    expect(
      _check({
        'enum': [1, 2],
      }, 2.0),
      isEmpty,
    );
    expect(
      _check(
        {
          'const': {'a': 1},
        },
        {'a': 1},
      ),
      isEmpty,
    );
    expect(_check({'const': 'x'}, 'y'), ['v: must be "x"']);
  });

  test('minimum and maximum, inclusive and exclusive (numbers and draft-4 booleans)', () {
    expect(_check({'minimum': 1, 'maximum': 8}, 1), isEmpty);
    expect(_check({'minimum': 1, 'maximum': 8}, 8), isEmpty);
    expect(_check({'minimum': 1}, 0), ['v: 0 is below the minimum 1']);
    expect(_check({'maximum': 8}, 9), ['v: 9 is above the maximum 8']);
    expect(_check({'exclusiveMinimum': 0}, 0), ['v: 0 must be above 0']);
    expect(_check({'exclusiveMaximum': 1.5}, 1.5), ['v: 1.5 must be below 1.5']);
    expect(_check({'minimum': 1, 'exclusiveMinimum': true}, 1), ['v: 1 must be above 1']);
    expect(_check({'maximum': 3, 'exclusiveMaximum': true}, 2), isEmpty);
    expect(_check({'minimum': 1}, 'text'), isEmpty, reason: 'numeric keywords apply to numbers only');
  });

  test('minLength and maxLength in code points, pattern searched, date and date-time formats', () {
    expect(_check({'minLength': 2}, 'a'), ['v: is shorter than 2 characters']);
    expect(_check({'maxLength': 2}, 'abc'), ['v: is longer than 2 characters']);
    expect(_check({'maxLength': 1}, '😀'), isEmpty);
    expect(_check({'pattern': r'^[0-9]{4}-[0-9]{2}$'}, '2026-09'), isEmpty);
    expect(_check({'pattern': r'^[0-9]{4}-[0-9]{2}$'}, '2026-9'), [
      r'v: "2026-9" does not match the pattern ^[0-9]{4}-[0-9]{2}$',
    ]);
    expect(_check({'pattern': 'b'}, 'abc'), isEmpty, reason: 'JSON Schema searches the pattern');
    expect(_check({'format': 'date'}, '2026-02-28'), isEmpty);
    expect(_check({'format': 'date'}, '2026-02-29'), ['v: "2026-02-29" is not a date (YYYY-MM-DD)']);
    expect(_check({'format': 'date'}, '2028-02-29'), isEmpty);
    expect(_check({'format': 'date-time'}, '2026-09-04T10:30:00Z'), isEmpty);
    expect(_check({'format': 'date-time'}, '2026-09-04T10:30:00.25+02:00'), isEmpty);
    expect(_check({'format': 'date-time'}, '2026-09-04 10:30'), [
      'v: "2026-09-04 10:30" is not a date and time (YYYY-MM-DDThh:mm:ss, RFC 3339)',
    ]);
    expect(_check({'format': 'email'}, 'not checked'), isEmpty);
    expect(() => _check({'pattern': '('}, 'x'), throwsArgumentError);
  });

  test('required, properties and additionalProperties, at the root and nested', () {
    final schema = {
      'type': 'object',
      'properties': {
        'when': {
          'type': 'object',
          'properties': {
            'date': {'type': 'string', 'format': 'date'},
            'hour': {'type': 'integer', 'maximum': 23},
          },
          'required': ['date'],
          'additionalProperties': false,
        },
        'extra': {
          'type': 'object',
          'additionalProperties': {'type': 'integer'},
        },
      },
      'required': ['when'],
      'additionalProperties': false,
    };
    expect(validateArguments(schema, {}), ["missing required argument 'when'"]);
    expect(validateArguments(schema, {'when': {}, 'foo': 1}), [
      "when: missing required property 'date'",
      "unknown argument 'foo'",
    ]);
    expect(
      validateArguments(schema, {
        'when': {'date': '2026-09-04', 'hour': 24, 'minute': 0},
      }),
      ['when.hour: 24 is above the maximum 23', "when: unknown property 'minute'"],
    );
    expect(
      validateArguments(schema, {
        'when': {'date': '2026-09-04'},
        'extra': {'a': 1, 'b': 'x'},
      }),
      ['extra.b: expected an integer, got a string'],
    );
    expect(
      validateArguments({'type': 'object'}, {'anything': 1}),
      isEmpty,
      reason: 'additional properties are allowed unless the schema says otherwise',
    );
  });

  test('items (a schema or a tuple), minItems and maxItems', () {
    expect(
      _check(
        {
          'items': {'type': 'string'},
          'maxItems': 2,
        },
        ['a', 1, 'c'],
      ),
      ['v: has more than 2 items', 'v[1]: expected a string, got an integer'],
    );
    expect(_check({'minItems': 1}, []), ['v: has fewer than 1 items']);
    expect(
      _check(
        {
          'items': [
            {'type': 'string'},
            {'type': 'integer'},
          ],
        },
        ['a', 'b'],
      ),
      ['v[1]: expected an integer, got a string'],
    );
  });

  test('anyOf, oneOf and allOf', () {
    final period = {
      'anyOf': [
        {
          'type': 'string',
          'enum': ['today', 'this_week'],
        },
        {'type': 'string', 'pattern': r'^[0-9]{4}-[0-9]{2}$'},
      ],
    };
    expect(_check(period, 'today'), isEmpty);
    expect(_check(period, '2026-09'), isEmpty);
    expect(_check(period, 'yesterday'), ['v: matches none of the allowed forms']);
    final oneOf = {
      'oneOf': [
        {'type': 'integer'},
        {'type': 'number'},
      ],
    };
    expect(_check(oneOf, 1.5), isEmpty);
    expect(_check(oneOf, 1), ['v: matches more than one of the allowed forms']);
    expect(_check(oneOf, 'x'), ['v: matches none of the allowed forms']);
    expect(
      _check({
        'allOf': [
          {'minimum': 1},
          {'maximum': 3},
        ],
      }, 4),
      ['v: 4 is above the maximum 3'],
    );
  });

  test(r'local $refs: $defs, definitions, JSON pointers and recursion; an unknown $ref is an error', () {
    final schema = {
      'type': 'object',
      'properties': {
        'node': {r'$ref': r'#/$defs/node'},
        'unit': {r'$ref': '#/definitions/unit'},
        'first': {r'$ref': '#/properties/unit'},
      },
      r'$defs': {
        'node': {
          'type': 'object',
          'properties': {
            'value': {'type': 'integer'},
            'next': {r'$ref': r'#/$defs/node'},
          },
          'required': ['value'],
        },
      },
      'definitions': {
        'unit': {
          'enum': ['c', 'f'],
        },
      },
    };
    expect(
      validateArguments(schema, {
        'node': {
          'value': 1,
          'next': {'value': 2},
        },
        'unit': 'c',
        'first': 'f',
      }),
      isEmpty,
    );
    expect(
      validateArguments(schema, {
        'node': {
          'value': 1,
          'next': {'value': 'x'},
        },
        'unit': 'k',
      }),
      ['node.next.value: expected an integer, got a string', 'unit: "k" is not one of "c", "f"'],
    );
    expect(() => validateArguments({r'$ref': '#/nope'}, {}), throwsArgumentError);
    expect(
      () => validateArguments({r'$ref': '#'}, {}),
      throwsArgumentError,
      reason: 'a loop that never reaches a value',
    );
  });
}
