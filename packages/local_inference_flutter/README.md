# local_inference_flutter

[![pub package](https://img.shields.io/pub/v/local_inference_flutter.svg)](https://pub.dev/packages/local_inference_flutter)
[![pub points](https://img.shields.io/pub/points/local_inference_flutter)](https://pub.dev/packages/local_inference_flutter/score)
[![CI](https://github.com/slimshadystark/local_inference/actions/workflows/ci.yml/badge.svg)](https://github.com/slimshadystark/local_inference/actions/workflows/ci.yml)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](https://github.com/slimshadystark/local_inference/blob/main/LICENSE)

**On-device AI chat and agents for Flutter.** Drop in a chat that runs an LLM on the phone: replies stream in, the
model calls your tools on its own, and it asks before it does anything that matters. Or build your own UI on the
same controllers. Offline, private, no API key.

![Tool calling, a confirmation before an action, and a custom theme](https://raw.githubusercontent.com/slimshadystark/local_inference/main/doc/hero.png)

*The kit's own widgets with a scripted model, drawn by [tool/screenshots](https://github.com/slimshadystark/local_inference/tree/main/packages/local_inference_flutter/tool/screenshots).*

## Why local_inference_flutter

- **A whole chat in one widget.** `LocalInferenceChat` asks before downloading the model, downloads it in the
  background, checks it, loads it and chats. Restyle it with a theme extension, translate it, or replace any piece
  with a builder.
- **Agents with your tools.** Declare a tool in a few lines; the model calls it, the UI shows what it is doing, and
  tools that change something wait for the user's yes.
- **Downloads that survive real life.** Background downloads on iOS and Android that resume after the app is killed,
  Wi-Fi-only by default, SHA-256 verification, and checks that the phone has the memory and the disk.
- **Ready for the stores.** An AI-disclosure banner and "report this reply" (the EU AI Act, Google Play's AI
  policy), screen-reader announcements, 48-point targets, text scaling and right-to-left layouts.
- **Measured on phones.** A fine-tuned Qwen3.5 2B streams 12-20 tokens per second on an iPhone 16 Pro Max, and a
  tool-calling turn takes 1-3 seconds.
- **Your architecture.** One widget, pages over controllers you keep, or headless Listenables for Riverpod, BLoC or
  anything else. Built on [local_inference](https://pub.dev/packages/local_inference) (pure Dart), re-exported.
- **A doctor for your host.** `dart run local_inference_flutter:doctor` checks the iOS, Android and macOS settings an
  on-device model needs and says how to fix each.

## Quick start

1. `flutter pub add local_inference_flutter`
2. Add llamadart's hooks block to your app's `pubspec.yaml` (it keeps a second runtime out of the app):

   ```yaml
   hooks:
     user_defines:
       llamadart:
         llamadart_native_runtimes: [llama_cpp]
   ```
3. Put a chat on screen: a weather tool, a model manifest, one widget.

```dart
import 'package:flutter/material.dart';
import 'package:local_inference_flutter/local_inference_flutter.dart';

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
```

4. Run `dart run local_inference_flutter:doctor --strict` and follow its fixes (iOS 16.4, the memory entitlement, …);
   "Host setup" below lists them.

The package's `example/` folder is a complete app with two tools that downloads LFM2.5-1.2B (696 MB) from Hugging Face:
`flutter run` in `example/` on an iPhone, an Android phone or a Mac.

## Install

```sh
flutter pub add local_inference_flutter
```

Then put llamadart's hooks block in the app's pubspec, and run `flutter clean`:

```yaml
# llamadart's build hook reads this block from the app's pubspec only (a workspace's root pubspec).
hooks:
  user_defines:
    llamadart:
      llamadart_native_runtimes: [llama_cpp]   # without it the app also bundles LiteRT-LM (+35 MB Android, +43 MB iOS)
```

- Optional: `llamadart_native_path` in the same block, for vendored and checked native bundles (local_inference's
  README, "Vendored natives").
- Then call `await LocalInferenceFlutter.installDownloaderStorage()` first in `main()`, set the host settings of "Host
  setup" below, and run `dart run local_inference_flutter:doctor --strict` in the app. When the app's model downloads
  use a `BackgroundDownloadConfig` of their own (`createModelManager(download:)`, `ModelOrigin.manifest(url,
  download:)`), pass the same config: `installDownloaderStorage(download: config)`. `LocalInferenceChat` with no
  `download:` uses the default config, which the call without arguments matches.

## Choose your layer

| Tier | What you get | Start with | Section |
|---|---|---|---|
| 1. One widget | the model setup, the assistant and the chat, made, started and disposed by one widget | `LocalInferenceChat(config:, model:)` | [One widget](#1-one-widget) |
| 2. Pages over your controllers | `ChatPage` (a Scaffold) or `ChatView` (a tab, a panel) over controllers kept above the Navigator; the model list and picker | `AssistantController`, `ModelSetupController`, `LocalInferenceScope` | [Pages over your own controllers](#2-pages-over-your-own-controllers) |
| 3. Headless | Listenables for a UI of your own; the core `Assistant.states` stream for Riverpod or BLoC | `AssistantController` | [Headless](#3-headless) |
| Model download alone | the platform's model manager, background download, the device probe | `LocalInferenceFlutter.createModelManager` | [Model download](#model-download) |
| Model layer only | `ChatModel` (L2) or the engine (L1) in an app, with the device's load options and a prefix store in the caches folder | `final (load, store) = await LocalInferenceFlutter.platformDefaults();` then `ChatModel.load(path, options: load, prefixStore: store)` | local_inference's README, "Model layer (L2)"; here, "When the app leaves the foreground" |

Every tier runs an `Assistant` of local_inference (L3) configured by an `AssistantConfig`: its tools, prompt, replies
and questions. local_inference's README describes the layers below it (the engine L1, `ChatModel` L2) and model
delivery. A domain preset, a package that exports the `AssistantConfig` of one app domain, plugs into every tier.

## Compatibility

| | Version | Notes |
|---|---|---|
| Flutter | 3.44 or newer (Dart 3.12 or newer) | tested on Flutter 3.47.2 and 3.44.8 |
| background_downloader | `>=9.5.9 <9.7.0`: pub picks 9.5.9 on Flutter 3.44 to 3.46, 9.6.x on 3.47 and newer | on 9.5.9 the Android Wi-Fi-only rule is kept in Dart, so only while the app runs ("Host setup") |
| local_inference | `^0.1.0` | llamadart 0.8.23, llama.cpp v0.4.0, dinja 1.0.x |

| Platform | Floor | State on 2026-09-30 |
|---|---|---|
| iOS | 16.4 (the plugin's and llamadart's floor); Swift Package Manager or CocoaPods | a release build passes; an iPhone 16 Pro Max runs the engine and the chat |
| macOS | 14.0 | runs (Apple M1 Pro); the example builds |
| Android | the plugin declares minSdk 24; `checkDeviceSupport()` requires API 28, arm64-v8a and a 64-bit process before any download | a release APK builds; nothing has run on an Android device yet |
| Linux, Windows | the plugin declares its Dart class only, for the native libraries' notices ("License and notices") | its channel calls fall back to Dart defaults (`MissingPluginException`); not tested |
| Web | none | not supported: local_inference uses dart:io |

A consumer app passes `flutter test` and the macOS and iOS debug builds on Flutter 3.47.2 and 3.44.8, with no
LiteRT-LM library in the apps. The model families and their measured speed are in local_inference's README,
"Compatibility".

## Performance and memory

Measured figures, each with its device and conditions (local_inference's README, "Performance and memory", has the
rest).

| What | Figure | Where and how |
|---|---|---|
| A fine-tuned Qwen3.5 4B, Q5_K_M (3.07 GB), iPhone 16 Pro Max | a tool-call turn 1.7-3.1 s after the prefix restore; first token 296-320 ms; decode 7.7-12.2 tok/s | iOS 26.6.1, Release build with the increased-memory-limit entitlement, micro-batch 128 |
| A fine-tuned Qwen3.5 2B, Q5_K_M (1.45 GB), same phone | a turn 1.0-2.0 s, hot and charging | the same build |
| GPU memory of the 4B, same phone | 3,321 MB after load, of a 5,461 MB Metal working set | Metal's allocation read after the load |
| First prefix build (14 tools, 2,054 tokens) | once per model install; 120 MB in the caches folder (4B). 12.1 s with the load on the Mac; not measured on an iPhone yet: an estimate from the measured prefill rate gives about 16-21 s on a cool phone and about 40 s on a hot one | M1 Pro; meanwhile the chat says it happens only the first time with this model |
| Heat | the iPhone reached "serious" within about three minutes of back-to-back turns, then ran at about half speed | iPhone 16 Pro Max |
| App size | an app on the kit, without models: iOS 32.9 MB, macOS 73.7 MB, Android APK (arm64 release) 80.6 MB | release builds, 2026-09-30 |
| Download | one file per model, 3.07 GB for a 4B Q5_K_M (a 2B Q5_K_M is 1.45 GB); on iOS the resource timeout is 24 hours (4 hours would stop below about 1.7 Mbit/s) | `BackgroundDownloadConfig.iosResourceTimeout` |
| Storage | models in Application Support (iOS, macOS) or `noBackupFilesDir` (Android), excluded from backups; up to 3 prefix states in the caches folder | this package's paths |

## Host setup

What a plugin cannot do for the app. The doctor checks most of it and says how to fix each finding:

```sh
dart run local_inference_flutter:doctor --strict                  # in the app folder; exit status 1 on a warning or error
dart run local_inference_flutter:doctor --install-ios-script      # copies the ITMS-90208 script to ios/scripts/
dart run local_inference_flutter:doctor --json --verify-natives   # for CI: JSON, and the natives against the manifest
```

local_inference's README, "Doctor", lists every check, the JSON format, and what to do when `dart run` cannot start
the doctor. The doctor does not check these; check them by hand: `installDownloaderStorage()` first in `main()`, the
`bg_downloader_*` strings, the backup rules, and that nothing else cleans `<models>/.partial` or `<models>/.resume`.
The notices of the native libraries need no code, only a license page users can open, as the Dart packages' licenses
do ("License and notices").

- All hosts: llamadart's hooks block in the **app** pubspec (the workspace root for a workspace),
  `hooks: user_defines: llamadart: llamadart_native_runtimes: [llama_cpp]`, then `flutter clean`; call
  `await LocalInferenceFlutter.installDownloaderStorage(download: config)` first in `main()`, right after
  `WidgetsFlutterBinding.ensureInitialized()` and before anything calls `FileDownloader()` (a host that creates
  FileDownloader itself passes it `RetainingResumeStorage()` on that first call instead, then calls
  `BackgroundModelDownloader.holdUpdates(config.group)`).
- The model downloader configures background_downloader for the whole app: the free space it checks, and on Android
  no cache folder, the temporary folder `<models>/.partial` and the foreground setting (never, unless opted in); on
  iOS the resource timeout, no iCloud backup and the words of the notification actions. A host that runs its own
  background_downloader tasks sets `BackgroundDownloadConfig(configureFileDownloader: false)` and configures
  FileDownloader itself.
- iOS:
  - deployment target 16.4 (Runner and Podfile) and the `com.apple.developer.kernel.increased-memory-limit`
    entitlement; a signed build also needs the Increased Memory Limit capability on the App ID, and so in its
    provisioning profile (Signing & Capabilities);
  - a Run Script phase after "Thin Binary" running a copy of `tool/ios/native_assets_min_os.sh` (ITMS-90208), with
    `ENABLE_USER_SCRIPT_SANDBOXING = NO`;
  - `UNUserNotificationCenter.current().delegate = self` in the AppDelegate (download notifications);
  - `NSPhotoLibraryUsageDescription` and `NSPhotoLibraryAddUsageDescription` in Info.plist, which background_downloader
    needs for an App Store upload, or `BYPASS_PERMISSION_IOSADDTOPHOTOLIBRARY=1` and
    `BYPASS_PERMISSION_IOSCHANGEPHOTOLIBRARY=1` in every build environment (Swift Package Manager builds; a CocoaPods
    build passes `-D BYPASS_PERMISSION_...` in the Podfile's `OTHER_SWIFT_FLAGS` instead, as background_downloader's
    doc/permissions.md shows);
  - FileTimestamp C617.1 in the app's privacy manifest.
- Android:
  - the plugin merges INTERNET, POST_NOTIFICATIONS and RUN_USER_INITIATED_JOBS. Keep the last one: from Android 14,
    with notifications allowed, a download runs as a user-initiated job, which without it would become an expedited
    job that Android stops after 2 minutes;
  - minSdk 28 is recommended (below it `checkDeviceSupport()` refuses before any download), with `abiFilters
    arm64-v8a` (plus `x86_64` for emulators);
  - the words of the download notification's buttons and channel are string resources of the host:
    `bg_downloader_cancel`, `bg_downloader_pause`, `bg_downloader_resume`, `bg_downloader_notification_channel_name`
    and `bg_downloader_notification_channel_description`. background_downloader's own are English; this plugin ships
    none. An app in Italian puts them in `android/app/src/main/res/values/strings.xml` (an app in several languages:
    one `values-<language>/` folder each):

    ```xml
    <resources>
        <string name="bg_downloader_cancel">Annulla</string>
        <string name="bg_downloader_pause">Pausa</string>
        <string name="bg_downloader_resume">Riprendi</string>
        <string name="bg_downloader_notification_channel_name">Download</string>
        <string name="bg_downloader_notification_channel_description">Avanzamento del download del modello</string>
    </resources>
    ```

  - a foreground-service download is opt-in (`AndroidForeground`). WorkManager already merges FOREGROUND_SERVICE and
    the `androidx.work.impl.foreground.SystemForegroundService` entry; a host that opts in adds
    FOREGROUND_SERVICE_DATA_SYNC, `android:foregroundServiceType="dataSync"` on that entry (`tools:node="merge"`) and
    the Play Console declaration;
  - models go to the no-backup folder. Where they stay in Application Support (an install from before the packages,
    or no plugin), the host's backup rules must leave out `models/`;
  - Wi-Fi-only is best effort on background_downloader 9.5.9 (Flutter 3.44 to 3.46), which would run a Wi-Fi-only
    task on any unmetered network: the downloader holds such a task back off Wi-Fi and pauses it when the connection
    leaves Wi-Fi, but only while the app runs (in the background the unmetered rule applies). The connection reading
    needs ACCESS_NETWORK_STATE, which WorkManager merges;
  - partial downloads live in `<models>/.partial` and the kept resume data of failed ones in `<models>/.resume`; both
    are cleaned by the downloader, so leave them out of any cleanup of your own;
  - nothing has run on an Android device yet.
- macOS: deployment target 14.0; `com.apple.security.network.client` when sandboxed. A sandboxed app reads a model
  file only in its container (the models the manager downloads are there) or one the user picked
  (`com.apple.security.files.user-selected.read-only`).

## Testing your assistant

`flutter_test` stays your dev dependency; the package ships no widget-test helpers.
`package:local_inference_flutter/testing.dart` re-exports local_inference's test doubles (`ScriptedEngine`,
`ScriptedTurn`, `scriptedAssistant`, `InMemoryPrefixStateStore`, …), so a test needs no other dependency. A widget
test gives `LocalInferenceChat` a scripted engine (no llama.cpp in a test) and a prefix store in memory
(path_provider has no folders in a test: without it the chat cannot start), and lets the assistant's work go on
with a helper like `pumpUntil`. The kit itself (`scriptedAssistant` for an assistant without a UI, `TestToolkit`, the
delivery fakes) is described in local_inference's README, "Testing your assistant".

```dart
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_inference_flutter/local_inference_flutter.dart';
import 'package:local_inference_flutter/testing.dart';

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
}

/// Lets the assistant and real I/O go on: short real waits and frames, until [done].
Future<void> pumpUntil(WidgetTester tester, bool Function() done, {int maxSteps = 300}) async {
  for (var i = 0; i < maxSteps && !done(); i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    await tester.pump();
  }
  expect(done(), isTrue);
}
```

**Hooks in library packages.** `flutter test` runs llamadart's build hook even when the tests only use
`ScriptedEngine`, and a package is the root package while it runs its own tests. So a library that depends on this
package (a feature package of a larger app, say) needs the hooks block in its own pubspec too, or its tests download
LiteRT-LM. The block is ignored when an app depends on the library: the app's own block counts. In CI, cache the pub
cache (llamadart keeps the bundle it downloads there) or vendor the natives with `llamadart_native_path`
(local_inference's README, "Vendored natives").

## Chat UI

A chat on an `Assistant` of local_inference (its tools, prompt, replies and questions come from the
`AssistantConfig`), in three tiers. `test/readme_examples_test.dart` holds the examples of this file and runs them (in
an app, `oneWidget` and `pagesOverControllers` are `main`); the second and third continue the first.

### 1. One widget

`LocalInferenceChat(config:, model:)` makes the model manager, the assistant and the model setup, starts them, and
disposes them when it goes. The first launch asks before downloading (size, device fit), shows the download, then
loads the model by itself. `model` is `ModelOrigin.manifest(url)` (a manifest you publish: its format is in
local_inference's README, "Model manifest"), `ModelOrigin.catalog(catalog)` or `ModelOrigin.file(path)`; it is read
once (for another model, give the widget a new key). A new `config` reaches the assistant after the turn under way.

The example is the quick start's, at the top of this page.


- **Languages.** The UI kit's texts follow the app's locale: Italian for `it`, English for any other
  (`LocalInferenceLocalizations.delegate` adds them to the app's localizations; `LocalInferenceScope(strings:)`
  fixes them). Material's own words, such as the selection menu's Copy, come from `flutter_localizations`
  (`GlobalMaterialLocalizations.delegates`) in an app that is not in English. What the assistant says (replies,
  questions, its Yes and No) comes from the `AssistantConfig` and is never translated by the UI: an Italian chat
  passes `AssistantConfig.basic(..., strings: AssistantStrings.italian, contextLine: ContextLines.italian)`.
- **When it fails.** A panel names the kind of failure ("the model could not be loaded"), with "Try again". The
  cause is `AssistantController.assistant.state.loadError` (and `PhaseChangedEvent.error`); debug builds print it,
  and `ChatFeatures(showDetails: true)` shows it under the panel.
- **A model file on macOS.** A sandboxed macOS app (the default of `flutter create`) reads only its own container
  and the files the user picked: keep the model in Application Support, let the user pick it
  (`com.apple.security.files.user-selected.read-only`), or turn the sandbox off while developing. A model outside
  the container fails to load with "Model file does not appear to be GGUF … Please verify the download completed
  correctly": the file is fine, the sandbox refused it.

### 2. Pages over your own controllers

`ChatPage` (a Scaffold with the title and the new-conversation button) and `ChatView` (no Scaffold: a tab, a panel,
a split view) over an `AssistantController` and a `ModelSetupController` the app keeps above its Navigator, in a
`LocalInferenceScope`: the chat survives pages pushed on top and a page closed and opened again (the messages and the
draft stay). A provider may hold the controllers and pass them to the pages (`controller:`, `setup:`); keep a
`LocalInferenceScope(assistant: controller, child: …)` above them all the same, since the scope applies the lifecycle
policy ("When the app leaves the foreground"). `ModelSetupView`, `ModelLibrary` (a settings page's model list, or
`ModelLibrary.forAssistant`) and `showModelPicker` work on their own too. The bundled manifest of the example below is
an asset: list it under `flutter: assets:` in the app's pubspec (its format: local_inference's README, "Model
manifest").

<!-- snippet: continues -->
```dart
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_inference_flutter/local_inference_flutter.dart';

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
```

- **Model files of your own.** A model file the app has (bundled, or found on the device) is a candidate of the
  setup, loaded at start, with or without a model manager:
  `ModelSetupController(assistant: assistant, candidates: (installed) => [ModelCandidate(path: file), ...installed.map(ModelCandidate.installed)])`.
  With `autoLoad: false`, or after `unloadModel()`, the chat offers "Load" (`SetupStage.modelAvailable`).
- **Screens.** A reply may ask for a screen (`AssistantConfig.screenRequests`): `onScreenRequest` opens it 600 ms
  after the reply, once the turn ended, only while the chat is the visible page (`ScreenRequestPolicy`: the delay,
  `whenHidden: drop | deferUntilVisible`, `isVisible` for a tab host, asked again whenever the chat rebuilds), and
  again from the reply's chip, unless the list item it named changed meanwhile (`onStaleScreenRequest`, default a
  SnackBar). Without it, no chip shows.
- **Scrolling.** The list is lazy and follows new text only while it is at the bottom (48 points,
  `ChatScrollController(stickThreshold:)`; `double.infinity` always follows); reading further up, nothing moves and
  a button jumps to the newest message. Sending a message or answering a question goes back to the newest message.
  A new conversation opens at its newest message.
- **Compliance.** The AI disclosure (EU AI Act, art. 50(1)): `ChatFeatures.aiDisclosure` = `banner` (default),
  `dismissible` (`onDisclosureDismissed`), `inWelcome` or `none`. With `onReport`, a reply can be reported from its
  selection menu or a flag button (`reportAffordance`; the flag when the text cannot be selected); the
  `ReportRequest` carries the reason, the comment, the reply, the user's text of its turn, the conversation id, the
  model file, the template SHA-256, the runtime and the time (`toJson()`). Model-written replies carry a semantics
  hint (`ProvenanceMarking`; a builder that draws a reply's text itself uses `MessageContext.provenanceHint`),
  optionally a badge and a notice on copied text.
- **Accessibility.** Live regions for "Thinking…" and the tool status (emoji are not read), the finished reply read
  aloud when a screen reader is on, tooltips (`ChatFeatures.tooltips`; the labels stay without them), 48-point tap
  targets, text scaled to 2.0 (on a small phone the disclosure and the suggestions then scroll within their part of
  the height, so the messages keep theirs), directional layout (right to left).

### 3. Headless

The adapters alone, for a UI of your own: `AssistantController.itemIds` changes only when messages come or go,
`item(id)` only when that message changes (while a reply streams, only its own item fires), `composer`,
`pendingActions`, `phase`, `draft`, `events` and `analytics` (usage events that never carry what was written).
Riverpod or BLoC hosts can also use the core `Assistant.states` stream. Put a `LocalInferenceScope(assistant: chat,
child: …)` above such a UI too (every other parameter is optional): it applies the lifecycle policy ("When the app
leaves the foreground").

<!-- snippet: continues -->
```dart
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
```

### Customizing

Precedence, for the look, the texts and the switches: **a widget's own parameter, then `LocalInferenceScope`, then
the app theme's `LocalInferenceTheme` extension and `LocalInferenceLocalizations.delegate`, then the defaults.**

- **Look.** `LocalInferenceTheme` (a `ThemeExtension`, every field optional) resolves into `LocalInferenceStyle` from
  the app's `ColorScheme` and `TextTheme`, so light and dark need no value: accent and user bubbles `primary`, text
  `onSurface`, secondary text `onSurfaceVariant`, and the default shapes (bubble radius 14, composer 24, cards 16;
  user bubbles up to 0.78 and replies up to 0.9 of the list's width). Every progress bar and spinner gets its colors
  explicitly (`progress`, `progressTrack`, and `panelProgressTrack` for the status panels), so an app-wide white
  `progressIndicatorTheme` cannot hide them.
- **Texts.** `LocalInferenceStrings` holds `chat`, `setup` (`ModelSetupStrings`), `a11y` and `formats`, in `.italian`
  and `.english`, with `copyWith` and `forLocale`; `LocalInferenceScope(stringsOverride:)` changes the texts chosen
  for the locale. Conversation text (replies, questions, Yes and No, tool labels) comes from the `AssistantConfig` and
  is never translated by the UI.
- **Parts.** `ChatBuilders` (header, welcome, userMessage, assistantMessage, messageText, thinking, toolStatus,
  screenChip, footer, details, suggestions, confirmation, composer, statusPanel, noModel, disclosure, jumpToLatest,
  setup) and `ModelSetupBuilders` (consent, progress, noneOffered, catalogUnavailable, tile, confirmDialog): each
  builder gets a context whose `buildDefault()` returns the package's widget, to wrap or decorate. The welcome row
  is drawn by `welcome`, not `assistantMessage`; the default `composer` includes the divider above it; `statusPanel`
  also draws the model setup's panels inside the chat.
- **Switches.** `ChatFeatures`: details, suggestions, confirmation buttons, chips, the disclosure, reports,
  provenance, selectable text, copy, the new-conversation and stop buttons, jump-to-latest, auto-scroll,
  announcements, tooltips, haptics, the composer's lines and length, the keyboard's send key and Enter on a desktop.
- **UI callbacks.** `ChatCallbacks`: `onScreenRequest`, `onStaleScreenRequest`, `onLinkTap` (http(s) links become
  tappable), `onReport`, `onCopy`, `beforeSend`, `onDisclosureDismissed`. Turns, phases, models and conversations come
  from `AssistantController.events`, and analytics from `AssistantController.analytics` and
  `ModelSetupController.analytics`, whether a chat is on screen or not.
- **Keys.** `LocalInferenceKeys` names the widgets for tests: `composerField`, `sendButton`, `message(id)`,
  `confirmAction(kind)`, `screenChip(id)`, `reportAction(id)`, `loadModel`, `setupDownload`, `libraryTile(id)`, …

### When the app leaves the foreground

`LocalInferenceScope(lifecycle:)` applies a `LifecyclePolicy`. The defaults:
- **`cancelTurnOnBackground: false`**: a turn running when the app goes to the background goes on. The system
  suspends the app, and the reply continues when the app comes back. On an iPhone 16 Pro Max with iOS 27, 20 s at the
  Home screen or with the phone locked, during a reply and during the first prefix build, paused the reply and then
  finished it (checked on 2026-10-01). iOS forbids GPU work in the
  background, so a host that sees turns fail there sets it to `true`: the turn then stops when the app is paused and
  keeps its text so far, while a minimized desktop window keeps its turn.
- **`retryPrefixOnResume: true`**: a model whose load failed while the app was away loads again on return.
- **`unloadOnMemoryPressure: false`**.

`LifecyclePolicy.none` turns all of them off.

Only `LocalInferenceScope` applies the policy; `LocalInferenceChat` makes its own scope. A host without one (the
controllers in a provider, a headless UI) wraps its UI in `LocalInferenceScope(assistant: controller, child: …)`, or
calls `controller.stop()` itself when the app is paused. A host on `ChatModel` or the engine cancels its
`ChatGeneration` or `Generation` there (an `AppLifecycleListener(onPause: …)`, for example); nothing in the packages
does it for them.

## Model download

`LocalInferenceFlutter.createModelManager` wires local_inference's `ModelManager` for the platform: models in
Application Support on iOS and macOS (Android's no-backup folder on Android), the plugin's probe (memory, free disk,
a native SHA-256, the backup flag), and background_downloader on phones (a foreground download on desktop). The
manager reports codes; `ModelSetupStrings` and `LocalizedFormats` say them. The catalog below is a manifest bundled as
an asset (listed under `flutter: assets:` in the app's pubspec) and published at a URL; local_inference's README,
"Model manifest", has its format.

```dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_inference_flutter/local_inference_flutter.dart';

const download = BackgroundDownloadConfig(group: 'my_app_models', appName: 'Assistant');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await LocalInferenceFlutter.installDownloaderStorage(download: download);
  final models = await LocalInferenceFlutter.createModelManager(
    catalog: ModelCatalog.bundled(
      () => rootBundle.loadString('assets/models/manifest.json'),
      remote: Uri.parse('https://example.org/models/manifest.json'),
    ),
    download: download,
  );
  runApp(MaterialApp(home: ModelsPage(models: models)));
  await models.init();
}

class ModelsPage extends StatelessWidget {
  const ModelsPage({super.key, required this.models});

  final ModelManager models;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: ListenableBuilder(
      listenable: ChangeSourceListenable(models),
      builder: (context, _) => ListView(
        children: [
          if (models.isReady)
            for (final entry in models.entries)
              ListTile(
                title: Text(entry.displayName),
                subtitle: Text(describe(entry)),
                onTap: () => models.download(entry.id),
              ),
        ],
      ),
    ),
  );

  String describe(ModelEntry entry) {
    const strings = ModelSetupStrings.english;
    const formats = LocalizedFormats.english;
    final problem = models.problemFor(entry);
    if (problem != null) return strings.problem(problem, formats);
    final status = models.statusOf(entry.id);
    final error = status.error;
    return switch (status.state) {
      ModelState.downloading => strings.tileDownloading(formats.percent(status.progress)),
      ModelState.failed when error != null => strings.error(error),
      ModelState.ready => strings.tileReady,
      _ => formats.bytes(entry.sizeBytes),
    };
  }
}
```

- `installDownloaderStorage(download:)` makes `RetainingResumeStorage` background_downloader's storage: a failed
  download keeps its resume data, and a retry resumes it, also after a relaunch. It must be the app's first
  `FileDownloader()` call; after one made elsewhere a retry starts from byte 0. It also holds the updates of the
  config's group that arrive before the manager's downloader sets up (a launch in the background to finish a
  download), so pass it the config `createModelManager` gets, and create and `init()` the manager at launch: what
  arrives before that is held in memory only.
- A finished download is checked before it counts: a web page, an answer other than 200 or 206, or a GGUF file
  without the GGUF magic fails (`BackgroundDownloadConfig.verifyContent`).
- `ModelManagerWatcher` gives `ValueListenable`s of `ready`, `installed` and each model's `status`.
- `LocalInferenceDevice` answers the platform, memory, the no-backup folder, the connection (`network()`) and a
  `diagnostics()` snapshot; `checkDeviceSupport()` applies the Android floor (API 28, arm64-v8a, 64-bit) before any
  download.
- `platformLoadOptions()` gives the engine's load options for the device (the CPU in a simulator).

## License and notices

- local_inference_flutter is released under the MIT License (`LICENSE`). `NOTICE` lists the third-party software this
  package depends on, the native libraries apps bundle and the models the documentation names, each with its license.
- The app bundles the native libraries llamadart's hook puts in it (llama.cpp and ggml, and the others of NOTICE,
  section 2), whose licenses ask for their notices in every copy. Flutter's license page (`showLicensePage`,
  `AboutDialog`, `AboutListTile`) lists them next to the Dart packages with no code in the app: Flutter's generated
  plugin registrant calls `NativeLicenses.registerWith()` before `main()` on every platform the plugin declares (on
  Linux and Windows it declares that Dart class only), which adds one `LicenseEntry` per component of
  local_inference's `NATIVE_LICENSES.txt` (its section, verbatim) under the component's names. Registered before the
  app's own code runs, they come first: the page keeps `llama.cpp`, the first package it reads, at the top of its
  list, and sorts the rest.
- Users see them only on a license page the app opens: give them a way to it (a settings entry with `AboutListTile`,
  an about dialog), as the licenses of the Dart packages need anyway. The example has none.
- `NativeLicenses.entries` gives the same entries to a notices screen of your own. A widget test calls
  `NativeLicenses.register()` itself (a second call adds nothing), since Flutter's test binding registers no licenses
  and runs no plugin registrant.
- What stays the host's: the notices of its other dependencies that are not Dart packages (Flutter collects the
  LICENSE files of those): native code of its own, and on Android the Java and Kotlin libraries of the plugins, which
  the page does not list in any Flutter app (NOTICE, section 2, names background_downloader's).
- A pure-Dart host (a server, a tool built with `dart build cli`) has no license page: it ships `NATIVE_LICENSES.txt`
  next to `bundle/` (local_inference's README, "License and notices").
- A model has its own license (NOTICE, section 3), which applies to the app that downloads or ships it.
