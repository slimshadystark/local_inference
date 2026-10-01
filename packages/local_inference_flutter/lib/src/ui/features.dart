/// What the chat UI shows and does, as switches.
library;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/widgets.dart';

import '../adapters/scope.dart';
import 'internal/resolved.dart';

/// Where the AI disclosure (EU AI Act, art. 50(1)) is shown.
enum AiDisclosureMode {
  /// A banner above the messages, always there (the default).
  banner,

  /// The same banner with a close button; the host keeps the choice (`ChatCallbacks.onDisclosureDismissed`).
  dismissible,

  /// A paragraph under the welcome text.
  inWelcome,

  /// Not shown: the host discloses in its own way.
  none,
}

/// Where a reply can be reported (with `ChatCallbacks.onReport` set).
enum ReportAffordance {
  /// Nowhere.
  none,

  /// "Report reply" in the text-selection menu (the default).
  menu,

  /// A flag button under each reply.
  icon,

  /// Both.
  both;

  bool get inMenu => this == menu || this == both;
  bool get asIcon => this == icon || this == both;
}

/// How model-written replies are marked as AI-generated.
@immutable
final class ProvenanceMarking {
  const ProvenanceMarking({this.semantics = true, this.badge = false, this.copyNotice});

  /// A semantics hint on model-written text, readable by assistive technology and automated tools.
  final bool semantics;

  /// A small visible mark under model-written replies.
  final bool badge;

  /// A line appended to text copied from a reply; null appends nothing.
  final String? copyNotice;

  @override
  bool operator ==(Object other) =>
      other is ProvenanceMarking &&
      other.semantics == semantics &&
      other.badge == badge &&
      other.copyNotice == copyNotice;

  @override
  int get hashCode => Object.hash(semantics, badge, copyNotice);
}

/// The chat UI's switches. The defaults suit a new app; [copyWith] changes any of them.
@immutable
final class ChatFeatures {
  const ChatFeatures({
    this.showDetails = false,
    this.showSuggestions = true,
    this.showConfirmationButtons = true,
    this.showScreenChips = true,
    this.aiDisclosure = AiDisclosureMode.banner,
    this.reportAffordance = ReportAffordance.menu,
    this.provenance = const ProvenanceMarking(),
    this.selectableText = true,
    this.selectableUserText = true,
    this.copyAction = true,
    this.newConversationAction = true,
    this.stopButton = true,
    this.jumpToLatest = true,
    this.autoScroll = true,
    this.announceReplies = true,
    this.tooltips = true,
    this.haptics = false,
    this.composerMaxLines = 5,
    this.maxInputLength,
    this.submitOnKeyboardAction = true,
    this.submitOnEnter = true,
  });

  /// The technical details under each reply (timings, raw output, tool calls).
  final bool showDetails;

  /// The suggestion chips before the first message.
  final bool showSuggestions;

  /// The Yes and No buttons of a question.
  final bool showConfirmationButtons;

  /// The chips that open a reply's screen again.
  final bool showScreenChips;

  final AiDisclosureMode aiDisclosure;
  final ReportAffordance reportAffordance;
  final ProvenanceMarking provenance;

  /// The replies' text can be selected and copied.
  final bool selectableText;

  /// The user's messages can be selected and copied.
  final bool selectableUserText;

  /// "Copy" in the selection menu of the messages.
  final bool copyAction;

  /// The new-conversation button of the app bar.
  final bool newConversationAction;

  /// The send button turns into a stop button during a turn.
  final bool stopButton;

  /// The button that scrolls back to the newest message when new text arrived below.
  final bool jumpToLatest;

  /// Follow new text when the list is at the bottom, and go to the newest message when the user sends a message or
  /// answers a question; false never scrolls by itself.
  final bool autoScroll;

  /// Read a finished reply aloud when a screen reader is on.
  final bool announceReplies;

  /// Tooltips on the icon buttons (their semantic labels stay either way).
  final bool tooltips;

  /// A light haptic tick on send and on a question's buttons.
  final bool haptics;

  final int composerMaxLines;

  /// The longest message; null for no limit.
  final int? maxInputLength;

  /// The mobile keyboard's send key sends.
  final bool submitOnKeyboardAction;

  /// Enter sends on a desktop (Shift+Enter starts a new line).
  final bool submitOnEnter;

  /// The features at [context]: [override], else the enclosing chat view's, else the scope's, else the defaults.
  static ChatFeatures of(BuildContext context, [ChatFeatures? override]) =>
      override ??
      ResolvedLook.maybeOf(context)?.features ??
      LocalInferenceScope.maybeOf(context)?.features ??
      const ChatFeatures();

  ChatFeatures copyWith({
    bool? showDetails,
    bool? showSuggestions,
    bool? showConfirmationButtons,
    bool? showScreenChips,
    AiDisclosureMode? aiDisclosure,
    ReportAffordance? reportAffordance,
    ProvenanceMarking? provenance,
    bool? selectableText,
    bool? selectableUserText,
    bool? copyAction,
    bool? newConversationAction,
    bool? stopButton,
    bool? jumpToLatest,
    bool? autoScroll,
    bool? announceReplies,
    bool? tooltips,
    bool? haptics,
    int? composerMaxLines,
    int? maxInputLength,
    bool? submitOnKeyboardAction,
    bool? submitOnEnter,
  }) => ChatFeatures(
    showDetails: showDetails ?? this.showDetails,
    showSuggestions: showSuggestions ?? this.showSuggestions,
    showConfirmationButtons: showConfirmationButtons ?? this.showConfirmationButtons,
    showScreenChips: showScreenChips ?? this.showScreenChips,
    aiDisclosure: aiDisclosure ?? this.aiDisclosure,
    reportAffordance: reportAffordance ?? this.reportAffordance,
    provenance: provenance ?? this.provenance,
    selectableText: selectableText ?? this.selectableText,
    selectableUserText: selectableUserText ?? this.selectableUserText,
    copyAction: copyAction ?? this.copyAction,
    newConversationAction: newConversationAction ?? this.newConversationAction,
    stopButton: stopButton ?? this.stopButton,
    jumpToLatest: jumpToLatest ?? this.jumpToLatest,
    autoScroll: autoScroll ?? this.autoScroll,
    announceReplies: announceReplies ?? this.announceReplies,
    tooltips: tooltips ?? this.tooltips,
    haptics: haptics ?? this.haptics,
    composerMaxLines: composerMaxLines ?? this.composerMaxLines,
    maxInputLength: maxInputLength ?? this.maxInputLength,
    submitOnKeyboardAction: submitOnKeyboardAction ?? this.submitOnKeyboardAction,
    submitOnEnter: submitOnEnter ?? this.submitOnEnter,
  );

  List<Object?> get _fields => [
    showDetails,
    showSuggestions,
    showConfirmationButtons,
    showScreenChips,
    aiDisclosure,
    reportAffordance,
    provenance,
    selectableText,
    selectableUserText,
    copyAction,
    newConversationAction,
    stopButton,
    jumpToLatest,
    autoScroll,
    announceReplies,
    tooltips,
    haptics,
    composerMaxLines,
    maxInputLength,
    submitOnKeyboardAction,
    submitOnEnter,
  ];

  @override
  bool operator ==(Object other) => other is ChatFeatures && listEquals(other._fields, _fields);

  @override
  int get hashCode => Object.hashAll(_fields);
}
