import 'package:test/test.dart';

/// Waits up to about 2 s, in 2 ms steps, for [condition]; then expects it.
Future<void> until(bool Function() condition, {String? reason}) async {
  for (var i = 0; i < 1000 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  expect(condition(), isTrue, reason: reason);
}
