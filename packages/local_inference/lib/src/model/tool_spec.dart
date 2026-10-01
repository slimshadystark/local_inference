/// A tool as the model sees it and as the grammar, the parser and the validator read it.
library;

import 'json_values.dart';

/// What running a tool does to the world.
enum SideEffect {
  /// It only reads.
  read,

  /// It changes something that can be undone (opens a screen, starts a form).
  recoverable,

  /// It changes something for good (books, cancels, pays).
  irreversible,
}

/// One tool.
///
/// [parameters] is the full JSON Schema of the arguments: the grammar, the typed parsing and the validation use it.
/// [promptDeclaration], when set, is the exact entry the model reads in the prompt's tool block (a fine-tune may have
/// learned a shorter form than the full schema).
final class ToolSpec {
  const ToolSpec({
    required this.name,
    required this.description,
    this.parameters = const {'type': 'object', 'properties': {}},
    this.sideEffect = SideEffect.read,
    this.promptDeclaration,
  });

  /// The name the model calls it by.
  final String name;

  /// What it does, for the model.
  final String description;

  /// The JSON Schema of the arguments (an object schema).
  final Map<String, Object?> parameters;

  /// What running it does; the assistant (L3) reads it, the model layer ignores it.
  final SideEffect sideEffect;

  /// The tool-block entry the model reads, verbatim; null derives it from the other fields.
  final Map<String, Object?>? promptDeclaration;

  /// The tool-block entry: [promptDeclaration] unchanged when set, else
  /// `{'type': 'function', 'function': {'name': …, 'description': …, 'parameters': …}}` in that key order, with the
  /// `x-*` extension keywords removed from every schema object at any depth (property names are kept).
  Map<String, Object?> get declaration =>
      promptDeclaration ??
      {
        'type': 'function',
        'function': {'name': name, 'description': description, 'parameters': _withoutExtensions(parameters)},
      };

  @override
  String toString() => 'ToolSpec($name, ${sideEffect.name})';
}

/// Keywords whose value maps names (not keywords) to schemas.
const Set<String> _schemaMaps = {'properties', 'patternProperties', r'$defs', 'definitions', 'dependentSchemas'};

/// Keywords whose value is data, never a schema.
const Set<String> _dataKeywords = {'enum', 'const', 'default', 'examples'};

/// A copy of [schema] without the `x-*` keywords of any schema object in it. The names under `properties`,
/// `$defs` and the like are names, not keywords, so they stay, as does data under `enum`, `const`, `default` and
/// `examples`.
Map<String, Object?> _withoutExtensions(Map<String, Object?> schema) => _stripSchema(schema) as Map<String, Object?>;

Object? _stripSchema(Object? node) {
  if (node is List) return [for (final item in node) _stripSchema(item)];
  if (node is! Map) return node;
  return <String, Object?>{
    for (final entry in node.entries)
      if (!entry.key.toString().startsWith('x-'))
        entry.key.toString(): switch (entry.key) {
          final String key when _schemaMaps.contains(key) && entry.value is Map => <String, Object?>{
            for (final named in (entry.value as Map).entries) named.key.toString(): _stripSchema(named.value),
          },
          final String key when _dataKeywords.contains(key) => jsonCopy(entry.value),
          _ => _stripSchema(entry.value),
        },
  };
}
