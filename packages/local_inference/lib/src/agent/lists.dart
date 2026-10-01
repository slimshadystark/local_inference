/// Numbered lists: what the user was shown, and what "the second one" names.
///
/// A tool result that holds a list (`{collection, items: [{n: 1, …}, …]}`) becomes the last list of its collection,
/// with a version that grows by one each time. An argument declared as an item number ([ListReferences]) names an
/// item of the last list of its collection. What a number named when it was used is kept by value ([ItemBinding]):
/// the list's version and the item as it read, so a later list of the same items still counts as the same.
library;

import 'dart:convert';

import 'package:meta/meta.dart';

import '../model/tool_call.dart';
import '../model/tool_spec.dart';
import 'tool_result.dart';

/// An item of a numbered list: the collection and the number.
@immutable
final class ItemRef {
  const ItemRef(this.collection, this.number);

  /// The list's collection (`orders`, `booking_slots`).
  final String collection;

  /// The item's number as the call wrote it.
  final Object? number;

  @override
  bool operator ==(Object other) => other is ItemRef && other.collection == collection && other.number == number;

  @override
  int get hashCode => Object.hash(collection, number);

  @override
  String toString() => 'ItemRef($collection #$number)';
}

/// Where the collection of an item-number argument comes from.
@immutable
sealed class ItemSource {
  const ItemSource();

  /// Always the collection [name] (`order_number` → `orders`).
  const factory ItemSource.collection(String name) = CollectionItemSource;

  /// The call's own string argument [argument] (`item_number` → the value of `collection`).
  const factory ItemSource.argument(String argument) = ArgumentItemSource;
}

/// [ItemSource.collection].
final class CollectionItemSource extends ItemSource {
  const CollectionItemSource(this.name);

  /// The collection.
  final String name;

  @override
  bool operator ==(Object other) => other is CollectionItemSource && other.name == name;

  @override
  int get hashCode => Object.hash(CollectionItemSource, name);
}

/// [ItemSource.argument].
final class ArgumentItemSource extends ItemSource {
  const ArgumentItemSource(this.argument);

  /// The argument that names the collection.
  final String argument;

  @override
  bool operator ==(Object other) => other is ArgumentItemSource && other.argument == argument;

  @override
  int get hashCode => Object.hash(ArgumentItemSource, argument);
}

/// How tool results show numbered lists and which arguments are item numbers.
///
/// A result is a list when it succeeded and its payload has a string [collectionKey] and a list [itemsKey]; each
/// item's number is its [numberKey]. [itemArguments] declares the item-number arguments; a top-level property of a
/// tool's parameters with `'x-item-of': '<collection>'` (as `ToolSchema.itemNumber` writes it) declares one too, and
/// [itemArguments] wins for the same name.
class ListReferences {
  const ListReferences({
    this.itemArguments = const {},
    this.itemsKey = 'items',
    this.collectionKey = 'collection',
    this.numberKey = 'n',
    this.annotate,
  });

  /// Item-number arguments by name, and where their collection comes from.
  final Map<String, ItemSource> itemArguments;

  /// The payload key of the items.
  final String itemsKey;

  /// The payload key of the collection's name.
  final String collectionKey;

  /// The item key of the number.
  final String numberKey;

  /// Facts about a call read synchronously right before it runs (for example the office its number names), kept with
  /// the list it shows and given to the tool, the reply writer and the confirmation question.
  final Map<String, Object?> Function(ToolCall call, ShownLists lists)? annotate;

  /// Where the collection of [argument] comes from: [itemArguments], else the argument's `x-item-of` in [spec].
  ItemSource? sourceOf(String argument, [ToolSpec? spec]) {
    final declared = itemArguments[argument];
    if (declared != null) return declared;
    final marker = _markers(spec)[argument];
    return marker == null ? null : ItemSource.collection(marker);
  }

  /// The item [call]'s [argument] names; null when the call lacks the argument, it is no item number, or its
  /// collection argument is not a string.
  ItemRef? refOf(ToolCall call, String argument, [ToolSpec? spec]) {
    if (!call.arguments.containsKey(argument)) return null;
    final collection = switch (sourceOf(argument, spec)) {
      CollectionItemSource(:final name) => name,
      ArgumentItemSource(:final argument) => switch (call.arguments[argument]) {
        final String name => name,
        _ => null,
      },
      null => null,
    };
    return collection == null ? null : ItemRef(collection, call.arguments[argument]);
  }

