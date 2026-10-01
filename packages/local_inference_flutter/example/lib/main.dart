// flutter_chat: LocalInferenceChat with two toy tools (lib/toolkit.dart). The first launch offers to download
// LFM2.5-1.2B-Instruct (about 700 MB) and chats once it is checked and loaded. See README.md.
import 'package:flutter/material.dart';
import 'package:local_inference_flutter/local_inference_flutter.dart';

import 'toolkit.dart';

/// LFM2.5-1.2B-Instruct, QAD Q4_0 (LFM Open License v1.0), from Liquid AI's own Hugging Face repository at a fixed
/// commit, with the size and SHA-256 the repository lists for the file. The download is checked against both.
final lfm25 = ModelEntry(
  id: 'lfm2.5-1.2b-instruct-qad-q4_0',
  url: Uri.parse(
    'https://huggingface.co/LiquidAI/LFM2.5-1.2B-Instruct-GGUF/resolve/8ed288026e23958ad9dfa92d53ed773a8eee7125/'
    'LFM2.5-1.2B-Instruct-QAD-Q4_0.gguf',
  ),
  sizeBytes: 695755488,
  sha256: 'bb741ebb106d543e9de114b843a3d3d73d51c74b5801e69da2abde821a0cb3e1',
  displayName: 'LFM2.5 1.2B Instruct',
  params: '1.2B',
  quant: 'Q4_0',
  minPhysicalRamMB: 3500,
  minAvailableMemoryMB: 1500,
  minFreeDiskMB: 1000,
);

/// The kit's English texts, with a consent text and a download hint for this model of about 700 MB (the kit's own
/// texts speak of a file of a few GB).
final strings = LocalInferenceStrings.english.copyWith(
  setup: ModelSetupStrings.english.copyWith(
    consentBody: (assistant) =>
        'To try $assistant, download its AI model once (about 700 MB, best on Wi-Fi). It runs on this device, so '
        'then it answers even offline.',
    downloadHint: 'Keep the app open until the download ends. If the connection drops, it resumes by itself.',
  ),
);

/// The background download: its own group, and English notifications.
final download = BackgroundDownloadConfig(
  group: 'flutter_chat_models',
  appName: 'Flutter chat',
  notifications: DownloadNotifications.english(appName: 'Flutter chat'),
);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // First, before anything uses background_downloader: a failed download then resumes after a relaunch.
  await LocalInferenceFlutter.installDownloaderStorage(download: download);
  runApp(const FlutterChatApp());
}

class FlutterChatApp extends StatelessWidget {
  const FlutterChatApp({super.key, this.model, this.engine, this.load, this.prefixStore});

  /// Where the model comes from; null: [lfm25], downloaded once the user agrees.
  final ModelOrigin? model;

  /// The engine, the load options and the prefix-state store; null: llama.cpp with the device's options and a
  /// store in the caches folder. The widget test passes a scripted engine.
  final EngineFactory? engine;
  final LoadOptions? load;
  final PrefixStateStore? prefixStore;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Flutter chat',
    // The chat takes its colors from the app's theme; the LocalInferenceTheme extension changes the chat's own look.
    theme: ThemeData(colorSchemeSeed: Colors.indigo, extensions: const [LocalInferenceTheme(bubbleRadius: 20)]),
    darkTheme: ThemeData(
      colorSchemeSeed: Colors.indigo,
      brightness: Brightness.dark,
      extensions: const [LocalInferenceTheme(bubbleRadius: 20)],
    ),
    home: LocalInferenceChat(
      config: chatConfig(),
      strings: strings,
      model: model ?? ModelOrigin.catalog(ModelCatalog.single(lfm25), download: download),
      assistantName: 'Helper',
      welcome: 'Hi! I run on this device. Ask me the time, or to convert a temperature, a distance or a weight.',
      suggestions: const ['What time is it?', 'How much is 20 °C in Fahrenheit?', 'How many miles is 42 km?'],
      engine: engine,
      load: load,
      prefixStore: prefixStore,
    ),
  );
}
