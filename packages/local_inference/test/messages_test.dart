// The model layer's values: ChatMessage, ToolCall, ToolSpec and ToolSchema.
import 'dart:convert';

import 'package:local_inference/local_inference.dart';
import 'package:test/test.dart';

void main() {
  group('ChatMessage', () {
    test('toJson: role and content in that order, then only the keys that are set', () {
      expect(jsonEncode(const ChatMessage.system('s').toJson()), '{"role":"system","content":"s"}');
      expect(jsonEncode(const ChatMessage.user('u').toJson()), '{"role":"user","content":"u"}');
      expect(jsonEncode(const ChatMessage.assistant('a').toJson()), '{"role":"assistant","content":"a"}');
      expect(jsonEncode(const ChatMessage.tool('t').toJson()), '{"role":"tool","content":"t"}');
      expect(
        jsonEncode(
          const ChatMessage.assistant(
            '',
            toolCalls: [
              ToolCall('f', {'x': 1}),
              ToolCall('g'),
            ],
            reasoning: 'r',
          ).toJson(),
        ),
        '{"role":"assistant","content":"","tool_calls":[{"type":"function","function":{"name":"f","arguments":{"x":1}}},'
        '{"type":"function","function":{"name":"g","arguments":{}}}],"reasoning_content":"r"}',
      );
      expect(jsonEncode(const ChatMessage.tool('t', name: 'f').toJson()), '{"role":"tool","content":"t","name":"f"}');
      expect(jsonEncode(const ChatMessage.assistant('a', reasoning: '').toJson()), contains('"reasoning_content":""'));
    });

    test('value equality, tool calls included', () {
      expect(const ChatMessage.user('a'), const ChatMessage.user('a'));
      expect(const ChatMessage.user('a'), isNot(const ChatMessage.system('a')));
      expect(
        const ChatMessage.assistant(
          'x',
          toolCalls: [
            ToolCall('f', {'a': 1}),
          ],
        ),
        ChatMessage.assistant(
          'x',
          toolCalls: [
            ToolCall('f', {'a': 1.0}),
          ],
        ),
      );
      expect(const ChatMessage.tool('t', name: 'a'), isNot(const ChatMessage.tool('t', name: 'b')));
      expect(const ChatMessage.user('a').hashCode, const ChatMessage.user('a').hashCode);
      expect(MessageRole.values.map((r) => r.name), ['system', 'user', 'assistant', 'tool']);
    });
  });

  group('ToolCall', () {
    test('fromJson takes the tool/args form and the name/arguments form, arguments as a map or a JSON string', () {
      expect(
        ToolCall.fromJson({
          'tool': 'list_appointments',
          'args': {'scope': 'past'},
        }),
        const ToolCall('list_appointments', {'scope': 'past'}),
      );
      expect(
        ToolCall.fromJson({
          'name': 'f',
          'arguments': {'n': 2},
        }),
        const ToolCall('f', {'n': 2}),
      );
      expect(ToolCall.fromJson({'name': 'f', 'arguments': '{"n": 2}'}), const ToolCall('f', {'n': 2}));
      expect(ToolCall.fromJson({'tool': 'f'}), const ToolCall('f'));
      expect(() => ToolCall.fromJson({'args': {}}), throwsFormatException);
      expect(() => ToolCall.fromJson({'tool': 'f', 'args': 3}), throwsFormatException);
      expect(() => ToolCall.fromJson({'name': 'f', 'arguments': '{oops'}), throwsFormatException);
    });

    test('key, toJson and toString', () {
      const call = ToolCall('book_appointment', {'slot_number': 2, 'note': 'è'});
      expect(call.key, 'book_appointment {"slot_number":2,"note":"è"}');
      expect(call.toJson(), {
        'tool': 'book_appointment',
        'args': {'slot_number': 2, 'note': 'è'},
      });
      expect(ToolCall.fromJson(call.toJson()), call);
      expect('$call', 'book_appointment({"slot_number":2,"note":"è"})');
    });

    test('typed accessors', () {
      const call = ToolCall('f', {
        's': 'text',
        'i': 3,
        'd': 4.0,
        'si': ' 5 ',
        'b': true,
        'sb': 'false',
        'x': [1],
        'half': 2.5,
      });
      expect([call.string('s'), call.string('i'), call.string('missing')], ['text', null, null]);
      expect(
        [call.integer('i'), call.integer('d'), call.integer('si'), call.integer('s'), call.integer('half')],
        [3, 4, 5, null, null],
      );
      expect([call.boolean('b'), call.boolean('sb'), call.boolean('s')], [true, false, null]);
      expect(call.requireString('s'), 'text');
      expect(() => call.requireString('i'), throwsArgumentError);
    });

    test('value equality is deep and ignores key order; the hash agrees', () {
      const a = ToolCall('f', {
        'x': [
          1,
          {'y': 'z'},
        ],
        'n': 1,
      });
      final b = ToolCall('f', {
        'n': 1.0,
        'x': [
          1,
          {'y': 'z'},
        ],
      });
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(
        a,
        isNot(
          const ToolCall('f', {
            'x': [1],
            'n': 1,
          }),
        ),
      );
      expect(const ToolCall('f'), isNot(const ToolCall('g')));
    });
  });

  group('ToolSpec', () {
    test('declaration: type, then function with name, description and parameters, in that key order', () {
      const spec = ToolSpec(name: 'f', description: 'Does f.');
      expect(
        jsonEncode(spec.declaration),
        '{"type":"function","function":{"name":"f","description":"Does f.","parameters":{"type":"object",'
        '"properties":{}}}}',
      );
      expect(spec.sideEffect, SideEffect.read);
    });

    test('declaration: promptDeclaration verbatim when set, key order kept', () {
      const compact = {
        'type': 'function',
        'function': {
          'name': 'f',
          'parameters': {'x-kept': 1},
          'description': 'short',
        },
      };
      const spec = ToolSpec(
        name: 'f',
        description: 'The long description.',
        parameters: {
          'type': 'object',
          'properties': {'a': {}},
        },
        promptDeclaration: compact,
      );
      expect(identical(spec.declaration, compact), isTrue);
    });

    test(r'declaration: x-* keywords go at any depth; property names, $defs names and enum data stay', () {
      const spec = ToolSpec(
        name: 'f',
        description: 'd',
        parameters: {
          'type': 'object',
          'x-top': true,
          'properties': {
            'x-coord': {'type': 'integer', 'x-item-of': 'lists'},
            'kind': {
              'enum': ['x-a', 'b'],
              'default': {'x-data': 1},
            },
            'list': {
              'type': 'array',
              'items': {'type': 'string', 'x-note': 'n'},
            },
            'either': {
              'anyOf': [
                {'type': 'string', 'x-a': 1},
                {'type': 'null'},
              ],
            },
          },
          r'$defs': {
            'x-def': {'type': 'string', 'x-b': 2},
          },
        },
      );
      expect(
        pythonJson((spec.declaration['function'] as Map)['parameters']),
        pythonJson({
          'type': 'object',
          'properties': {
            'x-coord': {'type': 'integer'},
            'kind': {
              'enum': ['x-a', 'b'],
              'default': {'x-data': 1},
            },
            'list': {
              'type': 'array',
              'items': {'type': 'string'},
            },
            'either': {
              'anyOf': [
                {'type': 'string'},
                {'type': 'null'},
              ],
            },
          },
          r'$defs': {
            'x-def': {'type': 'string'},
          },
        }),
      );
      expect(spec.parameters['x-top'], isTrue, reason: 'the spec keeps the full schema');
    });
  });

  group('ToolSchema', () {
    test('fixed key order: the kind, the description, then the constraints in parameter order', () {
      expect(
        jsonEncode(
          ToolSchema.string(
            format: 'date',
            pattern: '^a',
            maxLength: 9,
            minLength: 1,
            enumValues: ['a'],
            description: 'd',
          ),
        ),
        '{"type":"string","description":"d","enum":["a"],"minLength":1,"maxLength":9,"pattern":"^a","format":"date"}',
      );
      expect(jsonEncode(ToolSchema.string()), '{"type":"string"}');
      expect(
        jsonEncode(ToolSchema.integer(maximum: 8, minimum: 1, description: 'n')),
        '{"type":"integer","description":"n","minimum":1,"maximum":8}',
      );
      expect(jsonEncode(ToolSchema.number(minimum: 0.5, maximum: 2)), '{"type":"number","minimum":0.5,"maximum":2}');
      expect(jsonEncode(ToolSchema.boolean(description: 'b')), '{"type":"boolean","description":"b"}');
      expect(
        jsonEncode(ToolSchema.array(ToolSchema.integer(), maxItems: 3, minItems: 1, description: 'l')),
        '{"type":"array","description":"l","items":{"type":"integer"},"minItems":1,"maxItems":3}',
      );
      expect(
        jsonEncode(ToolSchema.anyOf([ToolSchema.string(), ToolSchema.integer()], description: 'u')),
        '{"anyOf":[{"type":"string"},{"type":"integer"}],"description":"u"}',
      );
      expect(
        jsonEncode(
          ToolSchema.object({'b': ToolSchema.boolean(), 'a': ToolSchema.string()}, required: ['a'], description: 'o'),
        ),
        '{"type":"object","description":"o","properties":{"b":{"type":"boolean"},"a":{"type":"string"}},'
        '"required":["a"]}',
      );
      expect(
        jsonEncode(ToolSchema.object({'a': ToolSchema.string()})),
        '{"type":"object","properties":{"a":{"type":"string"}}}',
      );
    });

    test('object rejects required names that are not properties; anyOf needs options', () {
      expect(() => ToolSchema.object({'a': ToolSchema.string()}, required: ['b']), throwsArgumentError);
      expect(() => ToolSchema.anyOf([]), throwsArgumentError);
    });

    test('itemNumber: an integer 1..maxShown with the x-item-of marker last; the model never reads the marker', () {
      expect(
        jsonEncode(ToolSchema.itemNumber('orders', description: 'n', maxShown: 5)),
        '{"type":"integer","description":"n","minimum":1,"maximum":5,"x-item-of":"orders"}',
      );
      expect(
        jsonEncode(ToolSchema.itemNumber('slots')),
        '{"type":"integer","minimum":1,"maximum":8,"x-item-of":"slots"}',
      );
      expect(() => ToolSchema.itemNumber(''), throwsArgumentError);
      expect(() => ToolSchema.itemNumber('orders', maxShown: 0), throwsArgumentError);
      final spec = ToolSpec(
        name: 'cancel_order',
        description: 'Cancels an order.',
        parameters: ToolSchema.object({'order_number': ToolSchema.itemNumber('orders')}, required: ['order_number']),
      );
      expect(
        jsonEncode(spec.declaration),
        '{"type":"function","function":{"name":"cancel_order","description":"Cancels an order.","parameters":'
        '{"type":"object","properties":{"order_number":{"type":"integer","minimum":1,"maximum":8}},'
        '"required":["order_number"]}}}',
      );
      expect(validateArguments(spec.parameters, {'order_number': 8}), isEmpty);
      expect(validateArguments(spec.parameters, {'order_number': 0}), ['order_number: 0 is below the minimum 1']);
    });

    test('a schema built with ToolSchema validates as it reads', () {
      final schema = ToolSchema.object(
        {
          'n': ToolSchema.integer(minimum: 1, maximum: 8),
          'tags': ToolSchema.array(ToolSchema.string(enumValues: ['a', 'b']), maxItems: 2),
        },
        required: ['n'],
      );
      expect(
        validateArguments(schema, {
          'n': 3,
          'tags': ['a'],
        }),
        isEmpty,
      );
      expect(validateArguments(schema, {'n': 9}), ['n: 9 is above the maximum 8']);
    });
  });
}
