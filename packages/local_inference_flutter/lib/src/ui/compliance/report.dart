/// "Report this reply": the payload a host receives (Google Play's AI-content policy asks for an in-app report).
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:local_inference/local_inference.dart';
import 'package:path/path.dart' as p;

/// Why the user reports a reply.
enum ReportReason {
  /// Offensive or inappropriate.
  offensive,

  /// Wrong or made up.
  wrong,

  /// Harmful.
  harmful,

  /// Something else (the comment says what).
  other,
}

/// Receives a report; the chat thanks the user when it completes.
typedef ReportHandler = FutureOr<void> Function(ReportRequest report);

/// One report of a reply, with what a reviewer needs: the reply, the user's text of its turn, the conversation and
/// the model. It carries no other message of the conversation.
@immutable
final class ReportRequest {
  const ReportRequest({
    required this.reason,
    this.comment,
    required this.message,
    this.userText,
    required this.conversationId,
    this.modelFile,
    this.templateSha256,
    this.runtime,
    required this.time,
  });

  /// A report of [message] from [state]: the user text is the last user item before it; the model's file name,
  /// template SHA-256 and runtime come from the loaded model. [time] defaults to now.
  factory ReportRequest.of(
    AssistantState state,
    ChatItem message, {
    required ReportReason reason,
    String? comment,
    DateTime? time,
  }) {
    final index = state.items.indexWhere((item) => item.id == message.id);
    String? userText;
    for (var i = (index < 0 ? state.items.length : index) - 1; i >= 0; i--) {
      final item = state.items[i];
      if (item.role == MessageRole.user) {
        userText = item.text;
        break;
      }
    }
    final info = state.info;
    final path = info?.modelPath ?? state.modelPath;
    final trimmed = comment?.trim();
    return ReportRequest(
      reason: reason,
      comment: trimmed == null || trimmed.isEmpty ? null : trimmed,
      message: message,
      userText: userText,
      conversationId: state.conversationId,
      modelFile: path == null ? null : p.basename(path),
      templateSha256: info?.chatTemplateSha256,
      runtime: info?.runtime.id,
      time: time ?? DateTime.now(),
    );
  }

  final ReportReason reason;

  /// What the user added; null when nothing.
  final String? comment;

  /// The reported reply.
  final ChatItem message;

  /// The user's text of the reply's turn; null when there is none (a reply to a screen's action).
  final String? userText;

  final String conversationId;

  /// The model file's name (not its path).
  final String? modelFile;

  /// The SHA-256 of the model's chat template.
  final String? templateSha256;

  /// The inference runtime, as `EngineInfo.runtime.id` gives it.
  final String? runtime;

  /// When the user sent the report.
  final DateTime time;

  /// The report as JSON: `reason`, `comment`, `message` (`id`, `text`, `source`), `userText`, `conversationId`,
  /// `modelFile`, `templateSha256`, `runtime`, `time` (ISO 8601, UTC). Unknown values are null.
  Map<String, Object?> toJson() => {
    'reason': reason.name,
    'comment': comment,
    'message': {'id': message.id, 'text': message.text, 'source': message.source?.name},
    'userText': userText,
    'conversationId': conversationId,
    'modelFile': modelFile,
    'templateSha256': templateSha256,
    'runtime': runtime,
    'time': time.toUtc().toIso8601String(),
  };

  @override
  String toString() => 'ReportRequest(${reason.name}, message ${message.id})';
}
