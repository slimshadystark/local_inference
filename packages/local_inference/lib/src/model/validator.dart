/// Checks tool arguments against the tool's JSON Schema.
library;

import 'json_values.dart';
import 'python_json.dart';

/// The problems of [arguments] against the object schema [schema], in English; an empty list means valid.
///
/// Supports `type` (a name or a list of names), `enum`, `const`, `minimum`/`maximum` and `exclusiveMinimum`/
/// `exclusiveMaximum` (numbers, or the draft-4 booleans), `minLength`/`maxLength` (in code points), `pattern`
/// (searched, as JSON Schema does), `format` `date` and `date-time`, `anyOf`, `oneOf`, `allOf`, `required`,
/// `properties`, `additionalProperties`, `items`, `minItems`/`maxItems`, and local `$ref`s (`#`, `#/$defs/…`, any
/// JSON pointer into [schema]). Other keywords are ignored. A problem starts with the path of the value
/// (`when.date`, `tags[1]`) when it is not the arguments object itself. Throws [ArgumentError] for a `$ref` that
/// does not resolve.
List<String> validateArguments(Map<String, Object?> schema, Map<String, Object?> arguments) {
  final problems = <String>[];
  _Validator(schema).check(schema, arguments, '', problems, 0);
  return problems;
}

/// A local `$ref` of [root] resolved: `#` or a JSON pointer (`#/$defs/Name`). Null when it does not resolve.
Map<String, Object?>? resolveLocalRef(Map<String, Object?> root, String ref) {
  if (!ref.startsWith('#')) return null;
  Object? node = root;
  final pointer = Uri.decodeComponent(ref.substring(1));
  if (pointer.isNotEmpty) {
    if (!pointer.startsWith('/')) return null;
    for (final raw in pointer.substring(1).split('/')) {
      final token = raw.replaceAll('~1', '/').replaceAll('~0', '~');
      node = switch (node) {
        final Map<Object?, Object?> map => map[token],
        final List<Object?> list => switch (int.tryParse(token)) {
          final int i when i >= 0 && i < list.length => list[i],
          _ => null,
        },
        _ => null,
      };
    }
  }
  return node is Map ? node.cast<String, Object?>() : null;
}

final class _Validator {
  _Validator(this.root);

  final Map<String, Object?> root;

  /// Schemas applied to the same value in a row (`$ref`s and combinators); above this the schema loops on itself.
  static const int _maxRefChain = 64;

  void check(Map<String, Object?> schema, Object? value, String path, List<String> problems, int refChain) {
    final ref = schema[r'$ref'];
    if (ref is String) {
      if (refChain >= _maxRefChain) throw ArgumentError.value(ref, r'$ref', 'loops without reaching a value');
      final target = resolveLocalRef(root, ref);
      if (target == null) throw ArgumentError.value(ref, r'$ref', 'does not resolve in the schema');
      check(target, value, path, problems, refChain + 1);
    }

    final type = schema['type'];
    if (type != null) {
      final types = type is List ? [for (final t in type) '$t'] : ['$type'];
      if (!types.any((t) => _isType(value, t))) {
        problems.add(_at(path, 'expected ${types.map(_typeName).join(' or ')}, got ${_kindOf(value)}'));
        return;
      }
    }

    final allowed = schema['enum'];
    if (allowed is List && !allowed.any((v) => jsonEquals(v, value))) {
      problems.add(_at(path, '${pythonJson(value)} is not one of ${allowed.map(pythonJson).join(', ')}'));
    }
    if (schema.containsKey('const') && !jsonEquals(schema['const'], value)) {
      problems.add(_at(path, 'must be ${pythonJson(schema['const'])}'));
    }

    if (value is num) _checkNumber(schema, value, path, problems);
    if (value is String) _checkString(schema, value, path, problems);
    if (value is Map) _checkObject(schema, value.cast<String, Object?>(), path, problems);
    if (value is List) _checkArray(schema, value, path, problems);

    // The combinators check the same value: they count as links of a $ref chain.
    final anyOf = schema['anyOf'];
    if (anyOf is List && !anyOf.any((option) => _passes(option, value, path, refChain + 1))) {
      problems.add(_at(path, 'matches none of the allowed forms'));
    }
    final oneOf = schema['oneOf'];
    if (oneOf is List) {
      final passing = oneOf.where((option) => _passes(option, value, path, refChain + 1)).length;
      if (passing == 0) problems.add(_at(path, 'matches none of the allowed forms'));
      if (passing > 1) problems.add(_at(path, 'matches more than one of the allowed forms'));
    }
    final allOf = schema['allOf'];
    if (allOf is List) {
      for (final part in allOf) {
        if (part is Map) check(part.cast<String, Object?>(), value, path, problems, refChain + 1);
      }
    }
  }

  bool _passes(Object? option, Object? value, String path, int refChain) {
    if (option is! Map) return true;
    final problems = <String>[];
    check(option.cast<String, Object?>(), value, path, problems, refChain);
    return problems.isEmpty;
  }

