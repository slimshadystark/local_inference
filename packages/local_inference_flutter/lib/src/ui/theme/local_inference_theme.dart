/// The look of the chat and model-setup UI: [LocalInferenceTheme] (overrides, a ThemeExtension) and the
/// [LocalInferenceStyle] the widgets use, resolved from the app's ColorScheme and TextTheme.
library;

import 'dart:ui' show lerpDouble;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';

import '../../adapters/scope.dart';
import '../internal/resolved.dart';

/// Overrides of the chat UI's look. Every field is optional: an unset one comes from the app's [ColorScheme] and
/// [TextTheme] (see [LocalInferenceStyle.resolve]), so light and dark themes work without any value here.
///
/// Put it in `ThemeData.extensions`, in `LocalInferenceScope(theme:)` or in a widget's `theme:`; the widget's wins,
/// then the scope's, then the extension's. Text styles merge onto the default (set only what changes); the other
/// fields replace it.
@immutable
final class LocalInferenceTheme extends ThemeExtension<LocalInferenceTheme> {
  const LocalInferenceTheme({
    this.accent,
    this.onAccent,
    this.background,
    this.surface,
    this.composerFill,
    this.userBubble,
    this.onUserBubble,
    this.assistantBubble,
    this.onAssistant,
    this.secondaryText,
    this.border,
    this.error,
    this.pending,
    this.progress,
    this.progressTrack,
    this.panelProgressTrack,
    this.shimmerBase,
    this.shimmerHighlight,
    this.disclosureBackground,
    this.onDisclosure,
    this.panelIconBackground,
    this.titleStyle,
    this.messageStyle,
    this.thinkingStyle,
    this.statusStyle,
    this.detailsStyle,
    this.hintStyle,
    this.composerStyle,
    this.panelTitleStyle,
    this.panelBodyStyle,
    this.bubbleRadius,
    this.composerRadius,
    this.cardRadius,
    this.buttonRadius,
    this.progressRadius,
    this.panelProgressRadius,
    this.userBubbleWidthFactor,
    this.assistantWidthFactor,
    this.panelMaxWidth,
    this.panelIconSize,
    this.setupIconSize,
    this.buttonMinHeight,
    this.listPadding,
    this.messagePadding,
    this.messageSpacing,
    this.composerPadding,
    this.shimmerPeriod,
  });

  /// Buttons, the focused composer, chips, links and icons of the panels. Default: `primary`.
  final Color? accent;

  /// Text and icons on [accent]. Default: `onPrimary`.
  final Color? onAccent;

  /// The page and the app bar. Default: `surface`.
  final Color? background;

  /// Cards (the model list) and sheets. Default: `surface`.
  final Color? surface;

  /// The composer's fill. Default: `surfaceContainerHigh`.
  final Color? composerFill;

  /// The user's bubbles. Default: [accent].
  final Color? userBubble;

  /// Text on [userBubble]. Default: [onAccent].
  final Color? onUserBubble;

  /// Behind the assistant's replies. Default: transparent (no bubble).
  final Color? assistantBubble;

  /// The assistant's text and most other text. Default: `onSurface`.
  final Color? onAssistant;

  /// Hints, sizes, details. Default: `onSurfaceVariant`.
  final Color? secondaryText;

  /// The composer's outline. Default: `outlineVariant`.
  final Color? border;

  /// Error icons and texts. Default: `error`.
  final Color? error;

  /// Waiting states of a download. Default: `tertiary`.
  final Color? pending;

  /// Every progress bar and spinner. Always passed explicitly, so an app-wide `progressIndicatorTheme` never hides
  /// them. Default: [accent].
  final Color? progress;

  /// The track of the progress bars. Default: [progress] at alpha 0.14.
  final Color? progressTrack;

  /// The track of the status panels' progress bar (preparing a model). Default: [progressTrack].
  final Color? panelProgressTrack;

  /// The dim end of the thinking shimmer. Default: [secondaryText].
  final Color? shimmerBase;

  /// The bright part of the thinking shimmer. Default: [onAssistant].
  final Color? shimmerHighlight;

