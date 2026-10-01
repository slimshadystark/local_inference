/// The chat: [ChatView] (no Scaffold, embeddable anywhere) and [ChatPage] (a page with an app bar).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:local_inference/local_inference.dart';

import '../../adapters/analytics.dart';
import '../../adapters/assistant_controller.dart';
import '../../adapters/chat_scroll_controller.dart';
import '../../adapters/model_setup_controller.dart';
import '../../adapters/scope.dart';
import '../../adapters/screen_request_dispatcher.dart';
import '../builders.dart';
import '../callbacks.dart';
import '../compliance/compliance.dart';
import '../features.dart';
import '../internal/conversation_layout.dart';
import '../internal/resolved.dart';
import '../internal/setup_panels.dart';
import '../keys.dart';
import '../l10n/strings.dart';
import '../setup/model_views.dart';
import '../theme/local_inference_theme.dart';
import 'controls.dart';
import 'message_list.dart';
import 'messages.dart';
import 'status_panel.dart';

/// A chat over an [AssistantController], without a Scaffold: put it in a page, a tab, a panel or a split view.
///
/// It shows, by the assistant's phase: without a model, the [setup] flow (or the `noModel` panel); while a model
/// loads, "preparing" (with a first-time note while its prefix state is built); after a failed load, the error with
/// "Retry"; then the conversation: the disclosure, the messages, the question's buttons or the suggestions, and the
/// composer.
///
/// [controller] and [setup] default to the [LocalInferenceScope]'s. The look, texts and switches come from [theme],
/// [strings] and [features], else the scope's, else the app theme's extension and the locale.
class ChatView extends StatefulWidget {
  const ChatView({
    super.key,
    this.controller,
    this.setup,
    this.assistantName,
    this.welcome,
    this.suggestions = const [],
    this.features,
    this.builders = const ChatBuilders(),
    this.callbacks = const ChatCallbacks(),
    this.screenRequestPolicy = const ScreenRequestPolicy(),
    this.strings,
    this.theme,
    this.scrollController,
    this.focusNode,
  });

  final AssistantController? controller;
  final ModelSetupController? setup;

  /// The assistant's name (screen readers, the consent's title); null uses [ChatStrings.defaultAssistantName].
  final String? assistantName;

  /// The first row of the list, drawn as a reply; null shows none.
  final String? welcome;

  /// Chips shown before the first message; a tap sends one.
  final List<String> suggestions;

  final ChatFeatures? features;
  final ChatBuilders builders;
  final ChatCallbacks callbacks;
  final ScreenRequestPolicy screenRequestPolicy;
  final LocalInferenceStrings? strings;
  final LocalInferenceTheme? theme;

  /// Null makes a [ChatScrollController] with the default threshold.
  final ChatScrollController? scrollController;

  /// The composer's focus; null makes one.
  final FocusNode? focusNode;

  @override
  State<ChatView> createState() => _ChatViewState();
}

enum _Mode { conversation, noModel, preparing, preparingFirstTime, failed }

class _ChatViewState extends State<ChatView> {
  AssistantController? _controller;
  ModelSetupController? _setup;
  ScreenRequestDispatcher? _dispatcher;
  StreamSubscription<AssistantEvent>? _events;
  ChatScrollController? _ownScroll;
  FocusNode? _ownFocus;
  _Mode _mode = _Mode.noModel;

  AssistantController get _chat => _controller!;

  ChatScrollController get _scroll => widget.scrollController ?? (_ownScroll ??= ChatScrollController());

  FocusNode get _focus => widget.focusNode ?? (_ownFocus ??= FocusNode(debugLabel: 'local_inference.composer'));

