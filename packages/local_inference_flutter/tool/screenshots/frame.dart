// The screenshot generator's frame: real fonts, the phone the screens render on, captures written as PNG, and the
// pictures around a screen (a phone frame under a caption, the hero image, the terminal window).
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// The phone every screen renders on: an iPhone-sized surface at 3x, with a status bar and a gesture bar.
const phoneSize = Size(390, 844);
const phonePixelRatio = 3.0;
const statusBarHeight = 32.0;
const gestureBarHeight = 18.0;

/// A store screenshot: [posterSize] logical points at [posterPixelRatio].
const posterSize = Size(500, 1080);
const posterPixelRatio = 2.0;

/// The hero image of the READMEs, at 1x.
const heroSize = Size(1600, 900);

const _bezel = 11.0;
const _frameSize = Size(390 + 2 * _bezel, 844 + 2 * _bezel);

const _ink = Color(0xFF141A2E);
const _inkSecondary = Color(0xFF4C5470);
const _backdrop = LinearGradient(
  begin: Alignment.topCenter,
  end: Alignment.bottomCenter,
  colors: [Color(0xFFF5F7FD), Color(0xFFDCE3F4)],
);

/// The Flutter SDK running the test: FLUTTER_ROOT, else the folder above flutter_tester holding bin/flutter.
String flutterRoot() {
  final env = Platform.environment['FLUTTER_ROOT'];
  if (env != null && env.isNotEmpty) return env;
  var dir = File(Platform.resolvedExecutable).parent;
  while (dir.parent.path != dir.path) {
    if (File(p.join(dir.path, 'bin', 'flutter')).existsSync()) return dir.path;
    dir = dir.parent;
  }
  throw StateError('the Flutter SDK was not found: set FLUTTER_ROOT');
}

ByteData _bytes(String path) => ByteData.sublistView(File(path).readAsBytesSync());

/// Roboto and the Material icons from the SDK's cache, so text and icons render as on a phone (a widget test draws
/// every glyph as a box otherwise).
Future<void> loadFonts() async {
  final dir = p.join(flutterRoot(), 'bin', 'cache', 'artifacts', 'material_fonts');
  final roboto = FontLoader('Roboto');
  for (final style in ['Regular', 'Italic', 'Light', 'Medium', 'MediumItalic', 'Bold', 'BoldItalic', 'Black']) {
    roboto.addFont(Future.value(_bytes(p.join(dir, 'Roboto-$style.ttf'))));
  }
  await roboto.load();
  await (FontLoader('MaterialIcons')..addFont(Future.value(_bytes(p.join(dir, 'MaterialIcons-Regular.otf'))))).load();
}

/// The terminal's monospace font: SF Mono, else Menlo (macOS). False when neither is on this computer.
Future<bool> loadMonospaceFont() async {
  for (final path in ['/System/Library/Fonts/SFNSMono.ttf', '/System/Library/Fonts/Menlo.ttc']) {
    if (!File(path).existsSync()) continue;
    await (FontLoader(terminalFont)..addFont(Future.value(_bytes(path)))).load();
    return true;
  }
  return false;
}

const terminalFont = 'Terminal Mono';

/// Renders the test's widgets as the phone: its size and pixel ratio, the status and gesture bars as view padding,
/// animations off (the thinking text stays still).
void usePhone(WidgetTester tester) {
  const padding = FakeViewPadding(top: statusBarHeight * phonePixelRatio, bottom: gestureBarHeight * phonePixelRatio);
  tester.view
    ..physicalSize = phoneSize * phonePixelRatio
    ..devicePixelRatio = phonePixelRatio
    ..padding = padding
    ..viewPadding = padding;
  tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true);
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
}

/// Renders the test's widgets on a canvas of [size] logical points at [pixelRatio], with no padding.
void useCanvas(WidgetTester tester, Size size, double pixelRatio) {
  tester.view
    ..physicalSize = size * pixelRatio
    ..devicePixelRatio = pixelRatio
    ..padding = FakeViewPadding.zero
    ..viewPadding = FakeViewPadding.zero;
  addTearDown(tester.view.reset);
}

const captureKey = ValueKey('screenshots.capture');

/// [child] as what [capture] takes.
Widget capturable(Widget child) => RepaintBoundary(key: captureKey, child: child);

/// The pixels of the [capturable] on screen, at [pixelRatio].
Future<ui.Image> capture(WidgetTester tester, double pixelRatio) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(captureKey));
  return (await tester.runAsync(() => boundary.toImage(pixelRatio: pixelRatio)))!;
}