  /// The AI-disclosure banner. Default: `surfaceContainerHighest`.
  final Color? disclosureBackground;

  /// Text on [disclosureBackground]. Default: `onSurfaceVariant`.
  final Color? onDisclosure;

  /// The circle behind the icon of the status and setup panels. Default: [accent] at alpha 0.14.
  final Color? panelIconBackground;

  /// The app bar's title. Default: bold, [onAssistant], on the app bar's text style.
  final TextStyle? titleStyle;

  /// Message text. Default: `bodyLarge` in [onAssistant] ([onUserBubble] in the user's bubbles).
  final TextStyle? messageStyle;

  /// "Thinking…". Default: italic, 16 px, on the ambient text style.
  final TextStyle? thinkingStyle;

  /// A running tool's label. Default: italic, [onAssistant].
  final TextStyle? statusStyle;

  /// The technical details. Default: 10.5 px monospace (Menlo, Roboto Mono), [secondaryText].
  final TextStyle? detailsStyle;

  /// The composer's hint. Default: 14 px, [secondaryText].
  final TextStyle? hintStyle;

  /// The composer's text. Default: [onAssistant].
  final TextStyle? composerStyle;

  /// Titles of the panels. Default: `titleMedium` in [onAssistant].
  final TextStyle? panelTitleStyle;

  /// Subtitles of the panels. Default: [secondaryText].
  final TextStyle? panelBodyStyle;

  /// The user's bubbles. Default: 14.
  final double? bubbleRadius;

  /// The composer's outline. Default: 24.
  final double? composerRadius;

  /// Cards of the model list. Default: 16.
  final double? cardRadius;

  /// The setup views' buttons. Default: 24.
  final double? buttonRadius;

  /// The download progress bars. Default: 8.
  final double? progressRadius;

  /// The progress bar of the status panels. Default: 4.
  final double? panelProgressRadius;

  /// A user bubble's widest share of the message list's width. Default: 0.78.
  final double? userBubbleWidthFactor;

  /// A reply's widest share of the message list's width. Default: 0.9.
  final double? assistantWidthFactor;

  /// The widest a status or setup panel gets. Default: 320.
  final double? panelMaxWidth;

  /// The icon of the status panels (in a circle twice its size plus 4). Default: 34.
  final double? panelIconSize;

  /// The icon of the setup views. Default: 36.
  final double? setupIconSize;

  /// The setup views' main buttons. Default: 48.
  final double? buttonMinHeight;

  /// Around the message list. Default: 12 on every side.
  final EdgeInsetsGeometry? listPadding;

  /// Inside each message. Default: 14 horizontal, 10 vertical.
  final EdgeInsetsGeometry? messagePadding;

  /// Around each message. Default: 4 above and below.
  final EdgeInsetsGeometry? messageSpacing;

  /// Inside the composer's outline. Default: 20 across, 12 above and below (a 48-point field for one line).
  final EdgeInsetsGeometry? composerPadding;

  /// One sweep of the thinking shimmer. Default: 1600 ms.
  final Duration? shimmerPeriod;

  List<Object?> get _fields => [
    accent,
    onAccent,
    background,
    surface,
    composerFill,
    userBubble,
    onUserBubble,
    assistantBubble,
    onAssistant,
    secondaryText,
    border,
    error,
    pending,
    progress,
    progressTrack,
    panelProgressTrack,
    shimmerBase,
    shimmerHighlight,
    disclosureBackground,
    onDisclosure,
    panelIconBackground,
    titleStyle,
    messageStyle,
    thinkingStyle,
    statusStyle,
    detailsStyle,
    hintStyle,
    composerStyle,
    panelTitleStyle,
    panelBodyStyle,
    bubbleRadius,
    composerRadius,
    cardRadius,
    buttonRadius,
    progressRadius,
    panelProgressRadius,
    userBubbleWidthFactor,
    assistantWidthFactor,
    panelMaxWidth,
    panelIconSize,
    setupIconSize,
    buttonMinHeight,
    listPadding,
    messagePadding,
    messageSpacing,
    composerPadding,
    shimmerPeriod,
  ];