  String _name(LocalInferenceStrings strings) => widget.assistantName ?? strings.chat.defaultAssistantName;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolve();
    // The route may have become current again: a screen request waiting for the chat opens now.
    _dispatcher?.attach(context);
  }

  @override
  void didUpdateWidget(covariant ChatView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The dispatcher calls the current callbacks and follows the current policy; only callbacks appearing or going
    // remake it (the requests it holds would be lost).
    _resolve(
      rebuildDispatcher: (oldWidget.callbacks.onScreenRequest == null) != (widget.callbacks.onScreenRequest == null),
    );
    _dispatcher?.policy = widget.screenRequestPolicy;
    // A tab host rebuilds the chat when its tab changes: a request waiting for the chat opens if it is visible now.
    _dispatcher?.attach(context);
    if (oldWidget.scrollController == null && widget.scrollController != null) {
      final own = _ownScroll;
      _ownScroll = null;
      if (own != null) WidgetsBinding.instance.addPostFrameCallback((_) => own.dispose());
    }
  }

  void _resolve({bool rebuildDispatcher = false}) {
    final scope = LocalInferenceScope.maybeOf(context);
    final controller = widget.controller ?? scope?.assistant;
    if (controller == null) {
      throw FlutterError(
        'ChatView needs a controller: pass one, or put a LocalInferenceScope with an assistant above it.',
      );
    }
    if (!identical(controller, _controller)) {
      _detach();
      _controller = controller;
      _mode = _modeOf(controller.phase.value);
      controller.phase.addListener(_onPhase);
      _events = controller.events.listen(_onEvent);
      controller.track(ChatShownEvent());
      rebuildDispatcher = true;
    }
    if (rebuildDispatcher) _makeDispatcher();
    final setup = widget.setup ?? scope?.setup;
    assert(
      setup?.assistant == null || identical(setup!.assistant, controller),
      "A chat's ModelSetupController loads the chat's own AssistantController: pass it as the setup's assistant.",
    );
    if (!identical(setup, _setup)) {
      _setup = setup;
      setup?.init().ignore();
    }
  }

  void _makeDispatcher() {
    _dispatcher?.dispose();
    _dispatcher = null;
    if (widget.callbacks.onScreenRequest == null) return;
    _dispatcher = ScreenRequestDispatcher(
      controller: _chat,
      onScreenRequest: (context, dispatch) => widget.callbacks.onScreenRequest?.call(context, dispatch),
      policy: widget.screenRequestPolicy,
      onStale: (context, dispatch) => (widget.callbacks.onStaleScreenRequest ?? _staleNote)(context, dispatch),
    )..attach(context);
  }

  void _staleNote(BuildContext context, ScreenRequestDispatch dispatch) {
    final strings = LocalInferenceStrings.of(context, widget.strings);
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(strings.chat.staleScreenRequest)));
  }

  void _detach() {
    _controller?.phase.removeListener(_onPhase);
    _events?.cancel().ignore();
    _events = null;
    _dispatcher?.dispose();
    _dispatcher = null;
  }

  static _Mode _modeOf(AssistantPhase phase) => switch (phase) {
    AssistantPhase.noModel => _Mode.noModel,
    AssistantPhase.loading => _Mode.preparing,
    AssistantPhase.preparing => _Mode.preparingFirstTime,
    AssistantPhase.failed => _Mode.failed,
    AssistantPhase.ready || AssistantPhase.busy => _Mode.conversation,
  };

  void _onPhase() {
    final mode = _modeOf(_chat.phase.value);
    if (mode == _mode || !mounted) return;
    setState(() => _mode = mode);
    // The panel names the kind of failure only: in debug builds the cause goes to the console (and, with
    // showDetails, under the panel).
    assert(() {
      if (mode == _Mode.failed) {
        debugPrint('local_inference_flutter: the model could not be loaded: ${_chat.assistant.state.loadError}');
      }
      return true;
    }());
  }

  /// A finished reply is read aloud when a screen reader is on.
  void _onEvent(AssistantEvent event) {
    if (event is! TurnFinishedEvent || !mounted) return;
    final outcome = event.outcome;
    // The view's own switches, else a ChatPage's or LocalInferenceChat's around it, else the scope's.
    final features = ChatFeatures.of(context, widget.features);
    if (!features.announceReplies || !outcome.accepted || outcome.reply.isEmpty) return;
    if (!MediaQuery.accessibleNavigationOf(context)) return;
    final strings = LocalInferenceStrings.of(context, widget.strings);
    SemanticsService.sendAnnouncement(
      View.of(context),
      strings.a11y.replyAnnouncement(_name(strings), outcome.reply),
      Directionality.of(context),
    ).ignore();
  }

  @override
  void dispose() {
    _detach();
    _ownScroll?.dispose();
    _ownFocus?.dispose();
    super.dispose();
  }

  /// Sends [text] or the draft: nothing when empty or while no message can be sent; `beforeSend` may refuse it.
  Future<void> _send([String? text, bool fromSuggestion = false]) async {
    final controller = _chat;
    final value = (text ?? controller.draft.text).trim();
    if (value.isEmpty || !controller.composer.value.canSend) return;
    final beforeSend = widget.callbacks.beforeSend;
    if (beforeSend != null) {
      final allowed = beforeSend(value);
      if (!(allowed is Future<bool> ? await allowed : allowed)) return;
      if (!mounted || !controller.composer.value.canSend) return;
    }
    controller.draft.clear();
    if (ChatFeatures.of(context, widget.features).haptics) HapticFeedback.lightImpact().ignore();
    _toLatest();
    controller.send(value, fromSuggestion: fromSuggestion).ignore();
  }

  /// Answers the open question with [action].
  void _act(ChatAction action) {
    _toLatest();
    _chat.act(action).ignore();
  }

  /// The user's own message or answer ends reading back: the list goes to the newest message and follows the reply,
  /// so a question shows above its buttons. Not with auto-scroll off, which never scrolls by itself.
  void _toLatest() {
    if (ChatFeatures.of(context, widget.features).autoScroll) _scroll.jumpToLatest().ignore();
  }

  Future<void> _report(BuildContext context, ChatItem message) async {
    final onReport = widget.callbacks.onReport;
    if (onReport == null) return;
    final strings = LocalInferenceStrings.of(context);
    final request = await showReportSheet(context, controller: _chat, message: message);
    if (request == null) return;
    _chat.track(ReplyReportedEvent(reason: request.reason));
    try {
      await onReport(request);
    } on Object catch (error, stack) {
      // Not recorded, so no thanks; the host's failure goes where Flutter's errors go.
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'local_inference_flutter',
          context: ErrorDescription('while handing a report to ChatCallbacks.onReport'),
        ),
      );
      return;
    }
    if (!context.mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(strings.chat.reportThanks)));
  }

  @override
  Widget build(BuildContext context) {
    return ResolvedLook.wrap(
      context,
      theme: widget.theme,
      strings: widget.strings,
      features: widget.features,
      child: Material(
        type: MaterialType.transparency,
        child: Builder(builder: _body),
      ),
    );
  }

  Widget _body(BuildContext context) => switch (_mode) {
    _Mode.conversation => _conversation(context),
    _Mode.noModel => _noModel(context),
    _Mode.preparing => _preparing(context, firstTime: false),
    _Mode.preparingFirstTime => _preparing(context, firstTime: true),
    _Mode.failed => _failed(context),
  };

  ChatSlotContext _slot(BuildContext context, Widget Function() buildDefault) => ChatSlotContext(
    controller: _chat,
    style: LocalInferenceStyle.of(context),
    strings: LocalInferenceStrings.of(context),
    features: ChatFeatures.of(context),
    defaultBuilder: buildDefault,
  );

  Widget _panel(BuildContext context, ChatPanelKind kind, ChatPanelData data) {
    Widget build() => ChatStatusPanel.fromData(data);
    final builder = widget.builders.statusPanel;
    if (builder == null) return build();
    final slot = _slot(context, build);
    return builder(
      context,
      StatusPanelContext(
        controller: slot.controller,
        style: slot.style,
        strings: slot.strings,
        features: slot.features,
        defaultBuilder: build,
        kind: kind,
        data: data,
      ),
    );
  }

  Widget _preparing(BuildContext context, {required bool firstTime}) {
    final strings = LocalInferenceStrings.of(context).chat;
    return _panel(
      context,
      firstTime ? ChatPanelKind.preparingFirstTime : ChatPanelKind.preparing,
      ChatPanelData(
        icon: Icons.memory_outlined,
        title: strings.preparingTitle,
        subtitle: firstTime ? strings.preparingFirstTime : null,
        progress: true,
      ),
    );
  }

  Widget _failed(BuildContext context) {
    final strings = LocalInferenceStrings.of(context).chat;
    final error = _chat.assistant.state.loadError;
    return _panel(
      context,
      ChatPanelKind.loadFailed,
      ChatPanelData(
        icon: Icons.error_outline,
        title: strings.loadFailedTitle,
        subtitle: strings.loadFailed(error ?? ''),
        details: ChatFeatures.of(context).showDetails && error != null ? '$error' : null,
        isError: true,
        action: FilledButton.tonalIcon(
          key: LocalInferenceKeys.retryLoad,
          onPressed: () => _chat.retryLoad().ignore(),
          icon: const Icon(Icons.refresh),
          label: Text(strings.retry),
        ),
      ),
    );
  }

  /// Without a model: the setup's flow when there is one, else the panel that says so.
  Widget _noModel(BuildContext context) {
    final setup = _setup;
    if (setup == null) return _noModelPanel(context, null);
    return ListenableBuilder(
      listenable: setup,
      builder: (context, _) => switch (setup.stage) {
        SetupStage.noneOffered when setup.manager == null => _noModelPanel(context, setup),
        // A model is there and nothing loads it by itself, or a setup that only downloads installed one.
        SetupStage.modelAvailable => _panel(
          context,
          ChatPanelKind.modelAvailable,
          modelAvailablePanel(context, () => setup.refresh().ignore()),
        ),
        SetupStage.ready || SetupStage.loadingModel => switch (setup.candidates.firstOrNull) {
          final candidate? => _panel(
            context,
            ChatPanelKind.modelAvailable,
            modelAvailablePanel(context, () => _chat.loadModel(candidate.path).ignore()),
          ),
          null => _noModelPanel(context, setup),
        },
        _ => SetupPanels(
          build: _panel,
          child: ModelSetupView(
            controller: setup,
            assistantName: widget.assistantName,
            builders: widget.builders.setup,
          ),
        ),
      },
    );
  }

  /// No model to load; with [setup], "Refresh" looks for model files again.
  Widget _noModelPanel(BuildContext context, ModelSetupController? setup) {
    final style = LocalInferenceStyle.of(context);
    final strings = LocalInferenceStrings.of(context).chat;
    Widget build() => _panel(
      context,
      ChatPanelKind.noModel,
      ChatPanelData(
        icon: Icons.cloud_download_outlined,
        title: strings.noModelTitle,
        // Without a setup nothing here can look for models: the host loads one.
        subtitle: setup == null ? null : strings.noModelSubtitle,
        action: setup == null
            ? null
            : FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: style.accent, foregroundColor: style.onAccent),
                onPressed: () => setup.refresh().ignore(),
                icon: const Icon(Icons.refresh),
                label: Text(strings.refresh),
              ),
      ),
    );
    final builder = widget.builders.noModel;
    if (builder == null) return build();
    final slot = _slot(context, build);
    return builder(
      context,
      NoModelContext(
        controller: slot.controller,
        style: slot.style,
        strings: slot.strings,
        features: slot.features,
        defaultBuilder: build,
        setup: setup,
      ),
    );
  }

  Widget _conversation(BuildContext context) {
    final features = ChatFeatures.of(context);
    final strings = LocalInferenceStrings.of(context);
    final builders = widget.builders;
    final header = builders.header;
    final disclosure = _disclosure(context, features);
    final welcome = _welcomeRow(features, strings);
    // With large text on a small screen, the disclosure and the action bar scroll within a part of the height, so
    // the messages keep theirs.
    Widget yielding(Widget child) => ConversationSlot(
      part: ConversationPart.yielding,
      child: SingleChildScrollView(primary: false, child: child),
    );
    return ConversationColumn(
      children: [
        if (header != null)
          ConversationSlot(
            part: ConversationPart.fixed,
            child: header(context, _slot(context, () => const SizedBox.shrink())),
          ),
        if (disclosure != null) yielding(disclosure),
        ConversationSlot(
          part: ConversationPart.messages,
          child: Stack(
            children: [
              ChatMessageList(
                controller: _chat,
                scrollController: _scroll,
                autoScroll: features.autoScroll,
                leading: [?welcome],
                messageBuilder: _message,
              ),
              if (features.jumpToLatest)
                PositionedDirectional(
                  end: 12,
                  bottom: 12,
                  child: ValueListenableBuilder<bool>(
                    valueListenable: _scroll.hasUnseen,
                    builder: (context, unseen, _) => unseen ? _jumpButton(context) : const SizedBox.shrink(),
                  ),
                ),
            ],
          ),
        ),
        yielding(
          ChatActionBar(
            controller: _chat,
            suggestions: widget.suggestions,
            onSuggestion: (text) => _send(text, true).ignore(),
            onAction: _act,
            builders: builders,
          ),
        ),
        ConversationSlot(part: ConversationPart.fixed, child: _composer(context)),
      ],
    );
  }

  WidgetBuilder? _welcomeRow(ChatFeatures features, LocalInferenceStrings strings) {
    final text = widget.welcome;
    final footnote = features.aiDisclosure == AiDisclosureMode.inWelcome ? strings.chat.disclosure : null;
    final builder = widget.builders.welcome;
    if (text == null && footnote == null && builder == null) return null;
    return (context) {
      if (builder == null) return WelcomeMessage(text: text ?? '', footnote: footnote);
      Widget build() => WelcomeMessage(text: text ?? '');
      final slot = _slot(context, build);
      final row = builder(
        context,
        WelcomeContext(
          controller: slot.controller,
          style: slot.style,
          strings: slot.strings,
          features: slot.features,
          defaultBuilder: build,
          text: text,
        ),
      );
      if (footnote == null) return row;
      // The disclosure is not the builder's to drop: it follows whatever the builder drew.
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          row,
          WelcomeMessage(key: const ValueKey('local_inference.welcomeDisclosure'), text: '', footnote: footnote),
        ],
      );
    };
  }

  Widget? _disclosure(BuildContext context, ChatFeatures features) {
    final mode = features.aiDisclosure;
    if (mode != AiDisclosureMode.banner && mode != AiDisclosureMode.dismissible) return null;
    Widget banner(VoidCallback? dismiss) {
      Widget build() => AiDisclosureBanner(onDismiss: dismiss);
      final builder = widget.builders.disclosure;
      if (builder == null) return build();
      final slot = _slot(context, build);
      return builder(
        context,
        DisclosureContext(
          controller: slot.controller,
          style: slot.style,
          strings: slot.strings,
          features: slot.features,
          defaultBuilder: build,
          mode: mode,
          dismiss: dismiss,
        ),
      );
    }

    if (mode == AiDisclosureMode.banner) return banner(null);
    return ValueListenableBuilder<bool>(
      valueListenable: _chat.disclosureDismissed,
      builder: (context, dismissed, _) => dismissed
          ? const SizedBox.shrink()
          : banner(() {
              _chat.disclosureDismissed.value = true;
              widget.callbacks.onDisclosureDismissed?.call();
            }),
    );
  }

  Widget _jumpButton(BuildContext context) {
    void jump() => _scroll.jumpToLatest().ignore();
    Widget build() => JumpToLatestButton(onPressed: jump);
    final builder = widget.builders.jumpToLatest;
    if (builder == null) return build();
    final slot = _slot(context, build);
    return builder(
      context,
      JumpToLatestContext(
        controller: slot.controller,
        style: slot.style,
        strings: slot.strings,
        features: slot.features,
        defaultBuilder: build,
        jump: jump,
      ),
    );
  }

  Widget _message(BuildContext context, ChatItem item, bool isLatest) {
    final callbacks = widget.callbacks;
    if (item.role == MessageRole.user) {
      Widget build() => UserMessageBubble(message: item, onCopy: callbacks.onCopy);
      final builder = widget.builders.userMessage;
      return builder == null ? build() : builder(context, _messageContext(context, item, isLatest, false, build));
    }
    return ValueListenableBuilder<ComposerState>(
      valueListenable: _chat.composer,
      builder: (context, composer, _) {
        final dispatcher = _dispatcher;
        final onReport = callbacks.onReport;
        final open = dispatcher != null && item.screenRequest != null
            ? () => dispatcher.openFromChip(context, item)
            : null;
        final report = onReport != null && ChatFeatures.of(context).reportAffordance != ReportAffordance.none
            ? () => _report(context, item).ignore()
            : null;
        Widget build() => AssistantMessage(
          message: item,
          assistantName: _name(LocalInferenceStrings.of(context)),
          isBusy: composer.isBusy,
          isLatest: isLatest,
          onOpenScreen: open,
          onReport: report,
          onCopy: callbacks.onCopy,
          onLinkTap: callbacks.onLinkTap,
          controller: _chat,
          builders: widget.builders,
        );
        final builder = widget.builders.assistantMessage;
        return builder == null
            ? build()
            : builder(
                context,
                _messageContext(context, item, isLatest, composer.isBusy, build, openScreen: open, report: report),
              );
      },
    );
  }

  MessageContext _messageContext(
    BuildContext context,
    ChatItem item,
    bool isLatest,
    bool isBusy,
    Widget Function() build, {
    VoidCallback? openScreen,
    VoidCallback? report,
  }) => MessageContext(
    controller: _chat,
    style: LocalInferenceStyle.of(context),
    strings: LocalInferenceStrings.of(context),
    features: ChatFeatures.of(context),
    defaultBuilder: build,
    message: item,
    isLatest: isLatest,
    isBusy: isBusy,
    openScreen: isBusy ? null : openScreen,
    report: report,
  );

  Widget _composer(BuildContext context) {
    final controller = _chat;
    // The divider above it is part of the default composer: a composer of the host's own draws its own edge.
    Widget build() => Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Divider(height: 1),
        ChatComposer(controller: controller, onSend: () => _send().ignore(), focusNode: _focus),
      ],
    );
    final builder = widget.builders.composer;
    if (builder == null) return build();
    return ValueListenableBuilder<ComposerState>(
      valueListenable: controller.composer,
      builder: (context, composer, _) {
        final slot = _slot(context, build);
        return builder(
          context,
          ComposerContext(
            controller: controller,
            style: slot.style,
            strings: slot.strings,
            features: slot.features,
            defaultBuilder: build,
            text: controller.draft,
            focus: _focus,
            canSend: composer.canSend,
            isBusy: composer.isBusy,
            send: ([text]) => _send(text).ignore(),
            stop: controller.stop,
          ),
        );
      },
    );
  }
}

