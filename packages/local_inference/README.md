# local_inference

On-device LLM inference for Dart and Flutter, in pure Dart: the llama.cpp engine (through llamadart), chat templates,
tool calling with GBNF grammars, a tool-using assistant, a prefix-state cache and verified model delivery.

- `local_inference` (this package, pure Dart): the engine, the model layer, the assistant, model delivery, the testing
  kit and the host doctor.
- [local_inference_flutter](https://pub.dev/packages/local_inference_flutter): the Flutter layer (a chat UI, the model
  setup, background download, a device plugin). It re-exports this package, so a Flutter app depends on it alone.

The package's `example/` folder holds a terminal chat in pure Dart with two tools.

## Install

```sh
dart pub add local_inference
```

Then put llamadart's hooks block in the pubspec of your app (the root package):

```yaml
# llamadart's build hook reads this block from the root package only: the app, or the workspace root.
hooks:
  user_defines:
    llamadart:
      llamadart_native_runtimes: [llama_cpp]   # without it the hook also downloads and bundles LiteRT-LM
```

- **The hooks block** belongs to the root package. A library's block counts only for the library's own tests
  ("Testing your assistant"). Without `llamadart_native_runtimes: [llama_cpp]` the hook also takes LiteRT-LM: 35 MB
  more on Android, 43 MB more on iOS, and a 138 MB `litert_lm` folder in llamadart's pub-cache folder. After changing
  the block, run `flutter clean` (a Flutter app) or delete `.dart_tool/hooks_runner`.
- **Natives.** At the first `dart run`, `dart test` or build, the hook downloads this computer's llama.cpp bundle
  (leehack/llamadart-native v0.4.0) from GitHub into llamadart's folder in the pub cache, and checks no checksum.
  `llamadart_native_path` points it at a vendored copy that was checked instead ("Vendored natives" below). The pub
  cache must be writable.
- Then check the host: `dart run local_inference:doctor --strict` ("Host setup").

## Choose your layer

