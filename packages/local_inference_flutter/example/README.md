# flutter_chat: an on-device AI chat in one widget

A complete Flutter chat app for iOS and macOS, on one `LocalInferenceChat` widget. It has two tools, the time and unit
conversion (lib/toolkit.dart). On the first launch it offers a 1.2B model, downloads it once the user agrees, checks
it, and runs it on the device. From then on it answers offline.

![The kit's chat: tool calling, a confirmation before an action, and a custom theme](https://raw.githubusercontent.com/slimshadystark/local_inference/main/doc/hero.png)

*The widget this example uses, with other tools and a scripted model, drawn by [tool/screenshots](https://github.com/slimshadystark/local_inference/tree/main/packages/local_inference_flutter/tool/screenshots).*

## Run it

```sh
git clone https://github.com/slimshadystark/local_inference
cd local_inference/packages/local_inference_flutter/example
flutter pub get
flutter run -d macos                    # or on an iPhone: flutter run --release -d <device-id>
flutter test                            # the widget tests run on a scripted engine: no model, no download
```

- iOS: set your team and a bundle id of yours (Signing & Capabilities). The App ID needs the Increased Memory Limit
  capability. The model needs a phone with about 4 GB of RAM or more; the simulator runs it on the CPU.
- macOS: the app is sandboxed, with `com.apple.security.network.client` for the download. The model goes to the app's
  container (Application Support).

## How it works

The whole app is `lib/main.dart` and `lib/toolkit.dart`, about 160 lines. The model is a `ModelEntry` with its URL,
size and SHA-256; the download resumes after a dropped connection or a relaunch, and the file is checked before it is
used. The chat is one widget:

```dart
import 'package:flutter/material.dart';
import 'package:local_inference_flutter/local_inference_flutter.dart';

final lfm25 = ModelEntry(
  id: 'lfm2.5-1.2b-instruct-qad-q4_0',
  url: Uri.parse(
    'https://huggingface.co/LiquidAI/LFM2.5-1.2B-Instruct-GGUF/resolve/8ed288026e23958ad9dfa92d53ed773a8eee7125/'
    'LFM2.5-1.2B-Instruct-QAD-Q4_0.gguf',
  ),
  sizeBytes: 695755488,
  sha256: 'bb741ebb106d543e9de114b843a3d3d73d51c74b5801e69da2abde821a0cb3e1',
  displayName: 'LFM2.5 1.2B Instruct',
);

Widget chat(AssistantConfig config) => LocalInferenceChat(
  config: config, // the system prompt and the tools
  model: ModelOrigin.catalog(ModelCatalog.single(lfm25)),
  assistantName: 'Helper',
  welcome: 'Hi! I run on this device. Ask me the time, or to convert a temperature, a distance or a weight.',
  suggestions: const ['What time is it?', 'How much is 20 °C in Fahrenheit?'],
);
```

The widget brings the consent and download screens, the streaming chat, the tool-status lines and the AI disclosure.
It takes its colors from the app's theme; `lib/main.dart` also changes two of the kit's English texts and the bubble
radius (`LocalInferenceTheme(bubbleRadius: 20)`). local_inference_flutter's README, "Customizing", lists the rest:
texts, theme, builders for every part, or your own UI on the headless controllers.

## The model

LFM2.5-1.2B-Instruct, QAD Q4_0, 695,755,488 bytes, from Liquid AI's own Hugging Face repository,
[LiquidAI/LFM2.5-1.2B-Instruct-GGUF](https://huggingface.co/LiquidAI/LFM2.5-1.2B-Instruct-GGUF), at commit
`8ed288026e23958ad9dfa92d53ed773a8eee7125`. The size and the SHA-256 are the ones the repository lists.

Its license is the LFM Open License v1.0 (the repository's LICENSE file). Section 5 licenses commercial use only to a
legal entity whose annual revenue does not exceed USD 10 million. Check this before you ship the model in an app; the
example's code and the packages do not depend on this model.

For another model, `FlutterChatApp(model: ModelOrigin.file(path))` loads a GGUF file that is already on the device (a
sandboxed macOS app reads only its container and the files the user picked). `ModelOrigin.manifest(url)` offers the
models of a manifest (its format: local_inference's README, "Model manifest"). The tools need a model whose family
has a tool-call format that local_inference reads: Qwen3.5, or one of llamadart's formats with tool calls (LFM2,
Gemma 4, Llama 3.x, …).

## In your own app

```yaml
dependencies:
  flutter:
    sdk: flutter
  local_inference_flutter: ^0.1.0

hooks:
  user_defines:
    llamadart:
      llamadart_native_runtimes: [llama_cpp]
```

The hooks block goes in the app's own `pubspec.yaml`; without it, llamadart also bundles LiteRT-LM. Call
`LocalInferenceFlutter.installDownloaderStorage()` first in `main()`, as `lib/main.dart` does: a download that fails
then resumes after a relaunch.

`flutter create` does not write the host settings below; this example has them, and
`dart run local_inference_flutter:doctor --strict` checks them in your app (local_inference_flutter's README, "Host
setup"):

- iOS: deployment target 16.4; `Runner/Runner.entitlements` with `com.apple.developer.kernel.increased-memory-limit`;
  the "Native Assets Minimum iOS" Run Script phase after "Thin Binary", which runs `ios/scripts/native_assets_min_os.sh`
  (copied with `dart run local_inference_flutter:doctor --install-ios-script`), with
  `ENABLE_USER_SCRIPT_SANDBOXING = NO`; `UNUserNotificationCenter.current().delegate = self` in `AppDelegate.swift`;
  `NSPhotoLibraryUsageDescription` and `NSPhotoLibraryAddUsageDescription` in `Info.plist`; `Runner/PrivacyInfo.xcprivacy`
  with FileTimestamp C617.1, in the Runner target's resources.
- macOS: deployment target 14.0; `com.apple.security.network.client` in both entitlements files.
- The notices of the native libraries: nothing to set. local_inference_flutter registers them before `main()`, so a
  license page of the app (`showLicensePage`, `AboutDialog`) lists them (local_inference_flutter's README, "License
  and notices").
