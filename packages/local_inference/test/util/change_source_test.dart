// ChangeListeners, the listener list behind every ChangeSource of the package: ChangeNotifier's order and reentrancy
// rules, without Flutter.
import 'dart:async';

import 'package:local_inference/src/util/change_source.dart';
import 'package:test/test.dart';

void main() {
  test('notify calls the listeners in the order they were added; a listener added twice runs twice', () {
    final listeners = ChangeListeners();
    final calls = <String>[];
    void a() => calls.add('a');
    void b() => calls.add('b');
    listeners
      ..add(a)
      ..add(b)
      ..add(a)
      ..notify();
    expect(calls, ['a', 'b', 'a']);
    calls.clear();
    listeners
      ..remove(a)
      ..notify();
    expect(calls, ['b', 'a'], reason: 'remove takes out the first registration only');
    listeners
      ..remove(a)
      ..remove(b)
      ..remove(b);
    expect(listeners.isEmpty, isTrue);
  });

  test('a listener removed during a notification is skipped if its turn has not come; one added waits', () {
    final listeners = ChangeListeners();
    final calls = <String>[];
    void c() => calls.add('c');
    void late() => calls.add('late');
    void b() {
      calls.add('b');
      listeners
        ..remove(c)
        ..add(late);
    }

    void a() => calls.add('a');
    listeners
      ..add(a)
      ..add(b)
      ..add(c)
      ..notify();
    expect(calls, ['a', 'b']);
    calls.clear();
    listeners.notify();
    expect(calls, ['a', 'b', 'late'], reason: 'c is gone and late now runs; b adds late once more');
  });

  test('a listener that throws reaches the zone and the others still run; clear empties the list', () async {
    final listeners = ChangeListeners();
    final calls = <String>[];
    final errors = <Object>[];
    listeners
      ..add(() => throw StateError('listener failed'))
      ..add(() => calls.add('after'));
    runZonedGuarded(listeners.notify, (error, _) => errors.add(error));
    expect(calls, ['after']);
    expect(errors.single, isA<StateError>());

    var cleared = 0;
    listeners
      ..clear()
      ..add(() {
        cleared++;
        listeners.clear();
      })
      ..add(() => cleared++)
      ..notify();
    expect(cleared, 1, reason: 'clear during a notification skips the listeners still to come');
    expect(listeners.isEmpty, isTrue);
  });
}
