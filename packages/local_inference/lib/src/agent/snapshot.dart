/// A conversation as a value that can be saved and restored.
library;

import 'package:meta/meta.dart';

import '../model/chat_message.dart';
import 'lists.dart';
import 'screen_requests.dart';
import 'state.dart';

/// A conversation to save and restore (`Assistant.snapshot`, `Assistant.restore`): its items, history, lists, open
/// question and offer, the toolkit's state and the host's own data. [toJson] gives JSON; [tryParse] reads it back.
///
/// Items keep their screen requests as [StoredScreenRequest]s (label, item, and the codec's JSON when the snapshot was
/// taken with one); a snapshot does not keep generation figures.
@immutable
final class ConversationSnapshot {
  const ConversationSnapshot({
    required this.id,
    required this.createdAt,
    required this.updatedAt,
    this.items = const [],
    this.history = const [],
    this.lists = const {'lists': <Object?>[]},
    this.pending,
    this.offer,
    this.toolkitState,
    this.hostData = const {},
  });

  /// The version of [toJson]'s format; [tryParse] refuses others.
  static const int formatVersion = 1;

  /// The conversation's id.
  final String id;

  /// When the conversation started.
  final DateTime createdAt;

  /// When it last changed.
  final DateTime updatedAt;

  /// The chat.
  final List<ChatItem> items;

  /// The history the prompts carry.
  final List<HistoryEntry> history;

  /// The shown lists (`{'lists': [...]}`).
  final Map<String, Object?> lists;

  /// The open question: `{userText, call, itemId, question, binding?}`; null when none.
  final Map<String, Object?>? pending;

  /// The offer: `{call, binding?}`; null when none.
  final Map<String, Object?>? offer;

  /// What `Toolkit.saveState` gave.
  final Map<String, Object?>? toolkitState;

  /// The host's own data.
  final Map<String, Object?> hostData;

  /// The first user text, on one line, cut to 80 characters (with `…`); `''` for an empty chat.
  String get title =>
      _cut(items.where((item) => item.role == MessageRole.user).map((item) => item.text).firstOrNull ?? '', 80);

  /// The last assistant text (else the last text), on one line, cut to 120 characters.
  String get preview =>
      _cut(items.lastWhere((item) => item.role == MessageRole.assistant, orElse: () => _lastOrEmpty).text, 120);

  ChatItem get _lastOrEmpty => items.isEmpty ? const ChatItem(id: 0, role: MessageRole.assistant) : items.last;

  /// The number of items.
  int get messageCount => items.length;

  /// The snapshot as JSON (title, preview and message count included, for a reader that lists conversations).
  Map<String, Object?> toJson() => {
    'formatVersion': formatVersion,
    'id': id,
    'title': title,
    'preview': preview,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    'messageCount': messageCount,
    'items': [for (final item in items) _itemJson(item)],
    'history': [
      for (final entry in history) {'user': entry.user, 'assistant': entry.assistant},
    ],
    'lists': lists,
    'pending': pending,
    'offer': offer,
    'toolkitState': toolkitState,
    'hostData': hostData,
  };

  /// The snapshot [json] ([toJson]'s form, decoded) holds; null when it is not one, has another format version, or
  /// any part is malformed. Never throws.
  static ConversationSnapshot? tryParse(Object? json) {
    try {
      if (json is! Map) return null;
      if (json['formatVersion'] != formatVersion) return null;
      final id = json['id'];
      final createdAt = DateTime.tryParse('${json['createdAt']}');
      final updatedAt = DateTime.tryParse('${json['updatedAt']}');
      final items = json['items'];
      final history = json['history'];
      final lists = json['lists'];
      final pending = json['pending'];
      final offer = json['offer'];
      final toolkitState = json['toolkitState'];
      final hostData = json['hostData'] ?? const <String, Object?>{};
      if (id is! String || id.isEmpty || createdAt == null || updatedAt == null) return null;
      if (items is! List || history is! List || lists is! Map || lists['lists'] is! List || hostData is! Map) {
        return null;
      }
      if ((pending != null && pending is! Map) ||
          (offer != null && offer is! Map) ||
          (toolkitState != null && toolkitState is! Map)) {
        return null;
      }
      final parsedItems = <ChatItem>[];
      final ids = <int>{};
      for (final item in items) {
        final parsed = _itemFromJson(item);
        if (parsed == null || !ids.add(parsed.id)) return null;
        parsedItems.add(parsed);
      }
      final parsedHistory = <HistoryEntry>[];
      for (final entry in history) {
        if (entry is! Map) return null;
        final user = entry['user'];
        final assistant = entry['assistant'];
        if (user is! String || assistant is! String) return null;
        parsedHistory.add(HistoryEntry(user, assistant));
      }
      return ConversationSnapshot(
        id: id,
        createdAt: createdAt,
        updatedAt: updatedAt,
        items: List.unmodifiable(parsedItems),
        history: List.unmodifiable(parsedHistory),
        lists: lists.cast<String, Object?>(),
        pending: (pending as Map?)?.cast<String, Object?>(),
        offer: (offer as Map?)?.cast<String, Object?>(),
        toolkitState: (toolkitState as Map?)?.cast<String, Object?>(),
        hostData: hostData.cast<String, Object?>(),
      );
    } on Object {
      return null;
    }
  }

  @override
  String toString() => 'ConversationSnapshot($id, $messageCount items)';
}

