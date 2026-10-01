// The README's examples, verbatim, so they keep compiling (the headless chat and the widget test also run), and a
// check that they are the README's: every line of its Dart blocks is here, in order. The "Model download" example is
// in readme/model_download_example.dart.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_inference_flutter/local_inference_flutter.dart';
import 'package:local_inference_flutter/testing.dart';

import 'readme/model_download_example.dart' as model_download;

// --- README: "One widget", and the config of "Testing your assistant" ----------------------------------------------

// The config under test; in an app it comes from the app's own code.
final weather = AssistantConfig.basic(
  systemPrompt: 'You tell the weather in a few words.',
  tools: [
    AssistantTool(
      name: 'weather',
      description: 'The weather in a city.',
      parameters: ToolSchema.object({'city': ToolSchema.string()}, required: ['city']),
      statusLabel: 'Checking the weather...',
      run: (call, context) => ToolResult.ok({'city': call.string('city'), 'sky': 'sunny'}),
    ),
  ],
);

Future<void> oneWidget() async {
  WidgetsFlutterBinding.ensureInitialized();
  await LocalInferenceFlutter.installDownloaderStorage();
  runApp(
    MaterialApp(
      home: LocalInferenceChat(
        config: weather,
        model: ModelOrigin.manifest(Uri.parse('https://example.org/models/manifest.json')),
        assistantName: 'Helper',
        welcome: 'Hi! Ask me about the weather.',
        suggestions: const ['Weather in Rome?'],
      ),
    ),
  );
}

// --- README: "Pages over your own controllers" --------------------------------------------------------------------

Future<void> pagesOverControllers() async {
  WidgetsFlutterBinding.ensureInitialized();
  const download = BackgroundDownloadConfig(group: 'my_app_models', appName: 'Helper');
  await LocalInferenceFlutter.installDownloaderStorage(download: download);
  final models = await LocalInferenceFlutter.createModelManager(
    catalog: ModelCatalog.bundled(() => rootBundle.loadString('assets/models/manifest.json')),
    download: download,
  );
  // An Italian chat: the assistant's own words (its Yes and No) in Italian too.
  final assistant = await LocalInferenceFlutter.createAssistantController(
    weather.copyWith(strings: AssistantStrings.italian),
  );
  final setup = ModelSetupController(manager: models, assistant: assistant);
  runApp(
    MaterialApp(
      theme: ThemeData(colorSchemeSeed: Colors.teal, extensions: const [LocalInferenceTheme(bubbleRadius: 20)]),
      // Above the Navigator: the chat survives the pages pushed on top, and sheets and dialogs get its texts.
      builder: (context, child) => LocalInferenceScope(
        assistant: assistant,
        setup: setup,
        models: models,
        strings: LocalInferenceStrings.italian,
        child: child!,
      ),
      home: ChatPage(
        assistantName: 'Helper',
        suggestions: const ['Che tempo fa a Roma?'],
        callbacks: ChatCallbacks(
          onScreenRequest: (context, dispatch) => Navigator.of(context).pushNamed('/city'),
          onReport: (report) => debugPrint(jsonEncode(report.toJson())),
        ),
        builders: ChatBuilders(
          assistantMessage: (context, slot) => Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const CircleAvatar(child: Icon(Icons.smart_toy)),
              Expanded(child: slot.buildDefault()),
            ],
          ),
        ),
      ),
    ),
  );
}

// --- README: "Headless" -------------------------------------------------------------------------------------------

class MyChat extends StatelessWidget {
  const MyChat(this.chat, {super.key});

