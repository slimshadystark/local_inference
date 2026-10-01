/// The tool-call grammar of the Qwen3-Coder XML envelope. Internal: QwenXmlToolFormat exposes it.
library;

import 'dart:math' as math;

import '../model/tool_spec.dart';
import 'gbnf_rules.dart';
import 'grammar_options.dart';
import 'json_rules.dart';
import 'parameter_sets.dart';
import 'regex_subset.dart';
import 'value_rules.dart';

/// A GBNF grammar that admits tool calls to [tools] in the XML envelope:
/// `<tool_call>\n<function=NAME>\n<parameter=KEY>\nVALUE\n</parameter>\n…</function>\n</tool_call>`.
///
/// Emission order (part of the contract): `root` first; then per tool, in order, for each property its value rule
/// (when it has one) and its `param-<tool>-<key>` rule, then the tool's parameter-set rules and its `call-<tool>`
/// rule; last the shared rules: those of [GrammarOptions.valueRules] in registration order, the string-mode rule,
/// then the built-in helpers the values used. Above [GrammarOptions.maxRules] rules or
/// [GrammarOptions.maxTextLength] characters, the tools with the most parameters fall back to
/// [ParameterOrder.free], until the grammar fits or every tool is free.
String xmlToolCallGrammar(List<ToolSpec> tools, GrammarOptions options) {
  if (tools.isEmpty) throw ArgumentError.value(tools, 'tools', 'a tool-call grammar needs at least one tool');
  final seen = <String>{};
  for (final tool in tools) {
    if (!seen.add(tool.name)) throw ArgumentError.value(tool.name, 'tools', 'two tools have this name');
  }
  if (options.maxCalls < 1) throw ArgumentError.value(options.maxCalls, 'maxCalls', 'must be at least 1');
  checkMaxRepetition(options.maxRepetition);
  final counts = [for (final tool in tools) _properties(tool).length];
  final orders = [
    for (var i = 0; i < tools.length; i++) _affordable(resolveOrder(options, counts[i]), tools[i], options),
  ];
  while (true) {
    final (:text, :ruleCount) = _build(tools, options, orders);
    if (ruleCount <= options.maxRules && text.length <= GrammarOptions.maxTextLength) return text;
    final open = [
      for (var i = 0; i < tools.length; i++)
        if (orders[i] != ParameterOrder.free) i,
    ];
    if (open.isEmpty) return text;
    final most = open.map((i) => counts[i]).reduce(math.max);
    for (final i in open) {
      if (counts[i] == most) orders[i] = ParameterOrder.free;
    }
  }
}

/// [order], or [ParameterOrder.free] when [order] alone would already exceed the size limits for [tool] (n!
/// alternatives, 2^n automaton rules): the check runs before the rules are written.
ParameterOrder _affordable(ParameterOrder order, ToolSpec tool, GrammarOptions options) {
  final keys = _properties(tool).keys.toList();
  final n = keys.length;
  switch (order) {
    case ParameterOrder.permutations when n > 8:
      return ParameterOrder.free;
    case ParameterOrder.permutations:
      var alternatives = 1;
      for (var i = 2; i <= n; i++) {
        alternatives *= i;
      }
      final id = GbnfRules.ruleId(tool.name);
      final perAlternative = keys.fold(0, (sum, key) => sum + 'param-$id-${GbnfRules.ruleId(key)}? '.length) + 3;
      return alternatives * perAlternative > GrammarOptions.maxTextLength ? ParameterOrder.free : order;
    case ParameterOrder.anyOrderOnce when n > 20 || (1 << n) > options.maxRules:
      return ParameterOrder.free;
    default:
      return order;
  }
}

({String text, int ruleCount}) _build(List<ToolSpec> tools, GrammarOptions options, List<ParameterOrder> orders) {
  final rules = GbnfRules()..reserveNames([...builtInSharedRuleNames, ...sharedRuleNames(options.valueRules)]);
  final calls = <String>[];
  for (var t = 0; t < tools.length; t++) {
    final tool = tools[t];
    final id = GbnfRules.ruleId(tool.name);
    final json = JsonRuleBuilder(rules, options, tool.parameters);
    final values = XmlValueRules(rules, options, json);
    final required = {for (final name in (tool.parameters['required'] as List?) ?? const []) '$name'};
    final params = <String>[];
    final isRequired = <bool>[];
    for (final MapEntry(:key, :value) in _properties(tool).entries) {
      final name = 'param-$id-${GbnfRules.ruleId(key)}';
      final schema = value is Map ? value.cast<String, Object?>() : const <String, Object?>{};
      final valueTerm = values.value(schema, '$name-value');
      params.add(
        rules.define(name, '${rules.literal('<parameter=$key>\n')} $valueTerm ${rules.literal('\n</parameter>\n')}'),
      );
      isRequired.add(required.contains(key));
    }
    final sets = parameterSets(params, isRequired, orders[t], rules, id);
    calls.add(
      rules.define(
        'call-$id',
        '${rules.literal('<function=${tool.name}>\n')} ($sets) ${rules.literal('</function>\n')}',
      ),
    );
  }
  final call = '${rules.literal('<tool_call>\n')} (${calls.join(' | ')}) ${rules.literal('</tool_call>')}';
  final more = options.maxCalls - 1;
  final head = more == 0
      ? ['root ::= $call']
      : [
          'root ::= tc ${more > options.maxRepetition ? '(${rules.literal('\n')} tc)*' : '(${rules.literal('\n')} tc){0,$more}'}',
          'tc ::= $call',
        ];
  final lines = <String>{
    ...head,
    ...rules.lines,
    ...valueRuleSharedLines(options.valueRules),
    stringModeRule(options.strings),
    ...rules.sharedLines,
  }.toList();
  return (text: lines.join('\n'), ruleCount: lines.length);
}

Map<String, Object?> _properties(ToolSpec tool) {
  final properties = tool.parameters['properties'];
  return properties is Map ? properties.cast<String, Object?>() : const {};
}
