/// What is specific to a model family above the engine: template, tool-call envelope, stop strings, prefix rule.
library;

import '../engine/engine_info.dart';
import '../engine/exceptions.dart';
import '../engine/options.dart';
import '../grammar/grammar_options.dart';
import '../grammar/json_rules.dart';
import '../llamadart/llamadart_families.dart';
import 'chat_message.dart';
import 'chat_template.dart';
import 'qwen_xml_format.dart';
import 'tool_call_format.dart';
import 'tool_spec.dart';

/// Whether a generation may call tools, and how the grammar holds it.
enum ToolMode {
  /// The model may answer or call a tool: the grammar applies from the envelope's first tag (lazy).
  auto,

  /// The model must call a tool: the grammar applies from the first token (eager).
  required,

  /// No grammar; the tools are still rendered in the prompt.
  none,
}

/// A rendered prompt and what its generation needs: the grammar, stop strings and preserved tokens.
final class PreparedPrompt {
  const PreparedPrompt({required this.prompt, this.grammar, this.stop = const [], this.preservedTokens = const []});

  /// The prompt text, rendered by the model's template.
  final String prompt;

  /// The grammar the answer must follow; null for free text.
  final Grammar? grammar;

  /// Strings that end the answer.
  final List<String> stop;

  /// Special strings kept whole while the grammar applies.
  final List<String> preservedTokens;

  /// The engine options of a generation with [sampling].
  GenerationOptions options(SamplingOptions sampling) =>
      GenerationOptions(sampling: sampling, stop: stop, grammar: grammar, preservedTokens: preservedTokens);

  @override
  String toString() => 'PreparedPrompt(${prompt.length} chars, grammar: $grammar, stop: $stop)';
}

/// A model family: how its prompts are rendered, how it calls tools, how its answers are parsed and shown, and how
/// its context is reused.
abstract class ModelProfile {
  const ModelProfile();

  /// A short name of the family, for logs.
  String get id;

  /// Whether [info] is a model of this family.
  bool matches(EngineInfo info);

  /// Whether the runtime can reuse a shared prompt prefix of [info]'s context (false for recurrent and hybrid
  /// architectures: a saved prefix state is then restored before every call).
  bool canRewind(EngineInfo info) => !info.isRecurrent;

  /// The stable prefix of a prompt (system prompt and tool block) ends after the first occurrence of this text;
  /// null lets `ChatModel.stablePrefix` compare two renderings.
  String? get prefixMarker;

  /// Template variables of every render. The built-in profiles pass `{'enable_thinking': false}`.
  Map<String, Object?> get templateVariables;

  /// The sampling of a generation that does not pass its own.
  SamplingOptions get sampling;

  /// The template of [info]'s model. Throws [UnsupportedModelException] when the model has none or it is not
  /// accepted.
  ChatTemplate templateFor(EngineInfo info);

  /// [messages] rendered with [tools] in the prompt, and the grammar [mode] asks for: [ToolMode.auto] a lazy tool-call
  /// grammar, [ToolMode.required] an eager one, [ToolMode.none] (or no tools) none. A [responseSchema] asks for an
  /// eager JSON grammar instead, whatever the tools.
  PreparedPrompt prepare(
    EngineInfo info,
    List<ChatMessage> messages, {
    List<ToolSpec> tools = const [],
    ToolMode mode = ToolMode.auto,
    GrammarOptions grammar = const GrammarOptions(),
    Map<String, Object?>? responseSchema,
    bool addGenerationPrompt = true,
  });

  /// A complete answer to [prompt], parsed with [tools]' schemas.
  ParsedOutput parse(String raw, List<ToolSpec> tools, PreparedPrompt prompt);

  /// The text of a partial answer to show; null while nothing should be shown.
  String? visibleText(String partialRaw, PreparedPrompt prompt);

