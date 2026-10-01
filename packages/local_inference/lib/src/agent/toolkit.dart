/// The tools an assistant can call: one tool at a time ([AssistantTool], [Toolkit.of]) or a whole set ([Toolkit]).
library;

import 'dart:async';

import 'package:meta/meta.dart';

import '../model/tool_call.dart';
import '../model/tool_spec.dart';
import '../model/validator.dart';
import 'confirmation.dart';
import 'lists.dart';
import 'tool_result.dart';

/// Runs one call of a tool.
typedef ToolRunner = FutureOr<ToolResult> Function(ToolCall call, ToolContext context);

/// Runs before a call (`AssistantConfig.beforeTool`): a non-null result is the call's result, and the tool does not
/// run.
typedef ToolGate = FutureOr<ToolResult?> Function(ToolCall call, ToolContext context);

/// What a running call may read.
final class ToolContext {
  ToolContext({
    required this.call,
    this.source = ToolCallSource.host,
    DateTime? today,
    ShownLists? lists,
    this.annotations = const {},
    this.spec,
    this.references = const ListReferences(),
  }) : today = today ?? DateTime.now(),
       lists = lists ?? ListLedger(references);

  /// The call.
  final ToolCall call;

  /// Who asked for it.
  final ToolCallSource source;

  /// The conversation's day (`AssistantConfig.today`).
  final DateTime today;

  /// The lists shown so far.
  final ShownLists lists;

  /// What `ListReferences.annotate` said about the call right before it ran.
  final Map<String, Object?> annotations;

  /// The tool's spec; null when the toolkit does not list it.
  final ToolSpec? spec;

  /// How arguments name list items.
  final ListReferences references;

  final Completer<void> _cancelled = Completer<void>();

  /// Completes when the user stops the turn or the call times out. A tool that can stop early should; its result is
  /// still used (the assistant never abandons a running call: an irreversible one may already have acted).
  Future<void> get cancelled => _cancelled.future;

  /// Whether [cancelled] has completed.
  bool get isCancelled => _cancelled.isCompleted;

  /// Completes [cancelled]. Called by the assistant.
  @internal
  void cancel() {
    if (!_cancelled.isCompleted) _cancelled.complete();
  }

  /// The shown list item that [argument] of the call names; null when it names none.
  Map<String, Object?>? item(String argument) {
    final ref = references.refOf(call, argument, spec);
    return ref == null ? null : lists.item(ref.collection, ref.number);
  }
}

/// One tool: its spec and how it runs.
final class AssistantTool {
  AssistantTool({
    required String name,
    required String description,
    Map<String, Object?>? parameters,
    SideEffect sideEffect = SideEffect.read,
    Map<String, Object?>? promptDeclaration,
    this.statusLabel,
    this.confirmationQuestion,
    this.timeout,
    required this.run,
  }) : spec = ToolSpec(
         name: name,
         description: description,
         parameters: parameters ?? const {'type': 'object', 'properties': <String, Object?>{}},
         sideEffect: sideEffect,
         promptDeclaration: promptDeclaration,
       );

  /// The tool as the model and the grammar see it.
  final ToolSpec spec;

  /// Shown while it runs; null uses `AssistantStrings.working`.
  final String? statusLabel;

  /// The question an irreversible call asks; null uses `AssistantStrings.confirmDefault`.
  final String Function(ToolCall call, ConfirmationContext context)? confirmationQuestion;

  /// Longest wait for a result; null uses `AssistantConfig.toolTimeout`.
  final Duration? timeout;

  /// Runs a call.
  final ToolRunner run;

  /// The tool's name.
  String get name => spec.name;

  @override
  String toString() => 'AssistantTool($name)';
}

/// A set of tools: their specs in prompt order (which is the order of the tool block, and so of the saved prefix),
/// and how each call is checked, run and described.
abstract class Toolkit {
  const Toolkit();

  /// A toolkit over [tools], in that order.
  factory Toolkit.of(List<AssistantTool> tools) = ToolRegistry;

  /// The tools, in prompt order.
  List<ToolSpec> get specs;

  /// The spec of [name]; null for a tool the toolkit does not have (the assistant answers `unknown tool`).
  ToolSpec? spec(String name) {
    for (final spec in specs) {
      if (spec.name == name) return spec;
    }
    return null;
  }

