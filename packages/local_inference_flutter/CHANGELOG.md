# Changelog

## 0.1.1

Documentation and package page only: no API or behavior changes.

- The README opens with what the package does, a quick start (one widget, the hooks block, the doctor) and
  screenshots.
- The example's README (the Example tab) has the commands to run it and the code of the chat.
- A shorter description; the topics are `llm`, `ai`, `chat`, `agents` and `on-device`.

## 0.1.0

Initial release.

- Chat UI in three tiers: `LocalInferenceChat` (one widget that makes, starts and disposes the model manager, the
  assistant and the model setup), `ChatPage` and `ChatView` over an `AssistantController` and a
  `ModelSetupController` kept above the Navigator (`LocalInferenceScope`), and headless Listenable adapters.
- Model setup UI: consent with the download size, progress with pause, resume and cancel, the mobile-data prompt, the
  model picker and `ModelLibrary`.
- Customization: `LocalInferenceTheme` (a `ThemeExtension`), `LocalInferenceStrings` (Italian and English, with
  `LocalInferenceLocalizations.delegate`), `ChatFeatures`, `ChatBuilders` and `ModelSetupBuilders` (each builder can
  wrap the default widget), `ChatCallbacks` and `LocalInferenceKeys`.
- Compliance and accessibility: an AI disclosure, reply reports, an AI-generated semantics hint, live regions,
  screen-reader announcements, 48-point targets, text scaled up to 2.0 and right-to-left layout.
- Background model download on background_downloader (`BackgroundModelDownloader`): downloads that go on while the
  app is in the background, Wi-Fi only or on mobile data, resume after a failure or a relaunch
  (`RetainingResumeStorage`), the content checked before a download counts, and notifications in Italian or English.
- `LocalInferenceFlutter`: `installDownloaderStorage`, `createModelManager`, `createAssistantController`,
  `platformDefaults`, `platformLoadOptions` and `checkDeviceSupport`.
- A device plugin for iOS, macOS and Android: memory, free disk, a native SHA-256, the backup exclusion, the no-backup
  folder, the network type and a diagnostics snapshot (thermal state, battery, memory).
- `LifecyclePolicy`: what a running turn and the model do when the app leaves the foreground.
- The licenses of the bundled native libraries on the app's license page, registered before `main()` with no app code
  (`NativeLicenses`).
- `package:local_inference_flutter/testing.dart` re-exports local_inference's test doubles.
  `dart run local_inference_flutter:doctor` runs the host doctor; `--install-ios-script` adds the build-phase script
  that fixes ITMS-90208 for the llama.cpp framework.
- Flutter 3.44 or newer. iOS 16.4, macOS 14.0, Android minSdk 24 with API 28, arm64-v8a and a 64-bit process checked
  at run time (not run on an Android device yet). Linux and Windows get the license notices only.
