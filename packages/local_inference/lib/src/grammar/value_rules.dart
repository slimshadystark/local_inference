/// The built-in rules of parameter values in the XML envelope (integers, strings, patterns, dates, unions, JSON).
/// Internal.
library;

import '../model/python_json.dart';
import '../model/validator.dart' show resolveLocalRef;
import 'gbnf_rules.dart';
import 'grammar_options.dart';
import 'integer_range.dart';
import 'json_rules.dart';
import 'regex_subset.dart';

/// The rule of free-text strings, written after the rules of the tools whether used or not.
String stringModeRule(StringValues strings) => switch (strings) {
  StringValues.singleLine => r'text-line ::= [^<>\n]+',
  StringValues.multiLine => r'xml-text ::= ([^<] | "<"+ [^</])+ "<"*',
};

/// The name of [stringModeRule].
String stringModeName(StringValues strings) => switch (strings) {
  StringValues.singleLine => 'text-line',
  StringValues.multiLine => 'xml-text',
};

/// Values written between `<parameter=NAME>\n` and `\n</parameter>`: strings raw, everything else as its JSON text.
final class XmlValueRules {
  XmlValueRules(this.rules, this.options, this.json);

  final GbnfRules rules;
  final GrammarOptions options;

  /// The JSON rules of object and array values; its root is the tool's parameter schema.
  final JsonRuleBuilder json;

  /// The term of a parameter's value in a `param-…` rule: a shared rule referenced as is (the string-mode rule for a
  /// plain string, as today), or [name] (`param-<tool>-<key>-value`) defined with the value's body.
  String value(Map<String, Object?> schema, String name) {
    for (final rule in options.valueRules) {
      final body = rule.build(schema, rules, ValueContext.xmlParameter);
      if (body != null) return rules.define(name, body);
    }
    final built = _body(schema, name);
    return built.reference ? built.text : rules.define(name, built.text);
  }

  /// The body of [schema]'s values, or ([reference]) the name of a rule that already describes them. [refs] are the
  /// `$ref`s followed to reach [schema].
  ({String text, bool reference}) _body(Map<String, Object?> schema, String name, [Set<String> refs = const {}]) {
    final ref = schema[r'$ref'];
    if (ref is String) {
      final target = resolveLocalRef(json.root, ref);
      if (target == null) throw ArgumentError.value(ref, r'$ref', 'does not resolve in the schema');
      // Objects, arrays and $ref loops go through the JSON rules, where a $ref is a named rule (it may recurse).
      if (_isJsonShaped(target) || refs.contains(ref)) {
        return (text: json.term(schema, name, inXml: true), reference: true);
      }
      return _body(target, name, {...refs, ref});
    }
    final union = schema['anyOf'] ?? schema['oneOf'];
    if (union is List && union.isNotEmpty) {
      return (
        text: [for (var i = 0; i < union.length; i++) _member(_schemaOf(union[i]), '$name-${i + 1}', refs)].join(' | '),
        reference: false,
      );
    }
    if (schema.containsKey('const')) return (text: rules.literal(_xmlText(schema['const'])), reference: false);
    final values = schema['enum'];
    if (values is List && values.isNotEmpty) {
      return (text: [for (final value in values) rules.literal(_xmlText(value))].join(' | '), reference: false);
    }
    final type = schema['type'];
    if (type is List && type.isNotEmpty) {
      return (
        text: [
          for (var i = 0; i < type.length; i++) _member({...schema, 'type': type[i]}, '$name-${i + 1}', refs),
        ].join(' | '),
        reference: false,
      );
    }
    switch (type) {
      case 'integer':
        final bounds = integerBounds(schema);
        final range = bounds == null ? null : integerRangeBody(bounds.$1, bounds.$2);
        return (text: range ?? '"-"? [0-9]+', reference: false);
      case 'number':
        return (text: '"-"? [0-9]+ ("." [0-9]+)?', reference: false);
      case 'boolean':
        return (text: '"true" | "false"', reference: false);
      case 'null':
        return (text: '"null"', reference: false);
      case 'string':
        return _string(schema, name);
      case 'object' || 'array':
        return (text: json.term(schema, name, inXml: true), reference: true);
    }
    if (_isJsonShaped(schema)) return (text: json.term(schema, name, inXml: true), reference: true);
    return (text: stringModeName(options.strings), reference: true);
  }

  /// One branch of a union: a custom rule's body, or the built-in one. [refs] are the `$ref`s followed to reach the
  /// union: a branch that leads back to one of them goes through the JSON rules, which refuse the loop.
  String _member(Map<String, Object?> schema, String name, Set<String> refs) {
    for (final rule in options.valueRules) {
      final body = rule.build(schema, rules, ValueContext.xmlParameter);
      if (body != null) return body;
    }
    return _body(schema, name, refs).text;
  }

  ({String text, bool reference}) _string(Map<String, Object?> schema, String name) {
    final pattern = schema['pattern'];
    if (pattern is String) {
      final body = regexBody(
        pattern,
        xml: true,
        maxRepetition: options.maxRepetition,
        defineGroup: (body) => rules.define('$name-group', body),
      );
      if (body != null) return (text: body, reference: false);
    }
    return switch (schema['format']) {
      'date' => (text: json.useShared('iso-date'), reference: true),
      'date-time' => (text: json.useShared('iso-date-time'), reference: true),
      _ => (text: stringModeName(options.strings), reference: true),
    };
  }
}

bool _isJsonShaped(Map<String, Object?> schema) =>
    schema['type'] == 'object' || schema['type'] == 'array' || schema['properties'] is Map || schema['items'] is Map;

/// The text a value has inside `<parameter>`: a string as is, anything else as JSON (Python's style, as the
/// template's `tojson` writes it).
String _xmlText(Object? value) => value is String ? value : pythonJson(value);

Map<String, Object?> _schemaOf(Object? node) => node is Map ? node.cast<String, Object?>() : const {};