  /// The model's arguments rewritten leniently, before anything checks them (default: unchanged).
  Map<String, Object?> coerce(ToolCall call) => call.arguments;

  /// The problems of [call]'s (coerced) arguments; empty when valid. Default: [validateArguments] against the spec.
  List<String> validate(ToolCall call) {
    final spec = this.spec(call.name);
    return spec == null ? const ['unknown tool'] : validateArguments(spec.parameters, call.arguments);
  }

  /// Runs [call]. A model's mistake is a [ToolFailure]; an exception follows `AssistantConfig.toolErrors`. The call
  /// must start synchronously (before the first `await`): the assistant reads `ToolContext.annotations` in the same
  /// step.
  Future<ToolResult> execute(ToolCall call, ToolContext context);

  /// The label shown while [call] runs; null uses `AssistantStrings.working`.
  String? statusLabel(ToolCall call) => null;

  /// The question [call] asks before it runs; null uses `AssistantStrings.confirmDefault`.
  String? confirmationQuestion(ToolCall call, ConfirmationContext context) => null;

  /// Longest wait for [call]'s result; null uses `AssistantConfig.toolTimeout`.
  Duration? timeoutOf(ToolCall call) => null;

  /// A new conversation starts: forget what the old one did (a backend's ledgers).
  void reset() {}

  /// What a conversation snapshot keeps of the toolkit; null for nothing.
  Map<String, Object?>? saveState() => null;

  /// Takes back what [saveState] gave, after a [reset].
  void restoreState(Map<String, Object?> state) {}
}

/// A [Toolkit] over [AssistantTool]s.
final class ToolRegistry extends Toolkit {
  /// Throws [ArgumentError] when two tools have the same name.
  ToolRegistry(List<AssistantTool> tools)
    : tools = List.unmodifiable(tools),
      specs = List.unmodifiable([for (final tool in tools) tool.spec]),
      _byName = {for (final tool in tools) tool.name: tool} {
    if (_byName.length != tools.length) throw ArgumentError.value(tools, 'tools', 'two tools have the same name');
  }

  /// The tools, in order.
  final List<AssistantTool> tools;

  @override
  final List<ToolSpec> specs;

  final Map<String, AssistantTool> _byName;

  @override
  ToolSpec? spec(String name) => _byName[name]?.spec;

  @override
  Future<ToolResult> execute(ToolCall call, ToolContext context) async {
    final tool = _byName[call.name];
    if (tool == null) return ToolResult.error('unknown_tool', 'no tool named ${call.name}');
    return await tool.run(call, context);
  }

  @override
  String? statusLabel(ToolCall call) => _byName[call.name]?.statusLabel;

  @override
  String? confirmationQuestion(ToolCall call, ConfirmationContext context) =>
      _byName[call.name]?.confirmationQuestion?.call(call, context);

  @override
  Duration? timeoutOf(ToolCall call) => _byName[call.name]?.timeout;

  @override
  String toString() => 'ToolRegistry(${_byName.keys.join(', ')})';
}

/// A [Toolkit] that forwards every member to [inner]; override the ones to change.
class DelegatingToolkit extends Toolkit {
  DelegatingToolkit(this.inner);

  /// The toolkit it forwards to.
  final Toolkit inner;

  @override
  List<ToolSpec> get specs => inner.specs;

  @override
  ToolSpec? spec(String name) => inner.spec(name);

  @override
  Map<String, Object?> coerce(ToolCall call) => inner.coerce(call);

  @override
  List<String> validate(ToolCall call) => inner.validate(call);

  @override
  Future<ToolResult> execute(ToolCall call, ToolContext context) => inner.execute(call, context);

  @override
  String? statusLabel(ToolCall call) => inner.statusLabel(call);

  @override
  String? confirmationQuestion(ToolCall call, ConfirmationContext context) => inner.confirmationQuestion(call, context);

  @override
  Duration? timeoutOf(ToolCall call) => inner.timeoutOf(call);

  @override
  void reset() => inner.reset();

  @override
  Map<String, Object?>? saveState() => inner.saveState();

  @override
  void restoreState(Map<String, Object?> state) => inner.restoreState(state);
}
