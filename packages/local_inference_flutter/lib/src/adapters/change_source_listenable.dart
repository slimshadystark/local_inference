/// local_inference's [ChangeSource] as a Flutter [Listenable].
library;

import 'package:flutter/foundation.dart';
import 'package:local_inference/local_inference.dart';

/// [source] as a [Listenable], for `ListenableBuilder`, `AnimatedBuilder` or `Listenable.merge`. It forwards the
/// listeners as they are, with no wrapper per listener. Two instances over the same source are equal, so a widget
/// that builds a new one each time keeps its subscription.
final class ChangeSourceListenable implements Listenable {
  const ChangeSourceListenable(this.source);

  final ChangeSource source;

  @override
  void addListener(VoidCallback listener) => source.addListener(listener);

  @override
  void removeListener(VoidCallback listener) => source.removeListener(listener);

  @override
  bool operator ==(Object other) => other is ChangeSourceListenable && identical(other.source, source);

  @override
  int get hashCode => identityHashCode(source);
}
