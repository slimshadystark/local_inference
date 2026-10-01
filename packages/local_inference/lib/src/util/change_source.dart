/// Change notification without Flutter: [ChangeSource] and the listener list behind it.
library;

import 'dart:async';

import 'package:meta/meta.dart';

/// An object that tells its listeners when its state changed. Listeners run synchronously, in the order they were
/// added; read the new state from the object itself. Flutter apps wrap it in a `Listenable` (local_inference_flutter's
/// `ChangeSourceListenable`).
abstract interface class ChangeSource {
  /// Calls [listener] after every change. A listener added twice runs twice.
  void addListener(void Function() listener);

  /// Removes one registration of [listener]; does nothing when it is not registered.
  void removeListener(void Function() listener);
}

/// The listeners of a [ChangeSource], with ChangeNotifier's rules: [notify] calls them synchronously in the order they
/// were added; one added during a notification waits for the next one; one removed during a notification is not
/// called if its turn has not come. An exception thrown by a listener goes to the current zone's error handler and the
/// other listeners still run.
@internal
final class ChangeListeners {
  final List<void Function()?> _listeners = [];
  int _notifying = 0;
  bool _removedWhileNotifying = false;

  /// Whether no listener is registered.
  bool get isEmpty => !_listeners.any((listener) => listener != null);

  void add(void Function() listener) => _listeners.add(listener);

  void remove(void Function() listener) {
    final index = _listeners.indexOf(listener);
    if (index < 0) return;
    if (_notifying > 0) {
      _listeners[index] = null;
      _removedWhileNotifying = true;
    } else {
      _listeners.removeAt(index);
    }
  }

  /// Calls every listener registered when the notification starts.
  void notify() {
    final end = _listeners.length;
    if (end == 0) return;
    _notifying++;
    try {
      for (var i = 0; i < end; i++) {
        final listener = _listeners[i];
        if (listener == null) continue;
        try {
          listener();
        } catch (error, stack) {
          Zone.current.handleUncaughtError(error, stack);
        }
      }
    } finally {
      _notifying--;
      if (_notifying == 0 && _removedWhileNotifying) {
        _listeners.removeWhere((listener) => listener == null);
        _removedWhileNotifying = false;
      }
    }
  }

  /// Removes every listener.
  void clear() {
    if (_notifying > 0) {
      for (var i = 0; i < _listeners.length; i++) {
        _listeners[i] = null;
      }
      _removedWhileNotifying = true;
    } else {
      _listeners.clear();
    }
  }
}
