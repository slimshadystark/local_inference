/// ValueListenables over local_inference's [ModelManager], for widgets that rebuild on one value only.
library;

import 'package:flutter/foundation.dart';
import 'package:local_inference/local_inference.dart';

import 'change_source_listenable.dart';

/// Follows [manager]: [ready], [installed] and each [status] change only when their value does. Dispose it when
/// done; it does not dispose the manager.
final class ModelManagerWatcher {
  ModelManagerWatcher(this.manager)
    : _ready = ValueNotifier(manager.isReady),
      _installed = ValueNotifier(manager.isReady ? List.unmodifiable(manager.installed) : const []) {
    manager.addListener(_update);
  }

  final ModelManager manager;
  final ValueNotifier<bool> _ready;
  final ValueNotifier<List<InstalledModel>> _installed;
  final _statuses = <String, ValueNotifier<ModelStatus>>{};
  bool _disposed = false;

  /// Every change of the manager.
  Listenable get listenable => ChangeSourceListenable(manager);

  /// Whether the manager's init completed.
  ValueListenable<bool> get ready => _ready;

  /// The verified models; empty until [ready].
  ValueListenable<List<InstalledModel>> get installed => _installed;

  /// The status of [id]; the same listenable for every call with the same id.
  ValueListenable<ModelStatus> status(String id) =>
      _statuses.putIfAbsent(id, () => ValueNotifier(manager.statusOf(id)));

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    manager.removeListener(_update);
    _ready.dispose();
    _installed.dispose();
    for (final status in _statuses.values) {
      status.dispose();
    }
    _statuses.clear();
  }

  void _update() {
    _ready.value = manager.isReady;
    final installed = manager.isReady ? manager.installed : const <InstalledModel>[];
    if (!_same(installed, _installed.value)) _installed.value = List.unmodifiable(installed);
    // ModelStatus compares by value, so a notifier fires only when its model's status changed.
    for (final MapEntry(key: id, value: status) in _statuses.entries) {
      status.value = manager.statusOf(id);
    }
  }

  static bool _same(List<InstalledModel> a, List<InstalledModel> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].entry != b[i].entry || a[i].path != b[i].path || a[i].sizeBytes != b[i].sizeBytes) return false;
    }
    return true;
  }
}
