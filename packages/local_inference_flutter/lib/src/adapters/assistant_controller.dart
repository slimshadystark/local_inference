/// Fine-grained Flutter listenables over local_inference's [Assistant].
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show TextEditingController;
import 'package:local_inference/local_inference.dart';

import 'analytics.dart';

/// What the composer needs: whether a message can be sent now, and whether a turn runs.
@immutable
final class ComposerState {
  const ComposerState({required this.canSend, required this.isBusy});

  final bool canSend;
  final bool isBusy;

  @override
  bool operator ==(Object other) => other is ComposerState && other.canSend == canSend && other.isBusy == isBusy;

  @override
  int get hashCode => Object.hash(canSend, isBusy);

  @override
  String toString() => 'ComposerState(canSend: $canSend, isBusy: $isBusy)';
}

/// An [Assistant] as Flutter listenables, each notifying only when its own value changes: while a reply streams,
/// only its item's listenable fires, so only that message rebuilds.
///
/// It also keeps what must survive a chat page that is closed and opened again: the composer's [draft], and whether
/// the dismissible disclosure was closed. Create it above the Navigator (in `LocalInferenceScope`, a provider or
/// `main`), not in a page.
///
/// As a [Listenable] it fires once per change of the assistant (once per streamed piece of text), after the
/// fine-grained listenables are up to date.
final class AssistantController implements Listenable {
  /// Borrows [assistant]: [dispose] detaches and leaves the assistant to its owner.
  AssistantController(Assistant assistant) : this._(assistant, owns: false);

  /// Owns [assistant]: [dispose] also disposes it and its model.
  AssistantController.owning(Assistant assistant) : this._(assistant, owns: true);

  AssistantController._(this.assistant, {required bool owns})
    : ownsAssistant = owns,
      _current = assistant.state,
      _state = ValueNotifier(assistant.state),
      _phase = ValueNotifier(assistant.state.phase),
      _composer = ValueNotifier(_composerOf(assistant.state)),
      _itemIds = ValueNotifier(List.unmodifiable([for (final item in assistant.state.items) item.id])),
      _pendingActions = ValueNotifier(assistant.state.pendingActions) {
    assistant.addListener(_sync);
    _subscription = assistant.events.listen(_onEvent);
  }

  /// The core assistant: its full API (snapshots, reconfiguration) for what this controller does not wrap.
  final Assistant assistant;

  /// Whether [dispose] disposes [assistant].
  final bool ownsAssistant;

  /// The composer's text; it outlives the chat views that show it.
  final TextEditingController draft = TextEditingController();

  /// Whether the user closed the dismissible AI disclosure in this session.
  final ValueNotifier<bool> disclosureDismissed = ValueNotifier(false);

  AssistantState _current;
  final ValueNotifier<AssistantState> _state;
  final ValueNotifier<AssistantPhase> _phase;
  final ValueNotifier<ComposerState> _composer;
  final ValueNotifier<List<int>> _itemIds;
  final ValueNotifier<List<ChatAction>> _pendingActions;
  final Map<int, ValueNotifier<ChatItem>> _items = {};
  final _Coarse _coarse = _Coarse();
  final StreamController<ChatAnalyticsEvent> _analytics = StreamController.broadcast();
  late final StreamSubscription<AssistantEvent> _subscription;
  Future<bool> Function()? _retryFallback;
  bool _disposed = false;

  // Analytics bookkeeping.
  DateTime? _loadStarted;
  bool _prefixBuilt = false;
  DateTime? _turnStarted;
  int _turnTools = 0;
  bool _turnStopped = false;

  /// The whole state, after every change (once per streamed piece of text).
  ValueListenable<AssistantState> get state => _state;

  /// The phase; fires when it changes.
  ValueListenable<AssistantPhase> get phase => _phase;

  /// Whether a message can be sent and whether a turn runs; fires when either changes.
  ValueListenable<ComposerState> get composer => _composer;

