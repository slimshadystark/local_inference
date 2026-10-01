/// The FIFO operation queue and the queued generation that the engines share. Internal and engine-agnostic, so it is
/// tested without a runtime.
library;

import 'dart:async';
import 'dart:collection';

import 'exceptions.dart';
import 'generation.dart';

/// Runs operations one at a time, in call order: each starts once the previous one has finished, whatever its
/// outcome. llamadart rejects a second generation while one runs (llama_cpp_backend.dart:333-337).
final class SerialQueue {
  final Queue<_Operation> _waiting = Queue<_Operation>();
  _Operation? _running;
  Future<void>? _runningDone;
  bool _closed = false;

  /// Whether [close] was called.
  bool get isClosed => _closed;

  /// Queues [body] and returns its outcome. An idle queue starts it before returning. Throws [StateError] once the
  /// queue is closed.
  Future<T> run<T>(Future<T> Function() body) {
    final operation = _Call<T>(body);
    _add(operation);
    return operation.completer.future;
  }

  /// Queues [generation]: in its turn [body] runs, unless the generation was cancelled while it waited, and the
  /// stats it returns complete the generation; an error it throws fails it. Throws [StateError] once the queue is
  /// closed.
  void runGeneration(QueuedGeneration generation, Future<GenerationStats> Function() body) {
    _add(_GenerationCall(generation, body));
  }

  /// Closes the queue: waiting generations complete as cancelled, other waiting operations fail with [StateError],
  /// and a running generation is cancelled. Completes when the running operation has finished.
  Future<void> close() {
    if (!_closed) {
      _closed = true;
      while (_waiting.isNotEmpty) {
        _waiting.removeFirst().drop();
      }
      final running = _running;
      if (running is _GenerationCall) running.generation.cancel();
    }
    return _runningDone ?? Future<void>.value();
  }

  void _add(_Operation operation) {
    if (_closed) throw StateError('the engine is disposed');
    _waiting.add(operation);
    _next();
  }

  void _next() {
    if (_running != null || _waiting.isEmpty) return;
    final operation = _running = _waiting.removeFirst();
    _runningDone = operation.start().whenComplete(() {
      _running = null;
      _runningDone = null;
      _next();
    });
  }
}

/// A queued operation. [start] never throws: the outcome goes to the operation's own future.
sealed class _Operation {
  Future<void> start();

  /// The queue closed before the operation ran.
  void drop();
}

final class _Call<T> extends _Operation {
  _Call(this._body);

  final Future<T> Function() _body;
  final Completer<T> completer = Completer<T>();

  @override
  Future<void> start() async {
    try {
      completer.complete(await _body());
    } catch (error, stackTrace) {
      completer.completeError(error, stackTrace);
    }
  }

  @override
  void drop() => completer.completeError(StateError('the engine was disposed before this call ran'));
}

final class _GenerationCall extends _Operation {
  _GenerationCall(this.generation, this._body);

  final QueuedGeneration generation;
  final Future<GenerationStats> Function() _body;

  @override
  Future<void> start() async {
    if (!generation._begin()) return;
    try {
      generation._complete(await _body());
    } catch (error, stackTrace) {
      generation._fail(error, stackTrace);
    }
  }

  @override
  void drop() => generation.cancel();
}

/// A [Generation] from the moment it is queued. The engine's body forwards deltas with [emit], checks [isCancelled]
/// before its runtime call, and sets [onCancel] to the runtime's cancel while it streams.
final class QueuedGeneration implements Generation {
  /// [maxTokens] decides [FinishReason.maxTokens]; [emptyStats] are the figures of a generation that never ran.
  QueuedGeneration({required this.maxTokens, required GenerationStats Function() emptyStats})
    : _emptyStats = emptyStats {
    _result.future.ignore();
  }

  final int maxTokens;
  final GenerationStats Function() _emptyStats;
  final StreamController<String> _text = StreamController<String>();
  final Completer<GenerationResult> _result = Completer<GenerationResult>();
  final StringBuffer _buffer = StringBuffer();
  bool _started = false;
  bool _finished = false;
  bool _cancelled = false;
  void Function()? _onCancel;

  @override
  Stream<String> get text => _text.stream;

  @override
  Future<GenerationResult> get result => _result.future;

  /// Whether [cancel] was called.
  bool get isCancelled => _cancelled;

  /// Called by [cancel] while the body streams; the body sets it around its runtime call.
  set onCancel(void Function()? callback) => _onCancel = callback;

  @override
  void cancel() {
    if (_cancelled || _finished) return;
    _cancelled = true;
    if (!_started) {
      _finish(_emptyStats());
    } else {
      _onCancel?.call();
    }
  }

  /// Forwards one delta of the output.
  void emit(String delta) {
    if (_finished) return;
    _buffer.write(delta);
    _text.add(delta);
  }

  /// Marks the generation dequeued; false when it was cancelled while it waited.
  bool _begin() {
    if (_finished) return false;
    _started = true;
    return true;
  }

  void _complete(GenerationStats stats) {
    _onCancel = null;
    _finish(stats);
  }

  void _fail(Object error, StackTrace stackTrace) {
    _onCancel = null;
    if (_finished) return;
    _finished = true;
    final failure = error is GenerationException ? error : GenerationException('generation failed', cause: error);
    _text.addError(failure, stackTrace);
    _settle(() => _result.completeError(failure, stackTrace));
  }

  void _finish(GenerationStats stats) {
    if (_finished) return;
    _finished = true;
    final reason = _cancelled
        ? FinishReason.cancelled
        : stats.decodeTokens >= maxTokens
        ? FinishReason.maxTokens
        : FinishReason.stop;
    final result = GenerationResult(text: _buffer.toString(), finishReason: reason, stats: stats);
    _settle(() => _result.complete(result));
  }

  /// Closes [text], then completes [result]: after a listener has received the last event, or at once without one.
  void _settle(void Function() completeResult) {
    final listened = _text.hasListener;
    final closed = _text.close();
    if (listened) {
      unawaited(closed.then((_) => completeResult(), onError: (Object _, StackTrace _) => completeResult()));
    } else {
      completeResult();
    }
  }
}
