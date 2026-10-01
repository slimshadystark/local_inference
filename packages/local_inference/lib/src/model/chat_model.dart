/// Direct chat with a model: messages in, visible text and typed tool calls out. No history, no tool execution.
library;

import 'dart:async';

import '../engine/engine_info.dart';
import '../engine/generation.dart';
import '../engine/inference_engine.dart';
import '../engine/options.dart';
import '../grammar/grammar_options.dart';
import '../llamadart/llamadart_engine.dart';
import 'chat_message.dart';
import 'chat_template.dart';
import 'model_profile.dart';
import 'prefix/model_identity.dart';
import 'prefix/prefix_cache.dart';
import 'prefix/prefix_state_store.dart';
import 'tool_call.dart';
import 'tool_spec.dart';

/// A loaded model with its [ModelProfile]: renders prompts, runs generations with the profile's stop strings and
/// grammars, parses the answers, and keeps a saved prompt prefix for models that cannot rewind their context.
final class ChatModel {
  ChatModel._(
    this.engine,
    this.info,
    this.profile,
    this.template,
    this._store, {
    required bool owned,
    required void Function(String message) log,
    ModelIdentity? identity,
  }) : _owned = owned,
       _log = log,
       _identity = identity;

  /// Loads [modelPath] on a new engine from [engine] and attaches to it; [dispose] disposes that engine. The profile
  /// is [profile], else [ModelProfile.detect]. When the load fails or the profile refuses the model
  /// ([UnsupportedModelException]), the engine is disposed and the error rethrown. [log] receives the model layer's
  /// notices (default: printed). [identity] names the model file in the prefix-state keys; null reads the file's name,
  /// size and modification time at the first [preparePrefix].
  static Future<ChatModel> load(
    String modelPath, {
    LoadOptions options = const LoadOptions(),
    ModelProfile? profile,
    EngineFactory engine = LlamadartEngine.new,
    PrefixStateStore? prefixStore,
    void Function(String message)? log,
    ModelIdentity? identity,
  }) async {
    final created = engine();
    try {
      await created.load(modelPath, options);
      return ChatModel._attach(created, profile, prefixStore, owned: true, log: log, identity: identity);
    } catch (_) {
      await created.dispose();
      rethrow;
    }
  }

  /// A model on [engine], which must be loaded; the engine stays the caller's ([dispose] leaves it). Throws
  /// [UnsupportedModelException] when the profile refuses the model's template, [StateError] when nothing is loaded.
  /// [identity] as for [load].
  factory ChatModel.attach(
    InferenceEngine engine, {
    ModelProfile? profile,
    PrefixStateStore? prefixStore,
    void Function(String message)? log,
    ModelIdentity? identity,
  }) => ChatModel._attach(engine, profile, prefixStore, owned: false, log: log, identity: identity);

  static ChatModel _attach(
    InferenceEngine engine,
    ModelProfile? profile,
    PrefixStateStore? prefixStore, {
    required bool owned,
    void Function(String message)? log,
    ModelIdentity? identity,
  }) {
    final info = engine.info ?? (throw StateError('ChatModel needs a loaded engine'));
    final resolved = profile ?? ModelProfile.detect(info);
    return ChatModel._(
      engine,
      info,
      resolved,
      resolved.templateFor(info),
      prefixStore,
      owned: owned,
      log: log ?? Zone.current.print,
      identity: identity,
    );
  }

  /// The engine that runs the model.
  final InferenceEngine engine;

  /// The loaded model.
  final EngineInfo info;

  /// The model's family.
  final ModelProfile profile;

  /// The model's chat template, as the profile accepted it.
  final ChatTemplate template;

  final PrefixStateStore? _store;
  final bool _owned;
  final void Function(String message) _log;

  PrefixCache? _cache;
  ModelIdentity? _identity;
  bool _warnedNoStore = false;
  bool _disposed = false;

  /// The chain that keeps prefix work and generation starts in call order.
  Future<void> _serial = Future<void>.value();

