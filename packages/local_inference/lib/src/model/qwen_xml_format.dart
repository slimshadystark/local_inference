/// The tool-call envelope of Qwen3.5 (Qwen3-Coder's XML).
library;

import 'dart:convert';

import '../engine/options.dart';
import '../grammar/grammar_options.dart';
import '../grammar/xml_call_grammar.dart';
import 'python_json.dart';
import 'tool_call.dart';
import 'tool_call_format.dart';
import 'tool_spec.dart';
import 'validator.dart' show resolveLocalRef;

/// The Qwen3-Coder XML envelope that Qwen3.5's chat template describes:
/// `<tool_call>\n<function=NAME>\n<parameter=KEY>\nVALUE\n</parameter>\n</function>\n</tool_call>`.
final class QwenXmlToolFormat implements ToolCallFormat {
  const QwenXmlToolFormat();

  static final RegExp _thinkBlock = RegExp(r'<think>(.*?)</think>', dotAll: true);
  static final RegExp _toolCallBlock = RegExp(r'<tool_call>\s*(.*?)\s*</tool_call>', dotAll: true);
  static final RegExp _functionBlock = RegExp(r'<function=([A-Za-z0-9_\-.]+)>(.*?)</function>', dotAll: true);
  static final RegExp _parameterBlock = RegExp(r'<parameter=([A-Za-z0-9_\-.]+)>\n?(.*?)\n?</parameter>', dotAll: true);

  static const String _toolCallTag = '<tool_call>';

  /// `<tool_call>`: plain answers stay free, a call is held to the grammar from its first tag.
  @override
  List<GrammarTrigger> get triggers => const [GrammarTrigger.word(_toolCallTag)];

  /// The envelope's tags, kept whole during constrained decoding (the list of llamadart's Qwen3-Coder handler).
  @override
  List<String> get preservedTokens => const [
    '<think>',
    '</think>',
    '<tool_call>',
    '</tool_call>',
    '<function=',
    '</function>',
    '<parameter=',
    '</parameter>',
  ];

  /// See [xmlToolCallGrammar]: `root ::= "<tool_call>\n" (call-… | …) "</tool_call>"` with [options].
  @override
  String grammar(List<ToolSpec> tools, [GrammarOptions options = const GrammarOptions()]) =>
      xmlToolCallGrammar(tools, options);

  /// Splits [raw] into its first think block (the reasoning, null when empty), its tool calls and the remaining text
  /// (trimmed). A `<tool_call>` without a `<function=…>` block is left out
  /// and named in [ParsedOutput.error] (the last one); a parameter written twice keeps its last value and is listed
  /// in [ParsedOutput.repeatedParameters].
  ///
  /// Each value is trimmed and typed from its schema in [tools], local `$ref`s followed. A schema that allows only
  /// strings (a string, a string enum, a union of strings such as a period name or a date) keeps the text. Otherwise
  /// the first type the schema allows that reads the text wins, in the order integer, number, boolean, null, then JSON
  /// (for objects, arrays or a schema with no type; when a string is allowed too, only a JSON object or array),
  /// and the text stays when none does. A lone `integer`, `number` or `boolean` thus parses as that type, and a
  /// tool or parameter missing from [tools] is decoded as JSON, falling back to the text: pass every tool the model
  /// may call, not only those of the prompt.
  @override
  ParsedOutput parse(String raw, List<ToolSpec> tools) {
    var text = raw;
    String? reasoning;
    final think = _thinkBlock.firstMatch(text);
    if (think != null) {
      final r = think.group(1)!.trim();
      reasoning = r.isEmpty ? null : r;
      text = text.replaceFirst(_thinkBlock, '');
    }
    final calls = <ToolCall>[];
    final repeated = <String>[];
    String? error;
    for (final block in _toolCallBlock.allMatches(text)) {
      final inner = block.group(1)!;
      final function = _functionBlock.firstMatch(inner);
      if (function == null) {
        error = 'tool_call without a <function=...> block: ${inner.trim()}';
        continue;
      }
      final name = function.group(1)!;
      final args = <String, Object?>{};
      for (final p in _parameterBlock.allMatches(function.group(2)!)) {
        final key = p.group(1)!;
        if (args.containsKey(key)) repeated.add('$name.$key');
        args[key] = _coerce(_argumentTypes(tools, name, key), p.group(2)!);
      }
      calls.add(ToolCall(name, args));
    }
    text = text.replaceAll(_toolCallBlock, '').trim();
    return ParsedOutput(text: text, toolCalls: calls, reasoning: reasoning, error: error, repeatedParameters: repeated);
  }

