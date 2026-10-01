/// The messages of a chat: the welcome text, the user's bubbles and the assistant's replies.
library;

import 'package:flutter/material.dart';
import 'package:local_inference/local_inference.dart';

import '../../adapters/assistant_controller.dart';
import '../builders.dart';
import '../features.dart';
import '../internal/icon_action.dart';
import '../internal/list_width.dart';
import '../keys.dart';
import '../l10n/strings.dart';
import '../theme/local_inference_theme.dart';
import 'indicators.dart';
import 'message_parts.dart';
import 'message_text.dart';

/// The welcome text at the top of the list, drawn as a reply; [footnote] (the disclosure in the welcome) follows in
/// the secondary color.
class WelcomeMessage extends StatelessWidget {
  const WelcomeMessage({super.key = LocalInferenceKeys.welcome, required this.text, this.footnote});

  final String text;
  final String? footnote;

  @override
  Widget build(BuildContext context) {
    final style = LocalInferenceStyle.of(context);
    final features = ChatFeatures.of(context);
    final footnote = this.footnote;
    return _ReplyFrame(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (text.isNotEmpty)
            MessageText(
              text: text,
              style: style.messageStyle,
              selectable: features.selectableText,
              copyAction: features.copyAction,
            ),
          if (footnote != null) ...[
            if (text.isNotEmpty) const SizedBox(height: 8),
            Text(footnote, style: style.messageStyle.copyWith(color: style.secondaryText, fontSize: 13)),
          ],
        ],
      ),
    );
  }
}

/// A user's message: a bubble at the end of the line (the right in left-to-right languages), in the user color, no
/// wider than the style's share of the list.
class UserMessageBubble extends StatelessWidget {
  const UserMessageBubble({super.key, required this.message, this.selectable, this.onCopy});

  final ChatItem message;

  /// Whether its text can be selected; null follows `ChatFeatures.selectableUserText`.
  final bool? selectable;

  final ValueChanged<String>? onCopy;

  @override
  Widget build(BuildContext context) {
    final style = LocalInferenceStyle.of(context);
    final strings = LocalInferenceStrings.of(context);
    final features = ChatFeatures.of(context);
    final textStyle = style.messageStyle.copyWith(color: style.onUserBubble);
    return Semantics(
      container: true,
      label: strings.a11y.userMessage,
      child: Align(
        alignment: AlignmentDirectional.centerEnd,
        child: Container(
          key: LocalInferenceKeys.message(message.id),
          margin: style.messageSpacing,
          padding: style.messagePadding,
          constraints: BoxConstraints(maxWidth: ChatListWidth.of(context) * style.userBubbleWidthFactor),
          decoration: BoxDecoration(color: style.userBubble, borderRadius: BorderRadius.circular(style.bubbleRadius)),
          child: MessageText(
            text: message.text,
            style: textStyle,
            selectable: selectable ?? features.selectableUserText,
            onCopy: onCopy,
            copyAction: features.copyAction,
          ),
        ),
      ),
    );
  }
}

/// A reply: its text (when there is some), "Thinking…" or the running tool's label, the chip of the screen it opened,
/// a footer (report button, AI-generated mark) and, with `ChatFeatures.showDetails`, the technical details. No bubble
/// by default, at the start of the line, no wider than the style's share of the list.
///
/// Inside a chat view the parts come from its [ChatBuilders] ([builders] and [controller] set by the view).
class AssistantMessage extends StatelessWidget {
  const AssistantMessage({
    super.key,
    required this.message,
    this.assistantName,
    this.isBusy = false,
    this.isLatest = false,
    this.onOpenScreen,
    this.onReport,
    this.onCopy,
    this.onLinkTap,
    this.controller,
    this.builders = const ChatBuilders(),
  });

  final ChatItem message;

  /// Who wrote it, for screen readers.
  final String? assistantName;

  /// A turn runs (the screen chip waits).
  final bool isBusy;
  final bool isLatest;

  /// Opens the reply's screen again; null hides the chip.
  final VoidCallback? onOpenScreen;

  /// Opens the report sheet; null when the reply cannot be reported.
  final VoidCallback? onReport;

  final ValueChanged<String>? onCopy;
  final ValueChanged<Uri>? onLinkTap;

  /// The chat's controller; with it, [builders] replace the parts.
  final AssistantController? controller;
  final ChatBuilders builders;