  /// The profile of [info]'s model: [Qwen35Profile] when it matches, else [LlamadartFamilyProfile] when llamadart
  /// knows the tool calls of its template's format, else [TextOnlyProfile].
  static ModelProfile detect(EngineInfo info) {
    if (const Qwen35Profile().matches(info)) return const Qwen35Profile();
    return LlamadartFamilyProfile.detect(info) ?? const TextOnlyProfile();
  }
}

/// Qwen3.5: ChatML with the Qwen3-Coder XML tool envelope ([QwenXmlToolFormat]), stop `<|im_end|>`, thinking off.
///
/// It matches a template holding `<|im_start|>`, `<function=` and `<parameter=`. [acceptedTemplateSha256], when set,
/// is the set of template hashes a fine-tune was trained with: another template is refused.
final class Qwen35Profile extends ModelProfile {
  const Qwen35Profile({this.acceptedTemplateSha256});

  /// The template SHA-256s accepted; null accepts any.
  final Set<String>? acceptedTemplateSha256;

  static const QwenXmlToolFormat _format = QwenXmlToolFormat();

  @override
  String get id => 'qwen3.5';

  @override
  bool matches(EngineInfo info) {
    final template = info.chatTemplate;
    return template != null &&
        template.contains('<|im_start|>') &&
        template.contains('<function=') &&
        template.contains('<parameter=');
  }

  @override
  String? get prefixMarker => '<|im_start|>user\n';

  /// `{'enable_thinking': false}`, always explicit: Qwen3.5-2B's template opens a think block only when it is true,
  /// the 4B's unless it is false.
  @override
  Map<String, Object?> get templateVariables => const {'enable_thinking': false};

  @override
  SamplingOptions get sampling => const SamplingOptions();

  @override
  ChatTemplate templateFor(EngineInfo info) {
    final template = _templateOf(info);
    final accepted = acceptedTemplateSha256;
    if (accepted != null && !accepted.contains(template.sha256)) {
      throw UnsupportedModelException(
        'the chat template of ${info.modelPath} (sha256 ${template.sha256}) is not an accepted one '
        '(${accepted.join(', ')})',
      );
    }
    return template;
  }

  @override
  PreparedPrompt prepare(
    EngineInfo info,
    List<ChatMessage> messages, {
    List<ToolSpec> tools = const [],
    ToolMode mode = ToolMode.auto,
    GrammarOptions grammar = const GrammarOptions(),
    Map<String, Object?>? responseSchema,
    bool addGenerationPrompt = true,
  }) {
    final prompt = templateFor(info).render(
      messages,
      tools: [for (final tool in tools) tool.declaration],
      addGenerationPrompt: addGenerationPrompt,
      variables: templateVariables,
    );
    final Grammar? constraint;
    if (responseSchema != null) {
      constraint = Grammar(jsonSchemaGrammar(responseSchema, grammar));
    } else if (tools.isEmpty || mode == ToolMode.none) {
      constraint = null;
    } else {
      final text = _format.grammar(tools, grammar);
      constraint = mode == ToolMode.auto ? Grammar(text, triggers: _format.triggers) : Grammar(text);
    }
    return PreparedPrompt(
      prompt: prompt,
      grammar: constraint,
      stop: const ['<|im_end|>'],
      preservedTokens: constraint == null ? const [] : _format.preservedTokens,
    );
  }

  @override
  ParsedOutput parse(String raw, List<ToolSpec> tools, PreparedPrompt prompt) => _format.parse(raw, tools);

  @override
  String? visibleText(String partialRaw, PreparedPrompt prompt) => _format.visibleText(partialRaw);

  @override
  String toString() => 'Qwen35Profile(accepted: ${acceptedTemplateSha256 ?? 'any'})';
}

/// Any chat model, for plain text: its own template, no tool-call envelope, no stop strings (the model's end token
/// ends an answer). A structured response (`responseSchema`) works; tools with a [ToolMode] other than
/// [ToolMode.none] throw [UnsupportedModelException].
final class TextOnlyProfile extends ModelProfile {
  const TextOnlyProfile();