  /// The item [call] names: its first item-number argument present, [itemArguments] first, then the markers of
  /// [spec] in property order.
  ItemRef? itemRefOf(ToolCall call, [ToolSpec? spec]) {
    for (final argument in [...itemArguments.keys, ..._markers(spec).keys]) {
      final ref = refOf(call, argument, spec);
      if (ref != null) return ref;
    }
    return null;
  }

  static Map<String, String> _markers(ToolSpec? spec) {
    final properties = spec?.parameters['properties'];
    if (properties is! Map) return const {};
    return {
      for (final entry in properties.entries)
        if (entry.value case {'x-item-of': final String collection}) entry.key.toString(): collection,
    };
  }
}

/// A numbered list the user was shown: the last one of its collection.
@immutable
final class ShownList {
  const ShownList({
    required this.collection,
    required this.call,
    required this.payload,
    required this.items,
    required this.version,
    this.annotations = const {},
  });

  /// Its collection.
  final String collection;

  /// The call that showed it.
  final ToolCall call;

  /// The whole payload of that call.
  final Map<String, Object?> payload;

  /// The items, in order.
  final List<Map<String, Object?>> items;

  /// 1 for the first list of the collection in a conversation, then one more for each.
  final int version;

  /// What `ListReferences.annotate` said about [call].
  final Map<String, Object?> annotations;

  @override
  String toString() => 'ShownList($collection v$version, ${items.length} items)';
}

/// What an item number named when it was used: the list's version and the item as it read then, with the list's
/// annotations. Value-based and serializable.
@immutable
final class ItemBinding {
  const ItemBinding({required this.collection, this.number, required this.listVersion, required this.snapshot});

  /// The list's collection.
  final String collection;

  /// The number.
  final Object? number;

  /// The list's version then (0: no list).
  final int listVersion;

  /// The item and the list's annotations then, as JSON text.
  final String snapshot;

  /// `{collection, number, listVersion, snapshot}`.
  Map<String, Object?> toJson() => {
    'collection': collection,
    'number': number,
    'listVersion': listVersion,
    'snapshot': snapshot,
  };

  /// Reads [toJson]'s map; throws [FormatException] when a field is missing or of the wrong type.
  factory ItemBinding.fromJson(Map<String, Object?> json) {
    final collection = json['collection'];
    final version = json['listVersion'];
    final snapshot = json['snapshot'];
    if (collection is! String || version is! int || snapshot is! String) {
      throw FormatException('not an item binding', json);
    }
    return ItemBinding(collection: collection, number: json['number'], listVersion: version, snapshot: snapshot);
  }

  @override
  bool operator ==(Object other) =>
      other is ItemBinding &&
      other.collection == collection &&
      other.number == number &&
      other.listVersion == listVersion &&
      other.snapshot == snapshot;

  @override
  int get hashCode => Object.hash(collection, number, listVersion, snapshot);

  @override
  String toString() => 'ItemBinding($collection #$number v$listVersion)';
}

/// The lists of a conversation, read-only.
abstract interface class ShownLists {
  /// The collections with a list.
  Iterable<String> get collections;

  /// The last list of [collection].
  ShownList? operator [](String collection);

  /// The version of [collection]'s last list; 0 when there is none.
  int versionOf(String collection);

  /// The item numbered [number] in [collection]'s last list; null when there is none (or [number] is null).
  Map<String, Object?>? item(String collection, Object? number);

  /// Whether [collection]'s last list came from [call] (same name, same arguments in the same order).
  bool isLastList(String collection, ToolCall call);

  /// Whether [ref]'s item is in its collection's last list.
  bool isShown(ItemRef ref);

  /// What [ref] names now; null for a null [ref].
  ItemBinding? bind(ItemRef? ref);

  /// Whether [binding]'s number still names the same item: true for null, for the same list version, or for a later
  /// list that shows the same item with the same annotations.
  bool stillNames(ItemBinding? binding);
}

/// The lists of a conversation as the assistant keeps them. Internal.
@internal
final class ListLedger implements ShownLists {
  ListLedger(this.references);

  /// How results show lists; replaced when the assistant is reconfigured.
  ListReferences references;

  final Map<String, ShownList> _lists = {};