  /// The ids of the chat's items, oldest first; fires when items are added, removed or reordered, not when their
  /// text changes.
  ValueListenable<List<int>> get itemIds => _itemIds;

  /// The open question's buttons; fires when they change.
  ValueListenable<List<ChatAction>> get pendingActions => _pendingActions;

  /// Item [id]; fires only when that item changes. The same listenable for every call while the item is in the
  /// chat. Throws [ArgumentError] for an id the chat does not have.
  ValueListenable<ChatItem> item(int id) {
    final existing = _items[id];
    if (existing != null) return existing;
    final current = _current.item(id);
    if (current == null) throw ArgumentError.value(id, 'id', 'no item with this id in the conversation');
    return _items[id] = ValueNotifier(current);
  }

  /// The assistant's events (asynchronous, broadcast).
  Stream<AssistantEvent> get events => assistant.events;

  /// Usage events for analytics (asynchronous, broadcast); none carries message text.
  Stream<ChatAnalyticsEvent> get analytics => _analytics.stream;

  /// The host side of the assistant, for the app's own screens.
  ToolHost get toolHost => assistant;

  @override
  void addListener(VoidCallback listener) => _coarse.addListener(listener);

  @override
  void removeListener(VoidCallback listener) => _coarse.removeListener(listener);

  // -------------------------------------------------------------------------------------------------------------------
  // Actions
  // -------------------------------------------------------------------------------------------------------------------

  /// Sends [text] ([Assistant.send]); [fromSuggestion] marks a suggestion chip in the analytics.
  Future<TurnOutcome> send(String text, {bool fromSuggestion = false}) {
    final trimmed = text.trim();
    // Read before the call: the assistant is busy as soon as it accepts.
    final accepted = trimmed.isNotEmpty && _current.canSend;
    final outcome = assistant.send(trimmed);
    if (accepted) track(MessageSentEvent(length: trimmed.length, fromSuggestion: fromSuggestion));
    return outcome;
  }

  /// Answers the open question with [action] ([Assistant.act]).
  Future<TurnOutcome> act(ChatAction action) {
    final accepted = _current.canSend && _current.pendingConfirmation != null;
    final outcome = assistant.act(action);
    if (accepted) track(ConfirmationAnsweredEvent(yes: action.kind == ChatActionKind.confirm));
    return outcome;
  }

  /// Stops the running turn ([Assistant.stop]).
  void stop() {
    if (!_current.isBusy) return;
    _turnStopped = true;
    assistant.stop();
    track(GenerationStoppedEvent());
  }

  /// Starts a new conversation ([Assistant.newConversation]); false while a turn runs.
  bool newConversation({String? id}) => assistant.newConversation(id: id);

  /// Loads [path] ([Assistant.loadModel]).
  Future<bool> loadModel(String path, {ModelIdentity? identity}) => assistant.loadModel(path, identity: identity);

  /// Frees the model ([Assistant.unloadModel]).
  Future<bool> unloadModel() => assistant.unloadModel();

  /// Loads the model again after a failure: the last model loaded when there is one; else a `ModelSetupController`
  /// attached to this controller looks for its models again and loads the first. False when nothing was loaded.
  Future<bool> retryLoad() async {
    final path = _current.modelPath;
    if (path != null) return assistant.loadModel(path);
    final fallback = _retryFallback;
    return fallback == null ? false : fallback();
  }

  /// Whether [request] can still open what it named ([ToolHost.isScreenRequestCurrent]).
  bool isScreenRequestCurrent(BoundScreenRequest request) => assistant.isScreenRequestCurrent(request);

  /// Adds [event] to [analytics]: for a custom UI that reports what the package's widgets report.
  void track(ChatAnalyticsEvent event) {
    if (!_analytics.isClosed) _analytics.add(event);
  }

  /// What [retryLoad] does when no model was loaded yet; set by a `ModelSetupController`.
  @internal
  set retryFallback(Future<bool> Function()? fallback) => _retryFallback = fallback;

  @internal
  Future<bool> Function()? get retryFallback => _retryFallback;

