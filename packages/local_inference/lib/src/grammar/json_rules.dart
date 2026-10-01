/// JSON values as GBNF, in Python's `json.dumps` style (`", "` and `": "`), for object and array parameters and for
/// structured responses.
library;

import '../model/python_json.dart';
import '../model/validator.dart' show resolveLocalRef;
import 'gbnf_rules.dart';
import 'grammar_options.dart';
import 'integer_range.dart';
import 'regex_subset.dart';

/// The eager grammar of the JSON value [schema] describes (a structured response): `root ::= …`, then the rules it
/// needs. Properties come in declaration order, the required ones first, as `json.dumps` writes a dict built in that
/// order; local `$ref`s become named rules. [GrammarOptions.valueRules] are asked first for every value (in the
/// [ValueContext.json] context); the parameter options do not apply.
String jsonSchemaGrammar(Map<String, Object?> schema, [GrammarOptions options = const GrammarOptions()]) {
  checkMaxRepetition(options.maxRepetition);
  final rules = GbnfRules()..reserveNames([...builtInSharedRuleNames, ...sharedRuleNames(options.valueRules)]);
  final body = JsonRuleBuilder(rules, options, schema).body(schema, 'root', inXml: false);
  return [
    'root ::= ${body.text}',
    ...rules.lines,
    ...valueRuleSharedLines(options.valueRules),
    ...rules.sharedLines,
  ].join('\n');
}

/// The names of the built-in helper rules; no other rule may take them.
const List<String> builtInSharedRuleNames = [
  'text-line', 'xml-text', //
  'json-value', 'json-object', 'json-array', 'json-string', 'json-char', 'json-escape', 'json-number', 'json-integer',
  'json-boolean', 'xjson-value', 'xjson-object', 'xjson-array', 'xjson-string', 'xjson-char', //
  'iso-date', 'iso-time', 'iso-date-time',
];

/// The rule names the shared lines of [valueRules] define.
List<String> sharedRuleNames(List<ValueRule> valueRules) => [
  for (final line in valueRuleSharedLines(valueRules)) line.split('::=').first.trim(),
];

/// The shared lines of [valueRules] in registration order, each once.
List<String> valueRuleSharedLines(List<ValueRule> valueRules) =>
    {for (final rule in valueRules) ...rule.sharedRules}.toList();

/// A rule body, and whether it is a single term that can be used inside a sequence or repeated as is.
typedef RuleBody = ({String text, bool atomic});

/// Builds the rules of JSON values into [rules]. `$ref`s resolve against [root].
final class JsonRuleBuilder {
  JsonRuleBuilder(this.rules, this.options, this.root);

  final GbnfRules rules;
  final GrammarOptions options;
  final Map<String, Object?> root;
  final Map<String, String> _defs = {};

  /// The `$ref`s whose rule is being built with no character written since it started: a `$ref` back to one of
  /// them would loop without a value (left recursion, which llama.cpp refuses).
  final Set<String> _open = {};

  /// A single term for the value [schema] describes: a shared rule, a literal, or a rule defined as [name].
  String term(Map<String, Object?> schema, String name, {required bool inXml}) {
    final built = body(schema, name, inXml: inXml);
    return built.atomic ? built.text : rules.define(name, built.text);
  }

  /// The body of the value [schema] describes; helper rules are named after [name].
  RuleBody body(Map<String, Object?> schema, String name, {required bool inXml}) {
    for (final rule in options.valueRules) {
      final custom = rule.build(schema, rules, ValueContext.json);
      if (custom != null) return (text: custom, atomic: false);
    }
    final ref = schema[r'$ref'];
    if (ref is String) return (text: _def(ref, inXml: inXml), atomic: true);
    final union = schema['anyOf'] ?? schema['oneOf'];
    if (union is List && union.isNotEmpty) {
      return _union([for (final option in union) _schemaOf(option)], name, inXml: inXml);
    }
    if (schema.containsKey('const')) return (text: rules.literal(pythonJson(schema['const'])), atomic: true);
    final values = schema['enum'];
    if (values is List && values.isNotEmpty) {
      return _alternatives([for (final value in values) rules.literal(pythonJson(value))]);
    }
    final type = schema['type'];
    if (type is List && type.isNotEmpty) {
      return _union(
        [
          for (final t in type) {...schema, 'type': t},
        ],
        name,
        inXml: inXml,
      );
    }
    switch (type) {
      case 'string':
        return _string(schema, name, inXml: inXml);
      case 'integer':
        final range = integerBounds(schema);
        final body = range == null ? null : integerRangeBody(range.$1, range.$2);
        return body == null ? (text: useShared('json-integer'), atomic: true) : _alternativesText(body);
      case 'number':
        return (text: useShared('json-number'), atomic: true);
      case 'boolean':
        return (text: useShared('json-boolean'), atomic: true);
      case 'null':
        return (text: '"null"', atomic: true);
      case 'object':
        return _afterCharacter(() => _object(schema, name, inXml: inXml));
      case 'array':
        return _afterCharacter(() => _array(schema, name, inXml: inXml));
    }
    if (schema['properties'] is Map) return _afterCharacter(() => _object(schema, name, inXml: inXml));
    if (schema['items'] is Map) return _afterCharacter(() => _array(schema, name, inXml: inXml));
    return (text: useShared(inXml ? 'xjson-value' : 'json-value'), atomic: true);
  }