| Layer | In and out | Start with | Section |
|---|---|---|---|
| L1 engine | a prompt already in the model's chat layout in, text out | `LlamadartEngine` (an `InferenceEngine`) | [Engine (L1)](#engine-l1) |
| L2 model | messages and tools in; visible text and typed tool calls out; a saved prompt prefix | `ChatModel.load` | [Model layer (L2)](#model-layer-l2) |
| L3 assistant | a conversation: calls run, a question before an irreversible one, numbered lists, saved conversations | `Assistant(AssistantConfig)` | [Assistant (L3)](#assistant-l3) |
| Model delivery | a catalog of models, downloaded, checked (size, SHA-256) and kept | `ModelManager` | [Model delivery](#model-delivery) |
| Flutter | a chat UI in three tiers (one widget, pages, headless adapters), background download, a device plugin | local_inference_flutter | [its README](https://pub.dev/packages/local_inference_flutter) |

Each layer is built on the one before and also works alone: L1 when you render the prompt yourself, L2 for single
calls with tools, L3 for a chat. Qwen3.5 is the validated model family, with prompts checked byte for byte; the others
work through llamadart's chat formats, best effort ([Other model families](#other-model-families)).

A domain preset can be built on top: a package that depends on local_inference and exports an `AssistantConfig` (or a
`Toolkit` subclass) with the tools, prompt, replies and texts of one app domain, so the apps of that domain share
them.

## Compatibility

| | Version | Checked by |
|---|---|---|
| Dart | 3.10.7 or newer; no Flutter | the tests, on the standalone Dart 3.10.7 and on Dart 3.13 |
| llamadart | 0.8.23 exactly (0.9 renders Qwen3 differently and needs dinja 1.2) | the doctor's `pins` check in a host |
| llama.cpp | v0.4.0, the bundles of llamadart-native v0.4.0 | the SHA-256 manifest `tool/native/llamadart-native-v0.4.0.sha256` |
| dinja | `>=1.0.0 <1.1.0`; 1.0.0 is the tested version (it renders the prompts) | the byte-for-byte prompt tests; the doctor warns on another 1.0.x |

| Platform | Floor | State on 2026-09-30 |
|---|---|---|
| macOS | 14.0; arm64 and x86_64 | runs (Apple M1 Pro, Metal): the tests, the model matrix below, the examples |
| iOS | 16.4; arm64 devices, the simulator on the CPU | runs on an iPhone 16 Pro Max (Metal) |
| Android | API 28 at run time; arm64-v8a (x86_64 for emulators) | a release APK builds; has not run on a device yet |
| Linux | x64 | the bundle is in the manifest; not run yet |
| Windows | none | no bundle in the manifest; not tested |

**Model families.** Apple M1 Pro 16 GB, macOS 26.6.2, Metal, llamadart 0.8.23 / llama.cpp v0.4.0, measured by
`test/family_test.dart` (tag `family`), one GGUF per run:

| Model | Arch | Family | Profile | Grammar auto/required | canRewind | Prefill tok/s | Decode tok/s | Tool round s |
|---|---|---|---|---|---|---|---|---|
| LFM2.5-1.2B-Instruct-QAD-Q4_0 | lfm2 | lfm2 | LlamadartFamilyProfile | none/eager | no | 1531 | 158.9 | 0.48 |
| Qwen3.5-0.8B-Q4_0 | qwen35 | qwen3CoderXml | Qwen35Profile | lazy/eager | no | 2089 | 119.9 | 1.09 |
| Qwen3.5-2B-Q4_0 | qwen35 | qwen3CoderXml | Qwen35Profile | lazy/eager | no | 982 | 79.9 | 1.25 |
| Qwen3.5-2B-Q8_0 | qwen35 | qwen3CoderXml | Qwen35Profile | lazy/eager | no | 993 | 60.5 | 1.42 |
| Qwen3.5-4B-Q4_0 | qwen35 | qwen3CoderXml | Qwen35Profile | lazy/eager | no | 388 | 39.0 | 2.00 |
| Qwen3.5-4B-Q8_0 | qwen35 | qwen3CoderXml | Qwen35Profile | lazy/eager | no | 395 | 28.2 | 2.38 |
| gemma-4-E2B-it-UD-Q4_K_XL | gemma4 | gemma4 | LlamadartFamilyProfile | none/eager | yes | 658 | 50.8 | 0.97 |
| granite-4.2-3b-Q4_K_M | granite | qwen3CoderXml | Qwen35Profile | lazy/eager | yes | 443 | 48.0 | 2.28 |

- Family is llamadart's reading of the model's template. Granite 4.2 writes Qwen3.5's XML envelope, so it gets
  `Qwen35Profile`.
- canRewind: whether the context can be cut back. Recurrent and hybrid models (Qwen3.5, LFM2) cannot, so the prefix
  state is restored before each call.
- Prefill: about 290 prompt tokens over the time to the first token. Decode: the tokens after the first over the time
  after it. Tool round: one `send` with `ModelWrittenReplies` that calls a tool and answers from its result.
- Every model gave plain chat with no markup, both grammars were admitted by llama.cpp, a required call validated,
  and one tool round answered from the result. The matrix also ran Qwen3.5-0.8B-Q8_0 and the 2B and 4B UD-Q4_K_XL
  files, which the table leaves out.
- Run it again on any llamadart upgrade, once per model:
  `LI_TEST_MODEL=/abs/path/model.gguf LI_TEST_REPORT=/abs/path/report.json dart test -t family` in this package.

## Performance and memory

Measured figures, each with its device and conditions; the one estimate says so. They depend on the device's
temperature: an iPhone reaches the "serious" thermal state within a few minutes of back-to-back inference and then
runs at about half speed.

| What | Figure | Where and how |
|---|---|---|
| Speed per model family, Mac | the table above | M1 Pro, Metal; `test/family_test.dart`, 2026-09-30 |
| A fine-tuned Qwen3.5 4B, Q5_K_M (3.07 GB), iPhone 16 Pro Max | prefill 111-156 tok/s, decode 7.7-12.2 tok/s; first token 296-320 ms after the prefix restore; a tool-call turn 1.7-3.1 s | iOS 26.6.1, Release build with the increased-memory-limit entitlement, micro-batch 128, from cool to "serious" |
| A fine-tuned Qwen3.5 2B, Q5_K_M (1.45 GB), same phone | prefill 142-315 tok/s, decode 12-20 tok/s; a turn 1.0-2.0 s | hot and charging |
| GPU memory of the 4B, same phone | 3,321 MB after load (3,695 MB with micro-batch 512) of a 5,461 MB Metal working set | Metal's allocation read after the load |
| Prefix state, 4B | 84 MB for 1,078 tokens (system prompt and 4 tools), saved in 9.3 s on the phone; 120 MB for 14 tools (2,054 tokens), 12.1 s with the load on the Mac. On the iPhone the 14-tool build is not measured yet: an estimate from the measured prefill rate gives about 16-21 s on a cool phone and about 40 s on a hot one | KV cache f16 |
| Prefix state, 2B | 32 MB for 1,078 tokens; 45 MB for the 14 tools, 4.4 s on the Mac | KV cache f16; the Mac figure on the 2B Q8_0 |
| Prefix states on disk | the 3 most recently used (`FilePrefixStateStore(maxEntries: 3)`), optionally within `maxBytes` | the store's defaults |
| Micro-batch on iOS | `LoadOptions.microBatchSize` null means 128 on iOS: at 512, 2 of 9 generations failed on a hot iPhone, at 128 none; no change on the Mac | iPhone 16 Pro Max, two runs |
| Model load | 22.7 s the first time on the Mac (Metal shaders, file cache), 1.8-2.3 s after; load and prefix restore of the 4B on a later launch 5.1 s on the Mac | M1 Pro |
| Model-written replies on a model that cannot rewind | one more model call per tool round, each with a prefix restore and a prefill of the conversation after the prefix (the tool round column above) | the model matrix. A model fine-tuned for app-written replies (`AppWrittenReplies`) needs one model call per message |
| Device requirements | set per model in the manifest: for example 7,000 MB of RAM, 3,800 MB available and 3,726 MB free disk for a 4B Q5_K_M; 5,500, 2,000 and 2,027 MB for a 2B Q5_K_M | "Model manifest" below |
| Native libraries in an app | iOS llamadart.framework 11 MB (arm64); macOS libllamadart.dylib 13.4 MB (arm64), 14.7 MB (x86_64); the Android arm64 bundle is 38.6 MB compressed, of which the hook keeps the CPU and Vulkan libraries unless `llamadart_native_backends` says otherwise | the llamadart-native v0.4.0 bundles |

## Host setup

What a pure-Dart host sets itself:

- The hooks block in the root pubspec ("Install").
- Build with `dart build cli -t bin/<entry>.dart -o build/cli`, never `dart compile exe`, which fails for a package
  with a build hook. `-t` names the entry point, which is needed when `bin/` holds more than one Dart file; the
  executable in `build/cli/bundle/bin` takes the entry file's name. Ship the whole `bundle/` folder: the executable
  loads the llama.cpp libraries from `bundle/lib`. Sign the bundled dylib of a macOS tool you distribute.
- Linux takes the linux-x64 bundle; the hook bundles its CPU and Vulkan backends by default. Nothing has run on Linux
  yet ("Compatibility").
- A Flutter app also sets iOS, Android and macOS settings: local_inference_flutter's README, "Host setup".
- The tool or server ships the notices of the native libraries it bundles, `NATIVE_LICENSES.txt`, next to `bundle/`
  ("License and notices"); a Flutter app on local_inference_flutter gets them on its license page by itself.

The doctor checks the host ("Doctor", next). Vendored natives are optional ("Vendored natives", after it).

### Doctor

`dart run local_inference:doctor` checks a host app or package against what the packages need and cannot set
themselves, and says for each check what it found and how to fix it. A Flutter app runs
`dart run local_inference_flutter:doctor` (`dart run` needs an immediate dependency); both run the same checks. The
doctor itself reads files only: it uses no network and changes nothing, except with `--install-ios-script`.

```sh
dart run local_inference:doctor                          # the host in the current folder
dart run local_inference_flutter:doctor --strict path/to/app
dart run local_inference_flutter:doctor --json --verify-natives
```

Add the hooks block before the first run. `dart run` resolves the host and runs the build hooks of the package it
runs from before the doctor starts:

- llamadart's hook builds for this computer: it takes this computer's bundle (such as `macos-arm64`) from the vendored
  folder, or downloads it into the pub cache once;
- without the hooks block, the hook also downloads LiteRT-LM into llamadart's folder in the pub cache, and the doctor
  then reports that build (`hooks-block`, `litert-lm`);
- the doctor does not start when the host's pubspec does not resolve, when a llamadart companion package is resolved
  (its hook fails), when the vendored folder lacks this computer's bundle, or offline without that bundle in the pub
  cache.

In those cases, run the doctor from a package of its own and name the host's folder. The host is then only read; its
hooks do not run:

```yaml
# doctor_runner/pubspec.yaml; then: dart pub get && dart run local_inference:doctor --strict ../my_app
name: doctor_runner
publish_to: none
environment:
  sdk: ^3.10.7
dependencies:
  local_inference: ^0.1.0   # the version the host uses
hooks:
  user_defines:
    llamadart:
      llamadart_native_runtimes: [llama_cpp]
```

| Check | What it reads, and what it wants |
|---|---|
| `hooks-block` | the pubspec the hooks runner reads (the app's, or its workspace root's): `llamadart_native_runtimes: [llama_cpp]` |
| `pins` | pubspec.lock: llamadart 0.8.23; dinja in `>=1.0.0 <1.1.0` (a warning for another 1.0.x); it names a `dependency_overrides` entry that causes a mismatch |
| `one-ref` | pubspec.lock: the local_inference packages from one source: one package server (pub.dev), or one git url and commit, or one checkout (from git or a checkout, also one version); a warning when the lock no longer matches pubspec.yaml |
| `sibling-ref` | pubspec.yaml, for the packages listed from git: one url and one ref (two spellings of one locked commit are a warning), and never local_inference next to local_inference_flutter at a ref that does not resolve |
| `runtimes` | pubspec.lock: no llamadart companion (`llamadart_*_flutter`, an error), no other on-device runtime (a warning) |
| `litert-lm` | the llamadart builds in `.dart_tool/hooks_runner` (input and log), and llamadart's `litert_lm` cache folder |
| `natives` | `llamadart_native_path`: the bundles the host builds for, and the guard file; with `--verify-natives`, every file of it (or the hook's downloads in the pub cache) against the manifest |
| `native-output` | with `--verify-natives`: the libraries the builds bundled, from the hook's output (a macOS build rewrites its copy in the app) |
| `ios-*` | the Xcode project and its .xcconfig files, the Podfile, the entitlements, Info.plist, the app's privacy manifest and sources: deployment target 16.4 (and where a lower one is set), the increased-memory-limit entitlement, the "Native Assets Minimum iOS" phase after "Thin Binary" and its script, script sandboxing off, the notification delegate, the photo-library strings (or the BYPASS variables; for a CocoaPods build of background_downloader, the Podfile's BYPASS flags), FileTimestamp C617.1 |
| `android-*` | android/app/build.gradle(.kts), the main manifest and the app's Dart code (lib/ and bin/ of the host, of its workspace members and of its path packages): minSdk 28, `abiFilters` against the llama.cpp bundles (a statement over several lines too), the dataSync foreground-service entries against `AndroidForeground` (a dot shorthand too) |
| `macos-*` | the Xcode project and the entitlements: deployment target 14.0, `network.client` when sandboxed |

- A check that does not apply is `skipped`, with the reason: a pure-Dart host, no ios/ folder, no pubspec.lock yet.
  Run it on the app, not on a workspace root: there the platform checks are skipped, and `hooks-block` warns when a
  member is a Flutter app.
- `--strict` fails on warnings too.
- Exit status: 0 when no check failed; 1 when a check found an error, or a warning with `--strict`; 2 for a usage
  error (an unknown option, a folder without a readable pubspec.yaml, `--install-ios-script` without an ios/ folder).
- `--install-ios-script` copies local_inference_flutter's `tool/ios/native_assets_min_os.sh` to the host's
  `ios/scripts/` and prints the build-phase steps. It does nothing when the app target already has an equivalent
  phase (a script of the host's own that does the same fix, such as one named `fix_framework_min_os.sh`).
- `--json` prints one JSON object on stdout (the hooks' "Running build hooks..." lines go to stderr): `tool`
  (`local_inference doctor`), `format` (1; raised by a change that breaks a reader), `version` (the package's),
  `host` (an absolute path), `kind` (`flutter`, `workspace` or `dart`), `platforms`, `strict`, `verifyNatives`,
  `results` (one per check, in the table's order: `id`, `title`, `status`, `found`, and `fix` or null), `summary` (the
  count of each status) and `exitCode`. The ids and the statuses (`ok`, `warning`, `error`, `skipped`) are stable;
  `title`, `found` and `fix` are text for people.
- What it does not read: `$(…)` values and conditional build settings (`KEY[sdk=…]`); it finds the notification
  delegate and the `AndroidForeground` opt-in by searching the source (comments left out; an `androidForeground:`
  value it cannot classify is a warning). It does not check `installDownloaderStorage()` in `main()`, the
  `bg_downloader_*` strings, Android backup rules, or the plugins' own privacy manifests.
- The manifest is `tool/native/llamadart-native-v0.4.0.sha256`, embedded in `lib/src/doctor/native_manifest.g.dart`
  (`dart run tool/embed_native_manifest.dart` after a change; a test compares the two).

### Vendored natives

To build offline from checked binaries, vendor the llama.cpp bundles and point the hook at them. Copy this package's
`tool/native/` folder (the fetch script, `bundles.txt` and the SHA-256 manifest) into your repository, then fetch the
bundles your builds target:

```sh
tool/native/fetch_llamadart_native.sh --dest third_party/llamadart-native/v0.4.0 macos-arm64 ios-arm64 android-arm64
tool/native/fetch_llamadart_native.sh --dest third_party/llamadart-native/v0.4.0 --verify-only   # offline check
```

```yaml
hooks:
  user_defines:
    llamadart:
      llamadart_native_runtimes: [llama_cpp]
      llamadart_native_path: third_party/llamadart-native/v0.4.0   # relative to this pubspec
```

- The script checks every archive and every file it unpacks against the manifest, and deletes a download that does
  not match. The folder then holds `<bundle>/<archive>` and `<bundle>/extracted/`, the layout of the hook's own
  cache, and the hook downloads and extracts nothing.
- A build for a bundle that is not in the folder fails on the guard file `extracted/target-bundle-not-vendored.so`
  ("No primary libllamadart library found") instead of taking another platform's libraries.
- iOS devices need `ios-arm64`, and a universal macOS build `macos-arm64` and `macos-x86_64`. The simulator on Apple
  silicon needs `ios-arm64-sim`. A simulator build that also targets x86_64 (`flutter build ios --simulator`, or an
  Intel Mac) needs `ios-x86_64-sim` too, which the manifest does not cover yet: such a build stops on the guard file,
  and the doctor does not warn about it.
- After changing files there, run `flutter clean` (or delete `.dart_tool/hooks_runner`): the hook does not declare
  the folder as a dependency.
- `tool/native/README.md` has the layout, the trust record of the manifest and the update steps.
- `dart run local_inference:doctor --verify-natives` checks the folder (or, without one, the hook's downloads in the
  pub cache) against the same manifest.

## Testing your assistant

`package:local_inference/testing.dart` holds test doubles with no model file and no native code. It does not depend
on `package:test`: add `test` (or `flutter_test`) to your dev dependencies.

- `scriptedAssistant(config, script: [...])` loads an `Assistant` on a `ScriptedEngine` and checks each scripted tool
  call against the grammar the real model would be held to (`ScriptRejectedByGrammar` otherwise; a call the model's
  family cannot read is refused too). `ScriptedTurn.text` is a plain answer, `ScriptedTurn.toolCall` a call in
  Qwen3.5's XML envelope; script another family's call with `ScriptedTurn.text` in its own syntax.
- `ScriptedEngine` answers each generation with the next string of `outputs` (in 7-character deltas) and records
  every prompt and option; its default template is `qwen35ChatTemplate`. An exhausted script fails the test with
  `ScriptExhausted`. `gate`, `failNextLoadState` and `throwAfterDeltas` script the hard cases.
- `TestToolkit` wraps a toolkit to record its calls and hold one tool's answer back; `InMemoryPrefixStateStore`
  records every prefix-state call; `GbnfRecognizer` tells which strings a grammar admits, with llama.cpp v0.4.0's
  GBNF rules.
- For model delivery: `FakeModelDownloader`, `FakeDeviceProbe`, `testManifestJson`, `testModelBytes` and
  `fixedClock`.

```dart
import 'package:local_inference/local_inference.dart';
import 'package:local_inference/testing.dart';
import 'package:test/test.dart';

void main() {
  test('the model answers from the tool result', () async {
    final (assistant, engine) = await scriptedAssistant(
      AssistantConfig.basic(
        systemPrompt: 'You help the customers of a shop.',
        tools: [
          AssistantTool(
            name: 'list_orders',
            description: "Lists the customer's orders.",
            run: (call, context) => ToolResult.list(
              collection: 'orders',
              items: const [
                {'code': 'A-17'},
              ],
            ),
          ),
        ],
      ),
      script: [const ScriptedTurn.toolCall('list_orders'), const ScriptedTurn.text('You have one order, A-17.')],
    );
    addTearDown(assistant.dispose);
    expect((await assistant.send('My orders?')).reply, 'You have one order, A-17.');
    expect(engine.prompts.last, contains('A-17'));
  });
}
```

**Hooks in library packages.** `dart test` and `flutter test` run llamadart's build hook even when the tests only use
`ScriptedEngine`, and while a package runs its own tests it is the root package. So a library that depends on
local_inference (or on local_inference_flutter) needs the hooks block in its own pubspec too, or its tests download
and bundle LiteRT-LM. The block is ignored when an app depends on the library: the app's own block counts.

**In CI**, the hook downloads this machine's bundle once into llamadart's folder in the pub cache
(`.dart_tool/llamadart/native_bundles/`): cache the pub cache, or vendor the bundles and set
`llamadart_native_path` ("Vendored natives"), which also makes the build offline.

## Engine (L1)

`InferenceEngine` takes a prompt already rendered in the model's chat layout and streams text back. `LlamadartEngine`
runs it on llama.cpp. Calls run one at a time in call order, so a generation, a tokenization and a state save never
overlap.

```dart
import 'dart:io';

import 'package:local_inference/local_inference.dart';

Future<void> main(List<String> args) async {
  final engine = LlamadartEngine(logLevel: EngineLogLevel.error);
  try {
    final info = await engine.load(args.first, const LoadOptions(contextTokens: 4096));
    stdout.writeln('${info.architecture} on ${info.backend}, ${info.runtime.id}');

    // Qwen3.5's layout (ChatML, thinking off); the engine adds nothing model-specific.
    const prompt = '<|im_start|>user\nCiao!<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n';
    final generation = engine.generate(
      prompt,
      const GenerationOptions(sampling: SamplingOptions(maxTokens: 128), stop: ['<|im_end|>']),
    );
    await for (final delta in generation.text) {
      stdout.write(delta); // generation.cancel() stops it, also before it starts
    }
    final result = await generation.result;
    stdout.writeln('\n${result.finishReason.name}: ${result.stats}');
  } on LocalInferenceException catch (e) {
    stderr.writeln(e);
  } finally {
    await engine.dispose();
  }
}
```

- `GenerationOptions` holds the sampling (greedy by default), stop strings, a GBNF `Grammar` (lazy when it has
  `GrammarTrigger`s), preserved tokens and the stream chunking (1 token per delta).
- `saveState(path, prefix)` fills the context with exactly `prefix` and writes it; `loadState(path)` restores it.
  `contextEpoch` moves with every call that changes the context, so a caller knows when to restore.
- Logging is process-global in llamadart: each `load` points it at that engine's level and sink.

Tests use `ScriptedEngine` from `package:local_inference/testing.dart`, with no model and no native code ("Testing
your assistant").

## Model layer (L2)

`ChatModel` puts a model family on top of the engine: it renders `ChatMessage`s with the model's own chat template,
holds tool calls to a grammar built from each `ToolSpec`'s JSON Schema, parses the answer into text and typed
`ToolCall`s, and keeps a saved prompt prefix for models that cannot rewind their context (Qwen3.5 is one).

```dart
import 'dart:io';

import 'package:local_inference/local_inference.dart';

final weather = ToolSpec(
  name: 'get_weather',
  description: 'Current weather for a city.',
  parameters: ToolSchema.object({
    'city': ToolSchema.string(description: 'City name.'),
    'days': ToolSchema.integer(minimum: 1, maximum: 7),
  }, required: ['city']),
);

Future<void> main(List<String> args) async {
  final model = await ChatModel.load(args.first, prefixStore: FilePrefixStateStore.temporary());
  try {
    const system = 'You are a helpful assistant. Answer briefly.';
    // The system prompt and tool block are prefilled once and saved; later calls restore them.
    await model.preparePrefix(systemPrompt: system, tools: [weather]);
    final generation = model.generate([
      const ChatMessage.system(system),
      const ChatMessage.user('Will it rain in Rome tomorrow?'),
    ], tools: [weather]);
    await for (final text in generation.text) {
      stdout.write(text); // visible text only: tool-call markup never shows
    }
    final result = await generation.result;
    for (final call in result.toolCalls) {
      final problems = validateArguments(weather.parameters, call.arguments);
      stdout.writeln('\n$call ${problems.isEmpty ? 'valid' : problems}');
    }
  } on LocalInferenceException catch (e) {
    stderr.writeln(e);
  } finally {
    await model.dispose();
  }
}
```

- **Profiles.** `ModelProfile.detect` picks `Qwen35Profile` for Qwen3.5 templates (ChatML, the XML tool envelope,
  stop `<|im_end|>`, `enable_thinking` always false; `acceptedTemplateSha256` refuses other templates with
  `UnsupportedModelException`), else `LlamadartFamilyProfile` for a template whose tool calls llamadart knows (see
  "Other model families"), else `TextOnlyProfile` (plain chat and structured output, no tool calls).
- **Tools.** `ToolSpec.parameters` is the full JSON Schema (grammar, typed parsing, `validateArguments`);
  `promptDeclaration`, when set, is the exact tool-block entry a fine-tuned model was trained on. `ToolSchema` builds
  schemas with a fixed key order. `ToolMode.auto` holds a call to the grammar once it starts (lazy),
  `ToolMode.required` forces one, `ToolMode.none` leaves the output free; `responseSchema` asks for JSON instead.
- **Grammar.** `GrammarOptions` sets how strings may look (`multiLine` never contains `</`), the parameter order
  (permutations up to 3, a subset automaton up to 8, free above), custom `ValueRule`s, the number of calls and the
  size limits. Integer ranges, patterns (a regex subset), ISO dates, unions and JSON objects and arrays (in
  `json.dumps` style) become exact rules; what a grammar cannot hold, the validator checks after parsing.
  `jsonSchemaGrammar` gives the grammar of a structured response.
- **Prefix states.** `FilePrefixStateStore(folder)` keeps `prefix_<key>.state` files (the 3 most recently used by
  default); the key covers the model file (name, size, modification time), the template, the runtime and the load
  settings. `preparePrefix` builds or restores the state; `generate` restores it before each call when the context
  has moved (`ChatResult.restore`). Without a store, a model that cannot rewind prefills every prompt in full.
- **Streaming.** `ChatGeneration.text` gives the visible text in appended pieces, `raw` the engine's deltas;
  `cancel()` stops it, before the engine call too.

The prompts are byte-identical to Hugging Face's `apply_chat_template` (save for the few doubles `pythonJson` writes
differently, and mapping or list arguments of tool calls in the history; see the CHANGELOG):
`test/fixtures/reference/` holds jinja2 renderings of both Qwen3.5 templates, which `test/chat_template_test.dart`
compares byte for byte. They come from `tool/render_reference.py`, run in a virtual environment with the jinja2
version pinned in `tool/requirements.txt`:

```sh
python3 -m venv tool/.venv && tool/.venv/bin/pip install -r tool/requirements.txt
tool/.venv/bin/python tool/render_reference.py           # render test/fixtures/reference/ again
tool/.venv/bin/python tool/render_reference.py --check   # compare with the committed files
```

`testing.dart` adds `InMemoryPrefixStateStore` (records every call) and `GbnfRecognizer` (tells which strings a
grammar admits, with llama.cpp v0.4.0's GBNF syntax, and refuses the grammars that llama.cpp refuses: unknown
escapes, repetitions over its limits, left recursion).

## Other model families

Beyond Qwen3.5, `LlamadartFamilyProfile` gives tool calling to the model families whose chat format llamadart 0.8.23
knows (`LlamadartFamilyProfile.families`: Gemma 4, LFM2, Llama 3.x, Mistral and Ministral, Granite, Hermes (Qwen 2.5
and 3), DeepSeek, GPT-OSS, FunctionGemma and about 25 more). It is best effort: Qwen3.5 stays the validated profile,
with prompts checked byte for byte against Hugging Face. Nothing changes in the calling code: `ChatModel.load` and
`Assistant.loadModel` detect the family from the model's template.

```dart
import 'dart:io';

import 'package:local_inference/local_inference.dart';

Future<void> main(List<String> args) async {
  final model = await ChatModel.load(args.first); // for example gemma-4-E2B-it-UD-Q4_K_XL.gguf
  try {
    stdout.writeln(model.profile); // LlamadartFamilyProfile(gemma4)
  } finally {
    await model.dispose();
  }
}
```

**What works.** The prompt is rendered by llamadart's template engine with the model's own template and the tools;
the grammar (lazy from the family's trigger, or eager for `ToolMode.required`), the stop strings and the preserved
tokens are the family handler's; the handler parses the answer into text, reasoning and tool calls (LFM2's calls are
read by the profile), and the streamed text stops before a tool call. A call that cannot be read is a parse error,
never a call with its arguments dropped. Model-written replies (the assistant's default) send the calls and their
results back in the family's own layout, and a recurrent family (LFM2) keeps a prefix state as Qwen3.5 does. Thinking
is off by default: `LlamadartFamilyProfile('gemma4', thinking: true)` turns it on.

**What is lost or different.**
- llamadart's `ToolParam` cannot carry `anyOf`, `additionalProperties`, `minimum`/`maximum`, patterns, lengths,
  non-string enums or the key order. The tool block and most families' grammars still get the full schema (the tool
  definitions handed to llamadart carry it), but GLM 4.5 and Hunyuan V3 write one grammar rule per parameter from the
  lossy list, and the XML formats (Seed-OSS, MiniCPM 5, MiniMax M2, Xiaomi MiMo, Apriel 1.5, Qwen3-Coder) constrain
  only the tool and parameter names. llamadart's JSON-schema grammars have no integer ranges or patterns (the range
  of a `ToolSchema.itemNumber` included). The calls are always checked against the full schema after parsing
  (`validateArguments`, the assistant's toolkit).
- The grammar is the family's: `GrammarOptions` (string shapes, parameter order, value rules) apply only to a
  `responseSchema`, which gets the JSON grammar every profile uses. Gemma 4, LFM2 and FunctionGemma have no grammar
  for `ToolMode.auto` (the call is free text that the parser finds; llama.cpp itself constrains Gemma 4 lazily).
  `ToolMode.required` forces a call where the family has an eager grammar, in llamadart's JSON variant for Gemma 4
  (JSON arguments) and LFM2 (a JSON list with an `id`, which LFM2 may pad with whitespace), not the syntax these models
  write. `ToolMode.none` keeps the tools in the prompt, as with every profile.
- The prompts are llamadart's rendering. For Gemma 4 E2B and LFM2.5 they were checked against Hugging Face's
  (jinja2): the same bytes, except the generation prompt that Gemma 4's template leaves out after a tool response to a
  message that also had text, which the profile adds as llama.cpp does. A tool the template writes with `tojson` is in
  Python's `json.dumps` form, as Hugging Face writes it; the other families are not checked.
- A template llamadart reads as generic or content-only, Gemma 3 (llamadart routes its tool calls to the generic JSON
  prompt, which replaces the system prompt) and TranslateGemma stay text-only: tools there throw
  `UnsupportedModelException`, naming llamadart's reading of the template.
- Where llamadart 0.8.23 gets a family wrong, the profile does it. Gemma 4 gets a tool result as the tool message's
  text with the tool's name (llamadart's `tool_responses` render as `value:null` in Gemma 4's templates), and a call's
  strings are read verbatim (llamadart loses the arguments when a string holds a comma and a colon, a quote or a line
  break). LFM2's calls are read by the profile (llamadart drops a call without arguments, with every call listed next
  to it, and keeps the string escapes). Gemma 4, LFM2 and FunctionGemma get a past call's arguments as a mapping
  (LFM2.5's template refuses llamadart's JSON text; Gemma 4's and FunctionGemma's write it as JSON, not their syntax).
- The text of an answer stops at the family's own call opener (its grammar trigger, `<|tool_call>` for Gemma 4,
  `<|tool_call_start|>` for LFM2), so prose that mentions another family's markup stays text.
- In scripted tests (`testing.dart`), `ScriptedTurn.toolCall` writes Qwen3.5's XML envelope: script another family's
  call with `ScriptedTurn.text` in its own syntax (`scriptedAssistant` refuses a scripted call the profile cannot read).
- The rendering depends on the exact llamadart version (0.9 changes it): run the family tests again on any upgrade.

**What the matrix found** ("Compatibility" has the table; Apple M1 Pro, Metal, 2026-09-30). On every model,
plain chat gave visible text only and no reasoning, llama.cpp admitted the grammars, a required call validated, a note
with a comma, a colon, quotes and a line break came back verbatim (in `ToolMode.required`, and in `ToolMode.auto`
whenever the model called), the prefix state was restored before each call on the recurrent ones (the others reused
the prefix with no restore), and one tool round with `ModelWrittenReplies` answered from the tool's result. Asked for
a sentence before the call, Gemma 4, Granite 4.2 and Qwen3.5-4B wrote it, called and answered from the result,
Qwen3.5-0.8B called but did not quote the result, and LFM2.5 and Qwen3.5-2B answered without calling.

## Assistant (L3)

An `Assistant` runs a conversation over a model with the tools of an `AssistantConfig`: it keeps the history, runs
the calls the model writes, asks before an irreversible one, knows what "the second one" means in the last list the
user saw, and saves conversations.

```dart
import 'dart:io';

import 'package:local_inference/local_inference.dart';

Future<void> main(List<String> args) async {
  final orders = <Map<String, Object?>>[
    {'code': 'A-17', 'item': 'headphones'},
    {'code': 'B-22', 'item': 'kettle'},
  ];
  final assistant = Assistant(
    AssistantConfig(
      prompt: const PromptLayout(
        systemPrompt: 'You help the customers of a shop. Refer to list items by number.',
        contextLine: ContextLines.english,
      ),
      toolkit: Toolkit.of([
        AssistantTool(
          name: 'list_orders',
          description: "Lists the customer's orders, numbered from 1.",
          statusLabel: 'Looking up your orders…',
          run: (call, context) => ToolResult.list(collection: 'orders', items: orders),
        ),
        AssistantTool(
          name: 'cancel_order',
          description: 'Cancels one order of the last list of orders.',
          parameters: ToolSchema.object(
            {'order_number': ToolSchema.itemNumber('orders')}, // 1..8, an item of the last list of orders
            required: ['order_number'],
          ),
          sideEffect: SideEffect.irreversible, // asks first
          confirmationQuestion: (call, context) => 'Cancel order ${context.item('order_number')?['code']}?',
          run: (call, context) {
            final order = context.item('order_number'); // the item the number named on screen
            if (order == null) return const ToolResult.error('not_shown', 'Show the orders first.');
            orders.removeWhere((o) => o['code'] == order['code']);
            return ToolResult.ok({'cancelled': order['code']});
          },
        ),
      ]),
      // replies: ModelWrittenReplies() by default: the model writes the answer from the tool result.
    ),
    prefixStore: FilePrefixStateStore('.prefix_states'),
  );
  try {
    if (!await assistant.loadModel(args.first)) {
      stderr.writeln(assistant.state.loadError);
      return;
    }
    final turn = assistant.sendStreaming('Which orders do I have?');
    await turn.text.forEach(stdout.write); // the visible text as it grows
    var outcome = await assistant.send('Cancel the second one');
    if (outcome.confirmation case final question?) {
      stdout.write('\n${question.question} [y/n] ');
      outcome = await assistant.confirm(stdin.readLineSync() == 'y');
    }
    stdout.writeln('\n${outcome.reply}');
  } finally {
    await assistant.dispose();
  }
}
```

- **State.** `state` is an immutable `AssistantState` (phase, items, the open question and its `pendingActions`,
  the model); every change makes a new one, and the items that did not change keep their identity. Listeners
  (`addListener`) run synchronously after each change; `states` and `events` (typed `…Event`s) deliver the same
  asynchronously. `ChatAction`s are data: `act(action)` or `confirm(yes)` performs them.
- **Calls.** `send` returns a `TurnOutcome` and never throws (a refused call says why: `TurnRejection`);
  `sendStreaming` also gives the turn's text as it grows and its events. `stop()` ends a turn while the model writes;
  a running tool sees `ToolContext.cancelled` and still finishes (it may already have acted).
- **Tools.** `Toolkit.of([AssistantTool(...)])`, or a `Toolkit` subclass for a whole set (a domain preset's). Calls
  are coerced, checked against the schema (`missingData` otherwise), asked about when their `SideEffect` is in the
  `ConfirmationPolicy`, then run with the `toolStatusDelay`, `beforeTool` and `toolTimeout` of the config; a tool that
  throws fails the turn, or becomes a failure the model sees (`ToolErrorPolicy.reportToModel`).
- **Replies.** `ModelWrittenReplies` (the default) sends the calls and their results back to the model, up to
  `maxToolRounds` rounds; `AppWrittenReplies(writer)` writes every reply in the app (for models fine-tuned to call
  tools that never saw a tool result). A `ToolReply` may carry a `followUp` (run once, right away) and an `offer` (run
  on the user's next yes).
- **Lists.** A result made with `ToolResult.list` becomes the last list of its collection; an argument built with
  `ToolSchema.itemNumber(collection)` is an item number of that collection (so is one `ListReferences.itemArguments`
  declares), and `ToolContext.item(argument)` gives the item as the user saw it. A number that a later list
  renumbered is never acted on: the question answers `listChanged`, the offer goes to the model.
- **The host.** Its screens use the same tools and lists through `ToolHost` (`runTool`, `recordAction`,
  `isLastList`, `isScreenRequestCurrent`, `revision`); a reply can ask for a screen (`ScreenRequest`, bound to the item
  it names).
- **Text.** `PromptLayout` keeps the last 3 exchanges within 1600 characters and puts the context line (the date) in
  the newest user message; `guards` check plain answers (`NumericFactsGuard` replaces invented numbers), a `rewriter`
  changes the model's text, `beforeModel` can answer instead of the model or add context, and `AssistantStrings`
  (English, Italian, `forLanguage`) holds every text the app writes into the conversation.
- **Conversations.** `snapshot()` and `restore()` with a typed `ConversationSnapshot` (`tryParse` never throws),
  `FileConversationStore` and `autosave`; `newConversation(id:)`, `setToolkit(keepConversation:)` and
  `reconfigure(config)` between turns, on the same engine. `restore` resets the toolkit and brings back the open
  question and the offer. With `AssistantConfig.restoreOpenQuestion: false` it drops them instead, as a message
  that is not a yes or a no does: the item that asked keeps its text without its buttons, the question joins the
  history as declined, and a yes typed next goes to the model. That suits a toolkit whose reset forgets the lists
  they name.

Tests script the model with `scriptedAssistant` ("Testing your assistant"), with no model file.

## Model delivery

A `ModelManager` lists the models of a catalog, downloads the missing ones, checks their size and SHA-256 and keeps
them in `<root>/models/<id>/`. It reports codes and numbers (`ModelStatus`, `ModelError`, `ModelProblem`); a UI says
them (local_inference_flutter's `ModelSetupStrings`). In a CLI or on a server, `forDirectory` downloads in the
foreground over HTTP:

```dart
import 'dart:io';

import 'package:local_inference/local_inference.dart';

Future<void> main() async {
  final models = ModelManager.forDirectory(
    'data',
    catalog: ModelCatalog.single(
      ModelEntry(
        id: 'qwen3.5-2b',
        url: Uri.parse('https://example.org/models/qwen3.5-2b-Q4_0.gguf'),
        sizeBytes: 1280000000,
        sha256: 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      ),
    ),
  );
  try {
    final model = await models.install(
      'qwen3.5-2b',
      onProgress: (status) => stdout.write('\r${(status.progress * 100).floor()}%'),
    );
    stdout.writeln('\n${model.path}');
  } on ModelInstallException catch (e) {
    stderr.writeln(e); // e.error, e.problem, or e.canceled
  } finally {
    await models.dispose();
  }
}
```

The URL, size and hash above are placeholders: take them from the GGUF file you publish, for example on Hugging Face.

- `ModelCatalog.bundled(read, remote: url)` is the app policy: the copy in the app, swapped for the published one
  when it answers within 5 seconds (awaited only before the first install). Both are manifests ("Model manifest",
  below).
- `problemFor(entry)` says why a model does not fit (RAM, available memory, disk, or the host's `preflight`);
  `watch(id)` streams its status; `init()` may be called again after a failure.
- A failed download resumes on the next `download(id)` or `install(id)`, also after a relaunch, when the downloader
  kept its data (`canResume`) and the network rule it started with still holds (kept in `models/downloads.json`);
  otherwise it starts again. `HttpModelDownloader` finds the part file an earlier process left, and resumes it with a
  Range request.
- A GGUF file is checked for the GGUF magic before its size and SHA-256: a web page served in its place fails as
  `ModelErrorCode.notAModelFile` and is never hashed.
- Tests use `FakeModelDownloader`, `FakeDeviceProbe` and `testManifestJson` from `package:local_inference/testing.dart`.

### Model manifest

A manifest is the published list of models that `ModelManifest.parse` reads: `ModelCatalog.bundled` (the copy in the
app and the published one) and local_inference_flutter's `ModelOrigin.manifest(url)` take one. Schema 1, with
placeholder values:

```json
{
  "schemaVersion": 1,
  "manifestVersion": "2026-09-30",
  "models": [
    {
      "id": "qwen3.5-2b-q4_0",
      "version": 1,
      "displayName": "Qwen3.5 2B",
      "params": "2B",
      "quant": "Q4_0",
      "format": "gguf",
      "status": "active",
      "recommended": true,
      "file": {
        "url": "https://example.org/models/Qwen3.5-2B-Q4_0.gguf",
        "sizeBytes": 1280000000,
        "sha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
      },
      "requirements": {
        "minPhysicalRamMB": 4000,
        "minAvailableMemoryMB": 1800,
        "minFreeDiskMB": 1800
      }
    }
  ]
}
```

- Parsing is strict: one bad field rejects the whole manifest with that field's path (`ModelManifestException`);
  `ModelCatalog.bundled` then keeps the copy in the app.
- `schemaVersion` is 1; `manifestVersion` is any non-empty text, such as a date; `models` is a non-empty list of
  models with distinct ids.
- A model: `id` (letters, digits, `.`, `_` and `-`; it names the model's folder), `version` (an integer),
  `displayName`, `params` and `quant` (non-empty texts that the UI shows), `format` `gguf`, `status` (`active`, the
  default; `deprecated`, kept where installed but not offered; `revoked`, not offered) and `recommended` (false by
  default).
- `file.url` is an https URL whose last segment is the `.gguf` file name the model is stored under. `file.sizeBytes`
  is the file's exact size and `file.sha256` its SHA-256 (64 hexadecimal characters): both are checked after the
  download. Take them from the file you upload (`wc -c < model.gguf`, `shasum -a 256 model.gguf`).
- `requirements` are in MB of 1024 × 1024 bytes. A model is offered when the device's physical memory reaches
  `minPhysicalRamMB` and its available memory `minAvailableMemoryMB` (a value the device does not report passes); its
  download needs `minFreeDiskMB` of free disk. Of the models offered, the one marked `recommended` comes first, then
  the one with the highest `minPhysicalRamMB`, then the larger file.
- Give a changed model a new id and file name, and never replace a published file in place: a resumed download or an
  installed copy would no longer match.
- For `minFreeDiskMB`, the file size plus 10% plus 500 MB leaves room for the download and the prefix states.
  `test/delivery/manifest_test.dart` parses the example above.

## License and notices

- local_inference is released under the MIT License (`LICENSE`). `NOTICE` lists the third-party software this package
  depends on, the native libraries apps bundle and the models the documentation names, each with its license.
- An app or a tool built on the packages bundles llama.cpp's native libraries (llamadart's build hook puts them in the
  app, or in `bundle/lib`). Their licenses, MIT for most and Apache-2.0 for KleidiAI in the Android arm64 CPU
  libraries, ask for their notices in every copy. `NATIVE_LICENSES.txt` holds the texts.
- A Flutter app on local_inference_flutter needs no code for them: that package registers each text with Flutter's
  `LicenseRegistry` before `main()`, so the license page the app opens (`showLicensePage`, `AboutDialog`,
  `AboutListTile`) lists them (its README, "License and notices").
- A command-line tool or a server (`dart build cli`) has no license page: ship `NATIVE_LICENSES.txt` next to
  `bundle/`. local_inference itself ships and registers nothing.
- A Flutter app built on local_inference without local_inference_flutter registers the texts itself: copy
  `NATIVE_LICENSES.txt` into its assets and, in `main()`, add a `LicenseRegistry.addLicense` collector that gives one
  `LicenseEntryWithLineBreaks` per numbered section, under the component's names (as local_inference_flutter's
  `NativeLicenses` does).
- A model has its own license (NOTICE, section 3), which applies to the app that downloads or ships it.
