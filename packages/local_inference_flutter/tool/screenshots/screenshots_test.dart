// The screenshots of pub.dev and the READMEs, drawn by the kit's own widgets: each scene runs a real Assistant on a
// scripted engine (no model), renders ChatPage on a phone-sized surface with Roboto and the Material icons from the
// Flutter SDK, captures it, and writes it in a phone frame under a caption.
//
// Run it from packages/local_inference_flutter (it is outside test/, so `flutter test` leaves it out):
//
//   flutter test tool/screenshots/screenshots_test.dart
//
// It writes screenshots/*.png (the package's pub.dev screenshots), ../../doc/hero.png (the READMEs' hero image, from
// three of the screens: run the whole file) and ../local_inference/screenshots/terminal.png (li_chat_session.txt, the
// stdout of a real li_chat session, in a terminal window; it needs SF Mono or Menlo, so elsewhere than macOS that test
// is skipped).
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_inference_flutter/local_inference_flutter.dart';
import 'package:local_inference_flutter/testing.dart';
import 'package:path/path.dart' as p;

import 'demo.dart';
import 'frame.dart';

/// The package folder (flutter test runs in it).
final String _package = Directory.current.path;

String _screenshot(String name) => p.join(_package, 'screenshots', name);

/// The phone screens, for the hero image.
final Map<String, ui.Image> _screens = {};

final ThemeData _light = ThemeData(
  colorSchemeSeed: Colors.indigo,
  extensions: const [LocalInferenceTheme(bubbleRadius: 20)],
);

/// The app around a chat page.
Widget _app(ThemeData theme, Widget home) =>
    capturable(MaterialApp(debugShowCheckedModeBanner: false, theme: theme, home: home));

/// A test with the real shadows (a widget test replaces them with solid blocks).
void _shot(String description, Future<void> Function(WidgetTester tester) body) =>
    testWidgets(description, (tester) async {
      debugDisableShadows = false;
      try {
        await body(tester);
      } finally {
        debugDisableShadows = true;
      }
    });

