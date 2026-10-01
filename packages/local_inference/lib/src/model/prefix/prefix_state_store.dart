/// Where saved prefix states live.
library;

import 'prefix_key.dart';

/// Files of saved prefix states, by key. A state is written by the engine (`InferenceEngine.saveState`) to a path
/// the store gives, and read back from the path [find] returns.
abstract interface class PrefixStateStore {
  /// The path of the state of [key], marked as just used; null when there is none.
  Future<String?> find(PrefixKey key);

  /// Calls [write] with a temporary path to fill, then moves the file into place atomically and evicts old states;
  /// returns the state's path. When [write] throws, the temporary file is removed and the error rethrown.
  Future<String> put(PrefixKey key, Future<void> Function(String tempPath) write);

  /// Removes the state of [key], if any.
  Future<void> remove(PrefixKey key);

  /// Removes every state.
  Future<void> clear();
}