  static final RegExp _thinkBlock = RegExp(r'<think>(.*?)</think>', dotAll: true);

  @override
  String get id => 'text';

  @override
  bool matches(EngineInfo info) => info.chatTemplate?.isNotEmpty ?? false;

  @override
  String? get prefixMarker => null;

  @override
  Map<String, Object?> get templateVariables => const {'enable_thinking': false};

  @override
  SamplingOptions get sampling => const SamplingOptions();

  @override
  ChatTemplate templateFor(EngineInfo info) => _templateOf(info);

  @override
  PreparedPrompt prepare(
    EngineInfo info,
    List<ChatMessage> messages, {
    List<ToolSpec> tools = const [],
    ToolMode mode = ToolMode.auto,
    GrammarOptions grammar = const GrammarOptions(),
    Map<String, Object?>? responseSchema,
    bool addGenerationPrompt = true,
  }) {
    if (responseSchema == null && tools.isNotEmpty && mode != ToolMode.none) {
      // As the runtime detected it at load, else llamadart's reading of the template (an engine without details).
      final family = info.runtimeDetails['llamadart.chat_format'] ?? llamadartChatFormat(info.chatTemplate) ?? 'none';
      throw UnsupportedModelException(
        'no tool-call format for ${info.modelPath} (template family $family): use ToolMode.none or a profile that '
        'knows its envelope',
      );
    }
    final prompt = templateFor(info).render(
      messages,
      tools: [for (final tool in tools) tool.declaration],
      addGenerationPrompt: addGenerationPrompt,
      variables: templateVariables,
    );
    return PreparedPrompt(
      prompt: prompt,
      grammar: responseSchema == null ? null : Grammar(jsonSchemaGrammar(responseSchema, grammar)),
    );
  }

  /// The first think block is the reasoning; the rest, trimmed, is the text. No tool calls.
  @override
  ParsedOutput parse(String raw, List<ToolSpec> tools, PreparedPrompt prompt) {
    final think = _thinkBlock.firstMatch(raw);
    final reasoning = think?.group(1)!.trim();
    final text = think == null ? raw : raw.replaceFirst(_thinkBlock, '');
    return ParsedOutput(text: text.trim(), reasoning: reasoning == null || reasoning.isEmpty ? null : reasoning);
  }

  /// The answer after a leading think block (null while the block is open), trimmed; `''` while the answer may still
  /// open one (a partial `<think>`), so nothing of the tag is shown.
  @override
  String? visibleText(String partialRaw, PreparedPrompt prompt) {
    final trimmed = partialRaw.trimLeft();
    if (trimmed.startsWith(_thinkTag)) {
      final end = trimmed.indexOf('</think>');
      return end < 0 ? null : trimmed.substring(end + '</think>'.length).trim();
    }
    if (_thinkTag.startsWith(trimmed)) return '';
    return trimmed.trimRight();
  }

  static const String _thinkTag = '<think>';

  @override
  String toString() => 'TextOnlyProfile()';
}

/// One parsed template per loaded model (an [EngineInfo] lives as long as its load).
final Expando<JinjaChatTemplate> _templates = Expando('chat templates');

JinjaChatTemplate _templateOf(EngineInfo info) {
  final cached = _templates[info];
  if (cached != null) return cached;
  final source = info.chatTemplate;
  if (source == null || source.isEmpty) {
    throw UnsupportedModelException('${info.modelPath} has no chat template (tokenizer.chat_template)');
  }
  // bos_token / eos_token when the runtime reports their text (the llama.cpp metadata has only their ids).
  final globals = <String, Object?>{
    'bos_token': ?info.metadata['tokenizer.ggml.bos_token'],
    'eos_token': ?info.metadata['tokenizer.ggml.eos_token'],
  };
  return _templates[info] = JinjaChatTemplate(source, globals: globals);
}
