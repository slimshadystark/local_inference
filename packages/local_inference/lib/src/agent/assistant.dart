/// The tool-using assistant (L3): a conversation over a model, with tools, questions before irreversible calls,
/// numbered lists, screen requests, guards, hooks and snapshots.
///
/// Everything domain-specific (tools, prompt, replies, questions, texts) comes from the [AssistantConfig]; the turn
/// order, the listener notifications and the history are the same for every domain (test/agent/assistant_loop_test.dart
/// pins them down).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import '../engine/engine_info.dart';
import '../engine/generation.dart';
import '../engine/inference_engine.dart';
import '../engine/options.dart';
import '../llamadart/llamadart_engine.dart';
import '../model/chat_message.dart';
import '../model/chat_model.dart';
import '../model/json_values.dart';
import '../model/model_profile.dart';
import '../model/prefix/file_prefix_state_store.dart';
import '../model/prefix/model_identity.dart';
import '../model/prefix/prefix_state_store.dart';
import '../model/tool_call.dart';
import '../model/tool_spec.dart';
import '../util/change_source.dart';
import 'config.dart';
import 'confirmation.dart';
import 'events.dart';
import 'guards.dart';
import 'hooks.dart';
import 'lists.dart';
import 'model_view.dart';
import 'replies.dart';
import 'screen_requests.dart';
import 'snapshot.dart';
import 'state.dart';
import 'tool_host.dart';
import 'tool_result.dart';
import 'toolkit.dart';

part 'assistant_turn.dart';

/// A conversation over a local model, with the tools of an [AssistantConfig].
///
/// One call at a time: [send], [sendStreaming], [confirm] and [act] are refused while a turn runs ([TurnRejection]);
/// they never throw. Listeners ([addListener]) run synchronously after every change; [states] and [events] deliver
/// the same asynchronously. A listener must not start a call itself.
///
/// A turn (`send`):
///  1. the text is trimmed; it is refused unless the phase is [AssistantPhase.ready];
///  2. the offer of the last reply is taken (cleared on every message); when its item number still names its item,
///     no question is open and the text is a yes or a no, the offered call runs (or `offerDeclined`), with no model;
///  3. an open question loses its buttons: a yes or a no answers it (`listChanged` when its item number now names
///     another item, else the call runs, or `declined`); any other text drops it (`(its text, declined)` joins the
///     history) and goes on;
///  4. the user item and a thinking assistant item are added; the phase is busy;
///  5. `beforeModel` may answer instead of the model or add context;
///  6. the prompt is the [PromptLayout]'s messages; the model's prefix state is restored first when the context moved;
///  7. the model generates with the lazy tool grammar; its visible text, rewritten, streams into the item;
///  8. a stopped turn keeps the text so far (in the history) or shows `interrupted` (not in the history);
///  9. a plain answer (or `notUnderstood`) is rewritten, checked by the guards and joins the history;
/// 10. each call is coerced, checked (unknown tool, then validation: `missingData`, and the rest is not run), asked
///     about (earlier replies go into their own item and history entry first; the turn ends with the question) or
///     run: status label, `toolStatusDelay`, annotations, execution, lists recorded, the reply written (a follow-up
///     once), the `[tool]` details line, the screen request;
/// 11. the replies are joined (displays by a blank line, texts by a space into the history); the phase is ready.
final class Assistant implements ChangeSource, ToolHost {
  /// An assistant with [config]. Each model loads on a new engine from [engine] with [load]. Prefix states go to
  /// [prefixStore] (default: the system's temporary folder, which phones may empty: pass a caches folder there).
  /// [wallClock] dates conversations (and is the default `today`).
  Assistant(
    AssistantConfig config, {
    EngineFactory engine = LlamadartEngine.new,
    LoadOptions load = const LoadOptions(),
    PrefixStateStore? prefixStore,
    DateTime Function()? wallClock,
  }) : _config = config,
       _engineFactory = engine,
       _load = load,
       _prefixStore = prefixStore ?? temporaryPrefixStateStore(),
       _clock = wallClock ?? DateTime.now,
       _lists = ListLedger(config.listReferences) {
    final now = _clock();
    _conversationId = _newConversationId(now);
    _createdAt = _updatedAt = now;
  }

  AssistantConfig _config;
  final EngineFactory _engineFactory;
  final LoadOptions _load;
  final PrefixStateStore _prefixStore;
  final DateTime Function() _clock;
  final ListLedger _lists;

  InferenceEngine? _engine;
  ChatModel? _model;
  AssistantPhase _phase = AssistantPhase.noModel;
  Object? _loadError;
  String? _modelPath;
  EngineInfo? _info;

  final List<ChatItem> _items = [];
  final List<HistoryEntry> _history = [];
  _Pending? _pending;
  _Offer? _offer;
  late String _conversationId;
  late DateTime _createdAt;
  late DateTime _updatedAt;
  int _nextItemId = 1;
  int _notifications = 0;
  int _structure = 0;

  bool _stopRequested = false;
  ChatGeneration? _generation;
  final Set<ToolContext> _turnTools = {};
  _Call? _call;
  bool _disposed = false;

  final ChangeListeners _listeners = ChangeListeners();
  final StreamController<AssistantState> _states = StreamController<AssistantState>.broadcast();
  final StreamController<AssistantEvent> _events = StreamController<AssistantEvent>.broadcast();
  AssistantState? _state;

  static final math.Random _random = math.Random();

  // -----------------------------------------------------------------------------------------------------------------
  // Observation
  // -----------------------------------------------------------------------------------------------------------------

  /// The behavior in use.
  AssistantConfig get config => _config;

  /// The state now.
  AssistantState get state => _state ??= AssistantState(
    phase: _phase,
    loadError: _loadError,
    items: List.unmodifiable(_items),
    pendingConfirmation: _pendingRequest,
    pendingActions: _pendingActions,
    conversationId: _conversationId,
    modelPath: _modelPath,
    info: _info,
    revision: _notifications,
  );

  /// The state after every change, asynchronously (broadcast).
  Stream<AssistantState> get states => _states.stream;

  /// What happens, asynchronously (broadcast).
  Stream<AssistantEvent> get events => _events.stream;

  /// The conversation as the prompts carry it: (user text, assistant text) pairs, oldest first, before windowing.
  List<HistoryEntry> get history => List.unmodifiable(_history);

  /// The loaded model, read-only; null when none is.
  ModelView? get model => switch (_model) {
    final ChatModel model => ChatModelView(model),
    null => null,
  };

  /// The conversation's day: `AssistantConfig.today`, else the wall clock.
  DateTime get today => _config.today?.call() ?? _clock();

  @override
  void addListener(void Function() listener) => _listeners.add(listener);

