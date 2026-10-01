/// Rendering messages with a model's own chat template.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:dinja/dinja.dart';

import 'chat_message.dart';
import 'python_json.dart';

/// A chat template: messages and tool declarations in, the model's prompt text out.
abstract interface class ChatTemplate {
  /// The template text.
  String get source;

  /// SHA-256 (hex) of [source]'s UTF-8 bytes.
  String get sha256;

  /// The prompt for [messages], with the tool block of [tools] (declarations as the model reads them) and a
  /// generation prompt when [addGenerationPrompt]; [variables] are further template variables
  /// (`enable_thinking`, …).
  String render(
    List<ChatMessage> messages, {
    List<Map<String, Object?>> tools = const [],
    bool addGenerationPrompt = true,
    Map<String, Object?> variables = const {},
  });
}

/// A Jinja chat template rendered with dinja (the Jinja engine llamadart uses), so that the prompt equals Hugging
/// Face's `apply_chat_template`, the renderer fine-tunes are trained with.
///
/// The context is `messages` (each [ChatMessage.toJson]), `tools` (only when there are tools), `add_generation_prompt`,
/// then [render]'s `variables`, then the [globals] given here (a model's `bos_token`, …); nothing is defaulted. dinja's
/// `tojson` writes compact JSON with non-ASCII escaped, Hugging Face's writes Python's `json.dumps(…,
/// ensure_ascii=False)`: after rendering, the first occurrence of each tool's dinja `tojson` text is replaced by
/// [pythonJson] of the tool (when the two differ), so the tool block is byte-identical. Only tool declarations are
/// swapped: a mapping or list argument of an assistant tool call in the history keeps dinja's text.
final class JinjaChatTemplate implements ChatTemplate {
  JinjaChatTemplate(this.source, {Map<String, Object?> globals = const {}})
    : _template = Template(source),
      globals = Map.unmodifiable(globals),
      sha256 = crypto.sha256.convert(utf8.encode(source)).toString();

  @override
  final String source;

  @override
  final String sha256;

  /// Variables added to every render, after the render's own.
  final Map<String, Object?> globals;

  final Template _template;

  static final Template _toolJson = Template('{{ t | tojson }}');

  @override
  String render(
    List<ChatMessage> messages, {
    List<Map<String, Object?>> tools = const [],
    bool addGenerationPrompt = true,
    Map<String, Object?> variables = const {},
  }) {
    var out = _template.render({
      'messages': [for (final message in messages) message.toJson()],
      if (tools.isNotEmpty) 'tools': tools,
      'add_generation_prompt': addGenerationPrompt,
      ...variables,
      ...globals,
    });
    for (final tool in tools) {
      final compact = _toolJson.render({'t': tool});
      final python = pythonJson(tool);
      if (compact != python && out.contains(compact)) out = out.replaceFirst(compact, python);
    }
    return out;
  }

  @override
  String toString() => 'JinjaChatTemplate(${sha256.substring(0, 8)}, ${source.length} chars)';
}
