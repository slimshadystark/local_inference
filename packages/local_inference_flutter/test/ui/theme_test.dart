// LocalInferenceTheme and LocalInferenceStyle: every default comes from a ColorScheme role (light and dark for free),
// the built-in shapes and sizes are the defaults, overrides merge, lerp and copyWith work, and every progress bar and
// spinner gets its colors explicitly, so an app-wide white progressIndicatorTheme cannot hide them.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_inference/testing.dart';
import 'package:local_inference_flutter/local_inference_flutter.dart';

import '../support/toy_chat.dart';

void main() {
  test('light and dark: the defaults are ColorScheme roles', () {
    for (final brightness in Brightness.values) {
      final theme = ThemeData(colorSchemeSeed: Colors.teal, brightness: brightness);
      final scheme = theme.colorScheme;
      final style = LocalInferenceStyle.resolve(theme);
      expect(style.accent, scheme.primary);
      expect(style.onAccent, scheme.onPrimary);
      expect(style.userBubble, scheme.primary);
      expect(style.onUserBubble, scheme.onPrimary);
      expect(style.onAssistant, scheme.onSurface);
      expect(style.secondaryText, scheme.onSurfaceVariant);
      expect(style.background, scheme.surface);
      expect(style.composerFill, scheme.surfaceContainerHigh);
      expect(style.border, scheme.outlineVariant);
      expect(style.error, scheme.error);
      expect(style.pending, scheme.tertiary);
      expect(style.progress, scheme.primary);
      expect(style.progressTrack, scheme.primary.withValues(alpha: 0.14));
      expect(style.panelProgressTrack, style.progressTrack);
      expect(style.panelIconBackground, scheme.primary.withValues(alpha: 0.14));
      expect(style.assistantBubble, Colors.transparent);
      expect(style.messageStyle.color, scheme.onSurface);
      expect(style.messageStyle.fontSize, theme.textTheme.bodyLarge!.fontSize);
    }
  });

  test('the default shapes, widths and spacing', () {
    final style = LocalInferenceStyle.resolve(ThemeData());
    expect((style.bubbleRadius, style.composerRadius, style.cardRadius, style.buttonRadius), (14.0, 24.0, 16.0, 24.0));
    expect((style.progressRadius, style.panelProgressRadius), (8.0, 4.0));
    expect((style.userBubbleWidthFactor, style.assistantWidthFactor), (0.78, 0.9));
    expect(style.listPadding, const EdgeInsets.all(12));
    expect(style.messagePadding, const EdgeInsets.symmetric(horizontal: 14, vertical: 10));
    expect(style.messageSpacing, const EdgeInsets.symmetric(vertical: 4));
    expect(
      (style.panelMaxWidth, style.panelIconSize, style.setupIconSize, style.buttonMinHeight),
      (320.0, 34.0, 36.0, 48.0),
    );
    expect(style.shimmerPeriod, const Duration(milliseconds: 1600));
    expect((style.detailsStyle.fontSize, style.detailsStyle.fontFamily), (10.5, 'Menlo'));
  });

  test('an accent alone recolors what follows it; text styles merge; other fields replace', () {
    final style = LocalInferenceStyle.resolve(
      ThemeData(),
      const LocalInferenceTheme(accent: Color(0xFFB72020), titleStyle: TextStyle(fontSize: 20), bubbleRadius: 9),
    );
    expect(style.userBubble, const Color(0xFFB72020));
    expect(style.progress, const Color(0xFFB72020));
    expect(style.progressTrack, const Color(0xFFB72020).withValues(alpha: 0.14));
    expect((style.titleStyle.fontSize, style.titleStyle.fontWeight), (20.0, FontWeight.bold));
    expect(style.bubbleRadius, 9);

    const a = LocalInferenceTheme(accent: Colors.red, messageStyle: TextStyle(fontSize: 10));
    const b = LocalInferenceTheme(
      accent: Colors.blue,
      messageStyle: TextStyle(color: Colors.green),
    );
    final merged = a.merge(b);
    expect(merged.accent, Colors.blue);
    expect((merged.messageStyle!.fontSize, merged.messageStyle!.color), (10.0, Colors.green));
    expect(a.merge(null), same(a));
  });

  testWidgets('the status panels\' track follows progressTrack unless set on its own', (tester) async {
    usePhoneSurface(tester);
    const blue = Color(0xFFE8F1FB);
    const pink = Color(0x33FF0000);
    expect(
      LocalInferenceStyle.resolve(ThemeData(), const LocalInferenceTheme(progressTrack: pink)).panelProgressTrack,
      pink,
    );
    final entry = ModelManifest.parse(testManifestJson()).models.first;
    Color? track() => tester.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator)).backgroundColor;
    const theme = LocalInferenceTheme(progressTrack: pink, panelProgressTrack: blue);
    await tester.pumpWidget(
      app(
        const Scaffold(
          body: ChatStatusPanel(icon: Icons.memory, title: 'Preparing', progress: true),
        ),
        theme: ThemeData(extensions: const [theme]),
      ),
    );
    expect(track(), blue, reason: 'a status panel');
    await tester.pumpWidget(
      app(
        Scaffold(
          body: ModelProgressView(
            entry: entry,
            status: const ModelStatus(state: ModelState.downloading, progress: 0.4),
          ),
        ),
        theme: ThemeData(extensions: const [theme]),
      ),
    );
    expect(track(), pink, reason: 'a download');
    expect(theme.copyWith(panelProgressTrack: pink).panelProgressTrack, pink);
    expect(theme.merge(const LocalInferenceTheme(panelProgressTrack: pink)).panelProgressTrack, pink);
    expect(theme.lerp(theme.copyWith(panelProgressTrack: pink), 1).panelProgressTrack, pink);
    expect(theme, isNot(theme.copyWith(panelProgressTrack: pink)));
  });

  test('copyWith, lerp and equality', () {
    const a = LocalInferenceTheme(accent: Colors.black, bubbleRadius: 10, shimmerPeriod: Duration(seconds: 1));
    const b = LocalInferenceTheme(accent: Colors.white, bubbleRadius: 20, shimmerPeriod: Duration(seconds: 2));
    expect(
      a.copyWith(bubbleRadius: 12),
      const LocalInferenceTheme(accent: Colors.black, bubbleRadius: 12, shimmerPeriod: Duration(seconds: 1)),
    );
    final half = a.lerp(b, 0.5);
    expect(half.bubbleRadius, 15);
    expect(half.accent, Color.lerp(Colors.black, Colors.white, 0.5));
    expect(half.shimmerPeriod, const Duration(seconds: 2));
    expect(a.lerp(null, 0.5), same(a));
    expect(a, const LocalInferenceTheme(accent: Colors.black, bubbleRadius: 10, shimmerPeriod: Duration(seconds: 1)));
    expect(a.hashCode, a.copyWith().hashCode);
    expect(LocalInferenceStyle.resolve(ThemeData(), a), LocalInferenceStyle.resolve(ThemeData(), a));
  });

  testWidgets('under a white progressIndicatorTheme every bar and spinner keeps the style\'s colors', (tester) async {
    usePhoneSurface(tester);
    final white = ThemeData(
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: Colors.white,
        linearTrackColor: Colors.white,
        circularTrackColor: Colors.white,
      ),
    );
    final style = LocalInferenceStyle.resolve(white);
    void expectExplicit(String where) {
      final bars = tester.widgetList<ProgressIndicator>(find.byWidgetPredicate((w) => w is ProgressIndicator));
      expect(bars, isNotEmpty, reason: where);
      for (final bar in bars) {
        expect(bar.color, isNotNull, reason: '$where: ${bar.runtimeType} color');
        expect(bar.color, isNot(Colors.white), reason: where);
        expect(bar.backgroundColor, isNotNull, reason: '$where: ${bar.runtimeType} track');
      }
    }

    final entry = ModelManifest.parse(testManifestJson()).models.first;
    await tester.pumpWidget(
      app(
        const Scaffold(
          body: ChatStatusPanel(icon: Icons.memory, title: 'Preparing', progress: true),
        ),
        theme: white,
      ),
    );
    expectExplicit('status panel');
    expect(
      tester.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator)).backgroundColor,
      style.panelProgressTrack,
    );

    await tester.pumpWidget(
      app(
        Scaffold(
          body: ModelProgressView(
            entry: entry,
            status: const ModelStatus(state: ModelState.downloading, progress: 0.4),
          ),
        ),
        theme: white,
      ),
    );
    expectExplicit('progress view');

    await tester.pumpWidget(
      app(
        const Scaffold(body: ToolStatusIndicator(label: '📦 Looking up...')),
        theme: white,
      ),
    );
    expectExplicit('tool status');
  });
}
