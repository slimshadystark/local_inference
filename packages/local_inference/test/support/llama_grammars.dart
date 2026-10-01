// Grammars at the edges of llama.cpp's GBNF parser (src/llama-grammar.cpp at llama.cpp v0.4.0, the runtime of
// llamadart 0.8.23) and whether it accepts them. GbnfRecognizer must agree with every verdict
// (gbnf_recognizer_test.dart), and so must the real runtime (model_test.dart, on a real model), which also parses the
// grammars the builder writes for the value shapes below.
import 'package:local_inference/local_inference.dart';

/// (what it shows, the grammar, whether llama.cpp accepts it).
const List<(String, String, bool)> llamaCppGrammars = [
  // parse_char (llama-grammar.cpp:162-184): the escapes x u U t r n \ " [ ] - and no other.
  ('an escaped caret', r'root ::= [a\^] "1"', false),
  ('a caret as a hex escape', r'root ::= [a\x5E] "1"', true),
  ('an escaped dash, in a class and in a literal', r'root ::= [+\-] "\-1"', true),
  // handle_repetitions (llama-grammar.cpp:463-528): the rules a group synthesizes (:597-599) times the bound.
  ('a group of 40 rules repeated 60 times', r'root ::= ([a-z]{1,40} " "){1,60}', false),
  ('a group of 20 rules repeated 60 times', r'root ::= ([a-z]{1,20} " "){1,60}', true),
  ('the same repetition through a rule', 'root ::= word{1,60}\nword ::= [a-z]{1,40} " "', true),
  ('a bound of 2000', r'root ::= "a"{0,2000}', false),
  ('a bound of 1999', r'root ::= "a"{0,1999}', true),
  ('an open repetition from 2000', r'root ::= "a"{2000,}', false),
  // llama-grammar.cpp:652-657: a minimum above 2000 is refused, a maximum above 2000 is dropped.
  ('a minimum above 2000', r'root ::= "a"{2001}', false),
  ('a maximum above 2000 is no maximum', r'root ::= "a"{0,5000}', true),
  // A rule name met for the first time inside a group is a rule the group synthesizes (get_symbol_id, :588).
  ('a rule first named inside a repeated group', 'root ::= ("a" | b){1000}\nb ::= "b"', false),
  ('a rule named before the repeated group', 'b ::= "b"\nroot ::= ("a" | b){1999}', true),
  // An open repetition's helper rule R ::= item R | (empty) is left recursion (llama_grammar_detect_left_recursion,
  // :958-1009) when the item may be empty: a rule with an alternative that writes nothing, one level deep.
  ('an open repetition of a group with an empty alternative', 'root ::= ("a" | "")* "b"', false),
  ('one or more of a group with an empty alternative', 'root ::= ("a" | "")+ "b"', false),
  ('a maximum above 2000 is open: the same', 'root ::= ("a" | ""){0,3000} "b"', false),
  ('an open repetition of a rule with an empty alternative', 'root ::= g* "b"\ng ::= "a" | ""', false),
  ('an optional, repeated', 'root ::= "a"?* "b"', false),
  ('a group of an optional, repeated: the group writes a reference', 'root ::= ("a"?)* "b"', true),
  ('a bounded repetition of a group with an empty alternative', 'root ::= ("a" | ""){0,5} "b"', true),
  ('an optional group with an empty alternative', 'root ::= ("a" | "")? "b"', true),
  ('a quantifier after an empty literal', 'root ::= "a" ""*', false),
];

/// Patterns whose classes hold characters llama.cpp has no escape for, a repeated group with inner repetitions, and
/// open repetitions of groups with an empty alternative.
const Map<String, String> edgePatterns = {
  'caret': r'^[a^]$',
  'not-word': r'^\W+$',
  'slug': r'^[a-z0-9-]+$',
  'signed': r'^[+-]?[0-9]+$',
  'words': r'^([a-z]{1,40} ){1,60}$',
  'empty-alternative': r'^x(|a|b)+(|c+)*$',
};

/// Grammars the builder writes for every kind of value, by name: patterns, integer ranges, unions, dates, JSON
/// objects and arrays with a recursive `$ref`, the parameter orders, several calls, a structured response.
Map<String, String> builderGrammars() {
  const format = QwenXmlToolFormat();
  final edge = ToolSpec(
    name: 'edge',
    description: 'Every kind of value.',
    parameters: {
      'type': 'object',
      'properties': {
        for (final MapEntry(:key, :value) in edgePatterns.entries) key: {'type': 'string', 'pattern': value},
        'count': {'type': 'integer', 'minimum': 15, 'maximum': 3050},
        'either': {
          'anyOf': [
            {'type': 'integer', 'minimum': -35, 'maximum': -15},
            {'type': 'null'},
          ],
        },
        'when': {
          'type': 'object',
          'properties': {
            'day': {'type': 'string', 'format': 'date'},
            'at': {'type': 'string', 'format': 'date-time'},
          },
          'required': ['day'],
        },
        'tags': {
          'type': 'array',
          'items': {
            'type': 'string',
            'enum': ['a', 'b"c'],
          },
          'maxItems': 3,
        },
        'tree': {r'$ref': r'#/$defs/node'},
      },
      'required': ['count'],
      r'$defs': {
        'node': {
          'type': 'object',
          'properties': {
            'label': {'type': 'string', 'minLength': 1, 'maxLength': 64, 'pattern': r'^[A-Za-z-]+$'},
            'children': {
              'type': 'array',
              'items': {r'$ref': r'#/$defs/node'},
              'minItems': 1,
            },
          },
          'required': ['label'],
        },
      },
    },
  );
  final small = ToolSpec(
    name: 'small',
    description: 'Four parameters.',
    parameters: {
      'type': 'object',
      'properties': {
        for (final key in ['a', 'b', 'c', 'd']) key: {'type': 'boolean'},
      },
      'required': ['a'],
    },
  );
  return {
    'every value, free order (above exactOrderLimit)': format.grammar([edge, small]),
    'the subset automaton': format.grammar([small], const GrammarOptions(order: ParameterOrder.anyOrderOnce)),
    'one line strings and permutations, three calls': format.grammar([
      small,
    ], const GrammarOptions(strings: StringValues.singleLine, order: ParameterOrder.permutations, maxCalls: 3)),
    'a structured response': jsonSchemaGrammar(edge.parameters),
  };
}
