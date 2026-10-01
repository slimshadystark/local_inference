/// A read-only view of an assistant's model.
library;

import 'package:meta/meta.dart';

import '../engine/engine_info.dart';
import '../model/chat_message.dart';
import '../model/chat_model.dart';
import '../model/model_profile.dart';
import '../model/tool_spec.dart';

/// The assistant's model, for reading: it renders prompts but cannot generate or be disposed (either would break the
/// assistant's prefix state).
abstract interface class ModelView {
  /// The loaded model.
  EngineInfo get info;

  /// Its family.
  ModelProfile get profile;

  /// The prompt of [messages] with [tools] in its tool block (`ChatModel.render`).
  String render(List<ChatMessage> messages, {List<ToolSpec> tools = const [], bool addGenerationPrompt = true});

  /// The part of every prompt with this system prompt and these tools that the prefix state holds
  /// (`ChatModel.stablePrefix`).
  String? stablePrefix({required String systemPrompt, List<ToolSpec> tools = const []});
}

/// A [ChatModel] seen through [ModelView]. Internal.
@internal
final class ChatModelView implements ModelView {
  const ChatModelView(this._model);

  final ChatModel _model;

  @override
  EngineInfo get info => _model.info;

  @override
  ModelProfile get profile => _model.profile;

  @override
  String render(List<ChatMessage> messages, {List<ToolSpec> tools = const [], bool addGenerationPrompt = true}) =>
      _model.render(messages, tools: tools, addGenerationPrompt: addGenerationPrompt);

  @override
  String? stablePrefix({required String systemPrompt, List<ToolSpec> tools = const []}) =>
      _model.stablePrefix(systemPrompt: systemPrompt, tools: tools);
}
