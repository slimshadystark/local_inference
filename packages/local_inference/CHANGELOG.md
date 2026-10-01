# Changelog

## 0.1.0

Initial release.

- Engine (L1): `InferenceEngine` and `LlamadartEngine`, on llamadart 0.8.23 (llama.cpp v0.4.0). Load options
  (context size, GPU layers, flash attention, KV cache type, micro-batch, compute backend), streaming generation with
  cancel, greedy or sampled decoding, GBNF grammars (lazy with triggers), stop strings, preserved tokens,
  tokenization, and prefix state files. Calls run one at a time, in call order.
- Model layer (L2): `ChatMessage`, `ToolSpec`, `ToolSchema` and `ToolCall`. `ChatModel` renders the prompt with the
  model's own Jinja template (byte-identical to Hugging Face's `apply_chat_template` for Qwen3.5), builds a tool-call
  grammar from each tool's JSON Schema, parses typed calls, checks arguments (`validateArguments`) and saves the
  prompt prefix (`FilePrefixStateStore`) for models that cannot rewind their context. `responseSchema` asks for JSON
  output.
- Model profiles: `Qwen35Profile` (the validated family), `LlamadartFamilyProfile` (best-effort tool calling for the
  chat formats llamadart knows: Gemma 4, LFM2, Llama 3.x, Mistral, Granite, Hermes, DeepSeek, GPT-OSS, FunctionGemma
  and more) and `TextOnlyProfile`. `ModelProfile.detect` picks one from the model's template.
- Assistant (L3): `Assistant` with an `AssistantConfig`: tools (`AssistantTool`, `Toolkit`), a question before an
  irreversible call, numbered lists and item references (`ToolSchema.itemNumber`), offers and follow-ups,
  model-written or app-written replies, output guards and rewriters, hooks before the model and before each tool,
  tool timeouts, streaming turns, typed state and events, conversation snapshots and a file store.
- Model delivery: `ModelManager` with a JSON manifest (schema 1), bundled and remote catalogs, device fit checks (RAM,
  available memory, free disk), downloads checked for size, SHA-256 and the GGUF magic, resume after a failure or a
  relaunch, and `HttpModelDownloader` for command-line tools and servers.
- Testing kit, `package:local_inference/testing.dart`: `ScriptedEngine`, `scriptedAssistant` (scripted tool calls
  checked against the grammar), `TestToolkit`, `InMemoryPrefixStateStore`, `GbnfRecognizer` and fakes for model
  delivery. No model file or native code needed.
- Host doctor, `dart run local_inference:doctor`: checks the hooks block, the pinned versions, where the packages come
  from, the llama.cpp bundles (with `--verify-natives`, against a SHA-256 manifest) and the iOS, Android and macOS
  host settings; text or JSON output.
- `tool/native/`: a script that vendors the llama.cpp bundles and checks them against the manifest, for offline
  builds.

Known limitations:

- llamadart 0.8.23 exactly, and dinja `>=1.0.0 <1.1.0` (1.0.0 tested): the prompt bytes depend on them.
- Prefix states are tied to the model file, the runtime and the load settings: a new llamadart or a new load setting
  builds them once more.
- In the prompts, JSON arguments inside a tool call follow Python's `json.dumps`; a mapping or list argument of a
  tool call in the history keeps dinja's own `tojson` text. `pythonJson` differs from `json.dumps` for doubles of
  magnitude below 1e-4 or from 1e16 up to 1e21, for -0.0 and for lone surrogates.
- llamadart's logging is process-global: each `load` points it at that engine's level and sink.
  `ComputeBackend.auto` leaves the choice to llamadart, which picks the CPU on Android.
- Platforms: macOS 14.0 (arm64, x86_64), iOS 16.4 (arm64; the simulator on the CPU), Android API 28 on arm64-v8a
  (x86_64 for emulators; not run on a device yet), Linux x64 (not run yet). Dart 3.10.7 or newer.