  @override
  bool operator ==(Object other) => other is LocalInferenceTheme && listEquals<Object?>(other._fields, _fields);

  @override
  int get hashCode => Object.hashAll(_fields);

  /// This theme with [other]'s set fields on top (text styles merge).
  LocalInferenceTheme merge(LocalInferenceTheme? other) {
    if (other == null) return this;
    TextStyle? style(TextStyle? mine, TextStyle? theirs) => mine == null ? theirs : mine.merge(theirs);
    return LocalInferenceTheme(
      accent: other.accent ?? accent,
      onAccent: other.onAccent ?? onAccent,
      background: other.background ?? background,
      surface: other.surface ?? surface,
      composerFill: other.composerFill ?? composerFill,
      userBubble: other.userBubble ?? userBubble,
      onUserBubble: other.onUserBubble ?? onUserBubble,
      assistantBubble: other.assistantBubble ?? assistantBubble,
      onAssistant: other.onAssistant ?? onAssistant,
      secondaryText: other.secondaryText ?? secondaryText,
      border: other.border ?? border,
      error: other.error ?? error,
      pending: other.pending ?? pending,
      progress: other.progress ?? progress,
      progressTrack: other.progressTrack ?? progressTrack,
      panelProgressTrack: other.panelProgressTrack ?? panelProgressTrack,
      shimmerBase: other.shimmerBase ?? shimmerBase,
      shimmerHighlight: other.shimmerHighlight ?? shimmerHighlight,
      disclosureBackground: other.disclosureBackground ?? disclosureBackground,
      onDisclosure: other.onDisclosure ?? onDisclosure,
      panelIconBackground: other.panelIconBackground ?? panelIconBackground,
      titleStyle: style(titleStyle, other.titleStyle),
      messageStyle: style(messageStyle, other.messageStyle),
      thinkingStyle: style(thinkingStyle, other.thinkingStyle),
      statusStyle: style(statusStyle, other.statusStyle),
      detailsStyle: style(detailsStyle, other.detailsStyle),
      hintStyle: style(hintStyle, other.hintStyle),
      composerStyle: style(composerStyle, other.composerStyle),
      panelTitleStyle: style(panelTitleStyle, other.panelTitleStyle),
      panelBodyStyle: style(panelBodyStyle, other.panelBodyStyle),
      bubbleRadius: other.bubbleRadius ?? bubbleRadius,
      composerRadius: other.composerRadius ?? composerRadius,
      cardRadius: other.cardRadius ?? cardRadius,
      buttonRadius: other.buttonRadius ?? buttonRadius,
      progressRadius: other.progressRadius ?? progressRadius,
      panelProgressRadius: other.panelProgressRadius ?? panelProgressRadius,
      userBubbleWidthFactor: other.userBubbleWidthFactor ?? userBubbleWidthFactor,
      assistantWidthFactor: other.assistantWidthFactor ?? assistantWidthFactor,
      panelMaxWidth: other.panelMaxWidth ?? panelMaxWidth,
      panelIconSize: other.panelIconSize ?? panelIconSize,
      setupIconSize: other.setupIconSize ?? setupIconSize,
      buttonMinHeight: other.buttonMinHeight ?? buttonMinHeight,
      listPadding: other.listPadding ?? listPadding,
      messagePadding: other.messagePadding ?? messagePadding,
      messageSpacing: other.messageSpacing ?? messageSpacing,
      composerPadding: other.composerPadding ?? composerPadding,
      shimmerPeriod: other.shimmerPeriod ?? shimmerPeriod,
    );
  }

