// QwenXmlToolFormat: the parser, the streaming rule (visibleText) and the envelope a model writes.
import 'package:local_inference/local_inference.dart';
import 'package:local_inference/testing.dart';
import 'package:test/test.dart';

const QwenXmlToolFormat _format = QwenXmlToolFormat();

final List<ToolSpec> _tools = [
  const ToolSpec(
    name: 'list_booking_slots',
    description: 'Slots of an office.',
    parameters: {
      'type': 'object',
      'properties': {
        'office_number': {'type': 'integer', 'minimum': 1, 'maximum': 8},
        'period': {
          'anyOf': [
            {
              'type': 'string',
              'enum': ['today', 'next_week'],
            },
            {'type': 'string', 'pattern': r'^[0-9]{4}-[0-9]{2}$'},
          ],
        },
      },
      'required': ['office_number'],
    },
  ),
  const ToolSpec(
    name: 'typed',
    description: 'Every kind of parameter.',
    parameters: {
      'type': 'object',
      'properties': {
        'kind': {
          'type': 'integer',
          'enum': [1, 2],
        },
        'ratio': {'type': 'number'},
        'flag': {'type': 'boolean'},
        'text': {'type': 'string'},
        'when': {
          'type': 'object',
          'properties': {
            'day': {'type': 'string'},
          },
        },
        'tags': {
          'type': 'array',
          'items': {'type': 'string'},
        },
        'either': {
          'type': ['integer', 'null'],
        },
        'choice': {
          'type': 'string',
          'enum': ['1', '2'],
        },
      },
    },
  ),
  const ToolSpec(name: 'list_booking_offices', description: 'Offices.'),
];

