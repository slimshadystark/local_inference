// A llamadart backend with no native code, for LlamadartEngine tests: it records every call, and a generation either
// replies at once ([FakeLlamaBackend.reply]) or waits for the test to drive it ([FakeGeneration]).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:llamadart/llamadart.dart' as ll;

/// The Qwen3.5 architecture and a short chat template.
const Map<String, String> fakeMetadata = {
  'general.architecture': 'qwen35',
  'tokenizer.chat_template': "{{ '<|im_start|>' }}<tool_call>",
};

/// One generation the backend was asked for.
class FakeGeneration {
  FakeGeneration(this.prompt, this.params);

  final String prompt;
  final ll.GenerationParams params;
  final StreamController<List<int>> controller = StreamController<List<int>>();

  /// Sends one piece of text, as the worker sends a token's bytes.
  void piece(String text) => controller.add(utf8.encode(text));

  /// Ends the generation, as the worker's done message does.
  Future<void> end() => controller.close();

  /// Fails the generation, as the worker's error message does.
  Future<void> fail(Object error) {
    controller.addError(error);
    return controller.close();
  }
}

class FakeLlamaBackend
    implements
        ll.LlamaBackend,
        ll.BackendPerformanceDiagnostics,
        ll.BackendStatePersistence,
        ll.BackendRuntimeDiagnostics {
  FakeLlamaBackend({this.metadata = fakeMetadata, this.bosToken});

  Map<String, String> metadata;

  /// Prepended by tokenize(addSpecial: true) when set (a vocabulary that adds BOS).
  final int? bosToken;

  /// Every call, in order: `modelLoad`, `tokenize(<text>, <addSpecial>)`, `generate(<prompt>)`, `cancelGeneration`,
  /// `stateSaveFile(<path>)`, `stateLoadFile(<path>, <capacity>)`, `dispose`, ...
  final List<String> calls = [];
  final List<FakeGeneration> generations = [];
  ll.ModelParams? modelParams;

  /// When set, each generation emits these pieces at once and ends; otherwise the test drives [generations].
  List<String> Function(String prompt, ll.GenerationParams params)? reply;

  /// When true, cancelGeneration ends the running driven generation (the worker stops at its next token).
  bool endOnCancel = true;

  Exception? loadError;
  Exception? tokenizeError;
  bool saveResult = true;
  Exception? stateLoadError;
  List<int> stateTokens = const [1, 2, 3];
  int contextSize = 4096;
  int? resolvedGpuLayers = 999;
  String backendName = 'Metal';
  ll.BackendPerfContextData? perf = const ll.BackendPerfContextData(
    loadMs: 0,
    promptEvalMs: 30,
    evalMs: 5,
    sampleMs: 7,
    promptEvalTokens: 9,
    evalTokens: 3,
    sampleCount: 3,
    reusedGraphs: 0,
  );

  FakeGeneration? _driven;

  /// Tokens of [text]: one per 4 characters (rounded up), after the BOS token when there is one and [addSpecial].
  List<int> tokensOf(String text, {bool addSpecial = true}) => [
    if (addSpecial && bosToken != null) bosToken!,
    for (var i = 0; i < text.length; i += 4) 100 + i ~/ 4,
  ];

  @override
  bool get isReady => true;

  @override
  bool get supportsUrlLoading => false;

  @override
  Future<void> setLogLevel(ll.LlamaLogLevel level) async {}

  @override
  Future<int> modelLoad(String path, ll.ModelParams params) async {
    calls.add('modelLoad');
    modelParams = params;
    final error = loadError;
    if (error != null) throw error;
    return 1;
  }

  @override
  Future<int> contextCreate(int modelHandle, ll.ModelParams params) async => 2;

  @override
  Future<int> getContextSize(int contextHandle) async => contextSize;

  @override
  Future<Map<String, String>> modelMetadata(int modelHandle) async => Map.of(metadata);

  @override
  Future<String> getBackendName() async => backendName;

  @override
  Future<int?> getResolvedGpuLayers() async => resolvedGpuLayers;

  @override
  Future<List<int>> tokenize(int modelHandle, String text, {bool addSpecial = true}) async {
    calls.add('tokenize(${text.length} chars, $addSpecial)');
    final error = tokenizeError;
    if (error != null) throw error;
    return tokensOf(text, addSpecial: addSpecial);
  }

  @override
  Stream<List<int>> generate(
    int contextHandle,
    String prompt,
    ll.GenerationParams params, {
    List<ll.LlamaContentPart>? parts,
  }) {
    calls.add('generate(${params.maxTokens})');
    final generation = FakeGeneration(prompt, params);
    generations.add(generation);
    final reply = this.reply;
    if (reply != null) return Stream.fromIterable([for (final piece in reply(prompt, params)) utf8.encode(piece)]);
    _driven = generation;
    return generation.controller.stream;
  }

  @override
  void cancelGeneration() {
    calls.add('cancelGeneration');
    final driven = _driven;
    if (endOnCancel && driven != null && !driven.controller.isClosed) unawaited(driven.end());
  }

  @override
  Future<ll.BackendPerfContextData?> getPerformanceContext(int contextHandle) async => perf;

  @override
  Future<bool> stateSaveFile(int contextHandle, String path, List<int> tokens) async {
    calls.add('stateSaveFile(${tokens.length} tokens)');
    if (saveResult) File(path).writeAsStringSync('state of ${tokens.length} tokens');
    return saveResult;
  }

  @override
  Future<ll.StateLoadResult> stateLoadFile(int contextHandle, String path, int tokenCapacity) async {
    calls.add('stateLoadFile($tokenCapacity)');
    final error = stateLoadError;
    if (error != null) throw error;
    return ll.StateLoadResult(tokens: stateTokens);
  }

  @override
  Future<void> contextFree(int contextHandle) async => calls.add('contextFree');

  @override
  Future<void> modelFree(int modelHandle) async => calls.add('modelFree');

  @override
  Future<void> dispose() async => calls.add('dispose');

  @override
  Object? noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('FakeLlamaBackend: ${invocation.memberName} is not faked');
}
