/// The parameter part of a call rule in each [ParameterOrder]. Internal.
library;

import 'gbnf_rules.dart';
import 'grammar_options.dart';

/// The order [options] gives a tool with [count] parameters: [ParameterOrder.auto] resolved by the count.
ParameterOrder resolveOrder(GrammarOptions options, int count) => switch (options.order) {
  ParameterOrder.auto when count <= 3 => ParameterOrder.permutations,
  ParameterOrder.auto when count <= options.exactOrderLimit => ParameterOrder.anyOrderOnce,
  ParameterOrder.auto => ParameterOrder.free,
  final order => order,
};

/// The text between the parentheses of `call-<id> ::= "<function=…>\n" ( … ) "</function>\n"` for the parameter
/// rules [params] (declaration order), [required] marking the required ones. [ParameterOrder.anyOrderOnce] defines
/// its `args-<id>-<mask>` rules in [rules]. No parameters give `""`.
String parameterSets(List<String> params, List<bool> required, ParameterOrder order, GbnfRules rules, String toolId) {
  if (params.isEmpty) return '""';
  String term(int i) => required[i] ? params[i] : '${params[i]}?';
  switch (order) {
    case ParameterOrder.permutations:
      // Every ordering, deduplicated in first-seen order, so the grammar text is stable.
      final alternatives = <String>{
        for (final ordering in permutations([for (var i = 0; i < params.length; i++) i])) ordering.map(term).join(' '),
      };
      return alternatives.join(' | ');
    case ParameterOrder.anyOrderOnce:
      return _subsetAutomaton(params, required, rules, toolId);
    case ParameterOrder.declared:
      return [for (var i = 0; i < params.length; i++) term(i)].join(' ');
    case ParameterOrder.free:
      return '(${params.join(' | ')})*';
    case ParameterOrder.auto:
      throw ArgumentError.value(order, 'order', 'resolve auto first (resolveOrder)');
  }
}

/// `args-<id>-<mask> ::= p_i args-<id>-<mask ∪ i> | … ( | "" once every required parameter is in the mask)`, one
/// rule per set of parameters written so far, from the empty set; returns the first rule's name. Any order, each
/// parameter at most once, the required ones present: the language of the permutations.
String _subsetAutomaton(List<String> params, List<bool> required, GbnfRules rules, String toolId) {
  final n = params.length;
  var requiredMask = 0;
  for (var i = 0; i < n; i++) {
    if (required[i]) requiredMask |= 1 << i;
  }
  // Every set is reachable from the empty one; fewer parameters first, then by mask.
  final masks = [for (var mask = 0; mask < 1 << n; mask++) mask]
    ..sort((a, b) {
      final bySize = _bits(a).compareTo(_bits(b));
      return bySize != 0 ? bySize : a.compareTo(b);
    });
  final names = {for (final mask in masks) mask: rules.reserve('args-$toolId-$mask')};
  for (final mask in masks) {
    rules.fill(
      names[mask]!,
      [
        for (var i = 0; i < n; i++)
          if (mask & (1 << i) == 0) '${params[i]} ${names[mask | 1 << i]}',
        if (mask & requiredMask == requiredMask) '""',
      ].join(' | '),
    );
  }
  return names[0]!;
}

int _bits(int mask) {
  var count = 0;
  for (var m = mask; m != 0; m &= m - 1) {
    count++;
  }
  return count;
}

/// Every ordering of [items]: each item in turn first, then every ordering of the others.
List<List<T>> permutations<T>(List<T> items) {
  if (items.isEmpty) return const [];
  if (items.length == 1) return [items];
  final out = <List<T>>[];
  for (var i = 0; i < items.length; i++) {
    final rest = [...items]..removeAt(i);
    for (final p in permutations(rest)) {
      out.add([items[i], ...p]);
    }
  }
  return out;
}