  /// [build]'s body, with no `$ref` open: an object's or an array's content comes after its `{` or `[`.
  RuleBody _afterCharacter(RuleBody Function() build) {
    final open = {..._open};
    _open.clear();
    try {
      return build();
    } finally {
      _open
        ..clear()
        ..addAll(open);
    }
  }

  RuleBody _union(List<Map<String, Object?>> options, String name, {required bool inXml}) =>
      _alternatives([for (var i = 0; i < options.length; i++) term(options[i], '$name-${i + 1}', inXml: inXml)]);

  RuleBody _string(Map<String, Object?> schema, String name, {required bool inXml}) {
    final pattern = schema['pattern'];
    if (pattern is String) {
      final content = regexBody(
        pattern,
        xml: inXml,
        json: true,
        maxRepetition: options.maxRepetition,
        defineGroup: (body) => rules.define('$name-group', body),
      );
      if (content != null) return (text: '"\\"" ${_group(content)} "\\""', atomic: false);
    }
    switch (schema['format']) {
      case 'date':
        return (text: '"\\"" ${useShared('iso-date')} "\\""', atomic: false);
      case 'date-time':
        return (text: '"\\"" ${useShared('iso-date-time')} "\\""', atomic: false);
    }
    if (inXml) return (text: useShared('xjson-string'), atomic: true);
    final minLength = schema['minLength'];
    final maxLength = schema['maxLength'];
    if (minLength is int || maxLength is int) {
      final min = minLength is int && minLength > 0 ? minLength : 0;
      final max = maxLength is int ? maxLength : null;
      if (max == null || max >= min) {
        final chars = repetition(useShared('json-char'), min, max, options.maxRepetition);
        return (text: '"\\"" $chars "\\""', atomic: false);
      }
    }
    return (text: useShared('json-string'), atomic: true);
  }

  RuleBody _array(Map<String, Object?> schema, String name, {required bool inXml}) {
    final items = schema['items'];
    if (items is! Map) return (text: useShared(inXml ? 'xjson-array' : 'json-array'), atomic: true);
    final minItems = schema['minItems'];
    final maxItems = schema['maxItems'];
    final min = minItems is int && minItems > 0 ? minItems : 0;
    final max = maxItems is int ? maxItems : null;
    if (max != null && (max <= 0 || max < min)) return (text: '"[" "]"', atomic: false);
    final item = term(items.cast<String, Object?>(), '$name-item', inXml: inXml);
    // item (", " item){min-1,max-1}, optional as a whole when min is 0 (llama.cpp's _build_repetition).
    final more = max == 1
        ? ''
        : ' ${repetition('(", " $item)', min > 0 ? min - 1 : 0, max == null ? null : max - 1, options.maxRepetition)}';
    return (text: min == 0 ? '"[" ($item$more)? "]"' : '"[" $item$more "]"', atomic: false);
  }

