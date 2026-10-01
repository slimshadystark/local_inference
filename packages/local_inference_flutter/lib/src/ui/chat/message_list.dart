/// The lazy list of a chat's messages, which follows new text only while at the bottom.
library;

import 'package:flutter/material.dart';
import 'package:local_inference/local_inference.dart';

import '../../adapters/assistant_controller.dart';
import '../../adapters/chat_scroll_controller.dart';
import '../internal/list_width.dart';
import '../keys.dart';
import '../theme/local_inference_theme.dart';

/// Builds the row of [message]; [isLatest] for the newest item.
typedef ChatMessageBuilder = Widget Function(BuildContext context, ChatItem message, bool isLatest);

/// The messages of [controller], oldest first, in a lazy list with stable keys: a message rebuilds only when it
/// changes, and the list itself only when messages are added or removed. [leading] rows (the welcome text) come
/// first. With [scrollController] (a [ChatScrollController]) the list follows new text while at the bottom and
/// opens at the bottom.
class ChatMessageList extends StatefulWidget {
  const ChatMessageList({
    super.key,
    required this.controller,
    required this.messageBuilder,
    this.scrollController,
    this.leading = const [],
    this.padding,
    this.autoScroll = true,
  });

  final AssistantController controller;
  final ChatMessageBuilder messageBuilder;

  /// Null makes one.
  final ChatScrollController? scrollController;

  /// Rows before the messages, built lazily.
  final List<WidgetBuilder> leading;

  /// Null uses the style's list padding.
  final EdgeInsetsGeometry? padding;

  /// Whether the list follows new text at the bottom.
  final bool autoScroll;

  @override
  State<ChatMessageList> createState() => _ChatMessageListState();
}

class _ChatMessageListState extends State<ChatMessageList> {
  ChatScrollController? _own;
  List<int>? _ids;

  ChatScrollController get _scroll => widget.scrollController ?? (_own ??= ChatScrollController());

  @override
  void initState() {
    super.initState();
    _listen(widget.controller);
    _scroll.following = widget.autoScroll;
    // Open at the newest message.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scroll.jumpToLatest(animate: false).ignore();
    });
  }

  @override
  void didUpdateWidget(covariant ChatMessageList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.removeListener(_onChange);
      _listen(widget.controller);
    }
    final own = _own;
    if (own != null && widget.scrollController != null) {
      // The list detaches from it in this frame's build.
      _own = null;
      WidgetsBinding.instance.addPostFrameCallback((_) => own.dispose());
    }
    _scroll.following = widget.autoScroll;
  }

  void _listen(AssistantController controller) {
    _ids = controller.itemIds.value;
    controller.addListener(_onChange);
  }

  void _onChange() {
    final ids = widget.controller.itemIds.value;
    final old = _ids ?? const <int>[];
    final structural = !identical(ids, _ids);
    _ids = ids;
    // A new conversation, or another one restored: it opens at its newest message, as the list does at first.
    if (structural && old.isNotEmpty && (ids.isEmpty || ids.first != old.first)) {
      _scroll.jumpToLatest(animate: false).ignore();
      return;
    }
    _scroll.contentChanged(structural: structural);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChange);
    _own?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final style = LocalInferenceStyle.of(context);
    final controller = widget.controller;
    final leading = widget.leading;
    return LayoutBuilder(
      builder: (context, constraints) => ChatListWidth(
        width: constraints.maxWidth,
        child: NotificationListener<ScrollMetricsNotification>(
          onNotification: (_) {
            _scroll.metricsChanged();
            return false;
          },
          child: ValueListenableBuilder<List<int>>(
            valueListenable: controller.itemIds,
            builder: (context, ids, _) => ListView.builder(
              key: LocalInferenceKeys.messageList,
              controller: _scroll,
              padding: widget.padding ?? style.listPadding,
              itemCount: leading.length + ids.length,
              findChildIndexCallback: (key) {
                if (key is! ValueKey<int>) return null;
                final index = ids.indexOf(key.value);
                return index < 0 ? null : leading.length + index;
              },
              itemBuilder: (context, index) {
                if (index < leading.length) return leading[index](context);
                final id = ids[index - leading.length];
                return _MessageRow(
                  key: ValueKey<int>(id),
                  controller: controller,
                  id: id,
                  isLatest: index == leading.length + ids.length - 1,
                  builder: widget.messageBuilder,
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// One message: rebuilt when its item changes, not when others do.
class _MessageRow extends StatelessWidget {
  const _MessageRow({
    super.key,
    required this.controller,
    required this.id,
    required this.isLatest,
    required this.builder,
  });

  final AssistantController controller;
  final int id;
  final bool isLatest;
  final ChatMessageBuilder builder;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<ChatItem>(
    valueListenable: controller.item(id),
    builder: (context, item, _) => builder(context, item, isLatest),
  );
}
