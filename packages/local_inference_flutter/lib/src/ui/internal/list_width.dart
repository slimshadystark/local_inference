/// Internal: the width of the message list, which the messages' width factors refer to.
library;

import 'package:flutter/widgets.dart';

/// The message list's width, set by the list; messages outside a list use the screen's width.
class ChatListWidth extends InheritedWidget {
  const ChatListWidth({super.key, required this.width, required super.child});

  final double width;

  /// The width a message's width factor refers to at [context].
  static double of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ChatListWidth>()?.width ?? MediaQuery.sizeOf(context).width;

  @override
  bool updateShouldNotify(ChatListWidth oldWidget) => oldWidget.width != width;
}
