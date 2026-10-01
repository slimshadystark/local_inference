/// When a call waits for the user's yes.
library;

import 'package:meta/meta.dart';

import '../model/tool_call.dart';
import '../model/tool_spec.dart';
import 'lists.dart';
import 'strings.dart';

/// Which calls wait for a yes. A tool's [SideEffect] says what it does:
/// - [SideEffect.read]: nothing outside the conversation;
/// - [SideEffect.recoverable]: something the user can see and undo, or still has to complete (a screen, a draft);
///   it runs at once with its status label;
/// - [SideEffect.irreversible]: something the app cannot take back (book, cancel, pay, send).
@immutable
final class ConfirmationPolicy {
  const ConfirmationPolicy({this.ask = const {SideEffect.irreversible}, this.skipWhenItemNotShown = false});

  /// The side effects that ask first.
  final Set<SideEffect> ask;

  /// Runs a call without asking when the list item it names is not shown: for tools that refuse such a number
  /// themselves (and answer with the list again).
  final bool skipWhenItemNotShown;

  /// Whether [call] waits for a yes.
  bool shouldAsk(ToolCall call, ConfirmationContext context) {
    if (!ask.contains(context.spec.sideEffect)) return false;
    if (!skipWhenItemNotShown) return true;
    final ref = context.itemRef;
    return ref == null || context.lists.isShown(ref);
  }
}

/// What a confirmation question may read.
final class ConfirmationContext {
  ConfirmationContext({
    required this.call,
    required this.spec,
    required this.lists,
    this.annotations = const {},
    required this.strings,
    this.references = const ListReferences(),
  });

  /// The call that waits.
  final ToolCall call;

  /// Its tool.
  final ToolSpec spec;

  /// The lists shown so far.
  final ShownLists lists;

  /// What `ListReferences.annotate` says about the call now.
  final Map<String, Object?> annotations;

  /// The conversation texts.
  final AssistantStrings strings;

  /// How arguments name list items.
  final ListReferences references;

  /// The list item the call names, if any.
  ItemRef? get itemRef => references.itemRefOf(call, spec);

  /// The shown item the call's [argument] names; null when it names none.
  Map<String, Object?>? item(String argument) {
    final ref = references.refOf(call, argument, spec);
    return ref == null ? null : lists.item(ref.collection, ref.number);
  }
}