  /// The plain text of a partial answer: `''` while it is empty or may still open a tool call, null while it
  /// starts with another tag, else the text before any `<tool_call>`, with a partial `<tool_call>` at its end held
  /// back and trailing whitespace trimmed.
  @override
  String? visibleText(String partialRaw) {
    final trimmed = partialRaw.trimLeft();
    if (trimmed.isEmpty) return '';
    if (trimmed.startsWith('<')) {
      return _toolCallTag.startsWith(trimmed) || trimmed.startsWith(_toolCallTag) ? '' : null;
    }
    final cut = trimmed.indexOf(_toolCallTag);
    var visible = cut >= 0 ? trimmed.substring(0, cut) : trimmed;
    // Hold back a partial "<tool_call>" at the end of the stream.
    final lt = visible.lastIndexOf('<');
    if (lt >= 0 && _toolCallTag.startsWith(visible.substring(lt))) visible = visible.substring(0, lt);
    return visible.trimRight();
  }

  /// `<tool_call>\n<function=NAME>\n`, then `<parameter=KEY>\nVALUE\n</parameter>\n` per argument, then
  /// `</function>\n</tool_call>`. A string value is written as is, any other as JSON in Python's style (the
  /// template's `tojson`, which the grammar's JSON rules follow).
  @override
  String render(ToolCall call) {
    final out = StringBuffer('<tool_call>\n<function=${call.name}>\n');
    for (final MapEntry(:key, :value) in call.arguments.entries) {
      out.write('<parameter=$key>\n${value is String ? value : pythonJson(value)}\n</parameter>\n');
    }
    out.write('</function>\n</tool_call>');
    return out.toString();
  }

  /// The JSON types [tool]'s [argument] may take ([_types]); `any` when [tools] do not describe it.
  static Set<String> _argumentTypes(List<ToolSpec> tools, String tool, String argument) {
    for (final spec in tools) {
      if (spec.name != tool) continue;
      final properties = spec.parameters['properties'];
      return _types(properties is Map ? properties[argument] : null, spec.parameters, const {});
    }
    return const {'any'};
  }

  /// The JSON types [schema] allows: the union of its `anyOf`/`oneOf` branches, the types of its `const` or `enum`
  /// values, its `type` (a name or a list), or those of the local `$ref` it names (resolved in [root]); `any` when
  /// it says nothing, names an unknown type, or its `$ref` does not resolve or loops.
  static Set<String> _types(Object? schema, Map<String, Object?> root, Set<String> refs) {
    if (schema is! Map) return const {'any'};
    final ref = schema[r'$ref'];
    if (ref is String) {
      final target = refs.contains(ref) ? null : resolveLocalRef(root, ref);
      return target == null ? const {'any'} : _types(target, root, {...refs, ref});
    }
    final union = schema['anyOf'] ?? schema['oneOf'];
    if (union is List && union.isNotEmpty) return {for (final branch in union) ..._types(branch, root, refs)};
    if (schema.containsKey('const')) return {_typeOf(schema['const'])};
    final values = schema['enum'];
    if (values is List && values.isNotEmpty) return {for (final value in values) _typeOf(value)};
    final type = schema['type'];
    if (type is List && type.isNotEmpty) return {for (final name in type) _typeNamed(name)};
    return {_typeNamed(type)};
  }

  static String _typeNamed(Object? name) => switch (name) {
    'string' || 'integer' || 'number' || 'boolean' || 'null' || 'object' || 'array' => name as String,
    _ => 'any',
  };

  static String _typeOf(Object? value) => switch (value) {
    null => 'null',
    bool() => 'boolean',
    int() => 'integer',
    num() => 'number',
    String() => 'string',
    List() => 'array',
    Map() => 'object',
    _ => 'any',
  };

  /// [rawValue], trimmed, as the first of [types] that reads it (see [parse]); else the text.
  static Object? _coerce(Set<String> types, String rawValue) {
    final value = rawValue.trim();
    if (types.contains('integer')) {
      final integer = int.tryParse(value);
      if (integer != null) return integer;
    }
    if (types.contains('number')) {
      final number = num.tryParse(value);
      if (number != null) return number;
    }
    if (types.contains('boolean') && (value == 'true' || value == 'false')) return value == 'true';
    if (types.contains('null') && value == 'null') return null;
    final any = types.contains('any');
    if (any || types.contains('object') || types.contains('array')) {
      try {
        final decoded = jsonDecode(value);
        if (any ||
            !types.contains('string') ||
            (decoded is Map && types.contains('object')) ||
            (decoded is List && types.contains('array'))) {
          return decoded;
        }
      } on FormatException {
        // Not JSON: the text.
      }
    }
    return value;
  }

  @override
  String toString() => 'QwenXmlToolFormat()';
}
