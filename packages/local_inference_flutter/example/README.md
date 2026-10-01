# flutter_chat

A Flutter chat app on `local_inference_flutter`, for iOS and macOS. One `LocalInferenceChat` widget runs an assistant
with two toy tools (lib/toolkit.dart): the time on the device (`get_time`) and unit conversion (`convert_units`). The
model writes the replies from the tool results.

The first launch offers the model and downloads it after the user agrees: LFM2.5-1.2B-Instruct, QAD Q4_0, 695,755,488
bytes. The file comes from Liquid AI's own Hugging Face repository,
[LiquidAI/LFM2.5-1.2B-Instruct-GGUF](https://huggingface.co/LiquidAI/LFM2.5-1.2B-Instruct-GGUF), at commit
`8ed288026e23958ad9dfa92d53ed773a8eee7125`. Before it is used, it is checked against the size and the SHA-256
(`bb741ebb106d543e9de114b843a3d3d73d51c74b5801e69da2abde821a0cb3e1`) that the repository lists. The next launches
load the model without a download.

The model's license is the LFM Open License v1.0 (the repository's LICENSE file). Its section 5 licenses commercial
use only to a legal entity whose annual revenue does not exceed USD 10 million. Check this before you ship the model
in an app; the example's code and the packages do not depend on this model.

The example is an app of its own, not a member of the repository's workspace. It depends on the package by path (and
overrides local_inference with the repository's copy) and has its own hooks block (`llamadart_native_runtimes:
[llama_cpp]`, no native path), so llamadart's build hook downloads the llama.cpp bundles into the pub cache on the
first build. An app of your own lists the package from pub.dev, with the same hooks block (local_inference_flutter's
README, "Install"):

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

## Commands

```sh
flutter pub get                                    # in packages/local_inference_flutter/example
flutter run -d macos                               # or: flutter run --release -d <iphone-id>
flutter test                                       # on a scripted engine: no model, no download
dart run local_inference_flutter:doctor --strict   # the host setup check (--help lists the options)
```

- iOS: set your team and a bundle id of yours (Signing & Capabilities). The App ID needs the Increased Memory Limit
  capability. The model needs a phone with about 4 GB of RAM or more; the simulator runs it on the CPU.
- macOS: the app is sandboxed, with `com.apple.security.network.client` for the download. The model goes to the app's
  container (Application Support).

## What the host sets

`flutter create` does not write these; local_inference_flutter's README ("Host setup") asks for them, and the doctor
checks them:

- iOS: deployment target 16.4; `Runner/Runner.entitlements` with `com.apple.developer.kernel.increased-memory-limit`;
  the "Native Assets Minimum iOS" Run Script phase after "Thin Binary", which runs `ios/scripts/native_assets_min_os.sh`
  (copied with `dart run local_inference_flutter:doctor --install-ios-script`), with
  `ENABLE_USER_SCRIPT_SANDBOXING = NO`; `UNUserNotificationCenter.current().delegate = self` in `AppDelegate.swift`;
  `NSPhotoLibraryUsageDescription` and `NSPhotoLibraryAddUsageDescription` in `Info.plist`; `Runner/PrivacyInfo.xcprivacy`
  with FileTimestamp C617.1, in the Runner target's resources.
- macOS: deployment target 14.0; `com.apple.security.network.client` in both entitlements files.
- `main()`: `LocalInferenceFlutter.installDownloaderStorage(download:)` first.
- The notices of the native libraries: nothing to set. local_inference_flutter registers them before `main()`, so a
  license page of the app (`showLicensePage`, `AboutDialog`) lists them; the example has none (local_inference_flutter's
  README, "License and notices").

## Texts and look

`lib/main.dart` changes two of the kit's English texts (the consent text and the download hint, which speak of a file
of a few GB by default) and one look setting (`LocalInferenceTheme(bubbleRadius: 20)` in the app's theme).
local_inference_flutter's README, "Customizing", lists the rest.

## Another model

`FlutterChatApp(model: ModelOrigin.file(path))` loads a GGUF file that is already on the device (a sandboxed macOS app
reads only its container and the files the user picked). `ModelOrigin.manifest(url)` offers the models of a manifest
(its format: local_inference's README, "Model manifest").
The tools need a model whose family has a tool-call format that local_inference reads: Qwen3.5, or one of llamadart's
formats with tool calls (LFM2, Gemma 4, Llama 3.x, …).
