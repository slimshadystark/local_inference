/// What an `Assistant` shows: its phase, the chat items and the open question. Immutable values: every change makes
/// a new [AssistantState] and a new [ChatItem] for each item it touches; the other items keep their identity.
library;

import 'package:meta/meta.dart';

import '../engine/engine_info.dart';
import '../engine/generation.dart';
import '../model/chat_message.dart';
import '../model/tool_call.dart';
import 'screen_requests.dart';

/// Where an assistant is.
enum AssistantPhase {
  /// No model is loaded.
  noModel,

  /// A model is loading, and its prefix state restoring.
  loading,

  /// The prefix state of this model, prompt and tool set is being built: the first time only (12-40 s on a phone).
  preparing,

  /// Ready for a message.
  ready,

  /// A turn runs.
  busy,

  /// The last load failed ([AssistantState.loadError]).
  failed,
}

/// Who wrote an assistant item's text.
enum ReplySource {
  /// The model (a plain answer, streamed text, the text of an interrupted answer).
  model,

  /// The app: a reply written from a tool result, a question, a fixed text of `AssistantStrings`.
  app,

  /// A guard replaced the model's answer.
  guard,

  /// The turn failed: the error text.
  error,
}

/// What a [ChatAction] does.
enum ChatActionKind {
  /// Answers yes to the open question.
  confirm,

  /// Answers no to the open question.
  decline,
}

/// A button under an assistant item (the open question's yes and no). Plain data with value equality:
/// `Assistant.act(action)` performs it.
@immutable
final class ChatAction {
  const ChatAction({required this.kind, required this.label, this.primary = false});

  /// What it does.
  final ChatActionKind kind;

  /// The button's text.
  final String label;

  /// Whether it is the main choice.
  final bool primary;

  @override
  bool operator ==(Object other) =>
      other is ChatAction && other.kind == kind && other.label == label && other.primary == primary;

  @override
  int get hashCode => Object.hash(kind, label, primary);

  @override
  String toString() => 'ChatAction(${kind.name}, $label${primary ? ', primary' : ''})';
}

/// One bubble of the chat. A change makes a new item with the same [id] and the next [revision].
@immutable
final class ChatItem {
  const ChatItem({
    required this.id,
    this.revision = 0,
    required this.role,
    this.text = '',
    this.thinking = false,
    this.status,
    this.actions = const [],
    this.guarded = false,
    this.source,
    this.screenRequest,
    this.details,
    this.stats,
  });

  /// Unique within one assistant.
  final int id;

  /// Counts the changes of this item: 0 when it was added.
  final int revision;

  /// [MessageRole.user] or [MessageRole.assistant].
  final MessageRole role;

  /// The text shown.
  final String text;

  /// Waiting for the first visible text, or for a tool.
  final bool thinking;

  /// The label of the tool that runs ("Looking up your orders…"), null otherwise.
  final String? status;

  /// The buttons under the item: the open question's yes and no, else none.
  final List<ChatAction> actions;

  /// A guard replaced the model's answer.
  final bool guarded;

  /// Who wrote the text of an assistant item; null for a user item.
  final ReplySource? source;

  /// The screen this reply asked the host to open, bound to the list item it names.
  final BoundScreenRequest? screenRequest;

  /// Debug text: the timing line and the raw output of each generation, then `[tool]`, `[validation]` and `[guard]`
  /// lines, or the error.
  final String? details;

  /// The figures of the last generation of this item.
  final GenerationStats? stats;

  @override
  String toString() => 'ChatItem($id.$revision ${role.name}: ${text.length} chars${thinking ? ', thinking' : ''})';
}

/// One exchange of the conversation as the prompt carries it: what the user wrote and what the assistant showed.
@immutable
final class HistoryEntry {
  const HistoryEntry(this.user, this.assistant);

  /// The user's text (`''` for the second half of a turn whose earlier replies went into their own entry).
  final String user;

  /// The assistant's text.
  final String assistant;

  @override
  bool operator ==(Object other) => other is HistoryEntry && other.user == user && other.assistant == assistant;

  @override
  int get hashCode => Object.hash(user, assistant);

  @override
  String toString() => 'HistoryEntry(${user.length} + ${assistant.length} chars)';
}

/// The open question: a call waiting for yes or no.
@immutable
final class ConfirmationRequest {
  const ConfirmationRequest({required this.itemId, required this.call, required this.question});

  /// The item that asks it.
  final int itemId;

  /// The call a yes runs (its arguments as the toolkit coerced them).
  final ToolCall call;

  /// The question's text.
  final String question;

  @override
  String toString() => 'ConfirmationRequest($itemId, $call)';
}

/// A snapshot of an assistant.
@immutable
final class AssistantState {
  const AssistantState({
    required this.phase,
    this.loadError,
    this.items = const [],
    this.pendingConfirmation,
    this.pendingActions = const [],
    required this.conversationId,
    this.modelPath,
    this.info,
    this.revision = 0,
  });

  /// Where the assistant is.
  final AssistantPhase phase;

  /// Why the last load failed ([AssistantPhase.failed]); null otherwise.
  final Object? loadError;

  /// The chat, oldest first.
  final List<ChatItem> items;

  /// The open question, if any.
  final ConfirmationRequest? pendingConfirmation;

  /// The open question's buttons, wherever its item sits in [items]: a screen may have added items after it.
  final List<ChatAction> pendingActions;

  /// The conversation's id (host-owned when given to `newConversation`).
  final String conversationId;

  /// The model file loaded or last loaded successfully; null before and after `unloadModel`.
  final String? modelPath;

  /// The loaded model; null when none is.
  final EngineInfo? info;

  /// Counts the changes of the state: every notification of the assistant's listeners makes a new one.
  final int revision;

  /// Whether a message can be sent now.
  bool get canSend => phase == AssistantPhase.ready;

  /// Whether a turn runs.
  bool get isBusy => phase == AssistantPhase.busy;

  /// Whether the chat has items.
  bool get hasConversation => items.isNotEmpty;

  /// The item with [id], null when the chat has none.
  ChatItem? item(int id) {
    for (var i = items.length - 1; i >= 0; i--) {
      if (items[i].id == id) return items[i];
    }
    return null;
  }

  @override
  String toString() => 'AssistantState(${phase.name}, ${items.length} items, revision $revision)';
}