  @override
  LocalInferenceTheme copyWith({
    Color? accent,
    Color? onAccent,
    Color? background,
    Color? surface,
    Color? composerFill,
    Color? userBubble,
    Color? onUserBubble,
    Color? assistantBubble,
    Color? onAssistant,
    Color? secondaryText,
    Color? border,
    Color? error,
    Color? pending,
    Color? progress,
    Color? progressTrack,
    Color? panelProgressTrack,
    Color? shimmerBase,
    Color? shimmerHighlight,
    Color? disclosureBackground,
    Color? onDisclosure,
    Color? panelIconBackground,
    TextStyle? titleStyle,
    TextStyle? messageStyle,
    TextStyle? thinkingStyle,
    TextStyle? statusStyle,
    TextStyle? detailsStyle,
    TextStyle? hintStyle,
    TextStyle? composerStyle,
    TextStyle? panelTitleStyle,
    TextStyle? panelBodyStyle,
    double? bubbleRadius,
    double? composerRadius,
    double? cardRadius,
    double? buttonRadius,
    double? progressRadius,
    double? panelProgressRadius,
    double? userBubbleWidthFactor,
    double? assistantWidthFactor,
    double? panelMaxWidth,
    double? panelIconSize,
    double? setupIconSize,
    double? buttonMinHeight,
    EdgeInsetsGeometry? listPadding,
    EdgeInsetsGeometry? messagePadding,
    EdgeInsetsGeometry? messageSpacing,
    EdgeInsetsGeometry? composerPadding,
    Duration? shimmerPeriod,
  }) => LocalInferenceTheme(
    accent: accent ?? this.accent,
    onAccent: onAccent ?? this.onAccent,
    background: background ?? this.background,
    surface: surface ?? this.surface,
    composerFill: composerFill ?? this.composerFill,
    userBubble: userBubble ?? this.userBubble,
    onUserBubble: onUserBubble ?? this.onUserBubble,
    assistantBubble: assistantBubble ?? this.assistantBubble,
    onAssistant: onAssistant ?? this.onAssistant,
    secondaryText: secondaryText ?? this.secondaryText,
    border: border ?? this.border,
    error: error ?? this.error,
    pending: pending ?? this.pending,
    progress: progress ?? this.progress,
    progressTrack: progressTrack ?? this.progressTrack,
    panelProgressTrack: panelProgressTrack ?? this.panelProgressTrack,
    shimmerBase: shimmerBase ?? this.shimmerBase,
    shimmerHighlight: shimmerHighlight ?? this.shimmerHighlight,
    disclosureBackground: disclosureBackground ?? this.disclosureBackground,
    onDisclosure: onDisclosure ?? this.onDisclosure,
    panelIconBackground: panelIconBackground ?? this.panelIconBackground,
    titleStyle: titleStyle ?? this.titleStyle,
    messageStyle: messageStyle ?? this.messageStyle,
    thinkingStyle: thinkingStyle ?? this.thinkingStyle,
    statusStyle: statusStyle ?? this.statusStyle,
    detailsStyle: detailsStyle ?? this.detailsStyle,
    hintStyle: hintStyle ?? this.hintStyle,
    composerStyle: composerStyle ?? this.composerStyle,
    panelTitleStyle: panelTitleStyle ?? this.panelTitleStyle,
    panelBodyStyle: panelBodyStyle ?? this.panelBodyStyle,
    bubbleRadius: bubbleRadius ?? this.bubbleRadius,
    composerRadius: composerRadius ?? this.composerRadius,
    cardRadius: cardRadius ?? this.cardRadius,
    buttonRadius: buttonRadius ?? this.buttonRadius,
    progressRadius: progressRadius ?? this.progressRadius,
    panelProgressRadius: panelProgressRadius ?? this.panelProgressRadius,
    userBubbleWidthFactor: userBubbleWidthFactor ?? this.userBubbleWidthFactor,
    assistantWidthFactor: assistantWidthFactor ?? this.assistantWidthFactor,
    panelMaxWidth: panelMaxWidth ?? this.panelMaxWidth,
    panelIconSize: panelIconSize ?? this.panelIconSize,
    setupIconSize: setupIconSize ?? this.setupIconSize,
    buttonMinHeight: buttonMinHeight ?? this.buttonMinHeight,
    listPadding: listPadding ?? this.listPadding,
    messagePadding: messagePadding ?? this.messagePadding,
    messageSpacing: messageSpacing ?? this.messageSpacing,
    composerPadding: composerPadding ?? this.composerPadding,
    shimmerPeriod: shimmerPeriod ?? this.shimmerPeriod,
  );

