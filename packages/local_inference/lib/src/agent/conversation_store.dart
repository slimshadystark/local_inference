/// Where conversations are saved, and saving them as they change.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'assistant.dart';
import 'events.dart';
import 'screen_requests.dart';
import 'snapshot.dart';

/// Saved conversations, by id.
abstract interface class ConversationStore {
  /// Every saved conversation that can be read, the most recently updated first.
  Future<List<ConversationSnapshot>> list();

  /// The conversation [id]; null when there is none or it cannot be read.
  Future<ConversationSnapshot?> load(String id);

  /// Saves [snapshot], replacing the one with its id.
  Future<void> save(ConversationSnapshot snapshot);

  /// Removes the conversation [id], if any.
  Future<void> delete(String id);
}

/// Conversations as `<directory>/conversation_<id>.json` files: the id with every character other than lower-case
/// letters, digits, `-` and `_` written as `%XX` of its UTF-8 bytes, so ids that differ only in case get two files
/// on any file system. A save writes a temporary file of its own and renames it, so neither a crash nor another save
/// of the same conversation leaves half a file; this store's saves and deletes of one id run in call order. A file
/// that cannot be read is skipped by [list] and read as none by [load].
final class FileConversationStore implements ConversationStore {
  FileConversationStore(this.directory);

  /// The folder of the files.
  final String directory;

  static final RegExp _plain = RegExp(r'^[a-z0-9_-]$');
  static final math.Random _random = math.Random();
  static int _temps = 0;

  /// The last save or delete of each id, while it runs.
  final Map<String, Future<void>> _queue = {};

  /// The file of conversation [id].
  String pathOf(String id) {
    final name = StringBuffer();
    for (final rune in id.runes) {
      final char = String.fromCharCode(rune);
      if (_plain.hasMatch(char)) {
        name.write(char);
      } else {
        for (final byte in utf8.encode(char)) {
          name.write('%${byte.toRadixString(16).toUpperCase().padLeft(2, '0')}');
        }
      }
    }
    return '$directory/conversation_$name.json';
  }

  @override
  Future<List<ConversationSnapshot>> list() async {
    final folder = Directory(directory);
    if (!await folder.exists()) return const [];
    final found = <ConversationSnapshot>[];
    await for (final entity in folder.list(followLinks: false)) {
      final name = entity.uri.pathSegments.last;
      if (entity is! File || !name.startsWith('conversation_') || !name.endsWith('.json')) continue;
      final snapshot = await _read(entity);
      if (snapshot != null) found.add(snapshot);
    }
    found.sort((a, b) {
      final byTime = b.updatedAt.compareTo(a.updatedAt);
      return byTime != 0 ? byTime : a.id.compareTo(b.id);
    });
    return found;
  }

  @override
  Future<ConversationSnapshot?> load(String id) async {
    final snapshot = await _read(File(pathOf(id)));
    return snapshot?.id == id ? snapshot : null;
  }

  @override
  Future<void> save(ConversationSnapshot snapshot) => _serially(snapshot.id, () async {
    await Directory(directory).create(recursive: true);
    final path = pathOf(snapshot.id);
    // A name of its own: another store or process may be saving the same conversation.
    final temp = File('$path.$pid-${_temps++}-${_random.nextInt(1 << 30).toRadixString(36)}.tmp');
    try {
      await temp.writeAsString(jsonEncode(snapshot.toJson(), toEncodable: (value) => '$value'), flush: true);
      await temp.rename(path);
    } catch (_) {
      if (await temp.exists()) await temp.delete();
      rethrow;
    }
  });

  @override
  Future<void> delete(String id) => _serially(id, () async {
    final file = File(pathOf(id));
    if (await file.exists()) await file.delete();
  });

  /// Runs [action] once the earlier saves and deletes of [id] have ended, failed or not.
  Future<void> _serially(String id, Future<void> Function() action) {
    final next = (_queue[id] ?? Future<void>.value()).then<void>((_) {}, onError: (Object _) {}).then((_) => action());
    _queue[id] = next;
    void forget(Object? _) {
      if (identical(_queue[id], next)) _queue.remove(id);
    }

    next.then(forget, onError: forget);
    return next;
  }

  static Future<ConversationSnapshot?> _read(File file) async {
    try {
      if (!await file.exists()) return null;
      return ConversationSnapshot.tryParse(jsonDecode(await file.readAsString()));
    } on Object {
      return null;
    }
  }

  @override
  String toString() => 'FileConversationStore($directory)';
}

/// Saves [assistant]'s conversation to [store] each time it changes: after every call, recorded action and restore
/// ([ConversationChangedEvent]), while no turn runs (a turn's own end saves it). Empty conversations are not saved.
/// Saves run one at a time; a failed one goes to [onError] (default: the zone's error handler). Cancel the
/// subscription to stop.
StreamSubscription<void> autosave(
  Assistant assistant,
  ConversationStore store, {
  ScreenRequestCodec? codec,
  void Function(Object error, StackTrace stackTrace)? onError,
}) {
  var chain = Future<void>.value();
  final report = onError ?? Zone.current.handleUncaughtError;
  return assistant.events.where((event) => event is ConversationChangedEvent).listen((_) {
    if (assistant.state.isBusy) return;
    final ConversationSnapshot snapshot;
    try {
      snapshot = assistant.snapshot(codec: codec);
    } catch (error, stackTrace) {
      report(error, stackTrace); // a codec that throws
      return;
    }
    if (snapshot.messageCount == 0) return;
    chain = chain.then((_) => store.save(snapshot)).catchError((Object error, StackTrace stackTrace) {
      report(error, stackTrace);
    });
  });
}
