/// A tool call a model wrote.
library;

import 'dart:convert';

import 'package:meta/meta.dart';

import 'json_values.dart';

/// One call: the tool's name and its arguments, typed from the tool's schema by the parser. Value equality, deep on
/// [arguments].
@immutable
final class ToolCall {
  const ToolCall(this.name, [this.arguments = const {}]);

  /// `{'tool': name, 'args': {...}}`, the compact form of a call (what [toJson] writes); also
  /// `{'name': name, 'arguments': {...}}`, where the arguments may be a JSON string. Missing arguments are `{}`.
  /// Throws [FormatException] when there is no name or the arguments are not an object.
  factory ToolCall.fromJson(Map<String, Object?> json) {
    final name = json['tool'] ?? json['name'];
    if (name is! String || name.isEmpty) throw FormatException('a tool call needs a name', json);
    var arguments = json.containsKey('args') ? json['args'] : json['arguments'];
    if (arguments is String) {
      try {
        arguments = jsonDecode(arguments);
      } on FormatException {
        throw FormatException('the arguments of $name are not JSON', arguments);
      }
    }
    if (arguments == null) return ToolCall(name);
    if (arguments is! Map) throw FormatException('the arguments of $name are not an object', arguments);
    return ToolCall(name, {for (final entry in arguments.entries) entry.key.toString(): entry.value});
  }

  /// The tool's name.
  final String name;

  /// The arguments by name, in the order the model wrote them.
  final Map<String, Object?> arguments;

  /// `'$name ${jsonEncode(arguments)}'`: equal for two calls with the same arguments in the same order.
  String get key => '$name ${jsonEncode(arguments)}';

  /// The argument [k] when it is a string, else null.
  String? string(String k) => switch (arguments[k]) {
    final String value => value,
    _ => null,
  };

  /// The argument [k] when it is an integer, a whole double or a string holding an integer, else null.
  int? integer(String k) => switch (arguments[k]) {
    final int value => value,
    final double value when value.isFinite && value == value.truncateToDouble() => value.toInt(),
    final String value => int.tryParse(value.trim()),
    _ => null,
  };

  /// The argument [k] when it is a boolean or the string `true` or `false`, else null.
  bool? boolean(String k) => switch (arguments[k]) {
    final bool value => value,
    'true' => true,
    'false' => false,
    _ => null,
  };

  /// The argument [k] as [string] reads it; throws [ArgumentError] when it is missing or not a string.
  String requireString(String k) =>
      string(k) ?? (throw ArgumentError.value(arguments[k], k, 'the $name call needs a string argument "$k"'));

  /// `{'tool': name, 'args': arguments}`.
  Map<String, Object?> toJson() => {'tool': name, 'args': arguments};

  @override
  bool operator ==(Object other) => other is ToolCall && other.name == name && jsonEquals(other.arguments, arguments);

  @override
  int get hashCode => Object.hash(name, jsonHash(arguments));

  @override
  String toString() => '$name(${jsonEncode(arguments)})';
}
