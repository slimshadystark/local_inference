// The oracle: an earlier, simpler grammar builder, logic unchanged, taking OpenAI-style declarations. It assumes every
// anyOf is a period (a name, a month or a date range) and knows integers only within 0..9; the current builder must
// write the same text on that domain with the matching options (grammar_test.dart, _oldOptions).

/// Old `buildToolCallGrammar(declarations)`.
String oldToolCallGrammar(List<Map<String, dynamic>> declarations) {
  final rules = <String>[];
  final callNames = <String>[];
  for (final decl in declarations) {
    final function = decl['function'] as Map;
    final name = function['name'] as String;
    final params = function['parameters'] as Map;
    final properties = Map<String, dynamic>.from((params['properties'] as Map?) ?? {});
    final required = ((params['required'] as List?) ?? const []).cast<String>().toSet();
    final ruleName = 'call-${_ruleId(name)}';
    callNames.add(ruleName);

    final paramRules = <String, String>{};
    for (final entry in properties.entries) {
      final pr = 'param-${_ruleId(name)}-${_ruleId(entry.key)}';
      paramRules[entry.key] = pr;
      final valueRule = _valueRule(entry.value as Map<String, dynamic>, '$pr-value', rules);
      rules.add('$pr ::= "<parameter=${entry.key}>\\n" $valueRule "\\n</parameter>\\n"');
    }
    final orderings = _permutations(paramRules.keys.toList());
    final alternatives = orderings.isEmpty
        ? ['""']
        : [
            for (final order in orderings)
              order.map((k) => required.contains(k) ? paramRules[k]! : '${paramRules[k]!}?').join(' '),
          ];
    rules.add('$ruleName ::= "<function=$name>\\n" (${alternatives.toSet().join(' | ')}) "</function>\\n"');
  }
  final root = 'root ::= "<tool_call>\\n" (${callNames.join(' | ')}) "</tool_call>"';
  return [root, ...rules, ...(oldSharedRules)].join('\n');
}

/// The four shared rules, always appended.
const List<String> oldSharedRules = [
  r'period-month ::= [0-9] [0-9] [0-9] [0-9] "-" ("0" [1-9] | "1" [0-2])',
  r'period-day ::= period-month "-" ("0" [1-9] | [12] [0-9] | "3" [01])',
  r'period-range ::= period-day ".." period-day',
  r'text-line ::= [^<>\n]+',
];

String _valueRule(Map<String, dynamic> schema, String ruleName, List<String> rules) {
  if (schema.containsKey('anyOf')) {
    final alternatives = <String>[];
    for (final option in (schema['anyOf'] as List).cast<Map<dynamic, dynamic>>()) {
      if (option.containsKey('enum')) {
        alternatives.addAll((option['enum'] as List).map((v) => _literal(v.toString())));
      } else if (option['pattern'] == r'^[0-9]{4}-[0-9]{2}$') {
        alternatives.add('period-month');
      } else if ((option['pattern'] as String?)?.contains(r'\.\.') ?? false) {
        alternatives.add('period-range');
      } else {
        alternatives.add('text-line');
      }
    }
    rules.add('$ruleName ::= ${alternatives.join(' | ')}');
    return ruleName;
  }
  if (schema.containsKey('enum')) {
    rules.add('$ruleName ::= ${(schema['enum'] as List).map((v) => _literal(v.toString())).join(' | ')}');
    return ruleName;
  }
  switch (schema['type']) {
    case 'integer':
      final min = schema['minimum'] as int?;
      final max = schema['maximum'] as int?;
      if (min != null && max != null && min >= 0 && max <= 9) {
        rules.add('$ruleName ::= [$min-$max]');
      } else {
        rules.add('$ruleName ::= "-"? [0-9]+');
      }
      return ruleName;
    case 'number':
      rules.add('$ruleName ::= "-"? [0-9]+ ("." [0-9]+)?');
      return ruleName;
    case 'boolean':
      rules.add('$ruleName ::= "true" | "false"');
      return ruleName;
    default:
      return 'text-line';
  }
}

String _literal(String value) => '"${value.replaceAll('\\', r'\\').replaceAll('"', r'\"').replaceAll('\n', r'\n')}"';

String _ruleId(String name) => name.replaceAll(RegExp(r'[^A-Za-z0-9]'), '-');

List<List<String>> _permutations(List<String> items) {
  if (items.isEmpty) return const [];
  if (items.length == 1) return [items];
  final out = <List<String>>[];
  for (var i = 0; i < items.length; i++) {
    final rest = [...items]..removeAt(i);
    for (final p in _permutations(rest)) {
      out.add([items[i], ...p]);
    }
  }
  return out;
}
