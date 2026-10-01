/// The chat's controls: the action bar (a question's buttons, the suggestions), the composer, the jump-to-latest
/// button and the app bar.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_inference/local_inference.dart';

import '../../adapters/assistant_controller.dart';
import '../../adapters/scope.dart';
import '../builders.dart';
import '../features.dart';
import '../internal/icon_action.dart';
import '../keys.dart';
import '../l10n/strings.dart';
import '../theme/local_inference_theme.dart';

/// Above the composer: the open question's buttons, else, before the first message, the suggestions.
class ChatActionBar extends StatelessWidget {
  const ChatActionBar({
    super.key,
    required this.controller,
    this.suggestions = const [],
    required this.onSuggestion,
    this.onAction,
    this.builders = const ChatBuilders(),
  });

  final AssistantController controller;
  final List<String> suggestions;

  /// Sends a suggestion.
  final ValueChanged<String> onSuggestion;

  /// Answers the open question; null calls the controller's `act`.
  final ValueChanged<ChatAction>? onAction;

  final ChatBuilders builders;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<List<ChatAction>>(
    valueListenable: controller.pendingActions,
    builder: (context, actions, _) => ValueListenableBuilder<ComposerState>(
      valueListenable: controller.composer,
      builder: (context, composer, _) => ValueListenableBuilder<List<int>>(
        valueListenable: controller.itemIds,
        builder: (context, ids, _) => _bar(context, actions, composer, ids.isEmpty),
      ),
    ),
  );

  Widget _bar(BuildContext context, List<ChatAction> actions, ComposerState composer, bool empty) {
    final style = LocalInferenceStyle.of(context);
    final strings = LocalInferenceStrings.of(context);
    final features = ChatFeatures.of(context);
    final Widget child;
    if (actions.isNotEmpty && features.showConfirmationButtons) {
      void act(ChatAction action) {
        if (features.haptics) HapticFeedback.selectionClick().ignore();
        final onAction = this.onAction;
        if (onAction != null) {
          onAction(action);
        } else {
          controller.act(action).ignore();
        }
      }

      Widget build() => ConfirmationButtons(actions: actions, enabled: composer.canSend, onAction: act);
      child =
          builders.confirmation?.call(
            context,
            ConfirmationButtonsContext(
              controller: controller,
              style: style,
              strings: strings,
              features: features,
              defaultBuilder: build,
              actions: actions,
              act: act,
              enabled: composer.canSend,
            ),
          ) ??
          build();
    } else if (empty && composer.canSend && features.showSuggestions && suggestions.isNotEmpty) {
      Widget build() => SuggestionChips(suggestions: suggestions, onSelected: onSuggestion);
      child =
          builders.suggestions?.call(
            context,
            SuggestionsContext(
              controller: controller,
              style: style,
              strings: strings,
              features: features,
              defaultBuilder: build,
              suggestions: suggestions,
              send: onSuggestion,
              enabled: composer.canSend,
            ),
          ) ??
          build();
    } else {
      return const SizedBox.shrink();
    }
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: Padding(padding: const EdgeInsetsDirectional.fromSTEB(12, 4, 12, 8), child: child),
    );
  }
}

/// A question's buttons: the main one filled in the accent color, the others outlined; enabled with [enabled].
class ConfirmationButtons extends StatelessWidget {
  const ConfirmationButtons({super.key, required this.actions, required this.onAction, this.enabled = true});

  final List<ChatAction> actions;
  final ValueChanged<ChatAction> onAction;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final style = LocalInferenceStyle.of(context);
    final strings = LocalInferenceStrings.of(context).chat;
    String label(ChatAction action) => switch (action.kind) {
      ChatActionKind.confirm => strings.confirmLabel ?? action.label,
      ChatActionKind.decline => strings.declineLabel ?? action.label,
    };
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final action in actions)
          action.primary
              ? FilledButton(
                  key: LocalInferenceKeys.confirmAction(action.kind),
                  style: FilledButton.styleFrom(backgroundColor: style.accent, foregroundColor: style.onAccent),
                  onPressed: enabled ? () => onAction(action) : null,
                  child: Text(label(action)),
                )
              : OutlinedButton(
                  key: LocalInferenceKeys.confirmAction(action.kind),
                  onPressed: enabled ? () => onAction(action) : null,
                  child: Text(label(action)),
                ),
      ],
    );
  }
}

/// The suggestions before the first message, as chips.
class SuggestionChips extends StatelessWidget {
  const SuggestionChips({super.key, required this.suggestions, required this.onSelected});

  final List<String> suggestions;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      for (final (index, suggestion) in suggestions.indexed)
        ActionChip(
          key: LocalInferenceKeys.suggestion(index),
          label: Text(suggestion),
          onPressed: () => onSelected(suggestion),
        ),
    ],
  );
}

/// The composer: a rounded text field (1 to `ChatFeatures.composerMaxLines` lines) and the send button, which is a
/// stop button during a turn. The mobile keyboard's send key sends (`submitOnKeyboardAction`); on a desktop Enter
/// sends and Shift+Enter starts a new line (`submitOnEnter`).
class ChatComposer extends StatelessWidget {
  const ChatComposer({super.key, required this.controller, required this.onSend, this.onStop, this.focusNode});

  /// Its draft is the text field's.
  final AssistantController controller;

  /// Sends the draft.
  final VoidCallback onSend;

  /// Stops the turn; null uses the controller's `stop`.
  final VoidCallback? onStop;

  final FocusNode? focusNode;

  static bool get _desktop => switch (defaultTargetPlatform) {
    TargetPlatform.macOS || TargetPlatform.windows || TargetPlatform.linux => true,
    _ => false,
  };

