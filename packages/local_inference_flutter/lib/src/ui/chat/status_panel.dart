/// The panel a chat shows instead of the conversation: preparing, failed, no model.
library;

import 'package:flutter/material.dart';

import '../builders.dart';
import '../keys.dart';
import '../theme/local_inference_theme.dart';

/// A centered panel: an icon in a tinted circle, a title, an optional subtitle, progress bar and button. It scrolls
/// when the text is large.
class ChatStatusPanel extends StatelessWidget {
  const ChatStatusPanel({
    super.key = LocalInferenceKeys.statusPanel,
    required this.icon,
    required this.title,
    this.subtitle,
    this.progress = false,
    this.isError = false,
    this.action,
    this.iconSize,
    this.details,
  });

  /// A panel showing [data].
  ChatStatusPanel.fromData(ChatPanelData data, {Key? key})
    : this(
        key: key ?? LocalInferenceKeys.statusPanel,
        icon: data.icon,
        title: data.title,
        subtitle: data.subtitle,
        progress: data.progress,
        isError: data.isError,
        action: data.action,
        details: data.details,
      );

  final IconData icon;
  final String title;
  final String? subtitle;

  /// An indeterminate progress bar under the texts.
  final bool progress;

  /// The icon in the error color.
  final bool isError;

  /// A button under the texts.
  final Widget? action;

  /// The icon's size; null uses the style's panel icon size.
  final double? iconSize;

  /// Technical text under the rest, selectable (the raw error).
  final String? details;

  @override
  Widget build(BuildContext context) {
    final style = LocalInferenceStyle.of(context);
    return Center(
      child: SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: style.panelMaxWidth),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                PanelIcon(icon: icon, size: iconSize ?? style.panelIconSize, color: isError ? style.error : null),
                const SizedBox(height: 16),
                Text(title, textAlign: TextAlign.center, style: style.panelTitleStyle),
                if (subtitle != null) ...[
                  const SizedBox(height: 8),
                  Text(subtitle!, textAlign: TextAlign.center, style: style.panelBodyStyle),
                ],
                if (progress) ...[
                  const SizedBox(height: 20),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(style.panelProgressRadius),
                    child: LinearProgressIndicator(
                      minHeight: 8,
                      color: style.progress,
                      backgroundColor: style.panelProgressTrack,
                    ),
                  ),
                ],
                if (action != null) ...[const SizedBox(height: 20), action!],
                if (details case final details?) ...[
                  const SizedBox(height: 16),
                  SelectableText(details, textAlign: TextAlign.center, style: style.detailsStyle),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The icon of a panel, in a 72-point circle of the style's panel color (larger for an icon over 34 points).
class PanelIcon extends StatelessWidget {
  const PanelIcon({super.key, required this.icon, this.size, this.color});

  final IconData icon;
  final double? size;

  /// The icon's color; null uses the accent.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final style = LocalInferenceStyle.of(context);
    final iconSize = size ?? style.panelIconSize;
    final diameter = iconSize > 36 ? iconSize * 2 : 72.0;
    return ExcludeSemantics(
      child: Container(
        width: diameter,
        height: diameter,
        decoration: BoxDecoration(color: style.panelIconBackground, shape: BoxShape.circle),
        child: Icon(icon, size: iconSize, color: color ?? style.accent),
      ),
    );
  }
}
