/// A prefix-state store for tests: the index in memory, the files in a temporary folder.
library;

import 'dart:io';

import '../model/prefix/prefix_key.dart';
import '../model/prefix/prefix_state_store.dart';

/// A [PrefixStateStore] that keeps its index in memory and records every call, for tests.
///
/// The engine still writes and reads files, so each state is a file in [directory] (a temporary folder created on
/// first use unless given; [clear] deletes it). No eviction. A state whose file was deleted behind the store's back
/// counts as missing, as a purged cache would.
final class InMemoryPrefixStateStore implements PrefixStateStore {
  InMemoryPrefixStateStore([this._given]);

  final String? _given;
  String? _created;
  final Map<String, String> _paths = {};

  /// The keys ([PrefixKey.id]) of [find] calls, in order.
  final List<String> finds = [];

  /// The keys of [put] calls, in order.
  final List<String> puts = [];

  /// The keys of [remove] calls, in order.
  final List<String> removes = [];

  /// The folder of the state files.
  String get directory => _given ?? (_created ??= Directory.systemTemp.createTempSync('li_prefix_store').path);

  /// The keys of the states it holds, in the order they were put.
  List<String> get keys => [
    for (final entry in _paths.entries)
      if (File(entry.value).existsSync()) entry.key,
  ];

  @override
  Future<String?> find(PrefixKey key) async {
    finds.add(key.id);
    final path = _paths[key.id];
    return path != null && File(path).existsSync() ? path : null;
  }

  @override
  Future<String> put(PrefixKey key, Future<void> Function(String tempPath) write) async {
    puts.add(key.id);
    final path = '$directory/prefix_${key.id}.state';
    final temp = '$path.tmp';
    try {
      await write(temp);
      File(temp).renameSync(path);
    } catch (_) {
      if (File(temp).existsSync()) File(temp).deleteSync();
      rethrow;
    }
    _paths[key.id] = path;
    return path;
  }

  @override
  Future<void> remove(PrefixKey key) async {
    removes.add(key.id);
    final path = _paths.remove(key.id);
    if (path != null && File(path).existsSync()) File(path).deleteSync();
  }

  /// Forgets every state and deletes the folder when it created it.
  @override
  Future<void> clear() async {
    for (final path in _paths.values) {
      if (File(path).existsSync()) File(path).deleteSync();
    }
    _paths.clear();
    final created = _created;
    if (created != null && Directory(created).existsSync()) Directory(created).deleteSync(recursive: true);
    _created = null;
  }
}