/// Writes [image] as a PNG file at [path]; returns its size in bytes.
Future<int> writePng(WidgetTester tester, ui.Image image, String path) async {
  final data = (await tester.runAsync(() => image.toByteData(format: ui.ImageByteFormat.png)))!;
  final file = File(path)..parent.createSync(recursive: true);
  file.writeAsBytesSync(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
  final bytes = file.lengthSync();
  // The pub.dev limit is 4 MB per screenshot.
  expect(bytes, lessThan(4 * 1024 * 1024), reason: path);
  printOnFailure('$path: ${image.width}x${image.height}, $bytes bytes');
  // ignore: avoid_print
  print('wrote $path (${image.width}x${image.height}, $bytes bytes)');
  return bytes;
}

/// Renders [picture] on a [size] canvas at [pixelRatio] and writes it to [path].
Future<void> renderPicture(WidgetTester tester, Widget picture, Size size, double pixelRatio, String path) async {
  useCanvas(tester, size, pixelRatio);
  await tester.pumpWidget(
    capturable(
      Directionality(
        textDirection: TextDirection.ltr,
        child: MediaQuery(
          data: MediaQueryData(size: size, devicePixelRatio: pixelRatio),
          child: picture,
        ),
      ),
    ),
  );
  await tester.pump();
  final image = await capture(tester, pixelRatio);
  await writePng(tester, image, path);
  image.dispose();
}

TextStyle _roboto(double size, FontWeight weight, Color color, {double? height, double? spacing}) => TextStyle(
  fontFamily: 'Roboto',
  fontSize: size,
  fontWeight: weight,
  color: color,
  height: height,
  letterSpacing: spacing,
  decoration: TextDecoration.none,
);

/// A store screenshot: [title] and [subtitle] above [screen] in a phone frame, on a light backdrop.
class Poster extends StatelessWidget {
  const Poster({super.key, required this.title, required this.subtitle, required this.screen, this.dark = false});

  final String title;
  final String subtitle;
  final ui.Image screen;

  /// The screen is dark: a light status bar.
  final bool dark;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: const BoxDecoration(gradient: _backdrop),
    child: Column(
      children: [
        const SizedBox(height: 46),
        Text(title, textAlign: TextAlign.center, style: _roboto(31, FontWeight.w700, _ink, spacing: -0.4)),
        const SizedBox(height: 10),
        SizedBox(
          height: 48,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 36),
            child: Text(
              subtitle,
              textAlign: TextAlign.center,
              maxLines: 2,
              style: _roboto(17, FontWeight.w400, _inkSecondary, height: 1.35),
            ),
          ),
        ),
        const SizedBox(height: 28),
        PhoneFrame(screen: screen, dark: dark),
      ],
    ),
  );
}

/// The README hero: [screens] side by side in phone frames, each under its caption.
class HeroPicture extends StatelessWidget {
  const HeroPicture({super.key, required this.screens});

  /// (caption, screen, dark).
  final List<(String, ui.Image, bool)> screens;