  final AssistantController chat;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Expanded(
        child: ValueListenableBuilder<List<int>>(
          valueListenable: chat.itemIds,
          builder: (context, ids, _) => ListView.builder(
            itemCount: ids.length,
            itemBuilder: (context, index) => ValueListenableBuilder<ChatItem>(
              key: ValueKey(ids[index]),
              valueListenable: chat.item(ids[index]),
              builder: (context, item, _) => ListTile(
                title: Text(item.thinking && item.text.isEmpty ? '…' : item.text),
                subtitle: item.status == null ? null : Text(item.status!),
                leading: Icon(item.role == MessageRole.user ? Icons.person : Icons.smart_toy),
              ),
            ),
          ),
        ),
      ),
      TextField(
        controller: chat.draft,
        // Enabled during a turn too: a disabled field would close the keyboard after each message.
        onSubmitted: (text) {
          if (!chat.composer.value.canSend) return;
          chat.draft.clear();
          chat.send(text);
        },
      ),
    ],
  );
}

// --- README: "Testing your assistant" (its test is the first below) ----------------------------------------------

void main() {
  testWidgets('the chat answers with the weather tool', (tester) async {
    final engine = ScriptedEngine(supportsStatePersistence: false)
      ..outputs.addAll([
        const ScriptedTurn.toolCall('weather', {'city': 'Rome'}).output,
        'Sunny in Rome.',
      ]);
    // Any file stands for the model: the scripted engine does not read it.
    final model = File('${Directory.systemTemp.createTempSync().path}/weather.gguf')..writeAsStringSync('x');
    await tester.pumpWidget(
      MaterialApp(
        home: LocalInferenceChat(
          config: weather,
          model: ModelOrigin.file(model.path),
          engine: () => engine,
          prefixStore: InMemoryPrefixStateStore(),
          suggestions: const ['Weather in Rome?'],
        ),
      ),
    );
    await pumpUntil(tester, () => find.text('Weather in Rome?').evaluate().isNotEmpty);
    await tester.tap(find.text('Weather in Rome?'));
    await pumpUntil(tester, () => find.text('Sunny in Rome.').evaluate().isNotEmpty);
  });

  test('the README\'s app examples compile', () {
    expect(oneWidget, isNotNull);
    expect(pagesOverControllers, isNotNull);
    expect(model_download.main, isNotNull);
  });

  testWidgets('the README\'s headless chat runs', (tester) async {
    final (assistant, engine) =
        await tester.runAsync(
              () => scriptedAssistant(
                weather,
                script: [
                  ScriptedTurn.toolCall('weather', {'city': 'Rome'}),
                ],
              ),
            )
            as (Assistant, ScriptedEngine);
    engine.outputs.add('Sunny in Rome.');
    final chat = AssistantController.owning(assistant);
    addTearDown(() => tester.runAsync(chat.dispose));
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: MyChat(chat))));
    await tester.enterText(find.byType(TextField), 'Weather in Rome?');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await pumpUntil(tester, () => find.text('Sunny in Rome.').evaluate().isNotEmpty);
    expect(find.text('Weather in Rome?'), findsOneWidget);
  });

  test('the README\'s Dart blocks are these examples', () {
    final readme = File('README.md').readAsStringSync();
    final blocks = [for (final block in RegExp(r'```dart\n(.*?)```', dotAll: true).allMatches(readme)) block[1]!];
    expect(blocks, hasLength(5));
    final here = [
      for (final file in ['test/readme_examples_test.dart', 'test/readme/model_download_example.dart'])
        ...File(file).readAsLinesSync().map((line) => line.trim()),
    ];
    for (final block in blocks) {
      var from = 0;
      for (final line in block.split('\n').map((line) => line.trim()).where((line) => line.isNotEmpty)) {
        // Imports are at the top of the files; the rest follows the README's order.
        final at = here.indexOf(line, line.startsWith('import ') ? 0 : from);
        expect(at, isNot(-1), reason: 'README line missing here, or out of order: $line');
        if (!line.startsWith('import ')) from = at + 1;
      }
    }
  });
}

/// Lets the assistant and real I/O go on: short real waits and frames, until [done].
Future<void> pumpUntil(WidgetTester tester, bool Function() done, {int maxSteps = 300}) async {
  for (var i = 0; i < maxSteps && !done(); i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    await tester.pump();
  }
  expect(done(), isTrue);
}
