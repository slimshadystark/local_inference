// Readers of test/fixtures: the two Qwen3.5 templates, the toy tools and the reference cases.
import 'dart:convert';
import 'dart:io';

import 'package:local_inference/local_inference.dart';

String fixture(String name) => File('test/fixtures/$name').readAsStringSync();

/// The Qwen3.5-2B template (sha256 ea210e5b…), as the project's 2B GGUFs embed it.
final String template2b = fixture('chat_template.jinja');

/// The Qwen3.5-4B template (sha256 8452ca85…); it differs from the 2B one only in the thinking default.
final String template4b = fixture('chat_template_4b.jinja');

/// The toy tools' declarations, as test/fixtures/toy_tools.json lists them.
final List<Map<String, Object?>> toyDeclarations = [
  for (final entry in jsonDecode(fixture('toy_tools.json')) as List) (entry as Map).cast<String, Object?>(),
];

/// The toy tools as specs whose derived declaration is the file's entry.
final List<ToolSpec> toyTools = [
  for (final declaration in toyDeclarations)
    ToolSpec(
      name: (declaration['function'] as Map)['name'] as String,
      description: (declaration['function'] as Map)['description'] as String,
      parameters: ((declaration['function'] as Map)['parameters'] as Map).cast<String, Object?>(),
    ),
];

/// The toy tool named [name].
ToolSpec toyTool(String name) => toyTools.firstWhere((tool) => tool.name == name);

/// A message of test/fixtures/reference/cases.json as a [ChatMessage].
ChatMessage messageFromJson(Map<String, Object?> json) {
  final content = json['content'] as String;
  return switch (json['role']) {
    'system' => ChatMessage.system(content),
    'user' => ChatMessage.user(content),
    'assistant' => ChatMessage.assistant(
      content,
      toolCalls: [
        for (final call in (json['tool_calls'] as List?) ?? const [])
          ToolCall.fromJson(((call as Map)['function'] as Map).cast<String, Object?>()),
      ],
      reasoning: json['reasoning_content'] as String?,
    ),
    'tool' => ChatMessage.tool(content, name: json['name'] as String?),
    final role => throw FormatException('unknown role $role'),
  };
}

/// One case of test/fixtures/reference/cases.json.
final class ReferenceCase {
  ReferenceCase(Map<String, Object?> json)
    : name = json['name'] as String,
      toolNames = [for (final name in json['tools'] as List) name as String],
      variables = (json['variables'] as Map).cast<String, Object?>(),
      addGenerationPrompt = json['add_generation_prompt'] as bool,
      messageJson = [for (final m in json['messages'] as List) (m as Map).cast<String, Object?>()];

  final String name;
  final List<String> toolNames;
  final Map<String, Object?> variables;
  final bool addGenerationPrompt;
  final List<Map<String, Object?>> messageJson;

  List<ChatMessage> get messages => [for (final json in messageJson) messageFromJson(json)];

  List<ToolSpec> get tools => [for (final name in toolNames) toyTool(name)];

  /// The jinja2 rendering of this case with the template tagged [tag] (`2b`, `4b`).
  String reference(String tag) => fixture('reference/$name.$tag.txt');
}

final Map<String, Object?> _cases = (jsonDecode(fixture('reference/cases.json')) as Map).cast<String, Object?>();

/// The reference cases.
final List<ReferenceCase> referenceCases = [
  for (final json in _cases['cases'] as List) ReferenceCase((json as Map).cast<String, Object?>()),
];

/// Template tag (`2b`, `4b`) -> template source, as cases.json names them.
final Map<String, String> referenceTemplates = {
  for (final entry in (_cases['templates'] as Map).entries) entry.key as String: fixture(entry.value as String),
};

/// The first difference of [actual] and [expected]: offset and 60 characters of each, or null when equal.
String? firstDifference(String actual, String expected) {
  if (actual == expected) return null;
  var k = 0;
  while (k < actual.length && k < expected.length && actual.codeUnitAt(k) == expected.codeUnitAt(k)) {
    k++;
  }
  String window(String s) => jsonEncode(s.substring(k, (k + 60).clamp(0, s.length)));
  return 'differs at offset $k: ${window(actual)} vs expected ${window(expected)}';
}