  @override
  void removeListener(void Function() listener) => _listeners.remove(listener);

  ConfirmationRequest? get _pendingRequest => switch (_pending) {
    final _Pending pending => ConfirmationRequest(
      itemId: pending.itemId,
      // A copy the host cannot change: a yes runs the pending call itself.
      call: ToolCall(pending.call.name, _frozen(pending.call.arguments) as Map<String, Object?>),
      question: pending.question,
    ),
    null => null,
  };

  /// A deep copy of the JSON value [value] that cannot be changed.
  static Object? _frozen(Object? value) => switch (value) {
    final Map<String, Object?> map => Map<String, Object?>.unmodifiable({
      for (final entry in map.entries) entry.key: _frozen(entry.value),
    }),
    final Map<Object?, Object?> map => Map<Object?, Object?>.unmodifiable({
      for (final entry in map.entries) entry.key: _frozen(entry.value),
    }),
    final List<Object?> list => List<Object?>.unmodifiable([for (final item in list) _frozen(item)]),
    _ => value,
  };

  List<ChatAction> get _pendingActions => switch (_pending) {
    final _Pending pending => _itemOrNull(pending.itemId)?.actions ?? const [],
    null => const [],
  };

  /// Calls the listeners, then gives the state to [states].
  void _notify() {
    _state = null;
    _notifications++;
    final snapshot = _states.hasListener ? state : null;
    _listeners.notify();
    if (snapshot != null && !_states.isClosed) _states.add(snapshot);
  }

  /// Gives [event] to [events] and, unless [call] is false, to the running call's events.
  void _emit(AssistantEvent event, {bool call = true}) {
    if (!_events.isClosed) _events.add(event);
    if (call) _call?.event(event);
  }

  void _setPhase(AssistantPhase phase, {Object? error}) {
    _phase = phase;
    _emit(PhaseChangedEvent(phase, error: error));
    _notify();
  }

  // -----------------------------------------------------------------------------------------------------------------
  // Model
  // -----------------------------------------------------------------------------------------------------------------

  /// Loads [path], replacing the model loaded before: the old engine is disposed, a new one loads the file, the
  /// profile checks its template (and, when the toolkit has tools, that it has a tool-call format: else
  /// [UnsupportedModelException]), then the prefix state of the system prompt and tools is restored (phase loading)
  /// or built (phase preparing, the first time only). A refused or failed model is freed and the phase is failed; the
  /// previous [AssistantState.modelPath] stays. Items and history are kept. [identity] names the file in the
  /// prefix-state keys (default: its name, size and modification time).
  ///
  /// True when the model is ready; false when the call was ignored (loading, preparing or busy) or the load failed.
  Future<bool> loadModel(String path, {ModelIdentity? identity}) async {
    if (_disposed || _phase == AssistantPhase.loading || _phase == AssistantPhase.preparing || _isBusy) return false;
    _loadError = null;
    _setPhase(AssistantPhase.loading);
    InferenceEngine? engine;
    try {
      final old = _engine;
      _engine = null;
      _model = null;
      await old?.dispose();
      engine = _engineFactory();
      await engine.load(path, _load);
      final model = ChatModel.attach(engine, profile: _config.profile, prefixStore: _prefixStore, identity: identity);
      _checkTools(model);
      _engine = engine;
      _model = model;
      _info = engine.info;
      _modelPath = path;
      await _preparePrefix(model);
      _setPhase(AssistantPhase.ready);
      return true;
    } catch (error) {
      // A model that failed to load or was refused is freed; one whose prefix failed stays loaded.
      if (engine != null && !identical(_engine, engine)) engine.dispose().ignore();
      _loadError = error;
      _setPhase(AssistantPhase.failed, error: error);
      return false;
    }
  }

  /// Throws when the toolkit has tools that [model]'s profile cannot give it ([UnsupportedModelException] of a model
  /// with no tool-call format): at load, not at every message.
  void _checkTools(ChatModel model) {
    final specs = _config.toolkit.specs;
    if (specs.isEmpty) return;
    model.prepare(
      [ChatMessage.system(_config.prompt.systemPrompt), ChatMessage.user('.')],
      tools: specs,
      grammar: _config.grammar,
    );
  }

  Future<void> _preparePrefix(ChatModel model) async {
    final watch = Stopwatch()..start();
    final how = await model.preparePrefix(
      systemPrompt: _config.prompt.systemPrompt,
      tools: _config.toolkit.specs,
      onBuild: () => _setPhase(AssistantPhase.preparing),
    );
    _emit(PrefixPreparedEvent(how, watch.elapsed));
  }

  /// Frees the model. False (nothing done) while loading, preparing or busy.
  Future<bool> unloadModel() async {
    if (_disposed || _phase == AssistantPhase.loading || _phase == AssistantPhase.preparing || _isBusy) return false;
    final engine = _engine;
    _engine = null;
    _model = null;
    _modelPath = null;
    _info = null;
    _loadError = null;
    await engine?.dispose();
    _setPhase(AssistantPhase.noModel);
    return true;
  }

  bool get _isBusy => _phase == AssistantPhase.busy;

  // -----------------------------------------------------------------------------------------------------------------
  // Conversation
  // -----------------------------------------------------------------------------------------------------------------

  /// Sends [text]; the returned turn streams its visible text and events. See the class comment for the steps.
  AssistantTurn sendStreaming(String text) => _startSend(text, streaming: true);

  /// Sends [text] and completes when the turn ends.
  Future<TurnOutcome> send(String text) => _startSend(text, streaming: false).outcome;

  AssistantTurn _startSend(String text, {required bool streaming}) {
    final call = _Call(streaming: streaming);
    final trimmed = text.trim();
    final rejection = trimmed.isEmpty
        ? TurnRejection.empty
        : _isBusy
        ? TurnRejection.busy
        : _phase != AssistantPhase.ready || _disposed
        ? TurnRejection.notReady
        : null;
    if (rejection != null) {
      call.complete(TurnOutcome(rejection: rejection));
    } else {
      unawaited(_run(call, () => _send(trimmed)));
    }
    return AssistantTurn._(call, this);
  }

  /// Answers the open question: yes runs its call, no declines it (as the buttons do, adding the user item
  /// `strings.yes` or `strings.no`).
  Future<TurnOutcome> confirm(bool yes) {
    final call = _Call(streaming: false);
    final rejection = _isBusy
        ? TurnRejection.busy
        : _phase != AssistantPhase.ready || _disposed
        ? TurnRejection.notReady
        : _pending == null
        ? TurnRejection.noQuestion
        : null;
    if (rejection != null) {
      call.complete(TurnOutcome(rejection: rejection));
    } else {
      unawaited(_run(call, () => _answerButton(yes)));
    }
    return call.outcome.future;
  }

