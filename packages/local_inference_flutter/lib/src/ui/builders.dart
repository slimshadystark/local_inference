/// Replaceable parts of the chat and model-setup UI. Each builder gets a context whose `buildDefault()` returns the
/// package's own widget for the slot, to wrap or decorate.
library;

import 'package:flutter/widgets.dart';
import 'package:local_inference/local_inference.dart';

import '../adapters/assistant_controller.dart';
import '../adapters/model_setup_controller.dart';
import 'features.dart';
import 'l10n/strings.dart';
import 'theme/local_inference_theme.dart';

/// What every chat builder gets: the controller, the resolved look, texts and switches, and the default widget.
class ChatSlotContext {
  const ChatSlotContext({
    required this.controller,
    required this.style,
    required this.strings,
    required this.features,
    required this.defaultBuilder,
  });

  final AssistantController controller;
  final LocalInferenceStyle style;
  final LocalInferenceStrings strings;
  final ChatFeatures features;

  /// Builds the package's widget for this slot; call [buildDefault].
  final Widget Function() defaultBuilder;

  /// The package's widget for this slot.
  Widget buildDefault() => defaultBuilder();
}

/// The welcome row at the top of the list.
class WelcomeContext extends ChatSlotContext {
  const WelcomeContext({
    required super.controller,
    required super.style,
    required super.strings,
    required super.features,
    required super.defaultBuilder,
    required this.text,
  });

  /// The chat view's `welcome` text; null when it has none.
  final String? text;
}

/// One message, and what can be done with it.
class MessageContext extends ChatSlotContext {
  const MessageContext({
    required super.controller,
    required super.style,
    required super.strings,
    required super.features,
    required super.defaultBuilder,
    required this.message,
    required this.isLatest,
    required this.isBusy,
    this.openScreen,
    this.report,
  });

  final ChatItem message;

  /// Whether it is the newest item.
  final bool isLatest;

  /// Whether a turn runs; for replies only (false for the user's messages, which do not rebuild with the turn).
  final bool isBusy;

  /// Opens the message's screen again; null when it has none, during a turn, or without `onScreenRequest`.
  final VoidCallback? openScreen;

  /// Opens the report sheet for the message; null when it cannot be reported.
  final VoidCallback? report;

  /// The screen readers' AI-generated hint, for a model-written reply with `ProvenanceMarking.semantics` on; null
  /// otherwise. The default text carries it; a builder that draws the text itself puts it there
  /// (`Semantics(container: true, hint: slot.provenanceHint, child: ...)`).
  String? get provenanceHint =>
      message.source == ReplySource.model && features.provenance.semantics ? strings.a11y.aiGeneratedHint : null;
}

/// The suggestion chips.
class SuggestionsContext extends ChatSlotContext {
  const SuggestionsContext({
    required super.controller,
    required super.style,
    required super.strings,
    required super.features,
    required super.defaultBuilder,
    required this.suggestions,
    required this.send,
    required this.enabled,
  });

  final List<String> suggestions;

  /// Sends a suggestion.
  final ValueChanged<String> send;
  final bool enabled;
}

/// The open question's buttons.
class ConfirmationButtonsContext extends ChatSlotContext {
  const ConfirmationButtonsContext({
    required super.controller,
    required super.style,
    required super.strings,
    required super.features,
    required super.defaultBuilder,
    required this.actions,
    required this.act,
    required this.enabled,
  });

  final List<ChatAction> actions;

  /// Performs an action.
  final ValueChanged<ChatAction> act;
  final bool enabled;
}

/// The composer.
class ComposerContext extends ChatSlotContext {
  const ComposerContext({
    required super.controller,
    required super.style,
    required super.strings,
    required super.features,
    required super.defaultBuilder,
    required this.text,
    required this.focus,
    required this.canSend,
    required this.isBusy,
    required this.send,
    required this.stop,
  });

  /// The draft (`AssistantController.draft`).
  final TextEditingController text;
  final FocusNode focus;
  final bool canSend;
  final bool isBusy;

  /// Sends [text] or, without it, the draft (then clears it); `ChatCallbacks.beforeSend` runs first.
  final void Function([String? text]) send;

  /// Stops the turn.
  final VoidCallback stop;
}

/// Which panel the chat shows instead of the conversation.
enum ChatPanelKind {
  /// A model loads, or the model list is read at start.
  preparing,

  /// A model's prefix state is built, the first time with it.
  preparingFirstTime,

  /// The model could not be loaded ("Retry").
  loadFailed,

  /// No model to load: the chat has no setup, or its setup has no model manager ("Refresh").
  noModel,