String _cut(String text, int max) {
  final line = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  final runes = line.runes.toList();
  return runes.length <= max ? line : '${String.fromCharCodes(runes.take(max - 1)).trimRight()}…';
}

Map<String, Object?> _itemJson(ChatItem item) => {
  'id': item.id,
  'role': item.role.name,
  'text': item.text,
  if (item.thinking) 'thinking': true,
  'status': ?item.status,
  if (item.actions.isNotEmpty)
    'actions': [
      for (final action in item.actions) {'kind': action.kind.name, 'label': action.label, 'primary': action.primary},
    ],
  if (item.guarded) 'guarded': true,
  'source': ?item.source?.name,
  if (item.screenRequest case final bound?) 'screenRequest': _requestJson(bound),
  'details': ?item.details,
};

Map<String, Object?> _requestJson(BoundScreenRequest bound) {
  final request = bound.request;
  final ref = request.itemRef;
  return {
    'label': request.label,
    if (ref != null) 'item': {'collection': ref.collection, 'number': ref.number},
    if (request case StoredScreenRequest(:final data?)) 'data': data,
    'binding': ?bound.binding?.toJson(),
  };
}

ChatItem? _itemFromJson(Object? json) {
  if (json is! Map) return null;
  final id = json['id'];
  final role = json['role'];
  final text = json['text'];
  final status = json['status'];
  final details = json['details'];
  final source = json['source'];
  final actions = json['actions'] ?? const <Object?>[];
  if (id is! int || text is! String || actions is! List) return null;
  if ((status != null && status is! String) || (details != null && details is! String)) return null;
  final parsedRole = switch (role) {
    'user' => MessageRole.user,
    'assistant' => MessageRole.assistant,
    _ => null,
  };
  if (parsedRole == null) return null;
  ReplySource? parsedSource;
  if (source != null) {
    parsedSource = ReplySource.values.where((value) => value.name == source).firstOrNull;
    if (parsedSource == null) return null;
  }
  final parsedActions = <ChatAction>[];
  for (final action in actions) {
    if (action is! Map) return null;
    final kind = ChatActionKind.values.where((value) => value.name == action['kind']).firstOrNull;
    final label = action['label'];
    final primary = action['primary'] ?? false;
    if (kind == null || label is! String || primary is! bool) return null;
    parsedActions.add(ChatAction(kind: kind, label: label, primary: primary));
  }
  BoundScreenRequest? request;
  final requestJson = json['screenRequest'];
  if (requestJson != null) {
    request = _requestFromJson(requestJson);
    if (request == null) return null;
  }
  return ChatItem(
    id: id,
    role: parsedRole,
    text: text,
    thinking: json['thinking'] == true,
    status: status as String?,
    actions: List.unmodifiable(parsedActions),
    guarded: json['guarded'] == true,
    source: parsedSource,
    screenRequest: request,
    details: details as String?,
  );
}

BoundScreenRequest? _requestFromJson(Object? json) {
  if (json is! Map) return null;
  final label = json['label'];
  final item = json['item'];
  final data = json['data'];
  final binding = json['binding'];
  if (label is! String || (item != null && item is! Map) || (data != null && data is! Map)) return null;
  ItemRef? ref;
  if (item is Map) {
    final collection = item['collection'];
    if (collection is! String) return null;
    ref = ItemRef(collection, item['number']);
  }
  return BoundScreenRequest(
    StoredScreenRequest(label: label, itemRef: ref, data: (data as Map?)?.cast<String, Object?>()),
    binding: binding is Map ? ItemBinding.fromJson(binding.cast<String, Object?>()) : null,
  );
}

/// [item] as a snapshot keeps it: its screen request stored (through [codec] when given). Internal.
@internal
ChatItem storedItem(ChatItem item, ScreenRequestCodec? codec) {
  final bound = item.screenRequest;
  if (bound == null || bound.request is StoredScreenRequest) return item;
  final request = bound.request;
  return _withRequest(
    item,
    item.id,
    BoundScreenRequest(
      StoredScreenRequest(label: request.label, itemRef: request.itemRef, data: codec?.encode(request)),
      binding: bound.binding,
    ),
  );
}

/// A snapshot's [item] back in a conversation, as item [id]: its stored screen request decoded by [codec] when it
/// can (a codec that throws cannot); without its actions unless [actions]. Internal.
@internal
ChatItem restoredItem(ChatItem item, int id, ScreenRequestCodec? codec, {bool actions = true}) {
  final bound = item.screenRequest;
  var request = bound;
  if (bound != null && codec != null) {
    if (bound.request case StoredScreenRequest(:final data?)) {
      final decoded = _decode(codec, data);
      if (decoded != null) request = BoundScreenRequest(decoded, binding: bound.binding);
    }
  }
  return _withRequest(item, id, request, actions: actions ? item.actions : const []);
}

ScreenRequest? _decode(ScreenRequestCodec codec, Map<String, Object?> data) {
  try {
    return codec.decode(data);
  } on Object {
    return null;
  }
}

ChatItem _withRequest(ChatItem item, int id, BoundScreenRequest? request, {List<ChatAction>? actions}) => ChatItem(
  id: id,
  revision: item.revision,
  role: item.role,
  text: item.text,
  thinking: item.thinking,
  status: item.status,
  actions: actions ?? item.actions,
  guarded: item.guarded,
  source: item.source,
  screenRequest: request,
  details: item.details,
  stats: item.stats,
);
