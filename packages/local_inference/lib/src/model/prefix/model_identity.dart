/// Which model file a saved prefix state belongs to.
library;

import 'dart:io';

import 'package:meta/meta.dart';

/// A model file as a prefix-state key sees it: its name, size and modification time. A caller's sha256 never
/// enters the key, so the same file reloaded gives the same key and a replaced file a new one.
@immutable
final class ModelIdentity {
  /// An identity given directly (tests, models that are not files).
  const ModelIdentity.fixed(this.fileName, {this.sizeBytes = 0, this.modifiedMs = 0});

  /// The file name, without its folder.
  final String fileName;

  /// Size of the file.
  final int sizeBytes;

  /// Last modification of the file, ms since the epoch.
  final int modifiedMs;

  /// The identity of the file at [path]. Throws [FileSystemException] when there is no file. The file is read
  /// synchronously (one stat), so this also completes where only microtasks run (a widget test's fake-async zone).
  static Future<ModelIdentity> ofFile(String path) async {
    final file = File(path);
    final stat = file.statSync();
    if (stat.type != FileSystemEntityType.file) throw FileSystemException('no model file', path);
    return ModelIdentity.fixed(
      file.uri.pathSegments.last,
      sizeBytes: stat.size,
      modifiedMs: stat.modified.millisecondsSinceEpoch,
    );
  }

  /// `'<fileName>|<sizeBytes>|<modifiedMs>'`.
  String get id => '$fileName|$sizeBytes|$modifiedMs';

  @override
  bool operator ==(Object other) => other is ModelIdentity && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'ModelIdentity($id)';
}
