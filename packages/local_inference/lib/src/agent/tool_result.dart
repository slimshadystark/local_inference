/// What a tool call returns, and the outcome of one execution.
library;

import 'package:meta/meta.dart';

import '../model/tool_call.dart';
import '../model/tool_spec.dart';
import 'lists.dart';

/// Who asked for a tool call.
enum ToolCallSource {
  /// The model, in a turn.
  model,

  /// The user's yes to the open question.
  confirmation,

  /// The user's yes to the call a reply offered (`ToolReply.offer`).
  offer,

  /// A reply's follow-up (`ToolReply.followUp`), run right after the call that asked for it.
  followUp,

  /// The host app (`ToolHost.runTool`).
  host,
}

/// What a tool call returned: [ToolSuccess] or [ToolFailure].
///
/// A result made by [ToolResult.fromJson] keeps its map: [toJson] returns it unchanged, so a backend's envelope
/// (`{ok, payload, error, tool, args, side_effect}`) reaches the reply writer and the host as the backend wrote it.
@immutable
sealed class ToolResult {
  const ToolResult();

  /// A success with [payload].
  const factory ToolResult.ok([Map<String, Object?> payload]) = ToolSuccess;

  /// A numbered list the user can refer to by number: `{collection, count, shown, items, ...extra}`, where each item
  /// gets `n` (1, 2, …) as its first key, `count` is [total] (default: the number of items) and `shown` the number of
  /// items; [extra] adds keys after those, but none of them.
  factory ToolResult.list({
    required String collection,
    required List<Map<String, Object?>> items,
    int? total,
    Map<String, Object?> extra = const {},
  }) {
    final payload = <String, Object?>{
      'collection': collection,
      'count': total ?? items.length,
      'shown': items.length,
      'items': [
        for (final (index, item) in items.indexed)
          <String, Object?>{
            'n': index + 1,
            for (final entry in item.entries)
              if (entry.key != 'n') entry.key: entry.value,
          },
      ],
    };
    for (final entry in extra.entries) {
      payload.putIfAbsent(entry.key, () => entry.value);
    }
    return ToolSuccess(payload);
  }

  /// A failure: a short machine [code] and a [message] (for the reply writer, or the model with
  /// `ModelWrittenReplies`); [details] go into [toJson]'s error map.
  const factory ToolResult.error(String code, String message, {Map<String, Object?> details}) = ToolFailure;

  /// The result of the envelope [json]: `ok` true gives a [ToolSuccess] with its `payload`; otherwise a
  /// [ToolFailure] whose code and message are the `error` map's `code` and `error` (`'error'` when missing), its
  /// other keys the details. [toJson] returns [json] itself.
  factory ToolResult.fromJson(Map<String, Object?> json) {
    final payload = switch (json['payload']) {
      final Map<Object?, Object?> map => map.cast<String, Object?>(),
      _ => const <String, Object?>{},
    };
    if (json['ok'] == true) return ToolSuccess._kept(payload, json);
    final error = json['error'];
    final map = error is Map ? error.cast<String, Object?>() : const <String, Object?>{};
    return ToolFailure._kept(
      map['code']?.toString() ?? 'error',
      map['error']?.toString() ?? (error is String ? error : 'error'),
      {
        for (final entry in map.entries)
          if (entry.key != 'code' && entry.key != 'error') entry.key: entry.value,
      },
      payload,
      json,
    );
  }

  /// Whether the call succeeded.
  bool get ok;

  /// What the call returned; `{}` for most failures.
  Map<String, Object?> get payload;

  /// The kept envelope of [ToolResult.fromJson]; otherwise `{'ok': true, 'payload': …, 'error': null}` or
  /// `{'ok': false, 'payload': {}, 'error': {'error': message, 'code': code, ...details}}`.
  Map<String, Object?> toJson();
}

/// A call that succeeded.
final class ToolSuccess extends ToolResult {
  const ToolSuccess([this.payload = const {}]) : _kept = null;

  const ToolSuccess._kept(this.payload, Map<String, Object?> json) : _kept = json;

  @override
  final Map<String, Object?> payload;

  final Map<String, Object?>? _kept;

  @override
  bool get ok => true;

  @override
  Map<String, Object?> toJson() => _kept ?? {'ok': true, 'payload': payload, 'error': null};

  @override
  String toString() => 'ToolSuccess(${payload.keys.join(', ')})';
}

/// A call that failed.
final class ToolFailure extends ToolResult {
  const ToolFailure(this.code, this.message, {this.details = const {}}) : payload = const {}, _kept = null;

  const ToolFailure._kept(this.code, this.message, this.details, this.payload, Map<String, Object?> json)
    : _kept = json;

  /// A short machine code (`timeout`, `tool_exception`, a backend's own).
  final String code;

  /// What went wrong, in words.
  final String message;

  /// More facts about the failure.
  final Map<String, Object?> details;

  @override
  final Map<String, Object?> payload;

  final Map<String, Object?>? _kept;

  @override
  bool get ok => false;

  @override
  Map<String, Object?> toJson() =>
      _kept ??
      {
        'ok': false,
        'payload': const <String, Object?>{},
        'error': {'error': message, 'code': code, ...details},
      };

  @override
  String toString() => 'ToolFailure($code: $message)';
}

/// One executed call: the call, its result and where it came from.
@immutable
final class ToolOutcome {
  const ToolOutcome({
    required this.call,
    required this.result,
    this.spec,
    required this.source,
    this.annotations = const {},
    this.shownList,
  });

  /// The call as it ran (the model's arguments as the toolkit coerced them).
  final ToolCall call;

  /// What it returned.
  final ToolResult result;

  /// The tool's spec; null for a tool the toolkit does not list.
  final ToolSpec? spec;

  /// Who asked for it.
  final ToolCallSource source;

  /// What `ListReferences.annotate` said about the call right before it ran; `{}` for a recorded action.
  final Map<String, Object?> annotations;

  /// The numbered list this result showed, when it was one.
  final ShownList? shownList;

  @override
  String toString() => 'ToolOutcome(${source.name} $call → $result)';
}