  /// The prompt of [messages] with [tools] in its tool block, as [prepare] renders it.
  String render(List<ChatMessage> messages, {List<ToolSpec> tools = const [], bool addGenerationPrompt = true}) =>
      profile
          .prepare(info, messages, tools: tools, mode: ToolMode.none, addGenerationPrompt: addGenerationPrompt)
          .prompt;

  /// The part of every prompt with this system prompt and these tools that does not depend on the conversation:
  /// `render([system(systemPrompt), user('.')], tools)` up to and including the first [ModelProfile.prefixMarker];
  /// with no marker, the longest common prefix of two renderings with different user messages. Null when there is
  /// none (no marker in the rendering, or nothing in common).
  String? stablePrefix({required String systemPrompt, List<ToolSpec> tools = const []}) {
    final marker = profile.prefixMarker;
    List<ChatMessage> probe(String user) => [ChatMessage.system(systemPrompt), ChatMessage.user(user)];
    if (marker != null) {
      final prompt = render(probe('.'), tools: tools);
      final index = prompt.indexOf(marker);
      return index < 0 ? null : prompt.substring(0, index + marker.length);
    }
    final a = render(probe('x'), tools: tools);
    final b = render(probe('y'), tools: tools);
    var length = 0;
    while (length < a.length && length < b.length && a.codeUnitAt(length) == b.codeUnitAt(length)) {
      length++;
    }
    // Never split a surrogate pair.
    if (length > 0 && length < a.length && _isHighSurrogate(a.codeUnitAt(length - 1))) length--;
    return length == 0 ? null : a.substring(0, length);
  }

  /// [messages] rendered, with the grammar, stop strings and preserved tokens of a generation (see
  /// [ModelProfile.prepare]).
  PreparedPrompt prepare(
    List<ChatMessage> messages, {
    List<ToolSpec> tools = const [],
    ToolMode toolMode = ToolMode.auto,
    GrammarOptions grammar = const GrammarOptions(),
    Map<String, Object?>? responseSchema,
  }) => profile.prepare(info, messages, tools: tools, mode: toolMode, grammar: grammar, responseSchema: responseSchema);

  /// Restores the saved state of this system prompt and tool list's [stablePrefix], or builds and saves it
  /// ([onBuild] is called first). Needs a prefix store ([StateError] without one). Returns
  /// [PrefixPreparation.unsupported], doing nothing, when the engine cannot save states, the profile can rewind the
  /// context (the runtime reuses the prefix by itself) or there is no stable prefix.
  Future<PrefixPreparation> preparePrefix({
    required String systemPrompt,
    List<ToolSpec> tools = const [],
    void Function()? onBuild,
  }) {
    _checkOpen();
    final store = _store;
    if (store == null) throw StateError('preparePrefix needs a ChatModel with a prefixStore');
    if (profile.canRewind(info) || !engine.supportsStatePersistence) {
      return Future.value(PrefixPreparation.unsupported);
    }
    final prefix = stablePrefix(systemPrompt: systemPrompt, tools: tools);
    if (prefix == null) return Future.value(PrefixPreparation.unsupported);
    return _serially(() async {
      final model = _identity ??= await ModelIdentity.ofFile(info.modelPath);
      final cache = _cache ??= PrefixCache(engine: engine, model: model, store: store);
      return cache.prepare(prefix, onBuild: onBuild);
    });
  }