  @override
  LocalInferenceTheme lerp(covariant ThemeExtension<LocalInferenceTheme>? other, double t) {
    if (other is! LocalInferenceTheme) return this;
    double? number(double? a, double? b) => lerpDouble(a, b, t);
    return LocalInferenceTheme(
      accent: Color.lerp(accent, other.accent, t),
      onAccent: Color.lerp(onAccent, other.onAccent, t),
      background: Color.lerp(background, other.background, t),
      surface: Color.lerp(surface, other.surface, t),
      composerFill: Color.lerp(composerFill, other.composerFill, t),
      userBubble: Color.lerp(userBubble, other.userBubble, t),
      onUserBubble: Color.lerp(onUserBubble, other.onUserBubble, t),
      assistantBubble: Color.lerp(assistantBubble, other.assistantBubble, t),
      onAssistant: Color.lerp(onAssistant, other.onAssistant, t),
      secondaryText: Color.lerp(secondaryText, other.secondaryText, t),
      border: Color.lerp(border, other.border, t),
      error: Color.lerp(error, other.error, t),
      pending: Color.lerp(pending, other.pending, t),
      progress: Color.lerp(progress, other.progress, t),
      progressTrack: Color.lerp(progressTrack, other.progressTrack, t),
      panelProgressTrack: Color.lerp(panelProgressTrack, other.panelProgressTrack, t),
      shimmerBase: Color.lerp(shimmerBase, other.shimmerBase, t),
      shimmerHighlight: Color.lerp(shimmerHighlight, other.shimmerHighlight, t),
      disclosureBackground: Color.lerp(disclosureBackground, other.disclosureBackground, t),
      onDisclosure: Color.lerp(onDisclosure, other.onDisclosure, t),
      panelIconBackground: Color.lerp(panelIconBackground, other.panelIconBackground, t),
      titleStyle: TextStyle.lerp(titleStyle, other.titleStyle, t),
      messageStyle: TextStyle.lerp(messageStyle, other.messageStyle, t),
      thinkingStyle: TextStyle.lerp(thinkingStyle, other.thinkingStyle, t),
      statusStyle: TextStyle.lerp(statusStyle, other.statusStyle, t),
      detailsStyle: TextStyle.lerp(detailsStyle, other.detailsStyle, t),
      hintStyle: TextStyle.lerp(hintStyle, other.hintStyle, t),
      composerStyle: TextStyle.lerp(composerStyle, other.composerStyle, t),
      panelTitleStyle: TextStyle.lerp(panelTitleStyle, other.panelTitleStyle, t),
      panelBodyStyle: TextStyle.lerp(panelBodyStyle, other.panelBodyStyle, t),
      bubbleRadius: number(bubbleRadius, other.bubbleRadius),
      composerRadius: number(composerRadius, other.composerRadius),
      cardRadius: number(cardRadius, other.cardRadius),
      buttonRadius: number(buttonRadius, other.buttonRadius),
      progressRadius: number(progressRadius, other.progressRadius),
      panelProgressRadius: number(panelProgressRadius, other.panelProgressRadius),
      userBubbleWidthFactor: number(userBubbleWidthFactor, other.userBubbleWidthFactor),
      assistantWidthFactor: number(assistantWidthFactor, other.assistantWidthFactor),
      panelMaxWidth: number(panelMaxWidth, other.panelMaxWidth),
      panelIconSize: number(panelIconSize, other.panelIconSize),
      setupIconSize: number(setupIconSize, other.setupIconSize),
      buttonMinHeight: number(buttonMinHeight, other.buttonMinHeight),
      listPadding: EdgeInsetsGeometry.lerp(listPadding, other.listPadding, t),
      messagePadding: EdgeInsetsGeometry.lerp(messagePadding, other.messagePadding, t),
      messageSpacing: EdgeInsetsGeometry.lerp(messageSpacing, other.messageSpacing, t),
      composerPadding: EdgeInsetsGeometry.lerp(composerPadding, other.composerPadding, t),
      shimmerPeriod: t < 0.5 ? shimmerPeriod : other.shimmerPeriod,
    );
  }
}