  @override
  Iterable<String> get collections => _lists.keys;

  @override
  ShownList? operator [](String collection) => _lists[collection];

  @override
  int versionOf(String collection) => _lists[collection]?.version ?? 0;

  @override
  Map<String, Object?>? item(String collection, Object? number) {
    if (number == null) return null;
    final key = references.numberKey;
    for (final item in _lists[collection]?.items ?? const <Map<String, Object?>>[]) {
      if (item[key] == number) return item;
    }
    return null;
  }

  @override
  bool isLastList(String collection, ToolCall call) => _lists[collection]?.call.key == call.key;

  @override
  bool isShown(ItemRef ref) => item(ref.collection, ref.number) != null;

  @override
  ItemBinding? bind(ItemRef? ref) => ref == null
      ? null
      : ItemBinding(
          collection: ref.collection,
          number: ref.number,
          listVersion: versionOf(ref.collection),
          snapshot: _snapshot(ref.collection, ref.number),
        );

  @override
  bool stillNames(ItemBinding? binding) =>
      binding == null ||
      versionOf(binding.collection) == binding.listVersion ||
      _snapshot(binding.collection, binding.number) == binding.snapshot;

  /// `[annotations, item]` of [collection]'s last list as JSON: two lists that give [number] the same item with the
  /// same annotations name the same thing.
  String _snapshot(String collection, Object? number) =>
      jsonEncode([_lists[collection]?.annotations ?? const {}, item(collection, number)], toEncodable: _text);

  /// What [call] says about itself right before it runs.
  Map<String, Object?> annotate(ToolCall call) => references.annotate?.call(call, this) ?? const {};

  /// The list [result] shows, with the next version of its collection; null when it shows none. Records nothing:
  /// [commit] does.
  ShownList? prepare(ToolCall call, ToolResult result, Map<String, Object?> annotations) {
    if (!result.ok) return null;
    final payload = result.payload;
    final collection = payload[references.collectionKey];
    final items = payload[references.itemsKey];
    if (collection is! String || items is! List) return null;
    return ShownList(
      collection: collection,
      call: call,
      payload: payload,
      items: [
        for (final item in items)
          if (item is Map) item.cast<String, Object?>(),
      ],
      version: versionOf(collection) + 1,
      annotations: annotations,
    );
  }

  /// Makes [list] (from [prepare], in the same synchronous step) the last list of its collection.
  void commit(ShownList? list) {
    if (list != null) _lists[list.collection] = list;
  }

  /// [prepare], then [commit]; returns the list.
  ShownList? record(ToolCall call, ToolResult result, Map<String, Object?> annotations) {
    final list = prepare(call, result, annotations);
    commit(list);
    return list;
  }

  /// Forgets every list: versions start again.
  void clear() => _lists.clear();

  /// `{'lists': [{collection, version, call, payload, annotations}, …]}`.
  Map<String, Object?> toJson() => {
    'lists': [
      for (final list in _lists.values)
        {
          'collection': list.collection,
          'version': list.version,
          'call': list.call.toJson(),
          'payload': list.payload,
          'annotations': list.annotations,
        },
    ],
  };

  /// Replaces the lists with those of [json] ([toJson]'s form); throws [FormatException] on a malformed one.
  void restore(Map<String, Object?> json) {
    final lists = json['lists'];
    if (lists is! List) throw FormatException('no lists', json);
    final restored = <String, ShownList>{};
    for (final entry in lists) {
      if (entry is! Map) throw FormatException('not a list', entry);
      final collection = entry['collection'];
      final version = entry['version'];
      final call = entry['call'];
      final payload = entry['payload'];
      final annotations = entry['annotations'] ?? const <String, Object?>{};
      if (collection is! String || version is! int || call is! Map || payload is! Map || annotations is! Map) {
        throw FormatException('not a list', entry);
      }
      final items = payload[references.itemsKey];
      restored[collection] = ShownList(
        collection: collection,
        call: ToolCall.fromJson(call.cast<String, Object?>()),
        payload: payload.cast<String, Object?>(),
        items: [
          if (items is List)
            for (final item in items)
              if (item is Map) item.cast<String, Object?>(),
        ],
        version: version,
        annotations: annotations.cast<String, Object?>(),
      );
    }
    _lists
      ..clear()
      ..addAll(restored);
  }

  static Object? _text(Object? value) => value.toString();
}