  /// Performs [action]: [confirm] with its kind.
  Future<TurnOutcome> act(ChatAction action) => confirm(action.kind == ChatActionKind.confirm);

  /// Stops the running turn: the generation stops (before its engine call when it has not started), the turn ends
  /// as interrupted when the model was writing, and each running tool's `ToolContext.cancelled` completes. A tool,
  /// an offer or a confirmation already running goes on to its reply (with `ModelWrittenReplies`, the model does not
  /// write it: see there). Does nothing unless busy.
  void stop() {
    if (!_isBusy) return;
    _stopRequested = true;
    _generation?.cancel();
    for (final context in _turnTools) {
      context.cancel();
    }
  }

  /// Starts a new conversation (id [id], else a new one): items, history, lists, question and offer go, and the
  /// toolkit is reset. False while busy.
  bool newConversation({String? id}) {
    if (_disposed || _isBusy) return false;
    _clearConversation(id: id);
    _notify();
    _emit(ConversationChangedEvent(ConversationChange.cleared, _conversationId), call: false);
    return true;
  }

  void _clearConversation({String? id}) {
    _items.clear();
    _history.clear();
    _lists.clear();
    _pending = null;
    _offer = null;
    _config.toolkit.reset();
    final now = _clock();
    _conversationId = id ?? _newConversationId(now);
    _createdAt = _updatedAt = now;
    _structure++;
    _state = null;
  }

  /// Uses [toolkit] from the next turn (the engine stays). A new conversation starts unless [keepConversation]; with
  /// it, items, history and lists stay, and an open question or offer is dropped as a screen action drops it. A model
  /// that is loaded gets the prefix state of the new tools (phase loading, or preparing when it is built). False while
  /// busy, loading or preparing.
  Future<bool> setToolkit(Toolkit toolkit, {bool keepConversation = false}) =>
      _reconfigure(_config.copyWith(toolkit: toolkit), keepConversation: keepConversation);

  /// Uses [next] from the next turn; the engine and the model's profile stay. When the system prompt or the tool specs
  /// changed, a new conversation starts and a loaded model gets the new prefix state (phase loading, or preparing
  /// when it is built); otherwise the conversation goes on. False while busy, loading or preparing.
  Future<bool> reconfigure(AssistantConfig next) => _reconfigure(next, keepConversation: null);

  Future<bool> _reconfigure(AssistantConfig next, {required bool? keepConversation}) async {
    if (_disposed || _isBusy || _phase == AssistantPhase.loading || _phase == AssistantPhase.preparing) return false;
    final old = _config;
    final prefixChanged =
        next.prompt.systemPrompt != old.prompt.systemPrompt || !_sameSpecs(next.toolkit.specs, old.toolkit.specs);
    _config = next;
    _lists.references = next.listReferences;
    final clear = keepConversation == null ? prefixChanged : !keepConversation;
    if (clear) {
      _clearConversation();
      _notify();
      _emit(ConversationChangedEvent(ConversationChange.cleared, _conversationId), call: false);
    } else if (keepConversation == true) {
      _offer = null;
      if (_pending != null) {
        _clearPendingButtons();
        _dropPending();
      }
    }
    final model = _model;
    if (prefixChanged && model != null && (_phase == AssistantPhase.ready || _phase == AssistantPhase.failed)) {
      _loadError = null;
      _setPhase(AssistantPhase.loading);
      try {
        _checkTools(model);
        await _preparePrefix(model);
        _setPhase(AssistantPhase.ready);
      } catch (error) {
        _loadError = error;
        _setPhase(AssistantPhase.failed, error: error);
        return false;
      }
    }
    return true;
  }

