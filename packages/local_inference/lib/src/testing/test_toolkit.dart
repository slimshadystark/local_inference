/// A toolkit wrapper for tests: it records the calls and can hold one tool's answer back.
library;

import 'dart:async';

import '../agent/tool_result.dart';
import '../agent/toolkit.dart';
import '../model/tool_call.dart';

/// Wraps [inner]: records every call it runs, and holds back the answers of [gatedTool] until [gate] completes (the
/// call itself starts at once, so it reads its list items when it is made).
final class TestToolkit extends DelegatingToolkit {
  TestToolkit(super.inner);

  /// Every call run, in order, as the assistant ran it.
  final List<ToolCall> calls = [];

  /// Who asked for each of [calls].
  final List<ToolCallSource> sources = [];

  /// The annotations each of [calls] ran with.
  final List<Map<String, Object?>> annotations = [];

  /// Times [reset] was called.
  int resets = 0;

  /// The tool whose answers wait for [gate]; null holds nothing back.
  String? gatedTool;

  /// Completing it lets the held answers go.
  Completer<void>? gate;

  @override
  Future<ToolResult> execute(ToolCall call, ToolContext context) async {
    calls.add(call);
    sources.add(context.source);
    annotations.add(context.annotations);
    final result = inner.execute(call, context)..ignore();
    if (call.name == gatedTool) await gate?.future;
    return result;
  }

  @override
  void reset() {
    resets++;
    inner.reset();
  }
}
