part of 'assistant.dart';

/// One call of [Assistant.sendStreaming]: its visible text as it grows, its events and its outcome.
final class AssistantTurn {
  AssistantTurn._(this._call, this._assistant);

  final _Call _call;
  final Assistant _assistant;

  /// The visible text of the call's replies as it grows, in appended pieces; a reply after the first is preceded by
  /// a blank line, and so is the model's answer after its calls with `ModelWrittenReplies` (the item keeps only the
  /// answer). When a reply's text is replaced by one that does not extend what was sent (a guard, an app-written
  /// reply after streamed text, the error text), nothing more of it is sent: `ReplyReplacedEvent` in [events] and
  /// [TurnOutcome.reply] carry the final text. Single subscription, buffered until listened to; it closes before
  /// [outcome] completes.
  Stream<String> get text => _call.text?.stream ?? const Stream.empty();

  /// The events of this call only, ending with [TurnFinishedEvent]. Single subscription, buffered until listened to;
  /// it closes before [outcome] completes.
  Stream<AssistantEvent> get events => _call.events?.stream ?? const Stream.empty();

  /// What the call did; never fails.
  Future<TurnOutcome> get outcome => _call.outcome.future;

  /// [Assistant.stop], while this call runs.
  void cancel() {
    if (identical(_assistant._call, _call)) _assistant.stop();
  }
}

/// What one accepted call records: its items, screen requests, question and error, and its streams.
final class _Call {
  _Call({required bool streaming})
    : text = streaming ? StreamController<String>() : null,
      events = streaming ? StreamController<AssistantEvent>() : null;

  final StreamController<String>? text;
  final StreamController<AssistantEvent>? events;
  final Completer<TurnOutcome> outcome = Completer<TurnOutcome>();

  final List<int> itemIds = [];
  final List<BoundScreenRequest> screenRequests = [];
  ConfirmationRequest? confirmation;
  Object? error;

  int? _textItem;
  String _sent = '';
  bool _anySent = false;
  final Set<int> _diverged = {};

  void event(AssistantEvent event) => events?.add(event);

  /// The model writes item [itemId] again from the start (the next round of `ModelWrittenReplies`): its new text is
  /// sent after a blank line, as another reply's is.
  void restart(int itemId) {
    _diverged.remove(itemId);
    if (_textItem == itemId) _textItem = null;
  }

  /// The assistant item [itemId] shows [next]: send what extends what was sent for it.
  void textChanged(int itemId, String next) {
    final stream = text;
    if (stream == null || _diverged.contains(itemId)) return;
    if (_textItem != itemId) {
      if (next.isEmpty) return;
      _textItem = itemId;
      _sent = '';
      if (_anySent) stream.add('\n\n');
    }
    if (!next.startsWith(_sent)) {
      _diverged.add(itemId);
      return;
    }
    if (next.length > _sent.length) {
      stream.add(next.substring(_sent.length));
      _sent = next;
      _anySent = true;
    }
  }

  /// Closes the streams, then completes [outcome] (after their listeners got the done event).
  void complete(TurnOutcome result) {
    final waits = <Future<void>>[];
    for (final controller in <StreamController<Object?>?>[text, events]) {
      if (controller == null) continue;
      final listened = controller.hasListener;
      final closed = controller.close();
      if (listened) waits.add(closed);
    }
    if (waits.isEmpty) {
      outcome.complete(result);
    } else {
      unawaited(
        Future.wait(waits).then((_) => outcome.complete(result), onError: (Object _) => outcome.complete(result)),
      );
    }
  }
}

/// The open question.
final class _Pending {
  _Pending({
    required this.userText,
    required this.call,
    required this.spec,
    required this.itemId,
    required this.question,
    this.binding,
    this.modelContext,
    this.modelAfter = const [],
    this.outcomes = const [],
    this.round = 0,
  });

  /// The user's text of the turn that asked; `''` when earlier replies of that turn went into their own entry.
  final String userText;
  final ToolCall call;
  final ToolSpec? spec;
  final int itemId;
  final String question;

  /// What the call's item number named when it asked.
  final ItemBinding? binding;

  /// With `ModelWrittenReplies`: the messages up to the call's result (the model's calls and the results of those
  /// before it), the results of the calls after it (not run), the outcomes of the calls that ran, and the round.
  final List<ChatMessage>? modelContext;
  final List<ChatMessage> modelAfter;
  final List<ToolOutcome> outcomes;
  final int round;

  Map<String, Object?> toJson() => {
    'userText': userText,
    'call': call.toJson(),
    'itemId': itemId,
    'question': question,
    'binding': ?binding?.toJson(),
  };
}

/// The call a reply offered, and what its item number named then.
final class _Offer {
  _Offer(this.call, this.binding);

  final ToolCall call;
  final ItemBinding? binding;

  Map<String, Object?> toJson() => {'call': call.toJson(), 'binding': ?binding?.toJson()};
}

/// A call's written reply: history text, display text, and the call it offers.
typedef _Written = ({String text, String display, ToolCall? offer});