  @override
  Widget build(BuildContext context) {
    final style = LocalInferenceStyle.of(context);
    final strings = LocalInferenceStrings.of(context);
    final features = ChatFeatures.of(context);
    final controller = this.controller;

    Widget part(ChatSlotBuilder<MessageContext>? builder, Widget Function() build) {
      if (builder == null || controller == null) return build();
      return builder(
        context,
        MessageContext(
          controller: controller,
          style: style,
          strings: strings,
          features: features,
          defaultBuilder: build,
          message: message,
          isLatest: isLatest,
          isBusy: isBusy,
          openScreen: isBusy ? null : onOpenScreen,
          report: onReport,
        ),
      );
    }

    final byModel = message.source == ReplySource.model;
    final canReport = onReport != null && message.source != ReplySource.error;
    final affordance = features.reportAffordance;
    // Text that cannot be selected has no selection menu: its report entry becomes the flag button.
    final reportInMenu = canReport && affordance.inMenu && features.selectableText;
    final reportIcon = canReport && (affordance.asIcon || (affordance.inMenu && !features.selectableText));
    final children = <Widget>[];
    if (message.text.isNotEmpty) {
      children.add(
        part(
          builders.messageText,
          () => MessageText(
            text: message.text,
            style: style.messageStyle,
            selectable: features.selectableText,
            onReport: reportInMenu ? onReport : null,
            reportLabel: strings.chat.report,
            onCopy: onCopy,
            copyAction: features.copyAction,
            copyNotice: byModel ? features.provenance.copyNotice : null,
            onLinkTap: onLinkTap,
            linkColor: style.accent,
            semanticsHint: byModel && features.provenance.semantics ? strings.a11y.aiGeneratedHint : null,
          ),
        ),
      );
    }
    if (message.thinking) {
      final status = message.status;
      children.add(
        Padding(
          padding: EdgeInsetsDirectional.only(top: message.text.isEmpty ? 0 : 6),
          child: status == null
              ? part(builders.thinking, () => const ThinkingIndicator())
              : part(builders.toolStatus, () => ToolStatusIndicator(label: status)),
        ),
      );
    }
    final request = message.screenRequest;
    if (request != null && !message.thinking && onOpenScreen != null && features.showScreenChips) {
      children.add(
        Padding(
          padding: const EdgeInsetsDirectional.only(top: 8),
          child: part(
            builders.screenChip,
            () => ScreenRequestChip(
              key: LocalInferenceKeys.screenChip(message.id),
              request: request,
              onOpen: isBusy ? null : onOpenScreen,
            ),
          ),
        ),
      );
    }
    if (!message.thinking) {
      final footer = part(builders.footer, () => _Footer(message: message, onReport: reportIcon ? onReport : null));
      if (footer is! _Footer || footer.isVisible(features)) children.add(footer);
    }
    if (features.showDetails && message.details != null && !message.thinking) {
      children.add(
        Padding(
          padding: const EdgeInsetsDirectional.only(top: 6),
          child: part(builders.details, () => MessageDetails(message: message)),
        ),
      );
    }
    return Semantics(
      container: true,
      label: strings.a11y.assistantMessage(assistantName ?? strings.chat.defaultAssistantName),
      child: _ReplyFrame(
        frameKey: LocalInferenceKeys.message(message.id),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
      ),
    );
  }
}

/// The default footer: the report button (with [onReport]) and the AI-generated mark, when enabled.
class _Footer extends StatelessWidget {
  const _Footer({required this.message, this.onReport});

  final ChatItem message;
  final VoidCallback? onReport;

  bool _badge(ChatFeatures features) => features.provenance.badge && message.source == ReplySource.model;

  bool isVisible(ChatFeatures features) => _badge(features) || onReport != null;

  @override
  Widget build(BuildContext context) {
    final style = LocalInferenceStyle.of(context);
    final strings = LocalInferenceStrings.of(context);
    final features = ChatFeatures.of(context);
    return Padding(
      padding: const EdgeInsetsDirectional.only(top: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_badge(features)) Text(strings.chat.aiGeneratedBadge, style: style.detailsStyle.copyWith(fontSize: 12)),
          if (onReport != null)
            labelledIconButton(
              label: strings.a11y.reportAction,
              tooltips: features.tooltips,
              build: (tooltip) => IconButton(
                key: LocalInferenceKeys.reportAction(message.id),
                icon: const Icon(Icons.outlined_flag),
                iconSize: 18,
                color: style.secondaryText,
                tooltip: tooltip,
                onPressed: onReport,
              ),
            ),
        ],
      ),
    );
  }
}

/// The frame of a reply: at the start of the line, the style's padding, width and (transparent by default) bubble.
class _ReplyFrame extends StatelessWidget {
  const _ReplyFrame({required this.child, this.frameKey});

  final Widget child;

  /// The key of the frame's box (the message's key).
  final Key? frameKey;

  @override
  Widget build(BuildContext context) {
    final style = LocalInferenceStyle.of(context);
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: Container(
        key: frameKey,
        margin: style.messageSpacing,
        padding: style.messagePadding,
        constraints: BoxConstraints(maxWidth: ChatListWidth.of(context) * style.assistantWidthFactor),
        decoration: style.assistantBubble.a == 0
            ? null
            : BoxDecoration(color: style.assistantBubble, borderRadius: BorderRadius.circular(style.bubbleRadius)),
        child: child,
      ),
    );
  }
}