  static bool _sameSpecs(List<ToolSpec> a, List<ToolSpec> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      final x = a[i];
      final y = b[i];
      if (identical(x, y)) continue;
      if (x.name != y.name ||
          x.description != y.description ||
          x.sideEffect != y.sideEffect ||
          !jsonEquals(x.parameters, y.parameters) ||
          !jsonEquals(x.promptDeclaration, y.promptDeclaration)) {
        return false;
      }
    }
    return true;
  }

  // -----------------------------------------------------------------------------------------------------------------
  // Calls: send, confirm
  // -----------------------------------------------------------------------------------------------------------------

  /// Runs an accepted call's [body], then records its outcome and ends its events and streams.
  Future<void> _run(_Call call, Future<void> Function() body) async {
    _call = call;
    _stopRequested = false;
    try {
      await body();
    } catch (error, stackTrace) {
      // A failure outside the turn's own handling: report it and leave the assistant usable.
      call.error ??= error;
      _emit(TurnFailedEvent(error, stackTrace));
      if (_isBusy) _setPhase(AssistantPhase.ready);
    }
    _updatedAt = _clock();
    final outcome = TurnOutcome(
      items: List.unmodifiable([for (final id in call.itemIds) ?_itemOrNull(id)]),
      confirmation: call.confirmation,
      screenRequests: List.unmodifiable(call.screenRequests),
      error: call.error,
    );
    for (final event in [
      ConversationChangedEvent(ConversationChange.exchange, _conversationId),
      TurnFinishedEvent(outcome),
    ]) {
      if (!_events.isClosed) _events.add(event);
      call.event(event);
    }
    if (identical(_call, call)) _call = null;
    call.complete(outcome);
  }

  /// The turn of [send], from the text trimmed.
  Future<void> _send(String text) async {
    final strings = _config.strings;
    final offer = _offer;
    final offerCurrent = _lists.stillNames(offer?.binding);
    _offer = null;
    // An offer whose item number a screen has renumbered meanwhile is not run: the text goes to the model.
    if (offer != null && offerCurrent && _pending == null) {
      final answer = strings.yesNo.parse(text);
      if (answer != null) return _answerOffer(text, offer, answer);
    }
    final pending = _pending;
    if (pending != null) {
      final answer = strings.yesNo.parse(text);
      _clearPendingButtons();
      if (answer != null) {
        _add(MessageRole.user, text: text);
        _notify();
        return _resolvePending(answer);
      }
      _dropPending();
    }
    _add(MessageRole.user, text: text);
    final reply = _add(MessageRole.assistant, thinking: true);
    _stopRequested = false;
    _setPhase(AssistantPhase.busy);
    try {
      await _modelTurn(text, reply);
    } catch (error, stackTrace) {
      _change(reply, thinking: false, status: null, text: strings.error, details: '$error', source: ReplySource.error);
      _failed(error, stackTrace);
    }
    _setPhase(AssistantPhase.ready);
  }

  /// A tap on Yes or No (or [confirm]).
  Future<void> _answerButton(bool yes) async {
    _clearPendingButtons();
    _add(MessageRole.user, text: yes ? _config.strings.yes : _config.strings.no);
    _notify();
    await _resolvePending(yes);
  }

  void _failed(Object error, StackTrace stackTrace) {
    _call?.error = error;
    _emit(TurnFailedEvent(error, stackTrace));
  }

  // -----------------------------------------------------------------------------------------------------------------
  // The model turn
  // -----------------------------------------------------------------------------------------------------------------

  Future<void> _modelTurn(String text, int reply) async {
    final model = _model!;
    var extra = const <String>[];
    final hook = _config.beforeModel;
    if (hook != null) {
      final directive = await hook(TurnRequest(text: text, window: _config.prompt.window(_history), today: today));
      if (_stopRequested) {
        _interrupted(text, reply);
        return;
      }
      switch (directive) {
        case AnswerDirective(text: final answer):
          _change(reply, thinking: false, text: answer, source: ReplySource.app);
          _history.add(HistoryEntry(text, answer));
          return;
        case ContextDirective(:final context):
          extra = context;
        case null:
          break;
      }
    }
    final watch = Stopwatch()..start();
    final messages = _config.prompt.messages(text, history: _history, today: today, extraContext: extra);
    final result = await _generate(model, messages, reply, watch);
    if (_stopRequested) {
      _interrupted(text, reply);
      return;
    }
    if (!result.hasToolCalls) return _answer(text, result, reply);
    switch (_config.replies) {
      case AppWrittenReplies(:final writer):
        await _runCalls(text, result.toolCalls, reply, writer);
      case final ModelWrittenReplies strategy:
        await _modelRounds(text, messages, result, reply, strategy, watch);
    }
  }

  /// One generation into [reply]: its visible text, rewritten, streams into the item; then the timing line and the
  /// raw output go into the details (after the earlier ones when [append]).
  Future<ChatResult> _generate(
    ChatModel model,
    List<ChatMessage> messages,
    int reply,
    Stopwatch watch, {
    ToolMode mode = ToolMode.auto,
    bool append = false,
  }) async {
    var raw = '';
    final generation = _generation = model.generate(
      messages,
      tools: _config.toolkit.specs,
      toolMode: mode,
      grammar: _config.grammar,
      sampling: _config.sampling,
    );
    // A stop that came first cancels it before its engine call.
    if (_stopRequested) generation.cancel();
    await for (final delta in generation.raw) {
      raw += delta;
      final shown = model.profile.visibleText(raw, generation.prompt);
      final visible = shown == null ? null : _rewrite(shown);
      if (visible != null && visible != _item(reply).text) {
        _change(reply, thinking: visible.isEmpty, text: visible, source: ReplySource.model);
        _notify();
      }
    }
    final result = await generation.result;
    final stats = result.stats;
    final timing =
        'restore ${result.restore.inMilliseconds}ms · prompt ${stats.promptTokens} tok '
        '(prefill ${stats.prefillTokens}, '
        '${stats.prefillMs.toStringAsFixed(0)}ms) · ttft ${stats.timeToFirstTokenMs.toStringAsFixed(0)}ms · '
        '${stats.decodeTokens} tok ${stats.decodeTokensPerSecond.toStringAsFixed(1)} tok/s · '
        'total ${watch.elapsedMilliseconds}ms';
    final details = '$timing\n${raw.trim()}';
    final before = _item(reply).details;
    _change(reply, details: append && before != null ? '$before\n$details' : details, stats: stats);
    return result;
  }

  String _rewrite(String text) => _config.rewriter?.call(text) ?? text;

  /// The stopped turn: the text so far (into the history), or `interrupted`.
  void _interrupted(String text, int reply) {
    final current = _item(reply).text;
    final shown = current.isEmpty ? _config.strings.interrupted : current;
    _change(reply, thinking: false, text: shown, source: current.isEmpty ? ReplySource.app : ReplySource.model);
    if (shown != _config.strings.interrupted) _history.add(HistoryEntry(text, shown));
  }

  /// A plain answer: rewritten, `notUnderstood` when empty or malformed, checked by the guards; into the history.
  Future<void> _answer(String text, ChatResult result, int reply, {List<ToolOutcome> outcomes = const []}) async {
    final strings = _config.strings;
    var answer = _rewrite(result.text);
    var source = ReplySource.model;
    String? guardLine;
    if (result.parseError != null || answer.isEmpty) {
      answer = strings.notUnderstood;
      source = ReplySource.app;
    } else {
      final context = GuardContext(userText: text, window: _config.prompt.window(_history), toolOutcomes: outcomes);
      for (final guard in _config.guards) {
        final checked = guard.check(answer, context);
        final verdict = checked is Future<GuardVerdict?> ? await checked : checked;
        if (verdict == null) continue;
        guardLine = '[guard] ${verdict.note}';
        answer = verdict.replacement;
        source = ReplySource.guard;
        break;
      }
    }
    final details = _item(reply).details;
    _change(
      reply,
      thinking: false,
      text: answer,
      guarded: guardLine != null ? true : null,
      details: guardLine == null ? details : [?details, guardLine].join('\n'),
      source: source,
    );
    _history.add(HistoryEntry(text, answer));
  }

  // -----------------------------------------------------------------------------------------------------------------
  // Tool calls
  // -----------------------------------------------------------------------------------------------------------------

  /// The model's calls with app-written replies.
  Future<void> _runCalls(String userText, List<ToolCall> calls, int firstReply, ReplyWriter writer) async {
    final strings = _config.strings;
    final texts = <String>[];
    final displays = <String>[];
    var reply = firstReply;
    var user = userText;
    for (final modelCall in calls) {
      final (call, spec, problems) = _check(modelCall);
      if (problems.isNotEmpty) {
        _appendDetails(reply, '[validation] ${modelCall.name}: ${problems.join('; ')}');
        texts.add(strings.missingData);
        displays.add(strings.missingData);
        break;
      }
      if (_shouldAsk(call, spec!)) {
        if (displays.isNotEmpty) {
          _finishReply(reply, displays);
          _history.add(HistoryEntry(user, texts.join(' ')));
          user = '';
          reply = _add(MessageRole.assistant);
          texts.clear();
          displays.clear();
        }
        _askConfirmation(user, call, spec, reply);
        return;
      }
      final written = await _execute(call, spec, reply, ToolCallSource.model, writer);
      texts.add(written.text);
      displays.add(written.display);
      _setOffer(written.offer);
    }
    _finishReply(reply, displays);
    _history.add(HistoryEntry(user, texts.join(' ')));
  }

  /// The call coerced, its spec, and its problems (`unknown tool` before validation).
  (ToolCall, ToolSpec?, List<String>) _check(ToolCall modelCall) {
    final toolkit = _config.toolkit;
    final call = ToolCall(modelCall.name, toolkit.coerce(modelCall));
    final spec = toolkit.spec(call.name);
    return (call, spec, spec == null ? const ['unknown tool'] : toolkit.validate(call));
  }

  /// Whether [call] waits for a yes. The policy reads no annotations, so none are read here: `annotate` runs only
  /// right before a call executes, and for the question.
  bool _shouldAsk(ToolCall call, ToolSpec spec) =>
      _config.confirmation.shouldAsk(call, _confirmationContext(call, spec, annotations: const {}));

  ConfirmationContext _confirmationContext(ToolCall call, ToolSpec spec, {Map<String, Object?>? annotations}) =>
      ConfirmationContext(
        call: call,
        spec: spec,
        lists: _lists,
        annotations: annotations ?? _lists.annotate(call),
        strings: _config.strings,
        references: _config.listReferences,
      );

  /// Status label, `toolStatusDelay`, the call, its reply ([writer]), the `[tool]` line and the screen request; then
  /// the reply's follow-up once.
  Future<_Written> _execute(ToolCall call, ToolSpec? spec, int reply, ToolCallSource source, ReplyWriter writer) async {
    late ToolReply written;
    await _executeCall(call, spec, reply, source, write: (outcome) => written = writer.write(outcome));
    final followUp = written.followUp;
    if (followUp == null) return (text: written.text, display: written.display, offer: written.offer);
    late ToolReply relisted;
    await _runTool(
      followUp,
      _config.toolkit.spec(followUp.name),
      ToolCallSource.followUp,
      write: (again) => relisted = writer.write(again),
    );
    return (
      text: '${written.text} ${relisted.text}',
      display: '${written.display}\n\n${relisted.display}',
      offer: relisted.offer,
    );
  }

  /// One call shown in [reply]: the status label (notified), the pause, the call, [write], the `[tool]` details line
  /// and the screen request.
  Future<ToolOutcome> _executeCall(
    ToolCall call,
    ToolSpec? spec,
    int reply,
    ToolCallSource source, {
    void Function(ToolOutcome outcome)? write,
  }) async {
    final label = _config.toolkit.statusLabel(call) ?? _config.strings.working;
    _change(reply, thinking: true, status: label);
    _notify();
    final delay = _config.toolStatusDelay;
    if (delay > Duration.zero) await Future<void>.delayed(delay); // the status label is readable
    final outcome = await _runTool(call, spec, source, label: label, write: write);
    final result = outcome.result;
    _appendDetails(
      reply,
      '[tool] ${call.name} ${jsonEncode(call.arguments)} → '
      '${result.ok ? 'ok' : jsonEncode(result.toJson()['error'])}',
    );
    _requestScreen(outcome, reply);
    return outcome;
  }

  /// Runs [call]: annotations read, `beforeTool`, the toolkit (with its timeout), then [write] and the list recorded,
  /// in that order and in one step (the reply is written before its list is recorded: a writer that throws records
  /// none). Every source goes through here, the host's too.
  Future<ToolOutcome> _runTool(
    ToolCall call,
    ToolSpec? spec,
    ToolCallSource source, {
    String? label,
    void Function(ToolOutcome outcome)? write,
  }) async {
    final host = source == ToolCallSource.host;
    final watch = Stopwatch()..start();
    _emit(ToolStartedEvent(call, source, label: label), call: !host);
    var context = _toolContext(call, spec, source);
    ToolResult result;
    Object? error;
    StackTrace? stackTrace;
    try {
      ToolResult? gated;
      final gate = host ? null : _config.beforeTool;
      if (gate != null) {
        final answer = gate(call, context);
        if (answer is Future<ToolResult?>) {
          gated = await answer;
          // Annotations are read in the same step as the call starts.
          if (gated == null) context = _toolContext(call, spec, source);
        } else {
          gated = answer;
        }
      }
      if (gated != null) {
        result = gated;
      } else {
        final running = context;
        if (!host) _turnTools.add(running);
        try {
          result = await _withTimeout(call, _config.toolkit.execute(call, running), running);
        } finally {
          _turnTools.remove(running);
        }
      }
    } catch (e, s) {
      error = e;
      stackTrace = s;
      result = ToolResult.error('tool_exception', _config.strings.toolFailed);
    }
    final shown = _lists.prepare(call, result, context.annotations);
    final outcome = ToolOutcome(
      call: call,
      result: result,
      spec: spec,
      source: source,
      annotations: context.annotations,
      shownList: shown,
    );
    _emit(
      ToolFinishedEvent(outcome, watch.elapsed, error: error, stackTrace: stackTrace),
      call: !host,
    );
    if (error != null && _config.toolErrors == ToolErrorPolicy.failTurn) {
      Error.throwWithStackTrace(error, stackTrace!);
    }
    write?.call(outcome);
    _lists.commit(shown);
    return outcome;
  }

  ToolContext _toolContext(ToolCall call, ToolSpec? spec, ToolCallSource source) => ToolContext(
    call: call,
    source: source,
    today: today,
    lists: _lists,
    annotations: _lists.annotate(call),
    spec: spec,
    references: _config.listReferences,
  );

  Future<ToolResult> _withTimeout(ToolCall call, Future<ToolResult> running, ToolContext context) {
    final limit = _config.toolkit.timeoutOf(call) ?? _config.toolTimeout;
    if (limit == null) return running;
    return running.timeout(
      limit,
      onTimeout: () {
        context.cancel();
        return ToolResult.error('timeout', _config.strings.toolFailed, details: {'timeout_ms': limit.inMilliseconds});
      },
    );
  }

  /// The screen [outcome] asks for, bound to its item, on [reply] and in the events.
  void _requestScreen(ToolOutcome outcome, int reply) {
    final request = _config.screenRequests?.call(outcome);
    if (request == null) return;
    final bound = BoundScreenRequest(request, binding: _lists.bind(request.itemRef));
    _change(reply, screenRequest: bound);
    _call?.screenRequests.add(bound);
    _emit(ScreenRequestedEvent(bound, itemId: reply));
  }

  void _setOffer(ToolCall? offer) {
    _offer = offer == null
        ? null
        : _Offer(offer, _lists.bind(_config.listReferences.itemRefOf(offer, _config.toolkit.spec(offer.name))));
  }

  void _finishReply(int reply, List<String> displays) {
    _change(reply, thinking: false, status: null, text: displays.join('\n\n'), source: ReplySource.app);
    _notify();
  }

  void _failReply(int reply, Object error, StackTrace stackTrace) {
    _change(
      reply,
      thinking: false,
      status: null,
      text: _config.strings.error,
      details: [?_item(reply).details, '$error'].join('\n'),
      source: ReplySource.error,
    );
    _notify();
    _failed(error, stackTrace);
  }

  void _appendDetails(int reply, String line) => _change(reply, details: [?_item(reply).details, line].join('\n'));

  // -----------------------------------------------------------------------------------------------------------------
  // Model-written replies
  // -----------------------------------------------------------------------------------------------------------------

  /// The standard loop: calls run, their results go back to the model, which writes the answer. A call that asks
  /// ends the turn with the question; the calls after it in the same answer are not run.
  Future<void> _modelRounds(
    String userText,
    List<ChatMessage> context,
    ChatResult first,
    int reply,
    ModelWrittenReplies strategy,
    Stopwatch watch, {
    int round = 0,
    List<ToolOutcome> outcomes = const [],
  }) async {
    final seen = [...outcomes];
    var messages = context;
    var result = first;
    while (result.hasToolCalls && round < strategy.maxToolRounds) {
      round++;
      final calls = result.toolCalls;
      final asked = ChatMessage.assistant(result.text, toolCalls: calls);
      final answers = <ChatMessage>[];
      for (var i = 0; i < calls.length; i++) {
        final (call, spec, problems) = _check(calls[i]);
        if (problems.isNotEmpty) {
          _appendDetails(reply, '[validation] ${call.name}: ${problems.join('; ')}');
          answers.add(_failureMessage(strategy, call, spec, 'invalid_arguments', problems.join('; ')));
          continue;
        }
        if (_shouldAsk(call, spec!)) {
          _askConfirmation(
            userText,
            call,
            spec,
            reply,
            modelContext: [...messages, asked, ...answers],
            modelAfter: [
              for (final later in calls.skip(i + 1))
                _failureMessage(strategy, later, _config.toolkit.spec(later.name), 'not_run', _notRun),
            ],
            outcomes: seen,
            round: round,
          );
          return;
        }
        final outcome = await _executeCall(call, spec, reply, ToolCallSource.model);
        seen.add(outcome);
        answers.add(ChatMessage.tool(_encode(strategy, outcome), name: call.name));
      }
      messages = [...messages, asked, ...answers];
      final next = await _nextRound(userText, messages, reply, watch, seen, last: round >= strategy.maxToolRounds);
      if (next == null) return;
      result = next;
    }
    await _answer(userText, result, reply, outcomes: seen);
  }

  /// The result the model gets for a call that did not run: the call after a question, in the same answer.
  static const String _notRun = 'not run: it came after a call that asked the user first';

  ChatMessage _failureMessage(ModelWrittenReplies strategy, ToolCall call, ToolSpec? spec, String code, String why) {
    final outcome = ToolOutcome(
      call: call,
      result: ToolResult.error(code, why),
      spec: spec,
      source: ToolCallSource.model,
    );
    return ChatMessage.tool(_encode(strategy, outcome), name: call.name);
  }

  /// The model's next answer, from [messages] with the results so far: the item's text starts again. Null when the
  /// turn ended instead: stopped (S3; after calls ran, [_endAfterCalls]), or failed after calls ran.
  Future<ChatResult?> _nextRound(
    String userText,
    List<ChatMessage> messages,
    int reply,
    Stopwatch watch,
    List<ToolOutcome> ran, {
    required bool last,
  }) async {
    _call?.restart(reply);
    _change(reply, thinking: true, status: null, text: '');
    _notify();
    final ChatResult result;
    try {
      result = await _generate(
        _model!,
        messages,
        reply,
        watch,
        mode: last ? ToolMode.none : ToolMode.auto,
        append: true,
      );
    } catch (error, stackTrace) {
      if (ran.isEmpty) rethrow;
      _appendDetails(reply, '$error');
      _endAfterCalls(userText, reply, ran);
      _failed(error, stackTrace);
      return null;
    }
    if (_stopRequested) {
      ran.isEmpty ? _interrupted(userText, reply) : _endAfterCalls(userText, reply, ran);
      return null;
    }
    return result;
  }

  /// A model's answer stopped or failed after calls ran: the text it wrote, else the plain reply to the calls
  /// (`done`, or `toolFailed` for a failure); into the history either way, so what ran is not lost.
  void _endAfterCalls(String userText, int reply, List<ToolOutcome> ran) {
    final strings = _config.strings;
    final written = _item(reply).text;
    final text = written.isNotEmpty
        ? written
        : {for (final outcome in ran) outcome.result.ok ? strings.done : strings.toolFailed}.join(' ');
    _change(
      reply,
      thinking: false,
      status: null,
      text: text,
      source: written.isNotEmpty ? ReplySource.model : ReplySource.app,
    );
    _history.add(HistoryEntry(userText, text));
  }

  String _encode(ModelWrittenReplies strategy, ToolOutcome outcome) {
    final text = strategy.encodeResult(outcome);
    if (text.length <= strategy.maxResultChars) return text;
    var cut = strategy.maxResultChars;
    if (cut > 0 && _isHighSurrogate(text.codeUnitAt(cut - 1))) cut--;
    return '${text.substring(0, cut)}…';
  }

  static bool _isHighSurrogate(int unit) => unit >= 0xD800 && unit <= 0xDBFF;

  /// A yes with `ModelWrittenReplies`: the call runs and the model writes the reply from its result.
  Future<void> _confirmedByModel(_Pending pending, int reply, ModelWrittenReplies strategy, String user) async {
    final watch = Stopwatch()..start();
    final outcome = await _executeCall(pending.call, pending.spec, reply, ToolCallSource.confirmation);
    final ran = [...pending.outcomes, outcome];
    final context =
        pending.modelContext ??
        [
          ..._config.prompt.messages(user, history: _history, today: today),
          ChatMessage.assistant('', toolCalls: [pending.call]),
        ];
    final messages = [
      ...context,
      ChatMessage.tool(_encode(strategy, outcome), name: pending.call.name),
      ...pending.modelAfter,
    ];
    final result = await _nextRound(user, messages, reply, watch, ran, last: pending.round >= strategy.maxToolRounds);
    if (result == null) return;
    await _modelRounds(user, messages, result, reply, strategy, watch, round: pending.round, outcomes: ran);
  }

  // -----------------------------------------------------------------------------------------------------------------
  // Questions and offers
  // -----------------------------------------------------------------------------------------------------------------

  /// Asks before [call]: it waits for a yes; [reply] asks the question with its buttons.
  void _askConfirmation(
    String userText,
    ToolCall call,
    ToolSpec spec,
    int reply, {
    List<ChatMessage>? modelContext,
    List<ChatMessage> modelAfter = const [],
    List<ToolOutcome> outcomes = const [],
    int round = 0,
  }) {
    final strings = _config.strings;
    final question =
        _config.toolkit.confirmationQuestion(call, _confirmationContext(call, spec)) ?? strings.confirmDefault;
    _pending = _Pending(
      userText: userText,
      call: call,
      spec: spec,
      itemId: reply,
      question: question,
      binding: _lists.bind(_config.listReferences.itemRefOf(call, spec)),
      modelContext: modelContext,
      modelAfter: modelAfter,
      outcomes: outcomes,
      round: round,
    );
    _change(
      reply,
      thinking: false,
      status: null,
      text: question,
      actions: List.unmodifiable([
        ChatAction(kind: ChatActionKind.confirm, label: strings.yes, primary: true),
        ChatAction(kind: ChatActionKind.decline, label: strings.no),
      ]),
      source: ReplySource.app,
    );
    _notify();
    final request = _pendingRequest!;
    _call?.confirmation = request;
    _emit(ConfirmationRequestedEvent(request));
  }

  /// The answer to an offer: a yes runs the offered call without the model, a no answers `offerDeclined`.
  Future<void> _answerOffer(String text, _Offer offer, bool yes) async {
    _add(MessageRole.user, text: text);
    final reply = _add(MessageRole.assistant);
    _setPhase(AssistantPhase.busy);
    try {
      if (yes) {
        final call = offer.call;
        final written = await _execute(call, _config.toolkit.spec(call.name), reply, ToolCallSource.offer, _writer);
        _finishReply(reply, [written.display]);
        _history.add(HistoryEntry(text, written.text));
        _setOffer(written.offer);
      } else {
        final answer = _config.strings.offerDeclined;
        _finishReply(reply, [answer]);
        _history.add(HistoryEntry(text, answer));
      }
    } catch (error, stackTrace) {
      _failReply(reply, error, stackTrace);
    } finally {
      _setPhase(AssistantPhase.ready);
    }
  }

  /// The answer to the open question: a yes runs the waiting call, a no declines it.
  Future<void> _resolvePending(bool yes) async {
    final strings = _config.strings;
    final pending = _pending!;
    _pending = null;
    // An offer from earlier in the question's turn: the answer's reply does not ask it.
    _offer = null;
    final reply = _add(MessageRole.assistant);
    _setPhase(AssistantPhase.busy);
    try {
      final user = pending.userText.isEmpty ? (yes ? strings.yes : strings.no) : pending.userText;
      if (yes && !_lists.stillNames(pending.binding)) {
        // A screen replaced the list the question's number came from: that number now names another item.
        _finishReply(reply, [strings.listChanged]);
        _history.add(HistoryEntry(user, strings.listChanged));
      } else if (yes) {
        switch (_config.replies) {
          case final ModelWrittenReplies strategy:
            await _confirmedByModel(pending, reply, strategy, user);
          case AppWrittenReplies(:final writer):
            final written = await _execute(pending.call, pending.spec, reply, ToolCallSource.confirmation, writer);
            _setOffer(written.offer);
            _finishReply(reply, [written.display]);
            _history.add(HistoryEntry(user, written.text));
        }
      } else {
        _finishReply(reply, [strings.declined]);
        _history.add(HistoryEntry(user, strings.declined));
      }
    } catch (error, stackTrace) {
      _failReply(reply, error, stackTrace);
    } finally {
      _setPhase(AssistantPhase.ready);
    }
  }

  void _clearPendingButtons() {
    final pending = _pending;
    if (pending != null) _change(pending.itemId, actions: const []);
    _notify();
  }

  /// The question is left unanswered: `(its user text, declined)` joins the history.
  void _dropPending() {
    final pending = _pending;
    if (pending == null) return;
    _pending = null;
    _history.add(HistoryEntry(pending.userText, _config.strings.declined));
  }

  /// The app's writer: the config's, else (model-written replies) `done` or `toolFailed`.
  ReplyWriter get _writer => switch (_config.replies) {
    AppWrittenReplies(:final writer) => writer,
    ModelWrittenReplies() => _PlainWriter(_config.strings.done, _config.strings.toolFailed),
  };

  // -----------------------------------------------------------------------------------------------------------------
  // Host
  // -----------------------------------------------------------------------------------------------------------------

  @override
  Future<ToolResult> runTool(ToolCall call) async =>
      (await _runTool(call, _config.toolkit.spec(call.name), ToolCallSource.host)).result;

  @override
  ToolReply recordAction(String userText, ToolCall call, ToolResult result, {String? reply}) {
    final written = reply != null
        ? ToolReply(text: reply)
        : _writer.write(
            ToolOutcome(call: call, result: result, spec: _config.toolkit.spec(call.name), source: ToolCallSource.host),
          );
    final exchange = [
      ChatItem(id: _nextItemId++, role: MessageRole.user, text: userText),
      ChatItem(id: _nextItemId++, role: MessageRole.assistant, text: written.display, source: ReplySource.app),
    ];
    // Every turn starts with one user item and adds no other, so the running turn starts at the last one.
    final turnStart = _isBusy ? _items.lastIndexWhere((item) => item.role == MessageRole.user) : -1;
    if (turnStart >= 0) {
      _items.insertAll(turnStart, exchange);
    } else {
      _offer = null;
      if (_pending != null) {
        _clearPendingButtons();
        _dropPending();
      }
      _items.addAll(exchange);
    }
    _structure++;
    _updatedAt = _clock();
    _history.add(HistoryEntry(userText, written.text));
    _notify();
    _emit(ConversationChangedEvent(ConversationChange.action, _conversationId), call: false);
    return written;
  }

  @override
  bool isLastList(String collection, ToolCall call) => _lists.isLastList(collection, call);

  @override
  bool isScreenRequestCurrent(BoundScreenRequest request) => _lists.stillNames(request.binding);

  @override
  ShownLists get lists => _lists;

  @override
  int get revision => _structure;

  // -----------------------------------------------------------------------------------------------------------------
  // Snapshots
  // -----------------------------------------------------------------------------------------------------------------

  /// The conversation as a snapshot: items (screen requests through [codec], else label and item only), history,
  /// lists, the open question and offer, the toolkit's state and [hostData].
  ConversationSnapshot snapshot({ScreenRequestCodec? codec, Map<String, Object?> hostData = const {}}) =>
      ConversationSnapshot(
        id: _conversationId,
        createdAt: _createdAt,
        updatedAt: _updatedAt,
        items: [for (final item in _items) storedItem(item, codec)],
        history: List.unmodifiable(_history),
        lists: _lists.toJson(),
        pending: _pending?.toJson(),
        offer: _offer?.toJson(),
        toolkitState: _config.toolkit.saveState(),
        hostData: hostData,
      );

  /// Replaces the conversation with [snapshot]'s (screen requests decoded by [codec] when it can); the toolkit is
  /// reset, then given the snapshot's state. Items get new ids. The open question and the offer come back unless
  /// `AssistantConfig.restoreOpenQuestion` is false: then they are dropped, the items come back without their actions
  /// (the question's yes and no), and `(its user text, strings.declined)` joins the history when the item that asked
  /// came back. False (nothing changed) while busy, or when the snapshot's lists, or the question or offer it brings
  /// back, cannot be read.
  bool restore(ConversationSnapshot snapshot, {ScreenRequestCodec? codec}) {
    if (_disposed || _isBusy) return false;
    final question = _config.restoreOpenQuestion;
    final ids = <int, int>{};
    final ListLedger lists;
    final List<ChatItem> items;
    final _Pending? pending;
    final _Offer? offer;
    try {
      lists = ListLedger(_config.listReferences)..restore(snapshot.lists);
      for (final item in snapshot.items) {
        ids[item.id] = _nextItemId + ids.length;
      }
      items = [for (final item in snapshot.items) restoredItem(item, ids[item.id]!, codec, actions: question)];
      pending = switch (snapshot.pending) {
        final Map<String, Object?> json when question => _pendingFromJson(json, ids),
        _ => null,
      };
      offer = switch (snapshot.offer) {
        final Map<String, Object?> json when question => _Offer(
          ToolCall.fromJson((json['call']! as Map).cast<String, Object?>()),
          _bindingFromJson(json['binding']),
        ),
        _ => null,
      };
    } on Object {
      return false;
    }
    _nextItemId += ids.length;
    _items
      ..clear()
      ..addAll(items);
    _history
      ..clear()
      ..addAll(snapshot.history);
    // A question not brought back is dropped as a message that is not a yes or a no drops it (_dropPending); one whose
    // item did not come back joins no history.
    final dropped = question ? null : snapshot.pending;
    if (dropped case {'userText': final String userText, 'itemId': final int id} when ids.containsKey(id)) {
      _history.add(HistoryEntry(userText, _config.strings.declined));
    }
    _lists.restore(lists.toJson());
    _pending = pending;
    _offer = offer;
    final toolkit = _config.toolkit..reset();
    if (snapshot.toolkitState case final state?) toolkit.restoreState(state);
    _conversationId = snapshot.id;
    _createdAt = snapshot.createdAt;
    _updatedAt = snapshot.updatedAt;
    _structure++;
    _notify();
    _emit(ConversationChangedEvent(ConversationChange.restored, _conversationId), call: false);
    return true;
  }

  _Pending _pendingFromJson(Map<String, Object?> json, Map<int, int> ids) {
    final call = json['call'];
    final itemId = json['itemId'];
    final userText = json['userText'];
    final question = json['question'];
    if (call is! Map || itemId is! int || userText is! String || question is! String || !ids.containsKey(itemId)) {
      throw FormatException('not an open question', json);
    }
    final parsed = ToolCall.fromJson(call.cast<String, Object?>());
    return _Pending(
      userText: userText,
      call: parsed,
      spec: _config.toolkit.spec(parsed.name),
      itemId: ids[itemId]!,
      question: question,
      binding: _bindingFromJson(json['binding']),
    );
  }

  static ItemBinding? _bindingFromJson(Object? json) =>
      json is Map ? ItemBinding.fromJson(json.cast<String, Object?>()) : null;

  // -----------------------------------------------------------------------------------------------------------------
  // Items
  // -----------------------------------------------------------------------------------------------------------------

  int _add(MessageRole role, {String text = '', bool thinking = false}) {
    final item = ChatItem(id: _nextItemId++, role: role, text: text, thinking: thinking);
    _items.add(item);
    _structure++;
    _state = null;
    _call?.itemIds.add(item.id);
    return item.id;
  }

  ChatItem? _itemOrNull(int id) {
    for (var i = _items.length - 1; i >= 0; i--) {
      if (_items[i].id == id) return _items[i];
    }
    return null;
  }

  ChatItem _item(int id) => _itemOrNull(id) ?? (throw StateError('item $id is no longer in the conversation'));

  static const Object _same = Object();

  /// Replaces item [id] with a copy that has the given fields (and the next revision). Does not notify.
  void _change(
    int id, {
    String? text,
    bool? thinking,
    Object? status = _same,
    List<ChatAction>? actions,
    bool? guarded,
    Object? source = _same,
    Object? screenRequest = _same,
    Object? details = _same,
    Object? stats = _same,
  }) {
    final index = _items.lastIndexWhere((item) => item.id == id);
    if (index < 0) return;
    final old = _items[index];
    final next = ChatItem(
      id: old.id,
      revision: old.revision + 1,
      role: old.role,
      text: text ?? old.text,
      thinking: thinking ?? old.thinking,
      status: identical(status, _same) ? old.status : status as String?,
      actions: actions ?? old.actions,
      guarded: guarded ?? old.guarded,
      source: identical(source, _same) ? old.source : source as ReplySource?,
      screenRequest: identical(screenRequest, _same) ? old.screenRequest : screenRequest as BoundScreenRequest?,
      details: identical(details, _same) ? old.details : details as String?,
      stats: identical(stats, _same) ? old.stats : stats as GenerationStats?,
    );
    _items[index] = next;
    _state = null;
    if (next.role == MessageRole.assistant && next.text != old.text) {
      _emit(
        next.text.startsWith(old.text)
            ? ReplyDeltaEvent(id, next.text.substring(old.text.length))
            : ReplyReplacedEvent(id, next.text),
      );
      _call?.textChanged(id, next.text);
    }
  }

  /// `c` + the time in base 36 + 6 random base-36 digits: letters and digits only (a file name as it is).
  static String _newConversationId(DateTime now) {
    final random = _random.nextInt(1 << 30).toRadixString(36).padLeft(6, '0');
    return 'c${now.microsecondsSinceEpoch.toRadixString(36)}$random';
  }

  // -----------------------------------------------------------------------------------------------------------------
  // Disposal
  // -----------------------------------------------------------------------------------------------------------------

  /// Stops the running turn, frees the model and closes [states] and [events]. Calls that follow are refused.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _stopRequested = true;
    _generation?.cancel();
    for (final context in _turnTools) {
      context.cancel();
    }
    final engine = _engine;
    _engine = null;
    _model = null;
    _listeners.clear();
    await engine?.dispose();
    await _states.close();
    await _events.close();
  }

  @override
  String toString() => 'Assistant(${_phase.name}, ${_items.length} items)';
}

/// The writer of `ModelWrittenReplies` for what the app must write itself (a recorded action).
final class _PlainWriter implements ReplyWriter {
  const _PlainWriter(this.done, this.failed);

  final String done;
  final String failed;

  @override
  ToolReply write(ToolOutcome outcome) => ToolReply(text: outcome.result.ok ? done : failed);
}
