/// Prefix states as files in a folder.
library;

import 'dart:async';
import 'dart:io';

import 'package:meta/meta.dart';

import 'prefix_key.dart';
import 'prefix_state_store.dart';

bool _warnedTemporary = false;

/// The store of an assistant given none: [FilePrefixStateStore.temporary]. On iOS and Android the system may empty the
/// temporary folder at any time, so the first such store of the process prints a notice ([log], default the zone's
/// print) to pass a store in the caches folder instead. Internal.
@internal
PrefixStateStore temporaryPrefixStateStore({void Function(String message)? log}) {
  if (!_warnedTemporary && (Platform.isIOS || Platform.isAndroid)) {
    _warnedTemporary = true;
    (log ?? Zone.current.print)(
      'local_inference: this assistant keeps its prefix states in the temporary folder, which the system may empty '
      'at any time (a prefix is then built again, 12-40 s). Pass a FilePrefixStateStore in the caches folder.',
    );
  }
  return FilePrefixStateStore.temporary();
}

/// Prefix states as `<directory>/prefix_<key>.state` files, least recently used first out.
///
/// [find] marks a state used by touching its modification time; [put] writes `prefix_<key>.state.tmp`, renames it
/// into place, then keeps the newest [maxEntries] states (and, when [maxBytes] is set, only as many of them as fit,
/// the new one always), counting every `prefix_*.state` in the folder, so states of keys no longer used age out.
/// The first call removes `prefix_*.tmp` files a previous run left behind. Give it a folder of its own, such as a
/// caches folder (the system may empty it: a missing state is rebuilt).
///
/// Its own file operations (look-ups, renames, deletions, modification times) are synchronous: they are quick, and
/// so the store also works where only microtasks run, as in a widget test's fake-async zone (flutter_test's
/// `testWidgets`). The state itself is written and read by the engine.
final class FilePrefixStateStore implements PrefixStateStore {
  FilePrefixStateStore(this.directory, {this.maxEntries = 3, this.maxBytes}) {
    if (maxEntries < 1) throw ArgumentError.value(maxEntries, 'maxEntries', 'must be at least 1');
  }

  /// A store in the system's temporary folder (`<temp>/local_inference/prefix_states`), shared by the runs of a
  /// program: the choice for command-line tools.
  factory FilePrefixStateStore.temporary() =>
      FilePrefixStateStore('${Directory.systemTemp.path}/local_inference/prefix_states');

  /// The folder of the states.
  final String directory;

  /// The most states kept.
  final int maxEntries;

  /// The most bytes of states kept, null for no limit; a state just put stays even when it alone is larger.
  final int? maxBytes;

  /// Temporary files being written by any store of this program: never stale.
  static final Set<String> _writing = {};

  bool _cleaned = false;

  /// The path of the state of [key] (whether it exists or not).
  String pathOf(PrefixKey key) => '$directory/prefix_${key.id}.state';

  @override
  Future<String?> find(PrefixKey key) async {
    _removeStaleTemporaries();
    final file = File(pathOf(key));
    if (!file.existsSync()) return null;
    _touch(file);
    return file.path;
  }

  @override
  Future<String> put(PrefixKey key, Future<void> Function(String tempPath) write) async {
    _removeStaleTemporaries();
    Directory(directory).createSync(recursive: true);
    final path = pathOf(key);
    final temp = '$path.tmp';
    _writing.add(temp);
    try {
      await write(temp);
      File(temp).renameSync(path);
    } catch (_) {
      _delete(File(temp));
      rethrow;
    } finally {
      _writing.remove(temp);
    }
    _touch(File(path));
    _evict(keep: _name(File(path)));
    return path;
  }

  @override
  Future<void> remove(PrefixKey key) async {
    _removeStaleTemporaries();
    _delete(File(pathOf(key)));
  }

  @override
  Future<void> clear() async {
    _cleaned = true;
    for (final file in _files()) {
      final name = _name(file);
      if (_isState(name) || (_isTemporary(name) && !_writing.contains(file.path))) _delete(file);
    }
  }

  void _removeStaleTemporaries() {
    if (_cleaned) return;
    _cleaned = true;
    for (final file in _files()) {
      if (_isTemporary(_name(file)) && !_writing.contains(file.path)) _delete(file);
    }
  }

  /// Keeps the newest states within [maxEntries] and [maxBytes]; the state named [keep] stays whatever its size.
  void _evict({required String keep}) {
    final states = <(File, DateTime, int)>[];
    for (final file in _files()) {
      if (!_isState(_name(file))) continue;
      final stat = file.statSync();
      // Removed meanwhile: the stat finds no file.
      if (stat.type != FileSystemEntityType.file) continue;
      states.add((file, stat.modified, stat.size));
    }
    states.sort((a, b) {
      if (_name(a.$1) == keep) return -1;
      if (_name(b.$1) == keep) return 1;
      final byTime = b.$2.compareTo(a.$2);
      return byTime != 0 ? byTime : a.$1.path.compareTo(b.$1.path);
    });
    var kept = 0;
    var bytes = 0;
    for (final (file, _, size) in states) {
      final fits = kept < maxEntries && (_name(file) == keep || maxBytes == null || bytes + size <= maxBytes!);
      if (fits) {
        kept++;
        bytes += size;
      } else {
        _delete(file);
      }
    }
  }

  List<File> _files() {
    final folder = Directory(directory);
    if (!folder.existsSync()) return const [];
    return [
      for (final entity in folder.listSync(followLinks: false))
        if (entity is File) entity,
    ];
  }

  static String _name(File file) => file.uri.pathSegments.last;

  static bool _isState(String name) => name.startsWith('prefix_') && name.endsWith('.state');

  static bool _isTemporary(String name) => name.startsWith('prefix_') && name.endsWith('.tmp');

  static void _touch(File file) {
    try {
      file.setLastModifiedSync(DateTime.now());
    } on FileSystemException {
      // The state is still usable; it only ages sooner.
    }
  }

  static void _delete(File file) {
    try {
      file.deleteSync();
    } on FileSystemException {
      // Already gone.
    }
  }

  @override
  String toString() => 'FilePrefixStateStore($directory, maxEntries: $maxEntries, maxBytes: $maxBytes)';
}
