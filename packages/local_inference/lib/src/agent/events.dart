/// What happens in an assistant, as typed events, and the outcome of one call.
library;

import 'package:meta/meta.dart';

import '../model/prefix/prefix_cache.dart';
import '../model/tool_call.dart';
import 'screen_requests.dart';
import 'state.dart';
import 'tool_result.dart';

/// Why a call was not accepted.
enum TurnRejection {
  /// The text was empty (after trimming).
  empty,

  /// No model is ready (no model, loading, preparing, failed, or disposed).
  notReady,

  /// A turn runs.
  busy,

  /// `confirm` or `act` with no question open.
  noQuestion,
}

/// What one call of `send`, `confirm` or `act` did.
@immutable
final class TurnOutcome {
  const TurnOutcome({
    this.rejection,
    this.items = const [],
    this.confirmation,
    this.screenRequests = const [],
    this.error,
  });

  /// Why the call was not accepted; null when it was.
  final TurnRejection? rejection;

  /// The items the call added, as they ended.
  final List<ChatItem> items;

  /// The question the call ended with, if any.
  final ConfirmationRequest? confirmation;

  /// The screens the call asked the host to open.
  final List<BoundScreenRequest> screenRequests;

  /// Why the call failed (its reply is `AssistantStrings.error`); null otherwise.
  final Object? error;

  /// Whether the call was accepted.
  bool get accepted => rejection == null;

  /// The texts of the assistant items the call added, joined by a blank line.
  String get reply => [
    for (final item in items)
      if (item.role.name == 'assistant') item.text,
  ].join('\n\n');

  @override
  String toString() => accepted
      ? 'TurnOutcome(${items.length} items${confirmation == null ? '' : ', question'}${error == null ? '' : ', error'})'
      : 'TurnOutcome(rejected: ${rejection!.name})';
}

/// How the conversation changed.
enum ConversationChange {
  /// A call ended: its exchanges joined the history.
  exchange,

  /// A screen's action was recorded (`ToolHost.recordAction`).
  action,

  /// A new conversation started.
  cleared,

  /// A snapshot was restored.
  restored,
}

/// Something that happened in an assistant.
@immutable
sealed class AssistantEvent {
  const AssistantEvent();
}

/// The phase changed; [error] is the load error of [AssistantPhase.failed].
final class PhaseChangedEvent extends AssistantEvent {
  const PhaseChangedEvent(this.phase, {this.error});

  final AssistantPhase phase;
  final Object? error;

  @override
  String toString() => 'PhaseChangedEvent(${phase.name})';
}

/// The text of the assistant item [itemId] grew by [appended].
final class ReplyDeltaEvent extends AssistantEvent {
  const ReplyDeltaEvent(this.itemId, this.appended);

  final int itemId;
  final String appended;

  @override
  String toString() => 'ReplyDeltaEvent($itemId, ${appended.length} chars)';
}

/// The text of the assistant item [itemId] became [text], which does not extend what it was (a guard, an app-written
/// reply, the error text).
final class ReplyReplacedEvent extends AssistantEvent {
  const ReplyReplacedEvent(this.itemId, this.text);

  final int itemId;
  final String text;

  @override
  String toString() => 'ReplyReplacedEvent($itemId, ${text.length} chars)';
}

/// A tool call starts; [label] is the status shown, when one is.
final class ToolStartedEvent extends AssistantEvent {
  const ToolStartedEvent(this.call, this.source, {this.label});

  final ToolCall call;
  final ToolCallSource source;
  final String? label;

  @override
  String toString() => 'ToolStartedEvent(${source.name} ${call.name})';
}

/// A tool call ended after [elapsed]. [error] is what the tool threw (the outcome then holds a `tool_exception`
/// failure; with `ToolErrorPolicy.failTurn` the turn fails next).
final class ToolFinishedEvent extends AssistantEvent {
  const ToolFinishedEvent(this.outcome, this.elapsed, {this.error, this.stackTrace});

  final ToolOutcome outcome;
  final Duration elapsed;
  final Object? error;
  final StackTrace? stackTrace;

  @override
  String toString() => 'ToolFinishedEvent(${outcome.call.name}, ${outcome.result.ok ? 'ok' : 'failed'})';
}

/// A question was asked.
final class ConfirmationRequestedEvent extends AssistantEvent {
  const ConfirmationRequestedEvent(this.request);

  final ConfirmationRequest request;

  @override
  String toString() => 'ConfirmationRequestedEvent(${request.call.name})';
}

/// A reply asks the host to open a screen; [itemId] is the reply's item.
final class ScreenRequestedEvent extends AssistantEvent {
  const ScreenRequestedEvent(this.request, {required this.itemId});

  final BoundScreenRequest request;
  final int itemId;

  @override
  String toString() => 'ScreenRequestedEvent(${request.request.label})';
}

/// A call of `send`, `confirm` or `act` ended; the last event of every accepted call.
final class TurnFinishedEvent extends AssistantEvent {
  const TurnFinishedEvent(this.outcome);

  final TurnOutcome outcome;

  @override
  String toString() => 'TurnFinishedEvent($outcome)';
}

/// A call failed with [error]; a [TurnFinishedEvent] follows.
final class TurnFailedEvent extends AssistantEvent {
  const TurnFailedEvent(this.error, this.stackTrace);

  final Object error;
  final StackTrace stackTrace;

  @override
  String toString() => 'TurnFailedEvent($error)';
}

/// The conversation [conversationId] changed: a host saves it.
final class ConversationChangedEvent extends AssistantEvent {
  const ConversationChangedEvent(this.change, this.conversationId);

  final ConversationChange change;
  final String conversationId;

  @override
  String toString() => 'ConversationChangedEvent(${change.name}, $conversationId)';
}

/// The prefix state of a load or a reconfiguration was restored, built or is not supported, in [elapsed].
final class PrefixPreparedEvent extends AssistantEvent {
  const PrefixPreparedEvent(this.how, this.elapsed);

  final PrefixPreparation how;
  final Duration elapsed;

  @override
  String toString() => 'PrefixPreparedEvent(${how.name}, ${elapsed.inMilliseconds} ms)';
}
