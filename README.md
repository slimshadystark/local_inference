# local_inference

Run a language model on the device, in Dart and Flutter, with tool calling and a ready chat UI. The models are GGUF
files, run by [llama.cpp](https://github.com/ggml-org/llama.cpp) through
[llamadart](https://pub.dev/packages/llamadart); nothing leaves the device.

| Package | What it is | |
|---|---|---|
| [local_inference](packages/local_inference) | Pure Dart: the engine, chat templates and tool calls of several model families, a grammar for tool calls, an assistant loop with your tools, model download and verification, a testing kit and a host doctor. Runs in Flutter apps and on servers. | [![pub](https://img.shields.io/pub/v/local_inference.svg)](https://pub.dev/packages/local_inference) |
| [local_inference_flutter](packages/local_inference_flutter) | Flutter: a customizable chat UI (one widget, pages, or headless controllers), model setup and library screens, background downloads on iOS and Android, device checks. | [![pub](https://img.shields.io/pub/v/local_inference_flutter.svg)](https://pub.dev/packages/local_inference_flutter) |

## Getting started

```sh
flutter pub add local_inference_flutter   # a Flutter app
dart pub add local_inference              # a pure-Dart app or server
```

Then add this block to your **app's** `pubspec.yaml` (llamadart reads it from the app only); without it llamadart also
bundles a second runtime you do not need:

```yaml
hooks:
  user_defines:
    llamadart:
      llamadart_native_runtimes: [llama_cpp]
```

Each package's README covers the layers, the host setup (iOS, Android, macOS), the supported model families and
their measured speed, and testing. `dart run local_inference:doctor` (or `local_inference_flutter:doctor`) checks a
host's setup and says how to fix what is missing.

The examples are in each package's `example/` folder: a terminal chat (pure Dart) and a Flutter chat app with two
small tools.

## Development

This repository is a pub workspace. With Flutter 3.47 or newer:

```sh
flutter pub get
(cd packages/local_inference && dart test)
(cd packages/local_inference_flutter && flutter test)
dart run tool/ci/snippets.dart      # every Dart block of the READMEs compiles
```

## License

MIT, see [LICENSE](LICENSE). The packages bundle or download third-party software under their own licenses (llama.cpp
and ggml, llamadart, and others): see each package's `NOTICE` and `NATIVE_LICENSES.txt`. Model files are not part
of this repository; each model has its own license.
