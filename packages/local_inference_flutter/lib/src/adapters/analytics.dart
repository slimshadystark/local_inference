/// Usage events of the chat and the model setup, for a host's analytics. None carries message text.
library;

import 'package:flutter/foundation.dart';

import '../ui/compliance/report.dart';
import 'screen_request_dispatcher.dart';

/// Something the user or the chat did. Events carry counts, durations, ids and codes, never what anyone wrote.
@immutable
sealed class ChatAnalyticsEvent {
  ChatAnalyticsEvent({DateTime? at}) : at = at ?? DateTime.now();

  /// When it happened.
  final DateTime at;
}

/// A chat view appeared.
final class ChatShownEvent extends ChatAnalyticsEvent {
  ChatShownEvent({super.at});

  @override
  String toString() => 'ChatShownEvent()';
}

/// A message was sent: its length in characters, and whether it was a suggestion.
final class MessageSentEvent extends ChatAnalyticsEvent {
  MessageSentEvent({required this.length, this.fromSuggestion = false, super.at});

  final int length;
  final bool fromSuggestion;

  @override
  String toString() => 'MessageSentEvent($length chars${fromSuggestion ? ', suggestion' : ''})';
}

/// A turn ended: how long it ran, how many tool calls it made, and whether it was stopped or failed.
final class TurnCompletedEvent extends ChatAnalyticsEvent {
  TurnCompletedEvent({
    required this.duration,
    required this.toolCalls,
    this.stopped = false,
    this.failed = false,
    super.at,
  });

  final Duration duration;
  final int toolCalls;
  final bool stopped;
  final bool failed;

  @override
  String toString() =>
      'TurnCompletedEvent(${duration.inMilliseconds} ms, $toolCalls tools'
      '${stopped ? ', stopped' : ''}${failed ? ', failed' : ''})';
}

/// The user answered a question.
final class ConfirmationAnsweredEvent extends ChatAnalyticsEvent {
  ConfirmationAnsweredEvent({required this.yes, super.at});

  final bool yes;

  @override
  String toString() => 'ConfirmationAnsweredEvent(${yes ? 'yes' : 'no'})';
}

/// The user stopped a turn.
final class GenerationStoppedEvent extends ChatAnalyticsEvent {
  GenerationStoppedEvent({super.at});

  @override
  String toString() => 'GenerationStoppedEvent()';
}

/// A screen a reply asked for was opened, by the assistant or from a chip.
final class ScreenRequestOpenedEvent extends ChatAnalyticsEvent {
  ScreenRequestOpenedEvent({required this.origin, super.at});

  final ScreenRequestOrigin origin;

  @override
  String toString() => 'ScreenRequestOpenedEvent(${origin.name})';
}

/// A chip was tapped whose list item changed meanwhile; nothing opened.
final class StaleScreenRequestBlockedEvent extends ChatAnalyticsEvent {
  StaleScreenRequestBlockedEvent({super.at});

  @override
  String toString() => 'StaleScreenRequestBlockedEvent()';
}

/// A reply was reported.
final class ReplyReportedEvent extends ChatAnalyticsEvent {
  ReplyReportedEvent({required this.reason, super.at});

  final ReportReason reason;

  @override
  String toString() => 'ReplyReportedEvent(${reason.name})';
}

/// A new conversation started.
final class ConversationStartedEvent extends ChatAnalyticsEvent {
  ConversationStartedEvent({required this.conversationId, super.at});

  final String conversationId;

  @override
  String toString() => 'ConversationStartedEvent($conversationId)';
}

/// A model became ready after [duration]; [prefixBuilt] when its prefix state had to be built.
final class ModelLoadedEvent extends ChatAnalyticsEvent {
  ModelLoadedEvent({required this.duration, this.prefixBuilt = false, super.at});

  final Duration duration;
  final bool prefixBuilt;

  @override
  String toString() => 'ModelLoadedEvent(${duration.inMilliseconds} ms${prefixBuilt ? ', prefix built' : ''})';
}

/// A model did not load; [errorType] is the error's type (`UnsupportedModelException`, …).
final class ModelLoadFailedEvent extends ChatAnalyticsEvent {
  ModelLoadFailedEvent({required this.errorType, super.at});

  final String errorType;

  @override
  String toString() => 'ModelLoadFailedEvent($errorType)';
}

/// The user started the download of [modelId].
final class ModelDownloadStartedEvent extends ChatAnalyticsEvent {
  ModelDownloadStartedEvent({required this.modelId, super.at});

  final String modelId;

  @override
  String toString() => 'ModelDownloadStartedEvent($modelId)';
}

/// [modelId] is downloaded and verified, [duration] after its download started.
final class ModelDownloadFinishedEvent extends ChatAnalyticsEvent {
  ModelDownloadFinishedEvent({required this.modelId, required this.duration, super.at});

  final String modelId;
  final Duration duration;

  @override
  String toString() => 'ModelDownloadFinishedEvent($modelId, ${duration.inSeconds} s)';
}

/// The download of [modelId] failed with [code] (a `ModelErrorCode` or `DownloadErrorCode` name, or the problem's
/// type).
final class ModelDownloadFailedEvent extends ChatAnalyticsEvent {
  ModelDownloadFailedEvent({required this.modelId, required this.code, super.at});

  final String modelId;
  final String code;

  @override
  String toString() => 'ModelDownloadFailedEvent($modelId, $code)';
}