/// A chat page: a Scaffold with a [ChatAppBar] (the title, the new-conversation button) over a [ChatView].
class ChatPage extends StatelessWidget {
  const ChatPage({
    super.key,
    this.controller,
    this.setup,
    this.assistantName,
    this.title,
    this.welcome,
    this.suggestions = const [],
    this.features,
    this.builders = const ChatBuilders(),
    this.callbacks = const ChatCallbacks(),
    this.screenRequestPolicy = const ScreenRequestPolicy(),
    this.strings,
    this.theme,
    this.appBar,
    this.onTitleLongPress,
    this.actions = const [],
    this.drawer,
    this.endDrawer,
  });

  final AssistantController? controller;
  final ModelSetupController? setup;
  final String? assistantName;

  /// The app bar's title; null uses [assistantName].
  final String? title;
  final String? welcome;
  final List<String> suggestions;
  final ChatFeatures? features;
  final ChatBuilders builders;
  final ChatCallbacks callbacks;
  final ScreenRequestPolicy screenRequestPolicy;
  final LocalInferenceStrings? strings;
  final LocalInferenceTheme? theme;

  /// Replaces the [ChatAppBar].
  final PreferredSizeWidget? appBar;

  /// A long press on the title (a hidden developer sheet).
  final VoidCallback? onTitleLongPress;

  /// App-bar buttons before the new-conversation button.
  final List<Widget> actions;
  final Widget? drawer;
  final Widget? endDrawer;

  @override
  Widget build(BuildContext context) => ResolvedLook.wrap(
    context,
    theme: theme,
    strings: strings,
    features: features,
    child: Builder(
      builder: (context) {
        final style = LocalInferenceStyle.of(context);
        final resolvedStrings = LocalInferenceStrings.of(context);
        final features = ChatFeatures.of(context);
        return Scaffold(
          backgroundColor: style.background,
          appBar:
              appBar ??
              ChatAppBar(
                controller: controller,
                title: title ?? assistantName ?? resolvedStrings.chat.defaultAssistantName,
                onTitleLongPress: onTitleLongPress,
                actions: actions,
                showNewConversation: features.newConversationAction,
              ),
          drawer: drawer,
          endDrawer: endDrawer,
          body: SafeArea(
            top: false,
            child: ChatView(
              controller: controller,
              setup: setup,
              assistantName: assistantName,
              welcome: welcome,
              suggestions: suggestions,
              builders: builders,
              callbacks: callbacks,
              screenRequestPolicy: screenRequestPolicy,
            ),
          ),
        );
      },
    ),
  );
}