  @override
  Widget build(BuildContext context) {
    final style = LocalInferenceStyle.of(context);
    final strings = LocalInferenceStrings.of(context);
    final features = ChatFeatures.of(context);
    final desktop = _desktop;
    final keyboardSends = features.submitOnKeyboardAction && !desktop;
    OutlineInputBorder border(Color color) => OutlineInputBorder(
      borderRadius: BorderRadius.circular(style.composerRadius),
      borderSide: BorderSide(color: color),
    );
    final field = TextField(
      key: LocalInferenceKeys.composerField,
      controller: controller.draft,
      focusNode: focusNode,
      minLines: 1,
      maxLines: features.composerMaxLines,
      maxLength: features.maxInputLength,
      buildCounter: features.maxInputLength == null ? null : _noCounter,
      textInputAction: keyboardSends ? TextInputAction.send : TextInputAction.newline,
      onSubmitted: keyboardSends ? (_) => onSend() : null,
      style: style.composerStyle,
      decoration: InputDecoration(
        hintText: strings.chat.composerHint,
        hintStyle: style.hintStyle,
        filled: true,
        fillColor: style.composerFill,
        isDense: true,
        contentPadding: style.composerPadding,
        border: border(style.border),
        enabledBorder: border(style.border),
        focusedBorder: border(style.accent),
      ),
    );
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Semantics(
              label: strings.a11y.composerLabel,
              child: desktop && features.submitOnEnter
                  ? Focus(canRequestFocus: false, skipTraversal: true, onKeyEvent: _onKey, child: field)
                  : field,
            ),
          ),
          const SizedBox(width: 8),
          ValueListenableBuilder<ComposerState>(
            valueListenable: controller.composer,
            builder: (context, composer, _) {
              final stop = composer.isBusy && features.stopButton;
              return labelledIconButton(
                label: stop ? strings.a11y.stop : strings.a11y.send,
                tooltips: features.tooltips,
                build: (tooltip) => IconButton.filled(
                  key: stop ? LocalInferenceKeys.stopButton : LocalInferenceKeys.sendButton,
                  style: IconButton.styleFrom(backgroundColor: style.accent, foregroundColor: style.onAccent),
                  tooltip: tooltip,
                  icon: Icon(stop ? Icons.stop : Icons.send),
                  onPressed: stop ? (onStop ?? controller.stop) : (composer.canSend ? onSend : null),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  static Widget? _noCounter(
    BuildContext context, {
    required int currentLength,
    required bool isFocused,
    required int? maxLength,
  }) => null;

  /// Enter sends on a desktop; Shift+Enter, and Enter while an input method composes, go to the text field.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey != LogicalKeyboardKey.enter && event.logicalKey != LogicalKeyboardKey.numpadEnter) {
      return KeyEventResult.ignored;
    }
    if (HardwareKeyboard.instance.isShiftPressed) return KeyEventResult.ignored;
    final composing = controller.draft.value.composing;
    if (composing.isValid && !composing.isCollapsed) return KeyEventResult.ignored;
    onSend();
    return KeyEventResult.handled;
  }
}

/// The button that scrolls back to the newest message.
class JumpToLatestButton extends StatelessWidget {
  const JumpToLatestButton({super.key = LocalInferenceKeys.jumpToLatest, required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final style = LocalInferenceStyle.of(context);
    final strings = LocalInferenceStrings.of(context);
    final features = ChatFeatures.of(context);
    return labelledIconButton(
      label: strings.a11y.jumpToLatest,
      tooltips: features.tooltips,
      build: (tooltip) => IconButton.filled(
        style: IconButton.styleFrom(backgroundColor: style.accent, foregroundColor: style.onAccent),
        tooltip: tooltip,
        icon: const Icon(Icons.arrow_downward),
        onPressed: onPressed,
      ),
    );
  }
}

/// The chat's app bar: the centered title (a long press calls [onTitleLongPress]) and the new-conversation button,
/// off during a turn.
class ChatAppBar extends StatelessWidget implements PreferredSizeWidget {
  const ChatAppBar({
    super.key,
    this.controller,
    required this.title,
    this.onTitleLongPress,
    this.actions = const [],
    this.showNewConversation = true,
  });

  /// Null: the scope's.
  final AssistantController? controller;
  final String title;

  /// A hidden hook (a developer sheet); it has no semantics.
  final VoidCallback? onTitleLongPress;

  /// Buttons before the new-conversation button.
  final List<Widget> actions;
  final bool showNewConversation;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    final style = LocalInferenceStyle.of(context);
    final strings = LocalInferenceStrings.of(context);
    final features = ChatFeatures.of(context);
    final controller = this.controller ?? LocalInferenceScope.maybeOf(context)?.assistant;
    return AppBar(
      backgroundColor: style.background,
      surfaceTintColor: style.background,
      elevation: 0,
      centerTitle: true,
      title: GestureDetector(
        key: LocalInferenceKeys.titleArea,
        excludeFromSemantics: true,
        onLongPress: onTitleLongPress,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text(title, style: style.titleStyle),
        ),
      ),
      actions: [
        ...actions,
        if (showNewConversation && controller != null)
          ValueListenableBuilder<ComposerState>(
            valueListenable: controller.composer,
            builder: (context, composer, _) => labelledIconButton(
              label: strings.a11y.newConversation,
              tooltips: features.tooltips,
              build: (tooltip) => IconButton(
                key: LocalInferenceKeys.newConversation,
                tooltip: tooltip,
                icon: Icon(Icons.add_comment_outlined, color: style.onAssistant),
                onPressed: composer.isBusy ? null : () => controller.newConversation(),
              ),
            ),
          ),
      ],
    );
  }
}