/// The resolved look the widgets draw with: every [LocalInferenceTheme] field set. Get it with [of].
@immutable
final class LocalInferenceStyle {
  const LocalInferenceStyle._(this.theme);

  /// The look for [theme] with [overrides] on top: every unset field from [theme]'s ColorScheme and TextTheme.
  factory LocalInferenceStyle.resolve(ThemeData theme, [LocalInferenceTheme? overrides]) {
    final scheme = theme.colorScheme;
    final text = theme.textTheme;
    final o = overrides;
    final accent = o?.accent ?? scheme.primary;
    final onAccent = o?.onAccent ?? scheme.onPrimary;
    final onAssistant = o?.onAssistant ?? scheme.onSurface;
    final secondary = o?.secondaryText ?? scheme.onSurfaceVariant;
    final progress = o?.progress ?? accent;
    final progressTrack = o?.progressTrack ?? progress.withValues(alpha: 0.14);
    final defaults = LocalInferenceTheme(
      accent: accent,
      onAccent: onAccent,
      background: scheme.surface,
      surface: scheme.surface,
      composerFill: scheme.surfaceContainerHigh,
      userBubble: accent,
      onUserBubble: onAccent,
      assistantBubble: Colors.transparent,
      onAssistant: onAssistant,
      secondaryText: secondary,
      border: scheme.outlineVariant,
      error: scheme.error,
      pending: scheme.tertiary,
      progress: progress,
      progressTrack: progressTrack,
      panelProgressTrack: progressTrack,
      shimmerBase: secondary,
      shimmerHighlight: onAssistant,
      disclosureBackground: scheme.surfaceContainerHighest,
      onDisclosure: scheme.onSurfaceVariant,
      panelIconBackground: accent.withValues(alpha: 0.14),
      titleStyle: TextStyle(fontWeight: FontWeight.bold, color: onAssistant),
      messageStyle: (text.bodyLarge ?? const TextStyle(fontSize: 16)).copyWith(color: onAssistant),
      thinkingStyle: TextStyle(fontStyle: FontStyle.italic, fontSize: 16, color: onAssistant),
      statusStyle: TextStyle(fontStyle: FontStyle.italic, color: onAssistant),
      detailsStyle: TextStyle(
        fontFamily: 'Menlo',
        fontFamilyFallback: const ['Roboto Mono', 'monospace'],
        fontSize: 10.5,
        color: secondary,
      ),
      hintStyle: TextStyle(fontSize: 14, color: secondary),
      composerStyle: TextStyle(color: onAssistant),
      panelTitleStyle: (text.titleMedium ?? const TextStyle(fontSize: 16)).copyWith(color: onAssistant),
      panelBodyStyle: TextStyle(color: secondary),
      bubbleRadius: 14,
      composerRadius: 24,
      cardRadius: 16,
      buttonRadius: 24,
      progressRadius: 8,
      panelProgressRadius: 4,
      userBubbleWidthFactor: 0.78,
      assistantWidthFactor: 0.9,
      panelMaxWidth: 320,
      panelIconSize: 34,
      setupIconSize: 36,
      buttonMinHeight: 48,
      listPadding: const EdgeInsets.all(12),
      messagePadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      messageSpacing: const EdgeInsets.symmetric(vertical: 4),
      composerPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      shimmerPeriod: const Duration(milliseconds: 1600),
    );
    return LocalInferenceStyle._(defaults.merge(overrides));
  }

  /// The look at [context]: [override] over the enclosing chat view's, else over the scope's
  /// (`LocalInferenceScope(theme:)`), over the app theme's [LocalInferenceTheme] extension, over the defaults.
  static LocalInferenceStyle of(BuildContext context, [LocalInferenceTheme? override]) {
    final resolved = ResolvedLook.maybeOf(context);
    if (resolved != null && override == null) return resolved.style;
    return LocalInferenceStyle.resolve(Theme.of(context), overridesAt(context).merge(override));
  }

