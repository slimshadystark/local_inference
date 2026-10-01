/// The messages of a chat, as a chat template reads them.
library;

import 'package:meta/meta.dart';

import 'tool_call.dart';

/// Who wrote a [ChatMessage].
enum MessageRole { system, user, assistant, tool }

/// One message of a chat. Value equality.
@immutable
final class ChatMessage {
  /// The instructions of the conversation.
  const ChatMessage.system(this.content)
    : role = MessageRole.system,
      toolCalls = const [],
      reasoning = null,
      name = null;

  /// What the user wrote.
  const ChatMessage.user(this.content) : role = MessageRole.user, toolCalls = const [], reasoning = null, name = null;

  /// What the model answered: its text, the tools it called and its reasoning.
  const ChatMessage.assistant(this.content, {this.toolCalls = const [], this.reasoning})
    : role = MessageRole.assistant,
      name = null;

  /// The result of a tool call; [name] is the tool's.
  const ChatMessage.tool(this.content, {this.name}) : role = MessageRole.tool, toolCalls = const [], reasoning = null;

  /// Who wrote it.
  final MessageRole role;

  /// The text.
  final String content;

  /// The tools an assistant message called, in order.
  final List<ToolCall> toolCalls;

  /// The reasoning of an assistant message; null when there is none.
  final String? reasoning;

  /// The tool a tool message answers for; null when not given.
  final String? name;

  /// The message as a chat template reads it: `{'role': …, 'content': …}` in that key order, then only the keys
  /// that are set: `tool_calls` (`[{'type': 'function', 'function': {'name': …, 'arguments': {…}}}]`),
  /// `reasoning_content` and `name`. Unset keys stay out, so a prompt without them renders as before they existed.
  Map<String, Object?> toJson() => {
    'role': role.name,
    'content': content,
    if (toolCalls.isNotEmpty)
      'tool_calls': [
        for (final call in toolCalls)
          {
            'type': 'function',
            'function': {'name': call.name, 'arguments': call.arguments},
          },
      ],
    if (reasoning != null) 'reasoning_content': reasoning,
    if (name != null) 'name': name,
  };

  @override
  bool operator ==(Object other) =>
      other is ChatMessage &&
      other.role == role &&
      other.content == content &&
      other.reasoning == reasoning &&
      other.name == name &&
      _listEquals(other.toolCalls, toolCalls);

  @override
  int get hashCode => Object.hash(role, content, reasoning, name, Object.hashAll(toolCalls));

  @override
  String toString() {
    final calls = toolCalls.isEmpty ? '' : ', calls: ${toolCalls.join(', ')}';
    return 'ChatMessage(${role.name}: ${content.length} chars$calls)';
  }
}

bool _listEquals<T>(List<T> a, List<T> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