void main() {
  test('triggers and preserved tokens: the <tool_call> word and the envelope\'s 8 tags', () {
    expect(_format.triggers, [const GrammarTrigger.word('<tool_call>')]);
    expect(_format.preservedTokens, [
      '<think>',
      '</think>',
      '<tool_call>',
      '</tool_call>',
      '<function=',
      '</function>',
      '<parameter=',
      '</parameter>',
    ]);
  });

  group('parse', () {
    test('a tool call with arguments typed from the schema; an anyOf stays a string', () {
      const raw =
          '<tool_call>\n<function=list_booking_slots>\n<parameter=office_number>\n2\n</parameter>\n'
          '<parameter=period>\nnext_week\n</parameter>\n</function>\n</tool_call>';
      final parsed = _format.parse(raw, _tools);
      expect(parsed.hasToolCalls, isTrue);
      expect(
        parsed.toolCalls.single,
        const ToolCall('list_booking_slots', {'office_number': 2, 'period': 'next_week'}),
      );
      expect((parsed.text, parsed.reasoning, parsed.error), ('', null, null));
    });

    test('a tool call without arguments', () {
      final parsed = _format.parse('<tool_call>\n<function=list_booking_offices>\n</function>\n</tool_call>', _tools);
      expect(parsed.toolCalls.single, const ToolCall('list_booking_offices'));
    });

    test('plain text and an empty think block; a think block with text is the reasoning', () {
      final plain = _format.parse('<think>\n\n</think>\n\nCiao, dimmi pure.', _tools);
      expect((plain.hasToolCalls, plain.text, plain.reasoning), (false, 'Ciao, dimmi pure.', null));
      final reasoned = _format.parse(
        '<think>\nThe user greets.\n</think>\n\nHi!\n<tool_call>\n<function=list_booking_offices>\n</function>\n'
        '</tool_call>',
        _tools,
      );
      expect((reasoned.reasoning, reasoned.text, reasoned.toolCalls.length), ('The user greets.', 'Hi!', 1));
    });

    test('a multi-line string value is kept, trimmed at its ends', () {
      const raw =
          '<tool_call>\n<function=typed>\n<parameter=text>\n  anagrafe\ncarta \n</parameter>\n</function>\n'
          '</tool_call>';
      expect(_format.parse(raw, _tools).toolCalls.single.arguments, {'text': 'anagrafe\ncarta'});
    });

    test('the typing of each kind: strings raw, numbers and booleans parsed, enums as their values, the rest JSON', () {
      String call(String key, String value) =>
          '<tool_call>\n<function=typed>\n<parameter=$key>\n$value\n</parameter>\n</function>\n</tool_call>';
      Object? value(String key, String text) => _format.parse(call(key, text), _tools).toolCalls.single.arguments[key];
      expect(value('choice', '2'), '2', reason: 'a string enum keeps the text');
      expect(value('kind', '2'), 2, reason: 'an integer enum gives the integer the validator expects');
      expect(value('ratio', '0.5'), 0.5);
      expect(value('ratio', 'half'), 'half');
      expect(value('flag', 'true'), true);
      expect(value('flag', 'false'), false);
      expect(value('flag', 'yes'), 'yes');
      expect(value('text', '42'), '42');
      expect(value('when', '{"day": "mon"}'), {'day': 'mon'});
      expect(value('tags', '["a", "b"]'), ['a', 'b']);
      expect(value('tags', 'a, b'), 'a, b');
      expect(value('either', 'null'), null);
    });

    test('grammar, parser and validator agree: what the grammar admits parses to arguments the schema accepts', () {
      final shapes = <String, (Map<String, Object?>, List<String>)>{
        'an optional integer (a Pydantic Optional[int])': (
          {
            'anyOf': [
              {'type': 'integer', 'minimum': 1, 'maximum': 9},
              {'type': 'null'},
            ],
          },
          ['5', 'null'],
        ),
        'an optional string': (
          {
            'anyOf': [
              {'type': 'string'},
              {'type': 'null'},
            ],
          },
          ['42', 'text', 'null'],
        ),
        'a string or an object': (
          {
            'anyOf': [
              {'type': 'string'},
              {
                'type': 'object',
                'properties': {
                  'a': {'type': 'integer'},
                },
              },
            ],
          },
          ['[1]', '42', '{"a": 1}'],
        ),
        'a type list': (
          {
            'type': ['string', 'null'],
          },
          ['42', 'null'],
        ),
        'an integer enum': (
          {
            'type': 'integer',
            'enum': [1, 2],
          },
          ['2'],
        ),
        'a mixed enum': (
          {
            'enum': [1, 'a', null],
          },
          ['1', 'a', 'null'],
        ),
        'a boolean const': ({'const': true}, ['true']),
        r'a $ref to a string': ({r'$ref': r'#/$defs/code'}, ['123']),
        r'a $ref to an integer': ({r'$ref': r'#/$defs/count'}, ['7']),
      };
      for (final MapEntry(key: name, value: (schema, texts)) in shapes.entries) {
        final tool = ToolSpec(
          name: 't',
          description: 'd',
          parameters: {
            'type': 'object',
            'properties': {'v': schema},
            'required': ['v'],
            r'$defs': {
              'code': {'type': 'string', 'pattern': r'^[0-9]+$'},
              'count': {'type': 'integer'},
            },
          },
        );
        final grammar = GbnfRecognizer(_format.grammar([tool]));
        for (final text in texts) {
          final call = '<tool_call>\n<function=t>\n<parameter=v>\n$text\n</parameter>\n</function>\n</tool_call>';
          expect(grammar.accepts(call), isTrue, reason: '$name: the grammar admits $text');
          final arguments = _format.parse(call, [tool]).toolCalls.single.arguments;
          expect(validateArguments(tool.parameters, arguments), isEmpty, reason: '$name: $text gave $arguments');
        }
      }
    });

    test('an unknown tool or argument is decoded as JSON, falling back to the string', () {
      const raw =
          '<tool_call>\n<function=nope>\n<parameter=n>\n3\n</parameter>\n<parameter=s>\nwords\n</parameter>\n'
          '</function>\n</tool_call>';
      expect(_format.parse(raw, _tools).toolCalls.single, const ToolCall('nope', {'n': 3, 's': 'words'}));
      const extra =
          '<tool_call>\n<function=list_booking_slots>\n<parameter=office_number>\n1\n</parameter>\n'
          '<parameter=extra>\n[1]\n</parameter>\n</function>\n</tool_call>';
      expect(_format.parse(extra, _tools).toolCalls.single.arguments, {
        'office_number': 1,
        'extra': [1],
      });
    });

    test('a tool_call without a function block is left out with an error; the text around stays', () {
      final parsed = _format.parse('Vediamo. <tool_call>\n<func=x>\n</tool_call>', _tools);
      expect(parsed.toolCalls, isEmpty);
      expect(parsed.error, 'tool_call without a <function=...> block: <func=x>');
      expect(parsed.text, 'Vediamo.');
    });

    test('several calls in order; a repeated parameter keeps its last value and is listed apart, not as an error', () {
      const repeat =
          '<tool_call>\n<function=list_booking_slots>\n<parameter=office_number>\n1\n</parameter>\n'
          '<parameter=office_number>\n3\n</parameter>\n</function>\n</tool_call>';
      final parsed = _format.parse(
        '<tool_call>\n<function=list_booking_offices>\n</function>\n</tool_call>\n$repeat',
        _tools,
      );
      expect(parsed.toolCalls, [
        const ToolCall('list_booking_offices'),
        const ToolCall('list_booking_slots', {'office_number': 3}),
      ]);
      expect(parsed.error, isNull, reason: 'the parse error is only for a block without a function');
      expect(parsed.repeatedParameters, ['list_booking_slots.office_number']);
      final after = _format.parse('<tool_call>\nfoo\n</tool_call>\n$repeat', _tools);
      expect(after.error, 'tool_call without a <function=...> block: foo');
      expect(after.repeatedParameters, ['list_booking_slots.office_number']);
      expect(_format.parse(repeat.replaceFirst('1', '2'), _tools).toolCalls.single.arguments, {'office_number': 3});
    });
  });

  group('visibleText', () {
    test('empty or whitespace: nothing yet', () {
      expect(_format.visibleText(''), '');
      expect(_format.visibleText(' \n '), '');
    });

    test('starting with <: empty while it may still become <tool_call>, null for another tag', () {
      expect(_format.visibleText('<'), '');
      expect(_format.visibleText('  <tool_ca'), '');
      expect(_format.visibleText('<tool_call>\n<function=x>'), '');
      expect(_format.visibleText('<think>'), isNull);
      expect(_format.visibleText('<b>bold</b>'), isNull);
    });

    test('text before a tool call, trimmed; the call is cut', () {
      expect(_format.visibleText('Ecco:\n<tool_call>\n<function=x>'), 'Ecco:');
      expect(_format.visibleText('  Ciao, dimmi pure.  '), 'Ciao, dimmi pure.');
    });

    test('a partial <tool_call> at the end is held back; another < is not', () {
      expect(_format.visibleText('Vediamo <tool'), 'Vediamo');
      expect(_format.visibleText('Vediamo <'), 'Vediamo');
      expect(_format.visibleText('a < b'), 'a < b');
      expect(_format.visibleText('Vediamo <toolx'), 'Vediamo <toolx');
    });
  });

  group('render', () {
    test('the envelope a model writes: strings as they are, other values as JSON in Python\'s style', () {
      expect(
        _format.render(const ToolCall('list_booking_slots', {'office_number': 2, 'period': 'next_week'})),
        '<tool_call>\n<function=list_booking_slots>\n<parameter=office_number>\n2\n</parameter>\n'
        '<parameter=period>\nnext_week\n</parameter>\n</function>\n</tool_call>',
      );
      expect(
        _format.render(const ToolCall('list_booking_offices')),
        '<tool_call>\n<function=list_booking_offices>\n</function>\n</tool_call>',
      );
      expect(
        _format.render(
          const ToolCall('typed', {
            'when': {'day': 'mon', 'n': 1},
          }),
        ),
        contains('<parameter=when>\n{"day": "mon", "n": 1}\n</parameter>'),
      );
    });

    test('round trip: parse(render(call)) is the call, and the grammar admits it', () {
      final calls = [
        const ToolCall('list_booking_slots', {'office_number': 8, 'period': '2026-09'}),
        const ToolCall('typed', {
          'ratio': 1.5,
          'flag': false,
          'text': 'two\nlines, a < b',
          'when': {'day': 'mon'},
          'tags': ['x', 'y'],
          'either': 3,
        }),
        const ToolCall('list_booking_offices'),
      ];
      final grammar = GbnfRecognizer(_format.grammar(_tools));
      for (final call in calls) {
        final text = _format.render(call);
        expect(_format.parse(text, _tools).toolCalls.single, call);
        expect(grammar.accepts(text), isTrue, reason: text);
      }
    });
  });
}
