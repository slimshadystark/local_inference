/// A message's text: selectable, with Copy and "Report reply" in its selection menu, and tappable links.
library;

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// The text of a message. Selectable by default; its selection menu adds [reportLabel] when [onReport] is set, and
/// [copyNotice] after copied text. With [onLinkTap], http(s) links are tappable. [semanticsHint] marks the text for
/// assistive technology (the AI-generated hint).
class MessageText extends StatefulWidget {
  const MessageText({
    super.key,
    required this.text,
    this.style,
    this.selectable = true,
    this.onReport,
    this.reportLabel,
    this.onCopy,
    this.copyAction = true,
    this.copyNotice,
    this.onLinkTap,
    this.linkColor,
    this.semanticsHint,
  });

  final String text;
  final TextStyle? style;
  final bool selectable;

  /// Reports the message; adds [reportLabel] to the selection menu.
  final VoidCallback? onReport;
  final String? reportLabel;

  /// The user copied the text given.
  final ValueChanged<String>? onCopy;

  /// Whether the selection menu offers "Copy".
  final bool copyAction;

  /// A line appended to copied text.
  final String? copyNotice;

  /// Opens a tapped link.
  final ValueChanged<Uri>? onLinkTap;

  /// The links' color; null uses the text's.
  final Color? linkColor;

  final String? semanticsHint;

  @override
  State<MessageText> createState() => _MessageTextState();
}

class _MessageTextState extends State<MessageText> {
  static final RegExp _link = RegExp(r'https?://[^\s<>"]+');

  final List<TapGestureRecognizer> _recognizers = [];

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  void _disposeRecognizers() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    _recognizers.clear();
  }

  /// The text with its links as tappable spans; null when it has none or links are off.
  TextSpan? _linked() {
    final onLinkTap = widget.onLinkTap;
    if (onLinkTap == null) return null;
    final text = widget.text;
    final matches = _link.allMatches(text).toList();
    if (matches.isEmpty) return null;
    final spans = <InlineSpan>[];
    var start = 0;
    for (final match in matches) {
      var end = match.end;
      // Punctuation after a link ends the sentence, not the link.
      while (end > match.start && '.,;:!?)]}»\''.contains(text[end - 1])) {
        end--;
      }
      final uri = Uri.tryParse(text.substring(match.start, end));
      if (uri == null) continue;
      if (match.start > start) spans.add(TextSpan(text: text.substring(start, match.start)));
      final recognizer = TapGestureRecognizer()..onTap = () => onLinkTap(uri);
      _recognizers.add(recognizer);
      spans.add(
        TextSpan(
          text: text.substring(match.start, end),
          style: TextStyle(color: widget.linkColor, decoration: TextDecoration.underline),
          recognizer: recognizer,
        ),
      );
      start = end;
    }
    if (start < text.length) spans.add(TextSpan(text: text.substring(start)));
    return TextSpan(children: spans);
  }

  /// The platform's items, the copy item wrapped (the copy notice, `onCopy`), and the report item right after it,
  /// where a phone's toolbar still shows it without its overflow menu.
  Widget _menu(BuildContext context, EditableTextState state) {
    final onReport = widget.onReport;
    final report = onReport == null
        ? null
        : ContextMenuButtonItem(
            label: widget.reportLabel ?? 'Report',
            onPressed: () {
              ContextMenuController.removeAny();
              onReport();
            },
          );
    final items = <ContextMenuButtonItem>[];
    for (final item in state.contextMenuButtonItems) {
      if (item.type != ContextMenuButtonType.copy) {
        items.add(item);
        continue;
      }
      if (widget.copyAction) items.add(item.copyWith(onPressed: () => _copy(state, item)));
      if (report != null) items.add(report);
    }
    if (report != null && !items.contains(report)) items.insert(0, report);
    return AdaptiveTextSelectionToolbar.buttonItems(anchors: state.contextMenuAnchors, buttonItems: items);
  }

  void _copy(EditableTextState state, ContextMenuButtonItem item) {
    final value = state.textEditingValue;
    final selected = value.selection.textInside(value.text);
    final notice = widget.copyNotice;
    if (notice == null) {
      item.onPressed?.call();
    } else {
      unawaited(Clipboard.setData(ClipboardData(text: '$selected\n\n$notice')));
      state.hideToolbar();
    }
    widget.onCopy?.call(selected);
  }

  @override
  Widget build(BuildContext context) {
    _disposeRecognizers();
    final linked = _linked();
    final Widget text;
    if (widget.selectable) {
      text = linked == null
          ? SelectableText(widget.text, style: widget.style, contextMenuBuilder: _menu)
          : SelectableText.rich(linked, style: widget.style, contextMenuBuilder: _menu);
    } else {
      text = linked == null ? Text(widget.text, style: widget.style) : Text.rich(linked, style: widget.style);
    }
    final hint = widget.semanticsHint;
    return hint == null ? text : Semantics(container: true, hint: hint, child: text);
  }
}
