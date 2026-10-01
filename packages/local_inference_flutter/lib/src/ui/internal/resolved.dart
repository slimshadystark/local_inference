/// Internal: the look, texts and switches a chat view or setup view resolved, for the widgets under it.
library;

import 'package:flutter/material.dart';

import '../features.dart';
import '../l10n/strings.dart';
import '../theme/local_inference_theme.dart';

/// What a view resolved from its parameters, the scope, the theme and the locale. The widgets under it use these
/// unless they get their own; not exported.
class ResolvedLook extends InheritedWidget {
  const ResolvedLook({
    super.key,
    required this.theme,
    required this.style,
    required this.strings,
    this.features,
    required super.child,
  });

  /// The overrides [style] was resolved from (the theme's extension, the scope's and the views'), not the defaults.
  final LocalInferenceTheme theme;
  final LocalInferenceStyle style;
  final LocalInferenceStrings strings;
  final ChatFeatures? features;

  static ResolvedLook? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<ResolvedLook>();

  /// [child] under the look resolved at [context] with a view's own [theme], [strings] and [features].
  static Widget wrap(
    BuildContext context, {
    LocalInferenceTheme? theme,
    LocalInferenceStrings? strings,
    ChatFeatures? features,
    required Widget child,
  }) {
    final overrides = LocalInferenceStyle.overridesAt(context).merge(theme);
    return ResolvedLook(
      theme: overrides,
      style: LocalInferenceStyle.resolve(Theme.of(context), overrides),
      strings: LocalInferenceStrings.of(context, strings),
      features: features ?? ChatFeatures.of(context),
      child: child,
    );
  }

  /// [child] (a sheet's or a dialog's content, built under the Navigator) with the look resolved at [from], the
  /// widget that opens it.
  static Widget carry(BuildContext from, Widget child) => ResolvedLook(
    theme: maybeOf(from)?.theme ?? LocalInferenceStyle.overridesAt(from),
    style: LocalInferenceStyle.of(from),
    strings: LocalInferenceStrings.of(from),
    features: ChatFeatures.of(from),
    child: child,
  );

  @override
  bool updateShouldNotify(ResolvedLook oldWidget) =>
      oldWidget.style != style || !identical(oldWidget.strings, strings) || oldWidget.features != features;
}