  /// Generates an answer to [messages]. The grammar follows [toolMode] with [tools] (lazy for [ToolMode.auto]) or
  /// [responseSchema]; the profile's stop strings and preserved tokens always apply; [sampling] defaults to the
  /// profile's.
  ///
  /// On a model that cannot rewind, with a prefix store and a prepared prefix that the prompt starts with, the
  /// prefix state is restored first when the context has moved away from it ([ChatResult.restore] is the time it
  /// took). Without a store such a model prefills every prompt in full; this is logged once.
  ChatGeneration generate(
    List<ChatMessage> messages, {
    List<ToolSpec> tools = const [],
    ToolMode toolMode = ToolMode.auto,
    GrammarOptions grammar = const GrammarOptions(),
    Map<String, Object?>? responseSchema,
    SamplingOptions? sampling,
  }) {
    _checkOpen();
    final prepared = prepare(
      messages,
      tools: tools,
      toolMode: toolMode,
      grammar: grammar,
      responseSchema: responseSchema,
    );
    if (_store == null && !_warnedNoStore && !profile.canRewind(info)) {
      _warnedNoStore = true;
      _log(
        'local_inference: ${info.modelPath} cannot rewind its context (architecture ${info.architecture}) and '
        'this ChatModel has no prefixStore: every generation prefills the whole prompt. Pass a PrefixStateStore '
        'and call preparePrefix to restore a saved prefix instead.',
      );
    }
    final generation = ChatGeneration._(prepared);
    unawaited(_run(generation, tools, sampling ?? profile.sampling));
    return generation;
  }

  /// [generate]'s result.
  Future<ChatResult> complete(
    List<ChatMessage> messages, {
    List<ToolSpec> tools = const [],
    ToolMode toolMode = ToolMode.auto,
    SamplingOptions? sampling,
  }) => generate(messages, tools: tools, toolMode: toolMode, sampling: sampling).result;

  /// Disposes the engine when [load] created it; a model from [ChatModel.attach] leaves the engine to its owner.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    if (_owned) await engine.dispose();
  }

  Future<void> _run(ChatGeneration generation, List<ToolSpec> tools, SamplingOptions sampling) async {
    try {
      final (restore, started) = await _serially(() async {
        final restore = await _restoreFor(generation.prompt.prompt);
        if (generation._cancelled) return (restore, null);
        final started = generation._generation = engine.generate(
          generation.prompt.prompt,
          generation.prompt.options(sampling),
        );
        return (restore, started);
      });
      if (started == null) {
        generation._finish(
          ChatResult(
            raw: '',
            text: '',
            stats: _emptyStats(),
            finishReason: FinishReason.cancelled,
            restore: restore,
            prompt: generation.prompt,
          ),
        );
        return;
      }
      final raw = StringBuffer();
      var sent = '';
      var sending = true;
      await for (final delta in started.text) {
        raw.write(delta);
        generation._raw.add(delta);
        if (!sending) continue;
        final visible = profile.visibleText(raw.toString(), generation.prompt);
        if (visible == null) continue;
        if (!visible.startsWith(sent)) {
          sending = false; // what was sent cannot be taken back
          continue;
        }
        if (visible.length > sent.length) {
          generation._text.add(visible.substring(sent.length));
          sent = visible;
        }
      }
      final result = await started.result;
      final parsed = profile.parse(result.text, tools, generation.prompt);
      generation._finish(
        ChatResult(
          raw: result.text,
          text: parsed.text,
          toolCalls: parsed.toolCalls,
          reasoning: parsed.reasoning,
          parseError: parsed.error,
          stats: result.stats,
          finishReason: result.finishReason,
          restore: restore,
          prompt: generation.prompt,
        ),
      );
    } catch (error, stackTrace) {
      generation._fail(error, stackTrace);
    }
  }

  /// Restores the prepared prefix when [prompt] starts with it and the context moved away; zero otherwise.
  Future<Duration> _restoreFor(String prompt) async {
    final cache = _cache;
    final prefix = cache?.prefix;
    if (cache == null || prefix == null || !prompt.startsWith(prefix)) return Duration.zero;
    return cache.beforeGeneration();
  }

  Future<T> _serially<T>(Future<T> Function() body) {
    final result = _serial.then((_) => body());
    _serial = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  GenerationStats _emptyStats() => GenerationStats(
    loadMs: info.loadMs,
    promptTokens: 0,
    prefillTokens: 0,
    prefillMs: 0,
    decodeTokens: 0,
    decodeMs: 0,
    timeToFirstTokenMs: 0,
    totalMs: 0,
  );

  void _checkOpen() {
    if (_disposed) throw StateError('the ChatModel is disposed');
  }

  static bool _isHighSurrogate(int unit) => unit >= 0xD800 && unit <= 0xDBFF;

  @override
  String toString() => 'ChatModel(${profile.id}, $info)';
}