  @override
  Widget build(BuildContext context) {
    const scale = 0.84;
    return DecoratedBox(
      decoration: const BoxDecoration(gradient: _backdrop),
      child: Padding(
        padding: const EdgeInsets.only(top: 42),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final (index, (caption, screen, dark)) in screens.indexed) ...[
              if (index > 0) const SizedBox(width: 92),
              Column(
                children: [
                  Text(caption, style: _roboto(26, FontWeight.w700, _ink, spacing: -0.3)),
                  const SizedBox(height: 22),
                  SizedBox(
                    width: _frameSize.width * scale,
                    height: _frameSize.height * scale,
                    child: FittedBox(
                      child: PhoneFrame(screen: screen, dark: dark),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// A phone around [screen] (a capture of [phoneSize]): rounded bezel, camera hole, status bar and gesture bar, with
/// a soft shadow.
class PhoneFrame extends StatelessWidget {
  const PhoneFrame({super.key, required this.screen, this.dark = false});

  final ui.Image screen;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    final onScreen = dark ? const Color(0xFFF2F3F7) : const Color(0xFF1B1C22);
    return Container(
      width: _frameSize.width,
      height: _frameSize.height,
      padding: const EdgeInsets.all(_bezel),
      decoration: BoxDecoration(
        color: const Color(0xFF111216),
        borderRadius: BorderRadius.circular(54),
        border: Border.all(color: const Color(0xFF34373F), width: 1.5),
        boxShadow: const [
          BoxShadow(color: Color(0x2E1A2340), blurRadius: 44, offset: Offset(0, 22)),
          BoxShadow(color: Color(0x1A1A2340), blurRadius: 8, offset: Offset(0, 3)),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(43),
        child: Stack(
          children: [
            RawImage(
              image: screen,
              width: phoneSize.width,
              height: phoneSize.height,
              fit: BoxFit.fill,
              filterQuality: FilterQuality.medium,
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: statusBarHeight,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 26),
                child: Row(
                  children: [
                    Text('9:41', style: _roboto(14, FontWeight.w500, onScreen)),
                    const Spacer(),
                    Icon(Icons.signal_cellular_alt, size: 16, color: onScreen),
                    const SizedBox(width: 3),
                    Icon(Icons.wifi, size: 16, color: onScreen),
                    const SizedBox(width: 3),
                    Icon(Icons.battery_full, size: 16, color: onScreen),
                  ],
                ),
              ),
            ),
            // The camera hole.
            Positioned(
              top: 9,
              left: phoneSize.width / 2 - 7,
              child: Container(
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  color: const Color(0xFF07080A),
                  shape: BoxShape.circle,
                  border: Border.all(color: const Color(0xFF26282E), width: 1.5),
                ),
              ),
            ),
            // The gesture bar.
            Positioned(
              bottom: 7,
              left: phoneSize.width / 2 - 54,
              child: Container(
                width: 108,
                height: 4,
                decoration: BoxDecoration(
                  color: onScreen.withValues(alpha: 0.75),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One line of the terminal: its runs of text.
typedef TerminalLine = List<TerminalRun>;

/// A run of terminal text in one style.
final class TerminalRun {
  const TerminalRun(this.text, {this.color = terminalText, this.bold = false});

  final String text;
  final Color color;
  final bool bold;
}

const terminalText = Color(0xFFD9DBE1);
const terminalDim = Color(0xFF8D93A1);
const terminalPrompt = Color(0xFF7FCF9A);
const terminalBright = Color(0xFFFFFFFF);

/// A dark terminal window of [columns] columns showing [lines], with [title] in its title bar, on the light backdrop.
class TerminalWindow extends StatelessWidget {
  const TerminalWindow({super.key, required this.title, required this.lines, required this.columns});

  final String title;
  final List<TerminalLine> lines;
  final int columns;

  static const fontSize = 13.5;
  static const lineHeight = 1.42;

  static TextStyle style(Color color, {bool bold = false}) => TextStyle(
    fontFamily: terminalFont,
    fontSize: fontSize,
    height: lineHeight,
    color: color,
    fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
    decoration: TextDecoration.none,
  );

  /// The width of one column, measured.
  static double columnWidth() {
    final painter = TextPainter(
      text: TextSpan(text: 'M' * 100, style: style(terminalText)),
      textDirection: TextDirection.ltr,
    )..layout();
    final width = painter.width / 100;
    painter.dispose();
    return width;
  }

  /// The picture's size for [lines] at [columns] columns.
  static Size sizeFor(int lineCount, int columns) =>
      Size(columns * columnWidth() + 2 * 22 + 2 * 36, lineCount * fontSize * lineHeight + 34 + 2 * 18 + 2 * 36);

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: const BoxDecoration(gradient: _backdrop),
    child: Padding(
      padding: const EdgeInsets.all(36),
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: const Color(0xFF1B1C21),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFF3A3C44)),
          boxShadow: const [
            BoxShadow(color: Color(0x381A2340), blurRadius: 40, offset: Offset(0, 18)),
            BoxShadow(color: Color(0x1F1A2340), blurRadius: 6, offset: Offset(0, 2)),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              height: 34,
              color: const Color(0xFF2A2B31),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Positioned(
                    left: 14,
                    child: Row(
                      children: [
                        for (final color in const [Color(0xFFFF5F57), Color(0xFFFEBC2E), Color(0xFF28C840)]) ...[
                          Container(
                            width: 12,
                            height: 12,
                            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                          ),
                          const SizedBox(width: 8),
                        ],
                      ],
                    ),
                  ),
                  Text(title, style: _roboto(13, FontWeight.w500, const Color(0xFFA9ACB6))),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final line in lines)
                    Text.rich(
                      TextSpan(
                        children: [
                          for (final run in line)
                            TextSpan(
                              text: run.text,
                              style: style(run.color, bold: run.bold),
                            ),
                        ],
                        style: style(terminalText),
                      ),
                      softWrap: false,
                      overflow: TextOverflow.clip,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