bool _shows(String text) => find.text(text).evaluate().isNotEmpty;

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await loadFonts();
  });

  _shot('tool calling: replies from the weather tool and the calculator, the calendar running', (tester) async {
    usePhone(tester);
    final gate = Completer<void>();
    final engine = ScriptedEngine(supportsStatePersistence: false)
      ..outputs.addAll([...weatherScript, ...billScript, calendarScript.first]);
    final controller = await demoController(
      tester,
      demoConfig([weatherTool(), calculatorTool(), calendarTool(gate: gate.future)]),
      engine,
    );
    await tester.pumpWidget(
      _app(
        _light,
        ChatPage(
          controller: controller,
          assistantName: 'Helper',
          welcome: helperWelcome,
          strings: LocalInferenceStrings.english,
        ),
      ),
    );
    await ask(tester, controller, weatherQuestion);
    await ask(tester, controller, billQuestion);
    unawaited(controller.send(calendarQuestion));
    await pumpUntil(tester, () => _shows('Checking your calendar…'), reason: 'the calendar tool runs');
    await tester.pump(const Duration(milliseconds: 300));
    final screen = _screens['tools'] = await capture(tester, phonePixelRatio);

    engine.outputs.add(calendarScript.last);
    gate.complete();
    await pumpUntil(tester, () => !controller.assistant.state.isBusy, reason: 'the calendar turn ends');
    await renderPicture(
      tester,
      Poster(
        title: 'Tool calling, on device',
        subtitle: 'The model calls your Dart functions,\nthen answers from their results.',
        screen: screen,
      ),
      posterSize,
      posterPixelRatio,
      _screenshot('1_tool_calling.png'),
    );
  });

  _shot('confirmation: an irreversible tool asks first, with Yes and No', (tester) async {
    usePhone(tester);
    final engine = ScriptedEngine(supportsStatePersistence: false)
      ..outputs.addAll([
        call('find_tables', {'near': 'the Pantheon', 'people': 2, 'day': 'Friday', 'time': '8 pm'}),
        'Three places near the Pantheon have a table for 2 on Friday at 8 pm:\n'
            '1. Trattoria Da Lucia, Roman cooking\n'
            '2. Osteria del Sole, wine and small plates\n'
            '3. Pizzeria Il Forno, wood-fired pizza',
        call('book_table', {'restaurant': 'Trattoria Da Lucia', 'people': 2, 'day': 'Friday', 'time': '8 pm'}),
      ]);
    final controller = await demoController(tester, demoConfig([findTablesTool(), bookTableTool()]), engine);
    await tester.pumpWidget(
      _app(
        _light,
        ChatPage(
          controller: controller,
          assistantName: 'Helper',
          welcome: helperWelcome,
          strings: LocalInferenceStrings.english,
        ),
      ),
    );
    await ask(tester, controller, 'Find a table for 2 near the Pantheon on Friday at 8 pm.');
    await ask(tester, controller, 'Book the first one.');
    expect(controller.pendingActions.value, hasLength(2), reason: 'the question waits for Yes or No');
    expect(find.byKey(LocalInferenceKeys.confirmAction(ChatActionKind.confirm)), findsOneWidget);
    final screen = _screens['confirm'] = await capture(tester, phonePixelRatio);
    await renderPicture(
      tester,
      Poster(
        title: 'Confirms before it acts',
        subtitle: 'A tool that books, pays or deletes\nwaits for the user’s yes.',
        screen: screen,
      ),
      posterSize,
      posterPixelRatio,
      _screenshot('2_confirmation.png'),
    );
  });

  _shot('download: the model setup downloads the model once', (tester) async {
    usePhone(tester);
    final root = Directory.systemTemp.createTempSync('li_screenshots');
    addTearDown(() => root.deleteSync(recursive: true));
    final downloader = FakeModelDownloader();
    final models = ModelManager(
      root: () async => root.path,
      probe: FakeDeviceProbe(),
      downloader: downloader,
      catalog: ModelCatalog.bundled(() async => demoManifest()),
    );
    addTearDown(models.dispose);
    final controller = await demoController(
      tester,
      demoConfig([weatherTool(), calculatorTool()]),
      ScriptedEngine(supportsStatePersistence: false),
      load: false,
    );
    final setup = ModelSetupController(manager: models, assistant: controller);
    addTearDown(setup.dispose);
    await tester.pumpWidget(
      _app(
        _light,
        ChatPage(controller: controller, setup: setup, assistantName: 'Helper', strings: LocalInferenceStrings.english),
      ),
    );
    await pumpUntil(tester, () => _shows('Download and try'), reason: 'the consent');
    await tester.tap(find.text('Download and try'));
    const id = 'qwen3.5-4b-q4_0';
    await pumpUntil(tester, () => downloader.lastStart(id) != null, reason: 'the download starts');
    downloader.emit(
      const ModelDownloadUpdate(
        id: id,
        state: ModelDownloadState.running,
        progress: 0.62,
        expectedBytes: 2583221408,
        bytesPerSecond: 14.2e6,
        timeRemaining: Duration(seconds: 70),
      ),
    );
    await pumpUntil(tester, () => _shows('62%'), reason: 'the progress');
    await tester.pumpAndSettle();
    final screen = await capture(tester, phonePixelRatio);
    await renderPicture(
      tester,
      Poster(
        title: 'Download once, run offline',
        subtitle: 'Consent, a background download, a checked file.\nThen it answers without a network.',
        screen: screen,
      ),
      posterSize,
      posterPixelRatio,
      _screenshot('3_model_download.png'),
    );
  });

  _shot('theme: the same chat in a dark brand theme, strings and builders of its own', (tester) async {
    usePhone(tester);
    final engine = ScriptedEngine(supportsStatePersistence: false)..outputs.addAll([...weatherScript, ...billScript]);
    final controller = await demoController(
      tester,
      demoConfig([weatherTool(), calculatorTool()], forecastChip: true),
      engine,
    );
    const accent = Color(0xFFFF8A4C);
    const onAccent = Color(0xFF2B1206);
    final dark = ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: accent, brightness: Brightness.dark),
      extensions: const [
        LocalInferenceTheme(
          accent: accent,
          onAccent: onAccent,
          background: Color(0xFF0F1116),
          surface: Color(0xFF0F1116),
          composerFill: Color(0xFF191C23),
          border: Color(0xFF2A2F39),
          assistantBubble: Color(0xFF1B1F27),
          onAssistant: Color(0xFFECEEF3),
          secondaryText: Color(0xFF9AA1AE),
          disclosureBackground: Color(0xFF1A1E26),
          onDisclosure: Color(0xFFAEB5C2),
          bubbleRadius: 22,
          composerRadius: 16,
          titleStyle: TextStyle(fontWeight: FontWeight.w800, letterSpacing: 0.6),
        ),
      ],
    );
    final strings = LocalInferenceStrings.english.copyWith(
      chat: ChatStrings.english.copyWith(
        composerHint: 'Ask Nova anything…',
        disclosure: 'Nova runs on your phone: its replies come from an AI and can be wrong.',
      ),
    );
    Widget avatar(Widget child) => Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(top: 8),
          child: CircleAvatar(
            radius: 15,
            backgroundColor: accent,
            child: Icon(Icons.auto_awesome, size: 17, color: onAccent),
          ),
        ),
        const SizedBox(width: 6),
        Expanded(child: child),
      ],
    );
    await tester.pumpWidget(
      _app(
        dark,
        ChatPage(
          controller: controller,
          assistantName: 'Nova',
          strings: strings,
          welcome: "Hi, I'm Nova. I run right on your phone, so I work offline too.",
          features: const ChatFeatures(aiDisclosure: AiDisclosureMode.dismissible),
          callbacks: ChatCallbacks(onScreenRequest: (context, dispatch) {}),
          builders: ChatBuilders(
            welcome: (context, slot) => avatar(slot.buildDefault()),
            assistantMessage: (context, slot) => avatar(slot.buildDefault()),
          ),
        ),
      ),
    );
    await tester.pump();
    await ask(tester, controller, weatherQuestion);
    await ask(tester, controller, billQuestion);
    expect(_shows('Open the forecast'), isTrue, reason: 'the chip of the weather reply');
    final screen = _screens['theme'] = await capture(tester, phonePixelRatio);
    await renderPicture(
      tester,
      Poster(
        title: 'Your theme, your strings',
        subtitle: 'LocalInferenceTheme, string packs and\nbuilders restyle every part.',
        screen: screen,
        dark: true,
      ),
      posterSize,
      posterPixelRatio,
      _screenshot('4_custom_theme.png'),
    );
  });

  _shot('compliance: the AI disclosure and the report sheet', (tester) async {
    usePhone(tester);
    final engine = ScriptedEngine(supportsStatePersistence: false)..outputs.addAll(weatherScript);
    final controller = await demoController(tester, demoConfig([weatherTool(), calculatorTool()]), engine);
    await tester.pumpWidget(
      _app(
        _light,
        ChatPage(
          controller: controller,
          assistantName: 'Helper',
          welcome: helperWelcome,
          strings: LocalInferenceStrings.english,
          features: const ChatFeatures(reportAffordance: ReportAffordance.icon),
          callbacks: ChatCallbacks(onReport: (report) {}),
        ),
      ),
    );
    await ask(tester, controller, weatherQuestion);
    final reply = controller.assistant.state.items.last;
    await tester.tap(find.byKey(LocalInferenceKeys.reportAction(reply.id)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Wrong or made up'));
    await tester.pumpAndSettle();
    final screen = await capture(tester, phonePixelRatio);
    await renderPicture(
      tester,
      Poster(
        title: 'Disclosure and reports, built in',
        subtitle: 'The AI notice of the EU AI Act and the\nreport sheet that Google Play asks for.',
        screen: screen,
      ),
      posterSize,
      posterPixelRatio,
      _screenshot('5_disclosure_and_reports.png'),
    );
  });

  _shot('hero: three screens side by side', (tester) async {
    final screens = [
      for (final (name, caption, dark) in const [
        ('tools', 'Tool calling, on device', false),
        ('confirm', 'Confirms before it acts', false),
        ('theme', 'Your theme, your strings', true),
      ])
        (caption, _screens[name] ?? (throw StateError('run the whole file: the $name screen is missing')), dark),
    ];
    await renderPicture(
      tester,
      HeroPicture(screens: screens),
      heroSize,
      1,
      p.normalize(p.join(_package, '..', '..', 'doc', 'hero.png')),
    );
  });

  // li_chat_session.txt is the stdout of this session, unedited: on 2026-10-16, an Apple M1 Pro (Metal), the stock
  // Qwen3.5-2B-Q4_0.gguf (1,214,873,856 bytes) linked into packages/local_inference/example, run there with the three
  // lines below on stdin. To take a new one, run the same and replace the file (and `typed` if the lines change):
  //
  //   printf 'What time is it?\nA dinner bill of 186.40 euros plus a 10%% tip, split between 4 people: how much '\
  //     'each?\n/quit\n' | dart run bin/li_chat.dart --model Qwen3.5-2B-Q4_0.gguf > li_chat_session.txt
  //
  // A piped stdin is not echoed, so the picture puts each line after the prompt it answered, as a terminal shows
  // what was typed. dart run's "Running build hooks..." goes to stderr and is left out.
  _shot('terminal: a real li_chat session', (tester) async {
    if (!await loadMonospaceFont()) {
      markTestSkipped('no SF Mono or Menlo on this computer');
      return;
    }
    const command = 'dart run bin/li_chat.dart --model Qwen3.5-2B-Q4_0.gguf';
    const typed = [
      'What time is it?',
      'A dinner bill of 186.40 euros plus a 10% tip, split between 4 people: how much each?',
      '/quit',
    ];
    final stdout = File(p.join(_package, 'tool', 'screenshots', 'li_chat_session.txt')).readAsStringSync();
    const prompt = TerminalRun('example % ', color: terminalPrompt, bold: true);
    final lines = <TerminalLine>[
      [prompt, const TerminalRun(command, color: terminalBright)],
    ];
    var next = 0;
    for (final line in stdout.split('\n')) {
      if (line.startsWith('> ') && next < typed.length) {
        lines.add([const TerminalRun('> '), TerminalRun(typed[next++], color: terminalBright, bold: true)]);
        if (line.length > 2) lines.add([TerminalRun(line.substring(2))]);
      } else {
        lines.add([TerminalRun(line.isEmpty ? ' ' : line)]);
      }
    }
    expect(next, typed.length, reason: 'every typed line found its prompt');
    lines.add([prompt, const TerminalRun('█', color: terminalDim)]);
    // As wide as the longest line, plus two columns: nothing wraps.
    final columns = 2 + lines.map((line) => line.fold(0, (width, run) => width + run.text.length)).reduce(math.max);
    await renderPicture(
      tester,
      TerminalWindow(title: 'example — dart run bin/li_chat.dart', lines: lines, columns: columns),
      TerminalWindow.sizeFor(lines.length, columns),
      2,
      p.normalize(p.join(_package, '..', 'local_inference', 'screenshots', 'terminal.png')),
    );
  });
}
