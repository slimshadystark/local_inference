/// Builders of the JSON Schema maps a [ToolSpec] takes.
library;

/// Plain JSON Schema maps for tool parameters, with a fixed key order, since the model reads the schema as text.
///
/// Key order: the key that says what the value is (`type`, or `anyOf`), then `description`, then the other keys in
/// the order of the builder's parameters. Keys whose parameter is null (or, for `required`, empty) are left out.
abstract final class ToolSchema {
  /// `{'type': 'object', 'description'?, 'properties': properties, 'required'?}`; [required] names properties.
  static Map<String, Object?> object(
    Map<String, Map<String, Object?>> properties, {
    List<String> required = const [],
    String? description,
  }) {
    final unknown = [
      for (final name in required)
        if (!properties.containsKey(name)) name,
    ];
    if (unknown.isNotEmpty) throw ArgumentError.value(required, 'required', 'names no property: $unknown');
    return {
      'type': 'object',
      'description': ?description,
      'properties': properties,
      if (required.isNotEmpty) 'required': required,
    };
  }

  /// `{'type': 'string', 'description'?, 'enum'?, 'minLength'?, 'maxLength'?, 'pattern'?, 'format'?}`.
  static Map<String, Object?> string({
    String? description,
    List<String>? enumValues,
    int? minLength,
    int? maxLength,
    String? pattern,
    String? format,
  }) => {
    'type': 'string',
    'description': ?description,
    'enum': ?enumValues,
    'minLength': ?minLength,
    'maxLength': ?maxLength,
    'pattern': ?pattern,
    'format': ?format,
  };

  /// `{'type': 'integer', 'description'?, 'minimum'?, 'maximum'?}`.
  static Map<String, Object?> integer({String? description, int? minimum, int? maximum}) => {
    'type': 'integer',
    'description': ?description,
    'minimum': ?minimum,
    'maximum': ?maximum,
  };

  /// `{'type': 'number', 'description'?, 'minimum'?, 'maximum'?}`.
  static Map<String, Object?> number({String? description, num? minimum, num? maximum}) => {
    'type': 'number',
    'description': ?description,
    'minimum': ?minimum,
    'maximum': ?maximum,
  };

  /// `{'type': 'boolean', 'description'?}`.
  static Map<String, Object?> boolean({String? description}) => {'type': 'boolean', 'description': ?description};

  /// `{'type': 'array', 'description'?, 'items': items, 'minItems'?, 'maxItems'?}`.
  static Map<String, Object?> array(Map<String, Object?> items, {String? description, int? minItems, int? maxItems}) =>
      {'type': 'array', 'description': ?description, 'items': items, 'minItems': ?minItems, 'maxItems': ?maxItems};

  /// `{'anyOf': options, 'description'?}`: a value that matches any of [options].
  static Map<String, Object?> anyOf(List<Map<String, Object?>> options, {String? description}) {
    if (options.isEmpty) throw ArgumentError.value(options, 'options', 'must not be empty');
    return {'anyOf': options, 'description': ?description};
  }

  /// `{'type': 'integer', 'description'?, 'minimum': 1, 'maximum': maxShown, 'x-item-of': collection}`, in that
  /// order: the number of an item of the last numbered list of [collection] the user was shown, 1 to [maxShown].
  ///
  /// The assistant's `ListReferences` reads the `x-item-of` marker as an item-number argument of that collection
  /// (next to its `itemArguments`) on a top-level property of the tool's parameters only; the model never sees it
  /// (`ToolSpec.declaration` drops `x-*` keywords). The range is in the grammar of `Qwen35Profile`; with
  /// `LlamadartFamilyProfile` (whose JSON-schema grammars have no integer ranges) only the validator checks it.
  static Map<String, Object?> itemNumber(String collection, {String? description, int maxShown = 8}) {
    if (collection.isEmpty) throw ArgumentError.value(collection, 'collection', 'must not be empty');
    if (maxShown < 1) throw ArgumentError.value(maxShown, 'maxShown', 'must be at least 1');
    return {'type': 'integer', 'description': ?description, 'minimum': 1, 'maximum': maxShown, 'x-item-of': collection};
  }
}
