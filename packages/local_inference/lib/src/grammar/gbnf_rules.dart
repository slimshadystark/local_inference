/// The ordered rule table a grammar is written from.
library;

import 'package:meta/meta.dart';

/// The rules of one GBNF grammar, in the order they are defined, with unique names.
///
/// A [ValueRule] defines its helper rules here and escapes its literals with [literal].
final class GbnfRules {
  GbnfRules();

  final List<String> _order = [];
  final Map<String, String?> _bodies = {};
  final Set<String> _reserved = {'root', 'tc'};
  final List<String> _sharedOrder = [];
  final Map<String, String> _shared = {};

  static final RegExp _name = RegExp(r'^[A-Za-z0-9-]+$');
  static final RegExp _notNameChar = RegExp(r'[^A-Za-z0-9]');

  /// Adds `name ::= body` after the rules defined so far and returns the name it got: [name], or [name] with a
  /// numeric suffix (`-2`, `-3`, …) when another rule already has that name. A rule with the same name and body is
  /// not added twice: its name is returned. [name] is made of letters, digits and `-` ([ruleId] makes one).
  String define(String name, String body) {
    _checkName(name);
    if (_bodies.containsKey(name) && _bodies[name] == body) return name;
    var unique = name;
    for (var n = 2; _bodies.containsKey(unique) || _reserved.contains(unique); n++) {
      unique = '$name-$n';
      if (_bodies.containsKey(unique) && _bodies[unique] == body) return unique;
    }
    _bodies[unique] = body;
    _order.add(unique);
    return unique;
  }

  /// [value] as a GBNF string literal: `\`, `"` and newlines escaped.
  String literal(String value) => '"${value.replaceAll('\\', r'\\').replaceAll('"', r'\"').replaceAll('\n', r'\n')}"';

  /// [name] with every character other than an ASCII letter or digit replaced by `-`: a valid rule name.
  static String ruleId(String name) => name.replaceAll(_notNameChar, '-');

  /// Takes a name for a rule whose body is set later with [fill] (a rule that refers to itself); it keeps the
  /// position of this call.
  @internal
  String reserve(String name) {
    _checkName(name);
    var unique = name;
    for (var n = 2; _bodies.containsKey(unique) || _reserved.contains(unique); n++) {
      unique = '$name-$n';
    }
    _bodies[unique] = null;
    _order.add(unique);
    return unique;
  }

  /// Sets the body of a rule taken with [reserve].
  @internal
  void fill(String name, String body) {
    if (!_bodies.containsKey(name) || _bodies[name] != null) throw StateError('$name was not reserved');
    _bodies[name] = body;
  }

  /// Keeps [names] out of [define] and [reserve]: they belong to rules written elsewhere (shared rules).
  @internal
  void reserveNames(Iterable<String> names) => _reserved.addAll(names);

  /// A built-in helper rule shared by every value that uses it, written after all other rules; its [name] must have
  /// been reserved with [reserveNames]. Returns [name].
  @internal
  String shared(String name, String body) {
    final existing = _shared[name];
    if (existing == null) {
      if (!_reserved.contains(name)) throw StateError('$name is not a reserved shared rule');
      _shared[name] = body;
      _sharedOrder.add(name);
    } else if (existing != body) {
      throw StateError('shared rule $name defined twice with different bodies');
    }
    return name;
  }

  /// Whether the shared rule [name] is defined.
  @internal
  bool hasShared(String name) => _shared.containsKey(name);

  /// The rules of [define] and [reserve], as `name ::= body` lines, in order.
  @internal
  List<String> get lines => [
    for (final name in _order) '$name ::= ${_bodies[name] ?? (throw StateError('$name was reserved but not filled'))}',
  ];

  /// The rules of [shared], as lines, in the order they were first used.
  @internal
  List<String> get sharedLines => [for (final name in _sharedOrder) '$name ::= ${_shared[name]}'];

  /// Rules defined so far, shared ones included.
  @internal
  int get length => _order.length + _sharedOrder.length;

  void _checkName(String name) {
    if (!_name.hasMatch(name)) throw ArgumentError.value(name, 'name', 'is not a GBNF rule name ([A-Za-z0-9-]+)');
  }
}