  // -------------------------------------------------------------------------------------------------------------------
  // Synchronization
  // -------------------------------------------------------------------------------------------------------------------

  static ComposerState _composerOf(AssistantState state) => ComposerState(canSend: state.canSend, isBusy: state.isBusy);

  /// One notification of the assistant: each listenable gets its new value if it changed. Items compare by identity
  /// (the assistant replaces an item it changes and keeps the others).
  void _sync() {
    if (_disposed) return;
    final state = assistant.state;
    _current = state;
    if (_items.isNotEmpty) {
      var present = 0;
      for (final item in state.items) {
        final notifier = _items[item.id];
        if (notifier == null) continue;
        present++;
        if (!identical(notifier.value, item)) notifier.value = item;
      }
      if (present != _items.length) {
        final ids = {for (final item in state.items) item.id};
        _items.removeWhere((id, _) => !ids.contains(id));
      }
    }
    if (!_sameIds(state.items, _itemIds.value)) {
      _itemIds.value = List.unmodifiable([for (final item in state.items) item.id]);
    }
    _phase.value = state.phase;
    _composer.value = _composerOf(state);
    if (!listEquals(_pendingActions.value, state.pendingActions)) _pendingActions.value = state.pendingActions;
    _state.value = state;
    _coarse.fire();
  }

  static bool _sameIds(List<ChatItem> items, List<int> ids) {
    if (items.length != ids.length) return false;
    for (var i = 0; i < ids.length; i++) {
      if (items[i].id != ids[i]) return false;
    }
    return true;
  }

  void _onEvent(AssistantEvent event) {
    final now = DateTime.now();
    switch (event) {
      case PhaseChangedEvent(phase: AssistantPhase.loading):
        _loadStarted ??= now;
        _prefixBuilt = false;
      case PhaseChangedEvent(phase: AssistantPhase.preparing):
        _prefixBuilt = true;
      case PhaseChangedEvent(phase: AssistantPhase.ready):
        final started = _loadStarted;
        if (started != null) track(ModelLoadedEvent(duration: now.difference(started), prefixBuilt: _prefixBuilt));
        _loadStarted = null;
      case PhaseChangedEvent(phase: AssistantPhase.failed, :final error):
        track(ModelLoadFailedEvent(errorType: '${error.runtimeType}'));
        _loadStarted = null;
      case PhaseChangedEvent(phase: AssistantPhase.busy):
        _turnStarted ??= now;
      case ToolStartedEvent(:final source) when source != ToolCallSource.host:
        _turnTools++;
      case TurnFinishedEvent(:final outcome):
        final started = _turnStarted;
        track(
          TurnCompletedEvent(
            duration: started == null ? Duration.zero : now.difference(started),
            toolCalls: _turnTools,
            stopped: _turnStopped,
            failed: outcome.error != null,
          ),
        );
        _turnStarted = null;
        _turnTools = 0;
        _turnStopped = false;
      case ConversationChangedEvent(change: ConversationChange.cleared, :final conversationId):
        track(ConversationStartedEvent(conversationId: conversationId));
      default:
        break;
    }
  }

  // -------------------------------------------------------------------------------------------------------------------
  // Disposal
  // -------------------------------------------------------------------------------------------------------------------

  /// Detaches from the assistant and frees the listenables and the [draft]; an owned assistant is disposed too.
  /// Dispose it after the widgets that listen to it.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    assistant.removeListener(_sync);
    await _subscription.cancel();
    for (final notifier in <ChangeNotifier>[_state, _phase, _composer, _itemIds, _pendingActions, ..._items.values]) {
      notifier.dispose();
    }
    _items.clear();
    _coarse.dispose();
    draft.dispose();
    disclosureDismissed.dispose();
    await _analytics.close();
    if (ownsAssistant) await assistant.dispose();
  }

  @override
  String toString() => 'AssistantController(${_current.phase.name}, ${_current.items.length} items)';
}

final class _Coarse extends ChangeNotifier {
  void fire() => notifyListeners();
}