  void _checkNumber(Map<String, Object?> schema, num value, String path, List<String> problems) {
    final minimum = schema['minimum'];
    final maximum = schema['maximum'];
    final exclusiveMinimum = schema['exclusiveMinimum'];
    final exclusiveMaximum = schema['exclusiveMaximum'];
    if (minimum is num) {
      if (exclusiveMinimum == true ? value <= minimum : value < minimum) {
        problems.add(
          _at(
            path,
            exclusiveMinimum == true ? '$value must be above $minimum' : '$value is below the minimum $minimum',
          ),
        );
      }
    }
    if (maximum is num) {
      if (exclusiveMaximum == true ? value >= maximum : value > maximum) {
        problems.add(
          _at(
            path,
            exclusiveMaximum == true ? '$value must be below $maximum' : '$value is above the maximum $maximum',
          ),
        );
      }
    }
    if (exclusiveMinimum is num && value <= exclusiveMinimum) {
      problems.add(_at(path, '$value must be above $exclusiveMinimum'));
    }
    if (exclusiveMaximum is num && value >= exclusiveMaximum) {
      problems.add(_at(path, '$value must be below $exclusiveMaximum'));
    }
  }

  void _checkString(Map<String, Object?> schema, String value, String path, List<String> problems) {
    final length = value.runes.length;
    final minLength = schema['minLength'];
    final maxLength = schema['maxLength'];
    if (minLength is int && length < minLength) {
      problems.add(_at(path, 'is shorter than $minLength characters'));
    }
    if (maxLength is int && length > maxLength) {
      problems.add(_at(path, 'is longer than $maxLength characters'));
    }
    final pattern = schema['pattern'];
    if (pattern is String) {
      final RegExp regex;
      try {
        regex = RegExp(pattern, unicode: true);
      } on FormatException {
        throw ArgumentError.value(pattern, 'pattern', 'is not a valid regular expression');
      }
      if (!regex.hasMatch(value)) problems.add(_at(path, '${pythonJson(value)} does not match the pattern $pattern'));
    }
    switch (schema['format']) {
      case 'date' when !isIsoDate(value):
        problems.add(_at(path, '${pythonJson(value)} is not a date (YYYY-MM-DD)'));
      case 'date-time' when !isIsoDateTime(value):
        problems.add(_at(path, '${pythonJson(value)} is not a date and time (YYYY-MM-DDThh:mm:ss, RFC 3339)'));
    }
  }

  void _checkObject(Map<String, Object?> schema, Map<String, Object?> value, String path, List<String> problems) {
    final what = path.isEmpty ? 'argument' : 'property';
    final required = schema['required'];
    if (required is List) {
      for (final name in required) {
        if (!value.containsKey(name)) problems.add(_at(path, "missing required $what '$name'"));
      }
    }
    final properties = schema['properties'] is Map ? (schema['properties'] as Map).cast<String, Object?>() : null;
    final additional = schema['additionalProperties'];
    for (final entry in value.entries) {
      final property = properties?[entry.key];
      final childPath = path.isEmpty ? entry.key : '$path.${entry.key}';
      if (property is Map) {
        check(property.cast<String, Object?>(), entry.value, childPath, problems, 0);
      } else if (additional == false) {
        problems.add(_at(path, "unknown $what '${entry.key}'"));
      } else if (additional is Map) {
        check(additional.cast<String, Object?>(), entry.value, childPath, problems, 0);
      }
    }
  }

  void _checkArray(Map<String, Object?> schema, List<Object?> value, String path, List<String> problems) {
    final minItems = schema['minItems'];
    final maxItems = schema['maxItems'];
    if (minItems is int && value.length < minItems) problems.add(_at(path, 'has fewer than $minItems items'));
    if (maxItems is int && value.length > maxItems) problems.add(_at(path, 'has more than $maxItems items'));
    final items = schema['items'];
    for (var i = 0; i < value.length; i++) {
      final itemSchema = switch (items) {
        final Map<Object?, Object?> map => map,
        final List<Object?> tuple when i < tuple.length && tuple[i] is Map => tuple[i] as Map,
        _ => null,
      };
      if (itemSchema != null) check(itemSchema.cast<String, Object?>(), value[i], '$path[$i]', problems, 0);
    }
  }
}

String _at(String path, String problem) => path.isEmpty ? problem : '$path: $problem';

bool _isType(Object? value, String type) => switch (type) {
  'string' => value is String,
  'integer' => value is int || (value is double && value.isFinite && value == value.truncateToDouble()),
  'number' => value is num,
  'boolean' => value is bool,
  'object' => value is Map,
  'array' => value is List,
  'null' => value == null,
  _ => true,
};

String _typeName(String type) => switch (type) {
  'integer' || 'array' || 'object' => 'an $type',
  'null' => 'null',
  _ => 'a $type',
};

String _kindOf(Object? value) => switch (value) {
  null => 'null',
  bool() => 'a boolean',
  int() => 'an integer',
  double() => 'a number',
  String() => 'a string',
  List() => 'an array',
  Map() => 'an object',
  _ => 'a ${value.runtimeType}',
};

final RegExp _isoDate = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$');
final RegExp _isoDateTime = RegExp(
  r'^(\d{4}-\d{2}-\d{2})[Tt]([01]\d|2[0-3]):[0-5]\d:[0-5]\d(\.\d+)?([Zz]|[+-]([01]\d|2[0-3]):[0-5]\d)$',
);

/// Whether [text] is a calendar date written `YYYY-MM-DD`.
bool isIsoDate(String text) {
  final match = _isoDate.firstMatch(text);
  if (match == null) return false;
  final year = int.parse(match.group(1)!);
  final month = int.parse(match.group(2)!);
  final day = int.parse(match.group(3)!);
  if (month < 1 || month > 12 || day < 1) return false;
  return day <= DateTime.utc(year, month + 1, 0).day;
}

/// Whether [text] is an RFC 3339 date-time (`2026-09-04T10:30:00Z`, `…+02:00`, optional fractions of a second).
bool isIsoDateTime(String text) {
  final match = _isoDateTime.firstMatch(text);
  return match != null && isIsoDate(match.group(1)!);
}