  RuleBody _object(Map<String, Object?> schema, String name, {required bool inXml}) {
    final properties = schema['properties'];
    final additional = schema['additionalProperties'];
    final hasAdditional = additional == true || additional is Map;
    if (properties is! Map && !hasAdditional) {
      return (text: useShared(inXml ? 'xjson-object' : 'json-object'), atomic: true);
    }
    final required = {for (final r in (schema['required'] as List?) ?? const []) '$r'};
    final kv = <String, String>{};
    final names = <String>[];
    if (properties is Map) {
      for (final entry in properties.entries) {
        final key = '${entry.key}';
        final valueTerm = term(_schemaOf(entry.value), '$name-${GbnfRules.ruleId(key)}', inXml: inXml);
        kv[key] = rules.define(
          '$name-${GbnfRules.ruleId(key)}-kv',
          '${rules.literal('${pythonJson(key)}: ')} $valueTerm',
        );
        names.add(key);
      }
    }
    final requiredNames = [
      for (final key in names)
        if (required.contains(key)) key,
    ];
    final optionalNames = [
      for (final key in names)
        if (!required.contains(key)) key,
    ];
    // '*' stands for any further property, last, as in llama.cpp's json-schema-to-grammar.
    const extra = '*';
    if (hasAdditional) {
      final valueTerm = additional is Map
          ? term(additional.cast<String, Object?>(), '$name-additional', inXml: inXml)
          : useShared(inXml ? 'xjson-value' : 'json-value');
      final keyTerm = useShared(inXml ? 'xjson-string' : 'json-string');
      kv[extra] = rules.define('$name-additional-kv', '$keyTerm ": " $valueTerm');
      optionalNames.add(extra);
    }

    String recursiveRefs(List<String> keys, {required bool firstIsOptional}) {
      final key = keys.first;
      final kvName = kv[key]!;
      final commaRef = '(", " $kvName)';
      var result = firstIsOptional
          ? '$commaRef${key == extra ? '*' : '?'}'
          : key == extra
          ? '$kvName $commaRef*'
          : kvName;
      if (keys.length > 1) {
        final restId = key == extra ? 'additional' : GbnfRules.ruleId(key);
        result += ' ${rules.define('$name-$restId-rest', recursiveRefs(keys.sublist(1), firstIsOptional: true))}';
      }
      return result;
    }

    final text = StringBuffer('"{"');
    if (requiredNames.isNotEmpty) text.write(' ${[for (final key in requiredNames) kv[key]].join(' ", " ')}');
    if (optionalNames.isNotEmpty) {
      final tails = [
        for (var i = 0; i < optionalNames.length; i++) recursiveRefs(optionalNames.sublist(i), firstIsOptional: false),
      ].join(' | ');
      text.write(requiredNames.isNotEmpty ? ' (", " ($tails))?' : ' ($tails)?');
    }
    text.write(' "}"');
    return (text: text.toString(), atomic: false);
  }

  /// The rule of the local `$ref` [ref], defined once per context; it may refer to itself inside an object or an
  /// array. Throws [ArgumentError] when it refers back to itself before any character (`a` → `b` → `a`, or a union
  /// with a branch `a` in `a`): that loops without a value, and the validator refuses it too.
  String _def(String ref, {required bool inXml}) {
    final key = '${inXml ? 'x' : ''}$ref';
    final known = _defs[key];
    if (known != null) {
      if (_open.contains(key)) {
        throw ArgumentError.value(ref, r'$ref', 'refers back to itself before any character: it loops without a value');
      }
      return known;
    }
    final target = resolveLocalRef(root, ref);
    if (target == null) throw ArgumentError.value(ref, r'$ref', 'does not resolve in the schema');
    final last = ref.split('/').last;
    final name = rules.reserve('${inXml ? 'xdef' : 'def'}-${GbnfRules.ruleId(last.isEmpty ? 'root' : last)}');
    _defs[key] = name;
    _open.add(key);
    try {
      rules.fill(name, body(target, name, inXml: inXml).text);
    } finally {
      _open.remove(key);
    }
    return name;
  }

  /// The built-in helper [name], defined (with the helpers it uses) the first time.
  String useShared(String name) {
    if (rules.hasShared(name)) return name;
    final body = _sharedBodies[name] ?? (throw ArgumentError.value(name, 'name', 'is not a built-in rule'));
    rules.shared(name, body);
    for (final dependency in _sharedDependencies[name] ?? const <String>[]) {
      useShared(dependency);
    }
    return name;
  }
}

