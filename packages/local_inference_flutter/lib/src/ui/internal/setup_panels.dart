/// Internal: the setup's panels inside a chat go through the chat's `statusPanel` builder.
library;

import 'package:flutter/material.dart';

import '../builders.dart';
import '../chat/status_panel.dart';
import '../keys.dart';
import '../l10n/strings.dart';
import '../theme/local_inference_theme.dart';

/// How the setup views below build their panels (a chat view's panel builder); without it, a [ChatStatusPanel].
class SetupPanels extends InheritedWidget {
  const SetupPanels({super.key, required this.build, required super.child});

  final Widget Function(BuildContext context, ChatPanelKind kind, ChatPanelData data) build;

  /// The panel of [kind] showing [data], at [context].
  static Widget panel(BuildContext context, ChatPanelKind kind, ChatPanelData data) {
    final panels = context.dependOnInheritedWidgetOfExactType<SetupPanels>();
    return panels == null ? ChatStatusPanel.fromData(data) : panels.build(context, kind, data);
  }

  @override
  bool updateShouldNotify(SetupPanels oldWidget) => build != oldWidget.build;
}

/// The panel of a model that is there but not loaded: [onLoad] loads it.
ChatPanelData modelAvailablePanel(BuildContext context, VoidCallback onLoad) {
  final style = LocalInferenceStyle.of(context);
  final strings = LocalInferenceStrings.of(context).chat;
  return ChatPanelData(
    icon: Icons.memory_outlined,
    title: strings.notLoadedTitle,
    action: FilledButton.icon(
      key: LocalInferenceKeys.loadModel,
      style: FilledButton.styleFrom(backgroundColor: style.accent, foregroundColor: style.onAccent),
      onPressed: onLoad,
      icon: const Icon(Icons.play_arrow),
      label: Text(strings.load),
    ),
  );
}
