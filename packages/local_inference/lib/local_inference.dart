/// On-device LLM inference for Dart: the engine, model families, the tool-using assistant and model delivery.
///
/// L1, the engine: an [InferenceEngine] takes a rendered prompt and streams text; [LlamadartEngine] runs it on
/// llama.cpp. L2, the model layer: a [ChatModel] renders [ChatMessage]s with the model's template, holds tool calls
/// to a grammar built from each [ToolSpec], parses the answers and keeps a saved prompt prefix ([PrefixCache]); a
/// [ModelProfile] ([Qwen35Profile], [LlamadartFamilyProfile], [TextOnlyProfile]) holds what is family-specific. L3,
/// the assistant: an [Assistant] runs a conversation with the tools of an [AssistantConfig] (a [Toolkit]), asks
/// before irreversible calls, resolves numbered-list references, writes or lets the model write the replies, and
/// saves conversations ([ConversationSnapshot]). Model delivery: a [ModelManager] lists, downloads, checks and keeps
/// model files from a [ModelCatalog].
library;

export 'src/agent/assistant.dart' show Assistant, AssistantTurn;
export 'src/agent/config.dart';
export 'src/agent/confirmation.dart';
export 'src/agent/context_lines.dart';
export 'src/agent/conversation_store.dart';
export 'src/agent/events.dart';
export 'src/agent/guards.dart';
export 'src/agent/hooks.dart';
export 'src/agent/lists.dart' hide ListLedger;
export 'src/agent/model_view.dart' show ModelView;
export 'src/agent/prompt_layout.dart';
export 'src/agent/replies.dart';
export 'src/agent/screen_requests.dart';
export 'src/agent/snapshot.dart' show ConversationSnapshot;
export 'src/agent/state.dart';
export 'src/agent/strings.dart';
export 'src/agent/tool_host.dart';
export 'src/agent/tool_result.dart';
export 'src/agent/toolkit.dart';
export 'src/agent/yes_no.dart';
export 'src/delivery/catalog.dart';
export 'src/delivery/device.dart' show DartDeviceProbe, DeviceCapabilities, DeviceProbe;
export 'src/delivery/downloader.dart';
export 'src/delivery/http_downloader.dart';
export 'src/delivery/manifest.dart';
export 'src/delivery/manifest_fetch.dart';
export 'src/delivery/model_manager.dart';
export 'src/engine/engine_info.dart';
export 'src/engine/exceptions.dart';
export 'src/engine/generation.dart';
export 'src/engine/inference_engine.dart';
export 'src/engine/options.dart';
export 'src/grammar/gbnf_rules.dart';
export 'src/grammar/grammar_options.dart';
export 'src/grammar/json_rules.dart' show jsonSchemaGrammar;
export 'src/llamadart/llamadart_engine.dart';
export 'src/llamadart/llamadart_families.dart' show LlamadartFamilyProfile;
export 'src/model/chat_message.dart';
export 'src/model/chat_model.dart';
export 'src/model/chat_template.dart';
export 'src/model/model_profile.dart';
export 'src/model/prefix/file_prefix_state_store.dart' show FilePrefixStateStore;
export 'src/model/prefix/model_identity.dart';
export 'src/model/prefix/prefix_cache.dart';
export 'src/model/prefix/prefix_key.dart';
export 'src/model/prefix/prefix_state_store.dart';
export 'src/model/python_json.dart';
export 'src/model/qwen_xml_format.dart';
export 'src/model/tool_call.dart';
export 'src/model/tool_call_format.dart';
export 'src/model/tool_schema.dart';
export 'src/model/tool_spec.dart';
export 'src/model/validator.dart' show validateArguments;
export 'src/util/change_source.dart' show ChangeSource;
export 'src/version.dart';
