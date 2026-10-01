# li_chat

A terminal chat with a GGUF model through `local_inference`, in pure Dart: an `Assistant` (`AssistantConfig.basic`)
with two tools, the time (`get_time`) and a calculator (`calculate`, lib/calculator.dart). The model calls them and
writes the reply from their results (`ModelWrittenReplies`, the default). The tools need a model whose family has a
tool-call format that `ModelProfile.detect` knows (Qwen3.5, or one of llamadart's formats with tool calls: Gemma 4,
LFM2, Llama 3.x, Mistral, Granite, …); any other chat model (Gemma 3, Phi-4, …) is refused at load, naming its
template family, and chats with `--no-tools`.

The example is an app of its own, not a member of the repository's workspace: it depends on the package by path and
carries its own hooks block (`llamadart_native_runtimes: [llama_cpp]`, no native path), so llamadart's build hook
downloads the llama.cpp bundle into the pub cache the first time. An app of your own lists the package from pub.dev,
with the same hooks block (local_inference's README, "Install"):

```yaml
dependencies:
  local_inference: ^0.1.0

hooks:
  user_defines:
    llamadart:
      llamadart_native_runtimes: [llama_cpp]
```

```sh
dart pub get                                                        # in packages/local_inference/example
dart run bin/li_chat.dart --model /path/to/model.gguf               # chat: /new, /quit
dart build cli -o build/cli && build/cli/bundle/bin/li_chat --version   # a standalone build (bundle/lib: the natives)
dart run local_inference:doctor --strict                            # the host check (--help lists the options)
```

`li_chat --help` lists the options (`--system`, `--max-tokens`, `--no-tools`). Ship `build/cli/bundle/` whole: the
executable loads the llama.cpp libraries from `bundle/lib/` (`dart compile exe` cannot bundle them). Ship
local_inference's `NATIVE_LICENSES.txt` with it: the notices of those libraries (local_inference's README, "License
and notices"). `dart test` runs the calculator's tests.

The models of local_inference's compatibility table work here (local_inference's README, "Compatibility"); none is
bundled. Each model has its own license: check it before you ship one (local_inference's NOTICE lists the ones its
docs name).
