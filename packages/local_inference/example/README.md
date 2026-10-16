# li_chat: a terminal AI agent in pure Dart

A chat with a local LLM in your terminal, with two tools the model calls on its own: the clock (`get_time`) and a
calculator (`calculate`). It is one Dart process with llama.cpp inside: no server, no API key, no Python, and nothing
leaves the computer.

![li_chat: the model calls the calculator and answers from its result](https://raw.githubusercontent.com/slimshadystark/local_inference/main/packages/local_inference/screenshots/terminal.png)

## Run it

```sh
git clone https://github.com/slimshadystark/local_inference
cd local_inference/packages/local_inference/example
dart pub get
curl -LO https://huggingface.co/unsloth/Qwen3.5-2B-GGUF/resolve/f6d5376be1edb4d416d56da11e5397a961aca8ae/Qwen3.5-2B-Q4_0.gguf
dart run bin/li_chat.dart --model Qwen3.5-2B-Q4_0.gguf    # /new starts over, /quit leaves
```

The first `dart run` also downloads the llama.cpp libraries for your computer into the pub cache, once (llamadart's
build hook). The model above is Qwen3.5-2B in Q4_0 (1.2 GB, Apache 2.0), from Unsloth's Hugging Face repository.
Any GGUF chat model of a family with tool calls works: Qwen3.5, Gemma 4, LFM2, Granite 4, Llama 3.x, Mistral and
others. local_inference's README, "Compatibility", lists the ones measured, with their speed.

## How it works

`bin/li_chat.dart` builds an `Assistant` with `AssistantConfig.basic` and the two tools, as in local_inference's
README ("An agent in 20 lines"). Then it streams each turn: the reply token by token, and each tool call when it
finishes.

```dart
import 'dart:io';

import 'package:local_inference/local_inference.dart';

Future<void> ask(Assistant assistant, String question) async {
  final turn = assistant.sendStreaming(question);
  await Future.wait([
    turn.text.forEach(stdout.write), // the reply, as the model writes it
    turn.events.forEach((event) {
      if (event case ToolFinishedEvent(:final outcome)) {
        stdout.writeln('[${outcome.call} -> ${encodeToolResult(outcome)}]'); // a tool call and its result
      }
    }),
  ]);
  final outcome = await turn.outcome;
  if (outcome.error != null) stderr.writeln(outcome.error);
}
```

Each model family writes tool calls in its own format, and the model's profile reads it; with Qwen3.5, a grammar also
keeps the call well-formed. The assistant checks each call against the tool's schema before it runs the tool.

## Ship it

```sh
dart build cli -o build/cli
build/cli/bundle/bin/li_chat --model Qwen3.5-2B-Q4_0.gguf
```

Ship `build/cli/bundle/` whole. The executable loads llama.cpp from `bundle/lib/`; `dart compile exe` cannot bundle
native libraries. Ship local_inference's `NATIVE_LICENSES.txt` with it: it holds the notices of those libraries.

## In your own app

```yaml
dependencies:
  local_inference: ^0.1.0

hooks:
  user_defines:
    llamadart:
      llamadart_native_runtimes: [llama_cpp]
```

The hooks block goes in the app's own `pubspec.yaml`. It keeps llamadart to the llama.cpp runtime; without it,
llamadart also bundles LiteRT-LM. `dart run local_inference:doctor` checks the setup and says how to fix what is
missing.

## Options

- `li_chat --help` lists them: `--system`, `--max-tokens`, `--no-tools`.
- A chat model with no tool-call format (Gemma 3, Phi-4, …) is refused at load, and the message names its template
  family. `--no-tools` chats with it.
- `dart test` runs the calculator's tests.

No model is bundled. Each model has its own license: check it before you ship one.