/// The inclusive integer bounds of an integer [schema] (`minimum`/`maximum`, `exclusiveMinimum`/`exclusiveMaximum`
/// as numbers or draft-4 booleans), or null when either is missing.
(int, int)? integerBounds(Map<String, Object?> schema) {
  int? low;
  int? high;
  final minimum = schema['minimum'];
  final maximum = schema['maximum'];
  final exclusiveMinimum = schema['exclusiveMinimum'];
  final exclusiveMaximum = schema['exclusiveMaximum'];
  // Beyond 10^18 the digit rules stop anyway (integerRangeBody), and double.ceil() could overflow an int.
  bool usable(Object? bound) => bound is num && bound.isFinite && bound.abs() < 1e18;
  if (usable(minimum)) {
    low = exclusiveMinimum == true ? (minimum as num).floor() + 1 : (minimum as num).ceil();
  }
  if (usable(exclusiveMinimum)) {
    final bound = (exclusiveMinimum as num).floor() + 1;
    low = low == null || bound > low ? bound : low;
  }
  if (usable(maximum)) {
    high = exclusiveMaximum == true ? (maximum as num).ceil() - 1 : (maximum as num).floor();
  }
  if (usable(exclusiveMaximum)) {
    final bound = (exclusiveMaximum as num).ceil() - 1;
    high = high == null || bound < high ? bound : high;
  }
  return low == null || high == null ? null : (low, high);
}

Map<String, Object?> _schemaOf(Object? node) => node is Map ? node.cast<String, Object?>() : const {};

RuleBody _alternatives(List<String> terms) =>
    terms.length == 1 ? (text: terms.single, atomic: true) : (text: terms.join(' | '), atomic: false);

RuleBody _alternativesText(String body) => (text: body, atomic: false);

String _group(String body) => body.contains(' ') ? '($body)' : body;

const Map<String, String> _sharedBodies = {
  'json-value': 'json-object | json-array | json-string | json-number | json-boolean | "null"',
  'json-object': r'"{" (json-string ": " json-value (", " json-string ": " json-value)*)? "}"',
  'json-array': r'"[" (json-value (", " json-value)*)? "]"',
  'json-string': r'"\"" json-char* "\""',
  'json-char': r'[^"\\\x00-\x1F] | json-escape',
  'json-escape': r'"\\" (["\\/bfnrt] | "u" [0-9a-fA-F]{4})',
  // Numbers as JSON writes them (no leading zeros), any length: pythonJson writes large doubles in full.
  'json-number': r'"-"? ("0" | [1-9] [0-9]*) ("." [0-9]+)? ([eE] ("-" | "+")? [0-9]+)?',
  'json-integer': r'"-"? ("0" | [1-9] [0-9]*)',
  'json-boolean': '"true" | "false"',
  'xjson-value': 'xjson-object | xjson-array | xjson-string | json-number | json-boolean | "null"',
  'xjson-object': r'"{" (xjson-string ": " xjson-value (", " xjson-string ": " xjson-value)*)? "}"',
  'xjson-array': r'"[" (xjson-value (", " xjson-value)*)? "]"',
  // No `</` inside a value written in a <parameter>: a `<` run is followed by anything but `/`, or ends the string.
  'xjson-string': r'"\"" xjson-char* "<"* "\""',
  'xjson-char': r'[^"\\<\x00-\x1F] | json-escape | "<"+ ([^"\\</\x00-\x1F] | json-escape)',
  'iso-date': r'[0-9]{4} "-" ("0" [1-9] | "1" [0-2]) "-" ("0" [1-9] | [12] [0-9] | "3" [01])',
  'iso-time': r'([01] [0-9] | "2" [0-3]) ":" [0-5] [0-9] ":" [0-5] [0-9] ("." [0-9]+)?',
  'iso-date-time': r'iso-date "T" iso-time ("Z" | ("+" | "-") ([01] [0-9] | "2" [0-3]) ":" [0-5] [0-9])',
};

const Map<String, List<String>> _sharedDependencies = {
  'json-value': ['json-object', 'json-array', 'json-string', 'json-number', 'json-boolean'],
  'json-object': ['json-string', 'json-value'],
  'json-array': ['json-value'],
  'json-string': ['json-char'],
  'json-char': ['json-escape'],
  'xjson-value': ['xjson-object', 'xjson-array', 'xjson-string', 'json-number', 'json-boolean'],
  'xjson-object': ['xjson-string', 'xjson-value'],
  'xjson-array': ['xjson-value'],
  'xjson-string': ['xjson-char'],
  'xjson-char': ['json-escape'],
  'iso-date-time': ['iso-date', 'iso-time'],
};
