/// An assistant's behavior, as one portable value.
library;

import 'package:meta/meta.dart';

import '../engine/options.dart';
import '../grammar/grammar_options.dart';
import '../model/model_profile.dart';
import 'confirmation.dart';
import 'context_lines.dart';
import 'guards.dart';
import 'hooks.dart';
import 'lists.dart';
import 'prompt_layout.dart';
import 'replies.dart';
import 'screen_requests.dart';
import 'strings.dart';
import 'toolkit.dart';

/// What happens when a tool throws.
enum ToolErrorPolicy {
  /// The turn fails: its reply is `AssistantStrings.error` and the exception goes into the item's details.
  failTurn,

  /// The call fails instead, with `ToolFailure('tool_exception', AssistantStrings.toolFailed)`, and the turn goes on;
  /// the exception is in `ToolFinishedEvent.error`, never in the prompt.
  reportToModel,
}

/// How an assistant behaves: its tools, prompt, replies, questions, lists, guards and texts. Runtime wiring (engine,
/// load settings, prefix store) goes to the `Assistant` constructor.
@immutable
final class AssistantConfig {
  const AssistantConfig({
    required this.toolkit,
    required this.prompt,
    this.profile,
    this.replies = const ModelWrittenReplies(),
    this.confirmation = const ConfirmationPolicy(),
    this.listReferences = const ListReferences(),
    this.screenRequests,
    this.guards = const [],
    this.rewriter,
    this.beforeModel,
    this.beforeTool,
    this.strings = AssistantStrings.english,
    this.grammar = const GrammarOptions(),
    this.sampling,
    this.toolStatusDelay = Duration.zero,
    this.toolTimeout,
    this.toolErrors = ToolErrorPolicy.failTurn,
    this.today,
    this.restoreOpenQuestion = true,
  });

  /// A config with [systemPrompt], [tools] and the defaults: the model writes the replies after a call, irreversible
  /// tools ask first, [contextLine] opens the newest user message.
  factory AssistantConfig.basic({
    required String systemPrompt,
    List<AssistantTool> tools = const [],
    AssistantStrings strings = AssistantStrings.english,
    String Function(DateTime today)? contextLine = ContextLines.english,
  }) => AssistantConfig(
    toolkit: Toolkit.of(tools),
    prompt: PromptLayout(systemPrompt: systemPrompt, contextLine: contextLine),
    strings: strings,
  );

  /// The tools.
  final Toolkit toolkit;

  /// The prompt's layout.
  final PromptLayout prompt;

  /// The model family; null detects it from the model (`ModelProfile.detect`). A loaded model keeps its profile until
  /// the next load.
  final ModelProfile? profile;

  /// Who writes the reply after a call.
  final ReplyStrategy replies;

  /// Which calls wait for a yes.
  final ConfirmationPolicy confirmation;

  /// How results show numbered lists and arguments name their items.
  final ListReferences listReferences;

  /// The screen an executed call asks the host to open; null for none.
  final ScreenRequestMapper? screenRequests;

  /// Checks of the model's plain answers, in order; the first verdict wins.
  final List<OutputGuard> guards;

  /// Rewrites the model's streamed text and plain answers (never app-written replies).
  final OutputRewriter? rewriter;

  /// Runs before the model call of each user message.
  final TurnHook? beforeModel;

  /// Runs before each call the assistant makes (not the host's): a non-null result stands for the call's.
  final ToolGate? beforeTool;

  /// The conversation texts.
  final AssistantStrings strings;

  /// How the tool-call grammar is built.
  final GrammarOptions grammar;

  /// The sampling of every generation; null uses the profile's.
  final SamplingOptions? sampling;

  /// A pause between showing a tool's status label and running it, so the label can be read.
  final Duration toolStatusDelay;

  /// Longest wait for a tool's result (a tool's own timeout wins); null waits forever. A call that times out gives
  /// `ToolFailure('timeout', AssistantStrings.toolFailed)` and its context is cancelled.
  final Duration? toolTimeout;

  /// What happens when a tool throws.
  final ToolErrorPolicy toolErrors;

  /// The conversation's day, read at every turn (the prompt's date line and `ToolContext.today`); null uses the
  /// assistant's clock.
  final DateTime Function()? today;

  /// Whether `Assistant.restore` brings back a snapshot's open question and offer (the default). False drops them, as
  /// a message that is not a yes or a no does: no question is open, no offer waits, the items come back without their
  /// actions (only an open question has any, its yes and no), so the item that asked shows its text alone, and
  /// `(its user text, strings.declined)` joins the history; a yes typed next goes to the model. For a toolkit whose
  /// `reset` (which `restore` runs) forgets the lists they name, where a yes could only answer that the list is gone,
  /// set it false.
  final bool restoreOpenQuestion;

  /// A copy with the given fields replaced (a null argument keeps the current value).
  AssistantConfig copyWith({
    Toolkit? toolkit,
    PromptLayout? prompt,
    ModelProfile? profile,
    ReplyStrategy? replies,
    ConfirmationPolicy? confirmation,
    ListReferences? listReferences,
    ScreenRequestMapper? screenRequests,
    List<OutputGuard>? guards,
    OutputRewriter? rewriter,
    TurnHook? beforeModel,
    ToolGate? beforeTool,
    AssistantStrings? strings,
    GrammarOptions? grammar,
    SamplingOptions? sampling,
    Duration? toolStatusDelay,
    Duration? toolTimeout,
    ToolErrorPolicy? toolErrors,
    DateTime Function()? today,
    bool? restoreOpenQuestion,
  }) => AssistantConfig(
    toolkit: toolkit ?? this.toolkit,
    prompt: prompt ?? this.prompt,
    profile: profile ?? this.profile,
    replies: replies ?? this.replies,
    confirmation: confirmation ?? this.confirmation,
    listReferences: listReferences ?? this.listReferences,
    screenRequests: screenRequests ?? this.screenRequests,
    guards: guards ?? this.guards,
    rewriter: rewriter ?? this.rewriter,
    beforeModel: beforeModel ?? this.beforeModel,
    beforeTool: beforeTool ?? this.beforeTool,
    strings: strings ?? this.strings,
    grammar: grammar ?? this.grammar,
    sampling: sampling ?? this.sampling,
    toolStatusDelay: toolStatusDelay ?? this.toolStatusDelay,
    toolTimeout: toolTimeout ?? this.toolTimeout,
    toolErrors: toolErrors ?? this.toolErrors,
    today: today ?? this.today,
    restoreOpenQuestion: restoreOpenQuestion ?? this.restoreOpenQuestion,
  );
}
