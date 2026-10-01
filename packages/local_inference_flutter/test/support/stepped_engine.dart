// A scripted engine whose generations a test drives delta by delta.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_inference/testing.dart';
import 'package:local_inference_flutter/local_inference_flutter.dart';

/// A generation whose deltas the test sends one by one.
final class _Manual implements Generation {
  _Manual(this._text, this._result);

  final StreamController<String> _text;
  final Completer<GenerationResult> _result;

  @override
  Stream<String> get text => _text.stream;

  @override
  Future<GenerationResult> get result => _result.future;

  @override
  void cancel() {}
}

/// A scripted engine whose generations the test drives once [stepped]: [send] one delta, then [finish].
final class SteppedEngine extends ScriptedEngine {
  SteppedEngine() : super(supportsStatePersistence: false);

  StreamController<String>? _live;
  Completer<GenerationResult>? _done;
  final StringBuffer _sent = StringBuffer();

  bool stepped = false;

  /// A generation waits for deltas.
  bool get live => _live != null && !_live!.isClosed;

  @override
  Generation generate(String prompt, [GenerationOptions options = const GenerationOptions()]) {
    if (!stepped) return super.generate(prompt, options);
    _sent.clear();
    return _Manual(_live = StreamController<String>(), _done = Completer<GenerationResult>());
  }

  void send(String delta) {
    _sent.write(delta);
    _live!.add(delta);
  }

  Future<void> finish() async {
    await _live!.close();
    _done!.complete(
      GenerationResult(
        text: '$_sent',
        finishReason: FinishReason.stop,
        stats: const GenerationStats(
          loadMs: 0,
          promptTokens: 1,
          prefillTokens: 1,
          prefillMs: 0,
          decodeTokens: 50,
          decodeMs: 0,
          timeToFirstTokenMs: 0,
          totalMs: 0,
        ),
      ),
    );
  }
}

/// Lets the turn started by a send reach the engine: short real waits and frames until the generation is [live].
Future<void> pumpUntilLive(WidgetTester tester, SteppedEngine engine) async {
  for (var i = 0; i < 300 && !engine.live; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    await tester.pump();
  }
  expect(engine.live, isTrue, reason: 'the generation started');
}