  /// A model is there but not loaded ("Load"): automatic loads are off, the model was unloaded on purpose, or the
  /// setup only downloads.
  modelAvailable,

  /// The model list could not be read ("Retry").
  catalogUnavailable,

  /// No model is offered.
  noneOffered,
}

/// What a panel shows.
@immutable
final class ChatPanelData {
  const ChatPanelData({
    required this.icon,
    required this.title,
    this.subtitle,
    this.progress = false,
    this.isError = false,
    this.action,
    this.details,
  });

  final IconData icon;
  final String title;
  final String? subtitle;

  /// Technical text under the rest (the raw error, with `ChatFeatures.showDetails`).
  final String? details;

  /// An indeterminate progress bar under the texts.
  final bool progress;

  /// The icon in the error color.
  final bool isError;

  /// A button under the texts.
  final Widget? action;
}

/// A panel of the chat.
class StatusPanelContext extends ChatSlotContext {
  const StatusPanelContext({
    required super.controller,
    required super.style,
    required super.strings,
    required super.features,
    required super.defaultBuilder,
    required this.kind,
    required this.data,
  });

  final ChatPanelKind kind;
  final ChatPanelData data;
}

/// The chat without a model to load.
class NoModelContext extends ChatSlotContext {
  const NoModelContext({
    required super.controller,
    required super.style,
    required super.strings,
    required super.features,
    required super.defaultBuilder,
    this.setup,
  });

  /// The chat's setup, when it has one (its `refresh` looks for model files again).
  final ModelSetupController? setup;
}

/// The AI disclosure.
class DisclosureContext extends ChatSlotContext {
  const DisclosureContext({
    required super.controller,
    required super.style,
    required super.strings,
    required super.features,
    required super.defaultBuilder,
    required this.mode,
    this.dismiss,
  });

  final AiDisclosureMode mode;

  /// Closes it ([AiDisclosureMode.dismissible] only).
  final VoidCallback? dismiss;
}

/// The jump-to-latest button.
class JumpToLatestContext extends ChatSlotContext {
  const JumpToLatestContext({
    required super.controller,
    required super.style,
    required super.strings,
    required super.features,
    required super.defaultBuilder,
    required this.jump,
  });

  /// Scrolls to the newest message.
  final VoidCallback jump;
}

/// Builds one slot of the chat.
typedef ChatSlotBuilder<T extends ChatSlotContext> = Widget Function(BuildContext context, T slot);

/// Replacements for parts of the chat; a null builder keeps the package's widget.
@immutable
final class ChatBuilders {
  const ChatBuilders({
    this.header,
    this.welcome,
    this.userMessage,
    this.assistantMessage,
    this.messageText,
    this.thinking,
    this.toolStatus,
    this.screenChip,
    this.footer,
    this.details,
    this.suggestions,
    this.confirmation,
    this.composer,
    this.statusPanel,
    this.noModel,
    this.disclosure,
    this.jumpToLatest,
    this.setup = const ModelSetupBuilders(),
  });

  /// Above the messages (default: nothing).
  final ChatSlotBuilder<ChatSlotContext>? header;

  /// The welcome row (default: the view's `welcome` text as a reply). With `AiDisclosureMode.inWelcome` the
  /// disclosure follows the row the builder draws.
  final ChatSlotBuilder<WelcomeContext>? welcome;

  /// A user message (default: `UserMessageBubble`).
  final ChatSlotBuilder<MessageContext>? userMessage;

  /// A reply (default: `AssistantMessage`, whose parts are the next builders). The welcome row is not a reply: it has
  /// its own builder, [welcome]. A builder that draws a reply's text itself marks it (`MessageContext.provenanceHint`).
  final ChatSlotBuilder<MessageContext>? assistantMessage;

  /// A reply's text (default: `MessageText`); one that does not call `buildDefault()` marks model-written text
  /// (`MessageContext.provenanceHint`).
  final ChatSlotBuilder<MessageContext>? messageText;

  /// "Thinking…" (default: `ThinkingIndicator`).
  final ChatSlotBuilder<MessageContext>? thinking;

  /// A running tool's label, `message.status` (default: `ToolStatusIndicator`).
  final ChatSlotBuilder<MessageContext>? toolStatus;

  /// The chip that opens `message.screenRequest` again (default: `ScreenRequestChip`).
  final ChatSlotBuilder<MessageContext>? screenChip;

  /// Under a reply (default: the report button and the AI-generated mark, when enabled).
  final ChatSlotBuilder<MessageContext>? footer;