  /// The overrides in force at [context], without a widget's own: the enclosing view's, else the scope's over the
  /// app theme's extension.
  static LocalInferenceTheme overridesAt(BuildContext context) =>
      ResolvedLook.maybeOf(context)?.theme ??
      (Theme.of(context).extension<LocalInferenceTheme>() ?? const LocalInferenceTheme()).merge(
        LocalInferenceScope.maybeOf(context)?.theme,
      );

  /// The overrides merged with the defaults; every field is set.
  final LocalInferenceTheme theme;

  @override
  bool operator ==(Object other) => other is LocalInferenceStyle && other.theme == theme;

  @override
  int get hashCode => theme.hashCode;

  Color get accent => theme.accent!;
  Color get onAccent => theme.onAccent!;
  Color get background => theme.background!;
  Color get surface => theme.surface!;
  Color get composerFill => theme.composerFill!;
  Color get userBubble => theme.userBubble!;
  Color get onUserBubble => theme.onUserBubble!;
  Color get assistantBubble => theme.assistantBubble!;
  Color get onAssistant => theme.onAssistant!;
  Color get secondaryText => theme.secondaryText!;
  Color get border => theme.border!;
  Color get error => theme.error!;
  Color get pending => theme.pending!;
  Color get progress => theme.progress!;
  Color get progressTrack => theme.progressTrack!;
  Color get panelProgressTrack => theme.panelProgressTrack!;
  Color get shimmerBase => theme.shimmerBase!;
  Color get shimmerHighlight => theme.shimmerHighlight!;
  Color get disclosureBackground => theme.disclosureBackground!;
  Color get onDisclosure => theme.onDisclosure!;
  Color get panelIconBackground => theme.panelIconBackground!;
  TextStyle get titleStyle => theme.titleStyle!;
  TextStyle get messageStyle => theme.messageStyle!;
  TextStyle get thinkingStyle => theme.thinkingStyle!;
  TextStyle get statusStyle => theme.statusStyle!;
  TextStyle get detailsStyle => theme.detailsStyle!;
  TextStyle get hintStyle => theme.hintStyle!;
  TextStyle get composerStyle => theme.composerStyle!;
  TextStyle get panelTitleStyle => theme.panelTitleStyle!;
  TextStyle get panelBodyStyle => theme.panelBodyStyle!;
  double get bubbleRadius => theme.bubbleRadius!;
  double get composerRadius => theme.composerRadius!;
  double get cardRadius => theme.cardRadius!;
  double get buttonRadius => theme.buttonRadius!;
  double get progressRadius => theme.progressRadius!;
  double get panelProgressRadius => theme.panelProgressRadius!;
  double get userBubbleWidthFactor => theme.userBubbleWidthFactor!;
  double get assistantWidthFactor => theme.assistantWidthFactor!;
  double get panelMaxWidth => theme.panelMaxWidth!;
  double get panelIconSize => theme.panelIconSize!;
  double get setupIconSize => theme.setupIconSize!;
  double get buttonMinHeight => theme.buttonMinHeight!;
  EdgeInsetsGeometry get listPadding => theme.listPadding!;
  EdgeInsetsGeometry get messagePadding => theme.messagePadding!;
  EdgeInsetsGeometry get messageSpacing => theme.messageSpacing!;
  EdgeInsetsGeometry get composerPadding => theme.composerPadding!;
  Duration get shimmerPeriod => theme.shimmerPeriod!;

  /// The setup views' main button: [accent] fill, [buttonMinHeight] high, [buttonRadius] round, full width.
  ButtonStyle get filledButton => FilledButton.styleFrom(
    backgroundColor: accent,
    foregroundColor: onAccent,
    minimumSize: Size.fromHeight(buttonMinHeight),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(buttonRadius)),
  );

  /// The setup views' secondary button: [accent] text.
  ButtonStyle get textButton => TextButton.styleFrom(foregroundColor: accent);
}