/// One generation of a [ChatModel].
final class ChatGeneration {
  ChatGeneration._(this.prompt) {
    _result.future.ignore();
  }

  /// The prompt, its grammar and stop strings; available at once.
  final PreparedPrompt prompt;

  final StreamController<String> _text = StreamController<String>();
  final StreamController<String> _raw = StreamController<String>();
  final Completer<ChatResult> _result = Completer<ChatResult>();
  Generation? _generation;
  bool _cancelled = false;

  /// The visible text as it grows, in appended pieces: the profile's [ModelProfile.visibleText] of the raw output so
  /// far, nothing while that is null; once it stops extending what was sent, nothing more is sent. Single
  /// subscription, buffered until listened to; a failure arrives as an error event.
  Stream<String> get text => _text.stream;

  /// The engine's raw deltas (tool-call markup included). Single subscription, buffered until listened to.
  Stream<String> get raw => _raw.stream;

  /// Completes after the last event of [text] and [raw] (for a listener), also when cancelled; fails with the
  /// generation's error. Ignoring it raises no unhandled error.
  Future<ChatResult> get result => _result.future;

  /// Stops the generation: before the engine call (during a prefix restore) it never starts, with a cancelled result
  /// and no text; while it streams, the engine stops at its next token.
  void cancel() {
    if (_cancelled || _result.isCompleted) return;
    _cancelled = true;
    _generation?.cancel();
  }

  void _finish(ChatResult result) => _settle(() => _result.complete(result));

  void _fail(Object error, StackTrace stackTrace) {
    _text.addError(error, stackTrace);
    _raw.addError(error, stackTrace);
    _settle(() => _result.completeError(error, stackTrace));
  }

  /// Closes both streams, then completes [result]: after their listeners have received the last event.
  void _settle(void Function() complete) {
    final pending = <Future<void>>[];
    for (final controller in [_text, _raw]) {
      final listened = controller.hasListener;
      final closed = controller.close();
      // Without a listener the done event waits for one: nothing to wait for.
      if (listened) pending.add(closed);
    }
    if (pending.isEmpty) {
      complete();
    } else {
      unawaited(Future.wait(pending).then((_) => complete(), onError: (Object _, StackTrace _) => complete()));
    }
  }
}

/// The outcome of a [ChatGeneration].
final class ChatResult {
  const ChatResult({
    required this.raw,
    required this.text,
    this.toolCalls = const [],
    this.reasoning,
    this.parseError,
    required this.stats,
    required this.finishReason,
    this.restore = Duration.zero,
    required this.prompt,
  });

  /// The whole output, as generated.
  final String raw;

  /// The plain text of the answer (markup and reasoning removed), trimmed.
  final String text;

  /// The tool calls, arguments typed from the tools' schemas.
  final List<ToolCall> toolCalls;

  /// The model's reasoning, when it wrote some.
  final String? reasoning;

  /// Why a tool call could not be read, when one could not.
  final String? parseError;

  /// The engine's figures of this generation.
  final GenerationStats stats;

  /// Why the generation ended.
  final FinishReason finishReason;

  /// Time spent restoring the prefix state before the generation.
  final Duration restore;

  /// The prompt it answered.
  final PreparedPrompt prompt;

  /// Whether the answer called a tool.
  bool get hasToolCalls => toolCalls.isNotEmpty;

  @override
  String toString() =>
      'ChatResult(${finishReason.name}, ${text.length} chars, calls: $toolCalls, restore ${restore.inMilliseconds}ms'
      '${parseError == null ? '' : ', parseError: $parseError'})';
}