  /// A reply's technical details (default: `MessageDetails`, when `ChatFeatures.showDetails`).
  final ChatSlotBuilder<MessageContext>? details;

  final ChatSlotBuilder<SuggestionsContext>? suggestions;
  final ChatSlotBuilder<ConfirmationButtonsContext>? confirmation;

  /// The composer (default: a divider above `ChatComposer`).
  final ChatSlotBuilder<ComposerContext>? composer;
  final ChatSlotBuilder<StatusPanelContext>? statusPanel;

  /// The chat without a model and without a setup to download one (default: a panel with "Refresh").
  final ChatSlotBuilder<NoModelContext>? noModel;

  final ChatSlotBuilder<DisclosureContext>? disclosure;
  final ChatSlotBuilder<JumpToLatestContext>? jumpToLatest;

  /// The model setup's parts, inside the chat.
  final ModelSetupBuilders setup;
}

/// What every model-setup builder gets.
class SetupSlotContext {
  const SetupSlotContext({required this.style, required this.strings, required this.defaultBuilder});

  final LocalInferenceStyle style;
  final LocalInferenceStrings strings;

  /// Builds the package's widget for this slot; call [buildDefault].
  final Widget Function() defaultBuilder;

  /// The package's widget for this slot.
  Widget buildDefault() => defaultBuilder();
}

/// A stage of the setup.
class SetupStageContext extends SetupSlotContext {
  const SetupStageContext({
    required super.style,
    required super.strings,
    required super.defaultBuilder,
    required this.setup,
    required this.stage,
  });

  final ModelSetupController setup;
  final SetupStage stage;

  /// The model the stage is about; null in the panels without one.
  ModelEntry? get entry => setup.entry;

  /// Its status.
  ModelStatus? get status => setup.status;
}

/// What a model card can do; a null action is not available now.
@immutable
final class ModelTileActions {
  const ModelTileActions({
    this.download,
    this.pause,
    this.resume,
    this.cancel,
    this.useCellular,
    this.use,
    this.delete,
  });

  final VoidCallback? download;
  final VoidCallback? pause;
  final VoidCallback? resume;
  final VoidCallback? cancel;

  /// Downloads over mobile data, after asking.
  final VoidCallback? useCellular;

  /// Makes the chat use the model.
  final VoidCallback? use;

  /// Deletes the model, after asking.
  final VoidCallback? delete;
}

/// A model's card in the model list.
class ModelTileContext extends SetupSlotContext {
  const ModelTileContext({
    required super.style,
    required super.strings,
    required super.defaultBuilder,
    required this.manager,
    required this.entry,
    required this.status,
    required this.actions,
    required this.inUse,
  });

  final ModelManager manager;
  final ModelEntry entry;
  final ModelStatus status;
  final ModelTileActions actions;

  /// Whether the chat uses this model.
  final bool inUse;
}

/// A confirmation the setup asks (mobile data, delete).
@immutable
final class ConfirmDialogRequest {
  const ConfirmDialogRequest({required this.title, required this.message, this.action, this.destructive = false});

  final String title;
  final String message;

  /// The confirming button; null shows a notice with one button.
  final String? action;

  /// The action deletes something.
  final bool destructive;
}

/// Shows [request] and completes with the user's answer.
typedef ConfirmDialogPresenter = Future<bool> Function(BuildContext context, ConfirmDialogRequest request);

/// Builds one slot of the model setup.
typedef SetupSlotBuilder<T extends SetupSlotContext> = Widget Function(BuildContext context, T slot);

/// Replacements for parts of the model setup; a null builder keeps the package's widget.
@immutable
final class ModelSetupBuilders {
  const ModelSetupBuilders({
    this.consent,
    this.progress,
    this.noneOffered,
    this.catalogUnavailable,
    this.tile,
    this.confirmDialog,
  });

  /// The consent to download (default: `ModelConsentView`).
  final SetupSlotBuilder<SetupStageContext>? consent;

  /// The download's progress (default: `ModelProgressView`).
  final SetupSlotBuilder<SetupStageContext>? progress;

  /// No model offered (default: a panel).
  final SetupSlotBuilder<SetupStageContext>? noneOffered;

  /// The model list could not be read (default: a panel with "Retry").
  final SetupSlotBuilder<SetupStageContext>? catalogUnavailable;

  /// A card of the model list (default: `ModelTile`).
  final SetupSlotBuilder<ModelTileContext>? tile;

  /// The mobile-data and delete confirmations (default: an AlertDialog).
  final ConfirmDialogPresenter? confirmDialog;
}
