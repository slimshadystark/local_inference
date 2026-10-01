/// Tool calling for the model families llamadart 0.8.23 knows (best effort: Qwen3.5 is the validated family), through
/// its own chat-format handlers. With llamadart_engine.dart, the only file of local_inference that imports llamadart.
library;

import 'dart:convert';
import 'dart:math' as math;

import 'package:dinja/dinja.dart' show Template;
import 'package:llamadart/llamadart.dart' as ll;

import '../engine/engine_info.dart';
import '../engine/exceptions.dart';
import '../engine/options.dart';
import '../grammar/grammar_options.dart';
import '../grammar/json_rules.dart';
import '../model/chat_message.dart';
import '../model/chat_template.dart';
import '../model/json_values.dart';
import '../model/model_profile.dart';
import '../model/python_json.dart';
import '../model/tool_call.dart';
import '../model/tool_call_format.dart';
import '../model/tool_spec.dart';

/// llamadart's name of the chat format of [template] (`ChatTemplateEngine.detectFormat`), for example `gemma4`;
/// null when there is no template. Internal: for messages.
String? llamadartChatFormat(String? template) =>
    template == null || template.isEmpty ? null : ll.ChatTemplateEngine.detectFormat(template).name;

/// A model family whose tool calls llamadart's template engine knows: Gemma 4, Hermes (Qwen 2.5 and 3), Llama 3.x,
/// Mistral, LFM2, Granite, DeepSeek, GPT-OSS and about 30 more ([families]).
///
/// Prompts are rendered by `ChatTemplateEngine.render` with the model's own template; the grammar (lazy with its
/// triggers, or eager), the stop strings and the preserved tokens are the family handler's; answers are read by
/// `ChatTemplateEngine.parse`. What the mapping to llamadart does:
/// - The tools go to llamadart as its tool definitions carrying the full schema: the prompt's tool block is
///   `ToolSpec.declaration` (where the template writes it with `tojson`, in Python's `json.dumps` form as Hugging Face
///   renders it, not dinja's compact JSON) and most families' grammars come from the full `ToolSpec.parameters` (`x-*`
///   keywords dropped). The definitions' `ToolParam` list cannot carry `anyOf`, `additionalProperties`,
///   `minimum`/`maximum`, patterns, lengths or non-string enums, and has no key order: GLM 4.5 and Hunyuan V3 write one
///   grammar rule per parameter from it and lose them, and the XML formats (Seed-OSS, MiniCPM 5, MiniMax M2, Xiaomi
///   MiMo, Apriel 1.5, Qwen3-Coder) constrain only the tool and parameter names, any JSON value going. llamadart's
///   JSON-schema grammars have no integer ranges or patterns either. The parsed arguments are validated against the
///   full schema by the caller (`validateArguments`, the assistant's toolkit).
/// - [ToolMode.auto] uses the family's grammar for `auto` (Gemma 4, LFM2 and FunctionGemma have none: the answer is
///   free and the parser finds the call; llama.cpp itself constrains Gemma 4 lazily), [ToolMode.required] its grammar
///   for `required` (eager for most; for Gemma 4 its call with JSON arguments, for LFM2 a JSON list with an `id`, not
///   the syntax these models write), and [ToolMode.none] renders as `auto` (the tools stay in the prompt, as with every
///   profile) with no grammar. A `responseSchema` gives the eager JSON grammar every profile uses
///   (`jsonSchemaGrammar`), with the prompt of [ToolMode.auto]; `GrammarOptions` apply only there.
/// - Thinking is off ([thinking] false) where the template has a switch.
/// - Where llamadart 0.8.23 gets a family wrong, the profile does it:
///   - Gemma 4: a tool result goes to the template as the tool message's text with the tool's name (llamadart's
///     `tool_responses` are not read by Gemma 4's templates: the result renders as `value:null`); a prompt that ends
///     with a closed model turn gets the generation prompt the template leaves out (after a tool response to a message
///     that also had text), as llama.cpp adds it; the strings of a call (`<|"|>…<|"|>`) are read verbatim, as
///     llama.cpp reads them (llamadart's pseudo-JSON pass loses the arguments when a string holds a comma and a colon,
///     a quote or a line break).
///   - LFM2: the calls are read by the profile, a JSON list or LFM2's Python-style list with its escapes (llamadart
///     drops a call without arguments, with every call listed next to it, and keeps the escapes).
///   - Gemma 4, LFM2 and FunctionGemma get a past call's arguments as a mapping (llamadart passes JSON text, which
///     LFM2.5's template refuses and Gemma 4's and FunctionGemma's write as JSON instead of their call syntax).
/// - A call that cannot be read is a [ParsedOutput.error], never dropped in silence; the text stops at the family's
///   own call opener (its grammar triggers, Gemma 4's `<|tool_call>`, LFM2's `<|tool_call_start|>`), or at any opener
///   llamadart's streaming knows for a family without one.
///
/// [ModelProfile.detect] picks it after [Qwen35Profile]: a template llamadart reads as a format with tool calls,
/// not its generic or content-only formats (nor Gemma 3, whose tool calls llamadart routes to the generic one).
final class LlamadartFamilyProfile extends ModelProfile {
  /// The profile of [family], one of [families]; [thinking] turns the template's reasoning on. Throws
  /// [ArgumentError] for any other name.
  factory LlamadartFamilyProfile(String family, {bool thinking = false}) {
    final format = ll.ChatFormat.values.where((format) => format.name == family).firstOrNull;
    if (format == null || !_hasToolCalls(format)) {
      throw ArgumentError.value(family, 'family', 'not a llamadart chat format with tool calls ($families)');
    }
    return LlamadartFamilyProfile._(format, thinking);
  }

  const LlamadartFamilyProfile._(this._format, this.thinking);

  /// The profile of [info]'s model when llamadart reads its template as a format with tool calls; null otherwise
  /// (no template, or a generic or content-only format).
  static LlamadartFamilyProfile? detect(EngineInfo info, {bool thinking = false}) {
    final format = _toolFormatOf(info.chatTemplate);
    return format == null ? null : LlamadartFamilyProfile._(format, thinking);
  }

  /// The families this profile takes: llamadart's chat formats with tool calls, by name.
  static List<String> get families => [
    for (final format in ll.ChatFormat.values)
      if (_hasToolCalls(format)) format.name,
  ];

  final ll.ChatFormat _format;

  /// Whether the template's reasoning (thinking) is on; off by default where the template has a switch.
  final bool thinking;

  /// llamadart's name of the family's chat format, for example `gemma4`.
  String get family => _format.name;

  @override
  String get id => 'llamadart:$family';

  @override
  bool matches(EngineInfo info) => _toolFormatOf(info.chatTemplate) == _format;

  /// Null: the stable prefix is found by comparing two renderings.
  @override
  String? get prefixMarker => null;

  @override
  Map<String, Object?> get templateVariables => {'enable_thinking': thinking};

  @override
  SamplingOptions get sampling => const SamplingOptions();

  /// A template that renders through llamadart, as [prepare] does. Throws [UnsupportedModelException] when the model
  /// has no template or llamadart reads it as another format.
  @override
  ChatTemplate templateFor(EngineInfo info) => _FamilyTemplate(this, info, _sourceOf(info));

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
    final definitions = [for (final tool in tools) _SpecTool.of(tool)];
    final (:rendered, :prompt) = _render(
      info,
      messages,
      definitions,
      required: mode == ToolMode.required && responseSchema == null,
      addGenerationPrompt: addGenerationPrompt,
    );
    final Grammar? constraint;
    if (responseSchema != null) {
      constraint = Grammar(jsonSchemaGrammar(responseSchema, grammar));
    } else if (tools.isEmpty || mode == ToolMode.none) {
      constraint = null;
    } else {
      constraint = _grammarOf(rendered);
    }
    final prepared = PreparedPrompt(
      prompt: prompt,
      grammar: constraint,
      stop: List.unmodifiable(rendered.additionalStops),
      preservedTokens: List.unmodifiable(rendered.preservedTokens),
    );
    final openers = [
      for (final trigger in rendered.grammarTriggers)
        if (trigger.type == 0 || trigger.type == 1) trigger.value,
      ...?_callOpeners[_format],
    ];
    final patterns = [
      for (final trigger in rendered.grammarTriggers)
        if (trigger.type == 2 || trigger.type == 3) ?_regExp(trigger.value),
    ];
    _answers[prepared] = _Answers(
      format: rendered.format,
      thinkingForcedOpen: rendered.thinkingForcedOpen,
      parser: rendered.parser,
      tools: definitions,
      openers: openers.isEmpty && patterns.isEmpty ? _commonOpeners : openers,
      patterns: patterns,
      eager: responseSchema == null && constraint != null && !constraint.isLazy,
      structured: responseSchema != null,
    );
    return prepared;
  }

  /// `ChatTemplateEngine.parse` of [raw]: the text (trimmed), the calls (their JSON arguments decoded) and the
  /// reasoning; LFM2's calls are read by the profile, and Gemma 4's strings made readable first. A call that cannot be
  /// read (arguments that are not an object, or lost; an envelope the parser skipped) is left out with a
  /// [ParsedOutput.error]; so is a call opener left in the text, and the text stops before it.
  @override
  ParsedOutput parse(String raw, List<ToolSpec> tools, PreparedPrompt prompt) {
    final answers = _answers[prompt];
    final thinkingForcedOpen = answers?.thinkingForcedOpen ?? false;
    final gemma = _format == ll.ChatFormat.gemma4 && tools.isNotEmpty
        ? _GemmaAnswer.of(raw, thinkingForcedOpen: thinkingForcedOpen)
        : null;
    final ll.ChatParseResult parsed;
    try {
      parsed = ll.ChatTemplateEngine.parse(
        answers?.format ?? _format.index,
        gemma?.text ?? raw,
        parseToolCalls: tools.isNotEmpty,
        thinkingForcedOpen: thinkingForcedOpen,
        parser: answers?.parser,
        tools: tools.isEmpty ? null : [for (final tool in tools) _SpecTool.of(tool)],
      );
    } catch (e) {
      return ParsedOutput(text: '', error: 'llamadart cannot read the answer as $family: $e');
    }
    final calls = <ToolCall>[];
    String? error;
    if (_format == ll.ChatFormat.lfm2 && tools.isNotEmpty) {
      for (final envelope in _lfm2Envelope.allMatches(raw)) {
        final read = _lfm2Calls(envelope.group(1)!);
        if (read == null) {
          error ??= 'a tool call that cannot be read: ${_snippet(envelope.group(0)!)}';
        } else {
          calls.addAll(read);
        }
      }
    } else {
      for (final (i, call) in parsed.toolCalls.indexed) {
        final name = call.function?.name;
        final arguments = call.function?.arguments;
        if (name == null || name.isEmpty) {
          error ??= 'a tool call without a name';
          continue;
        }
        final decoded = _decodeObject(arguments);
        if (decoded == null) {
          error ??= 'the arguments of $name are not a JSON object: $arguments';
          continue;
        }
        if (decoded.isEmpty && gemma != null && i < gemma.envelopes.length && gemma.envelopes[i].hasArguments) {
          error ??= 'the arguments of $name cannot be read: ${_snippet(gemma.envelopes[i].text)}';
          continue;
        }
        calls.add(ToolCall(name, decoded));
      }
      if (gemma != null && parsed.toolCalls.length < gemma.envelopes.length) {
        error ??= 'a tool call that cannot be read: ${_snippet(gemma.envelopes[parsed.toolCalls.length].text)}';
      }
    }
    var text = parsed.content;
    if (tools.isNotEmpty && answers != null && !answers.structured) {
      final end = _toolCallStart(text, answers);
      if (end < text.length) {
        error ??= 'a tool call llamadart could not read: ${_snippet(text.substring(end))}';
        text = text.substring(0, end);
      }
    }
    final reasoning = parsed.reasoningContent?.trim();
    return ParsedOutput(
      text: text.trim(),
      toolCalls: calls,
      reasoning: reasoning == null || reasoning.isEmpty ? null : reasoning,
      error: error,
    );
  }

  /// The partial parse's text, trimmed, up to the first sign of a tool call (the family's trigger words and
  /// patterns, and the envelopes llamadart's own streaming holds back), with a partial one at the end held back;
  /// `''` while an eager tool grammar holds the answer; null while the handler cannot read the answer yet.
  @override
  String? visibleText(String partialRaw, PreparedPrompt prompt) {
    final answers = _answers[prompt];
    final ll.ChatParseResult parsed;
    try {
      parsed = ll.ChatTemplateEngine.parse(
        answers?.format ?? _format.index,
        partialRaw,
        isPartial: true,
        parseToolCalls: answers != null && answers.tools.isNotEmpty,
        thinkingForcedOpen: answers?.thinkingForcedOpen ?? false,
        parser: answers?.parser,
        tools: answers == null || answers.tools.isEmpty ? null : answers.tools,
      );
    } catch (_) {
      return null;
    }
    if (answers == null || answers.structured || answers.tools.isEmpty) return parsed.content.trim();
    if (answers.eager) return '';
    final text = parsed.content;
    final visible = text.substring(0, _toolCallStart(text, answers));
    return visible.substring(0, visible.length - _heldBack(visible, answers.openers)).trim();
  }

  @override
  bool operator ==(Object other) =>
      other is LlamadartFamilyProfile && other._format == _format && other.thinking == thinking;

  @override
  int get hashCode => Object.hash(LlamadartFamilyProfile, _format, thinking);

  @override
  String toString() => 'LlamadartFamilyProfile($family${thinking ? ', thinking' : ''})';

  /// [messages] rendered by llamadart with [tools] (`auto`, or `required`), and the prompt: llamadart's, with each
  /// tool that dinja's `tojson` wrote compact in Python's `json.dumps` form (as Hugging Face's `tojson` writes it),
  /// and for Gemma 4 the generation prompt its template leaves out when the prompt ends with a closed model turn (a
  /// tool response to a message that also had text), which llama.cpp adds too.
  ({ll.LlamaChatTemplateResult rendered, String prompt}) _render(
    EngineInfo info,
    List<ChatMessage> messages,
    List<ll.ToolDefinition> tools, {
    bool required = false,
    bool addGenerationPrompt = true,
    Map<String, Object?> variables = const {},
  }) {
    final source = _sourceOf(info);
    final ll.LlamaChatTemplateResult rendered;
    try {
      rendered = ll.ChatTemplateEngine.render(
        templateSource: source,
        messages: _messages(messages),
        metadata: info.metadata,
        addAssistant: addGenerationPrompt,
        tools: tools.isEmpty ? null : tools,
        toolChoice: required ? ll.ToolChoice.required : ll.ToolChoice.auto,
        enableThinking: thinking,
        chatTemplateKwargs: {...templateVariables, ...variables},
      );
    } catch (e) {
      throw UnsupportedModelException('llamadart cannot render a $family prompt for ${info.modelPath}', cause: e);
    }
    var prompt = _pythonToolJson(rendered.prompt, tools);
    if (_format == ll.ChatFormat.gemma4 && addGenerationPrompt && prompt.endsWith('<turn|>\n')) {
      prompt += '<|turn>model\n';
    }
    return (rendered: rendered, prompt: prompt);
  }

  /// [prompt] with the first occurrence of each compact `tojson` text of [tools] (the list, each tool's entry as the
  /// handlers hand it over: the declaration, its function, LFM2's flat entry) in Python's `json.dumps` form, longest
  /// first: dinja's `tojson` is compact where Hugging Face's has `", "` and `": "`.
  static String _pythonToolJson(String prompt, List<ll.ToolDefinition> tools) {
    if (tools.isEmpty) return prompt;
    final declarations = [for (final tool in tools) tool.toJson()];
    final flat = [
      for (final tool in tools) {'name': tool.name, 'description': tool.description, 'parameters': tool.toJsonSchema()},
    ];
    final functions = [
      for (final declaration in declarations)
        if (declaration['function'] case final Map<Object?, Object?> function) function,
    ];
    var out = prompt;
    final seen = <String>{};
    for (final value in <Object>[declarations, flat, ...declarations, ...functions, ...flat]) {
      final compact = _tojson.render({'value': value});
      if (!seen.add(compact) || !out.contains(compact)) continue;
      final python = pythonJson(value);
      if (python != compact) out = out.replaceFirst(compact, python);
    }
    return out;
  }

  static final Template _tojson = Template('{{ value | tojson }}');

  /// The model's template; throws when there is none or llamadart reads it as another format.
  String _sourceOf(EngineInfo info) {
    final source = info.chatTemplate;
    if (source == null || source.isEmpty) {
      throw UnsupportedModelException('${info.modelPath} has no chat template (tokenizer.chat_template)');
    }
    final format = ll.ChatTemplateEngine.detectFormat(source);
    if (format != _format) {
      throw UnsupportedModelException(
        'llamadart reads the chat template of ${info.modelPath} as ${format.name}, not $family',
      );
    }
    return source;
  }

  /// [messages] as llamadart's. A tool message answers the next unanswered call of the assistant message before it
  /// (its id; its name when the message has none). Call ids are `call00000`, `call00001`, … in conversation order:
  /// the same conversation always renders the same (Mistral's templates want 9 alphanumeric characters).
  List<ll.LlamaChatMessage> _messages(List<ChatMessage> messages) {
    final out = <ll.LlamaChatMessage>[];
    final unanswered = <(String, String)>[];
    var calls = 0;
    for (final message in messages) {
      switch (message.role) {
        case MessageRole.system:
          out.add(ll.LlamaChatMessage.fromText(role: ll.LlamaChatRole.system, text: message.content));
        case MessageRole.user:
          out.add(ll.LlamaChatMessage.fromText(role: ll.LlamaChatRole.user, text: message.content));
        case MessageRole.assistant:
          unanswered.clear();
          final parts = <ll.LlamaContentPart>[
            if (message.reasoning case final reasoning?) ll.LlamaThinkingContent(reasoning),
            if (message.content.isNotEmpty) ll.LlamaTextContent(message.content),
            for (final call in message.toolCalls) _callPart(call, 'call${(calls++).toString().padLeft(5, '0')}'),
          ];
          for (final part in parts) {
            if (part is ll.LlamaToolCallContent) unanswered.add((part.id!, part.name));
          }
          out.add(
            parts.isEmpty
                ? const ll.LlamaChatMessage.fromText(role: ll.LlamaChatRole.assistant, text: '')
                : ll.LlamaChatMessage.withContent(role: ll.LlamaChatRole.assistant, content: parts),
          );
        case MessageRole.tool:
          final (String? id, String? called) = unanswered.isEmpty ? (null, null) : unanswered.removeAt(0);
          final name = message.name ?? called ?? 'tool';
          out.add(
            _format == ll.ChatFormat.gemma4
                ? _TextToolResult(message.content, name: name, id: id)
                : ll.LlamaChatMessage.withContent(
                    role: ll.LlamaChatRole.tool,
                    content: [ll.LlamaToolResultContent(id: id, name: name, result: message.content)],
                  ),
          );
      }
    }
    return out;
  }

  ll.LlamaToolCallContent _callPart(ToolCall call, String id) {
    final arguments = Map<String, dynamic>.of(call.arguments);
    final rawJson = jsonEncode(call.arguments);
    return _objectArguments.contains(_format)
        ? _ObjectArgumentsCall(id: id, name: call.name, arguments: arguments, rawJson: rawJson)
        : ll.LlamaToolCallContent(id: id, name: call.name, arguments: arguments, rawJson: rawJson);
  }

  /// The families whose templates read a past call's arguments as a mapping, which llamadart 0.8.23 hands them as JSON
  /// text: Gemma 4 and FunctionGemma write their own call syntax from the mapping (from text, JSON), LFM2.5 refuses
  /// text.
  static const Set<ll.ChatFormat> _objectArguments = {
    ll.ChatFormat.gemma4,
    ll.ChatFormat.lfm2,
    ll.ChatFormat.functionGemma,
  };

  /// The call openers of the families whose `auto` rendering has no grammar trigger.
  static const Map<ll.ChatFormat, List<String>> _callOpeners = {
    ll.ChatFormat.gemma4: ['<|tool_call>'],
    ll.ChatFormat.lfm2: ['<|tool_call_start|>'],
  };

  /// An LFM2 tool-call envelope, as llamadart's handler finds it.
  static final RegExp _lfm2Envelope = RegExp(r'<\|tool_call_start\|>\s*(.*?)\s*<\|tool_call_end\|>', dotAll: true);

  /// The formats whose tool calls this profile cannot use: llamadart's unknown and generic formats (the generic one
  /// prompts for JSON and replaces the system prompt with its instruction), the parser-only formats, Gemma 3 (llamadart
  /// routes its tool calls to the generic format) and TranslateGemma (no tools).
  static const Set<ll.ChatFormat> _withoutToolCalls = {
    ll.ChatFormat.contentOnly,
    ll.ChatFormat.generic,
    ll.ChatFormat.pegSimple,
    ll.ChatFormat.pegNative,
    ll.ChatFormat.pegConstructed,
    ll.ChatFormat.gemma,
    ll.ChatFormat.translateGemma,
  };

  static bool _hasToolCalls(ll.ChatFormat format) => !_withoutToolCalls.contains(format);

  static ll.ChatFormat? _toolFormatOf(String? template) {
    if (template == null || template.isEmpty) return null;
    final format = ll.ChatTemplateEngine.detectFormat(template);
    return _hasToolCalls(format) ? format : null;
  }

  /// The texts that start a tool call in many families, as llamadart's own streaming parser looks for them: the
  /// openers of a family without its own.
  static const List<String> _commonOpeners = [
    '<tool_call',
    '<|tool_call',
    '<function',
    '<start_function_call',
    '<|python_tag|>',
    '[TOOL_CALLS]',
    '<|START_ACTION|>',
    '<TOOLCALL>',
    '<|tool_calls_section_begin|>',
    '<minimax:tool_call>',
    '<seed:tool_call>',
    '<｜tool▁calls▁begin｜>',
  ];

  /// What the answers to each prepared prompt need: kept with the prompt, which the profile's callers hand back.
  static final Expando<_Answers> _answers = Expando('llamadart answers');
}

/// How the answers to one prepared prompt are read.
final class _Answers {
  const _Answers({
    required this.format,
    required this.thinkingForcedOpen,
    required this.parser,
    required this.tools,
    required this.openers,
    required this.patterns,
    required this.eager,
    required this.structured,
  });

  /// llamadart's format index of the rendering.
  final int format;

  /// Whether the prompt left a think block open.
  final bool thinkingForcedOpen;

  /// The PEG parser of the rendering, when the family has one.
  final String? parser;

  /// The tools of the prompt, as llamadart's definitions.
  final List<ll.ToolDefinition> tools;

  /// Texts that start a tool call: the family's own, else llamadart's common list.
  final List<String> openers;

  /// Patterns that match a tool call.
  final List<RegExp> patterns;

  /// Whether an eager tool grammar holds the whole answer.
  final bool eager;

  /// Whether the answer follows a response schema.
  final bool structured;
}

/// A [ToolSpec] as llamadart's tool definition: [toJson] is the tool-block entry, [toJsonSchema] the full schema
/// (both copied on every call: handlers may change what they get); `parameters` is a lossy `ToolParam` list.
final class _SpecTool extends ll.ToolDefinition {
  _SpecTool._(this._declaration, this._schema, {required super.name, required super.description})
    : super(parameters: _params(_schema), handler: _notRun);

  /// [spec]'s entry ([ToolSpec.declaration]) and its full parameters, `x-*` keywords dropped.
  factory _SpecTool.of(ToolSpec spec) {
    final derived = ToolSpec(name: spec.name, description: spec.description, parameters: spec.parameters).declaration;
    final schema = (derived['function']! as Map<String, Object?>)['parameters']! as Map<String, Object?>;
    return _SpecTool._(spec.declaration, schema, name: spec.name, description: spec.description);
  }

  /// A tool-block entry as a template reads it (`{'type': 'function', 'function': {name, description, parameters}}`).
  factory _SpecTool.declared(Map<String, Object?> declaration) {
    final function = declaration['function'];
    final fields = function is Map ? function.cast<String, Object?>() : declaration;
    final parameters = fields['parameters'];
    return _SpecTool._(
      declaration,
      parameters is Map ? parameters.cast<String, Object?>() : const {'type': 'object', 'properties': {}},
      name: switch (fields['name']) {
        final String name => name,
        _ => 'tool',
      },
      description: switch (fields['description']) {
        final String description => description,
        _ => '',
      },
    );
  }

  final Map<String, Object?> _declaration;
  final Map<String, Object?> _schema;

  @override
  Map<String, dynamic> toJsonSchema() => jsonCopy(_schema)! as Map<String, Object?>;

  @override
  Map<String, dynamic> toJson() => jsonCopy(_declaration)! as Map<String, Object?>;

  static Future<Object?> _notRun(ll.ToolParams params) =>
      throw StateError('local_inference runs tools itself, not through llamadart');

  static List<ll.ToolParam> _params(Map<String, Object?> schema) {
    final properties = schema['properties'];
    if (properties is! Map) return const [];
    final required = {...?(schema['required'] as List?)?.whereType<String>()};
    return [
      for (final MapEntry(:key, :value) in properties.entries)
        _param(
          key.toString(),
          value is Map ? value.cast<String, Object?>() : const {},
          required: required.contains(key),
        ),
    ];
  }

  /// [schema] as a `ToolParam`: a string enum, the scalar types, arrays and objects; anything else (a union, no
  /// type) as a string.
  static ll.ToolParam _param(String name, Map<String, Object?> schema, {bool required = false}) {
    final description = switch (schema['description']) {
      final String text => text,
      _ => null,
    };
    final values = schema['enum'];
    if (values is List && values.isNotEmpty && values.every((value) => value is String)) {
      return ll.ToolParam.enumType(name, values: values.cast<String>(), description: description, required: required);
    }
    return switch (schema['type']) {
      'integer' => ll.ToolParam.integer(name, description: description, required: required),
      'number' => ll.ToolParam.number(name, description: description, required: required),
      'boolean' => ll.ToolParam.boolean(name, description: description, required: required),
      'null' => ll.ToolParam.nullType(name, description: description, required: required),
      'array' => ll.ToolParam.array(
        name,
        itemType: _param('items', switch (schema['items']) {
          final Map<Object?, Object?> items => items.cast<String, Object?>(),
          _ => const {},
        }),
        description: description,
        required: required,
      ),
      'object' => ll.ToolParam.object(name, properties: _params(schema), description: description, required: required),
      _ => ll.ToolParam.string(name, description: description, required: required),
    };
  }
}

/// A tool result as a text message that still names its call (`tool_call_id`, `name`): what Gemma 4's templates read
/// (llamadart 0.8.23's Gemma 4 handler turns a `LlamaToolResultContent` into `tool_responses`, which they ignore).
final class _TextToolResult extends ll.LlamaChatMessage {
  const _TextToolResult(String text, {required this.name, required this.id})
    : super.fromText(role: ll.LlamaChatRole.tool, text: text);

  final String name;
  final String? id;

  @override
  Map<String, dynamic> toJson() => {...super.toJson(), 'tool_call_id': id, 'name': name};
}

/// A past tool call whose `arguments` reach the template as a mapping (llamadart's own part gives the JSON text).
final class _ObjectArgumentsCall extends ll.LlamaToolCallContent {
  const _ObjectArgumentsCall({required super.name, required super.arguments, required super.rawJson, super.id});

  @override
  Map<String, dynamic> toJson() => {
    'type': 'function',
    'function': {'name': name, 'arguments': arguments},
    'id': id,
  };
}

/// A template that renders through llamadart ([LlamadartFamilyProfile.templateFor]).
final class _FamilyTemplate implements ChatTemplate {
  _FamilyTemplate(this._profile, this._info, this.source) : sha256 = _info.chatTemplateSha256!;

  final LlamadartFamilyProfile _profile;
  final EngineInfo _info;

  @override
  final String source;

  @override
  final String sha256;

  @override
  String render(
    List<ChatMessage> messages, {
    List<Map<String, Object?>> tools = const [],
    bool addGenerationPrompt = true,
    Map<String, Object?> variables = const {},
  }) => _profile
      ._render(
        _info,
        messages,
        [for (final declaration in tools) _SpecTool.declared(declaration)],
        addGenerationPrompt: addGenerationPrompt,
        variables: variables,
      )
      .prompt;

  @override
  String toString() => 'llamadart ${_profile.family} template (${sha256.substring(0, 8)})';
}

/// [rendered]'s grammar: lazy with its triggers, or eager; null when there is none (or it is lazy with no trigger).
Grammar? _grammarOf(ll.LlamaChatTemplateResult rendered) {
  final gbnf = rendered.grammar;
  if (gbnf == null || gbnf.trim().isEmpty) return null;
  if (!rendered.grammarLazy) return Grammar(gbnf);
  final triggers = [for (final trigger in rendered.grammarTriggers) ?_trigger(trigger)];
  return triggers.isEmpty ? null : Grammar(gbnf, triggers: triggers);
}

GrammarTrigger? _trigger(ll.GrammarTrigger trigger) => switch (trigger.type) {
  0 => GrammarTrigger.word(trigger.value),
  1 => trigger.token == null ? GrammarTrigger.word(trigger.value) : GrammarTrigger.token(trigger.token!, trigger.value),
  2 => GrammarTrigger.pattern(trigger.value),
  3 => GrammarTrigger.patternFull(trigger.value),
  _ => null,
};

RegExp? _regExp(String pattern) {
  try {
    return RegExp(pattern);
  } on FormatException {
    return null;
  }
}

/// Where the first sign of a tool call is in [text]: an opener or a pattern match; [text]'s length when none.
int _toolCallStart(String text, _Answers answers) {
  var start = text.length;
  for (final opener in answers.openers) {
    final at = text.indexOf(opener);
    if (at >= 0 && at < start) start = at;
  }
  for (final pattern in answers.patterns) {
    final match = pattern.firstMatch(text);
    if (match != null && match.start < start) start = match.start;
  }
  return start;
}

/// How many characters at the end of [text] may be the start of one of [openers].
int _heldBack(String text, List<String> openers) {
  var held = 0;
  for (final opener in openers) {
    for (var n = math.min(opener.length - 1, text.length); n > held; n--) {
      if (text.endsWith(opener.substring(0, n))) {
        held = n;
        break;
      }
    }
  }
  return held;
}

/// [text]'s start, for a message.
String _snippet(String text) => text.length <= 80 ? text : '${text.substring(0, 80)}…';

/// [arguments] (JSON text) as an object; `{}` for none; null when it is not a JSON object.
Map<String, Object?>? _decodeObject(String? arguments) {
  if (arguments == null || arguments.trim().isEmpty) return const {};
  try {
    final decoded = jsonDecode(arguments);
    if (decoded is! Map) return null;
    return {for (final entry in decoded.entries) entry.key.toString(): entry.value};
  } on FormatException {
    return null;
  }
}

/// A Gemma 4 answer made readable by llamadart 0.8.23's call parser, whose pseudo-JSON pass replaces the `<|"|>`
/// quotes without escaping what is inside and quotes any `word:` after a comma or a brace, inside strings too: in each
/// `<|tool_call>` envelope, every string (`<|"|>…<|"|>` taken verbatim, as llama.cpp reads it, or a JSON string)
/// becomes a JSON string whose commas, braces and `<` are `\u` escapes. Thought channels are left as they are.
final class _GemmaAnswer {
  _GemmaAnswer._(this.text, this.envelopes);

  factory _GemmaAnswer.of(String raw, {required bool thinkingForcedOpen}) {
    final out = StringBuffer();
    final envelopes = <({String text, bool hasArguments})>[];
    var at = 0;
    if (thinkingForcedOpen) at = _after(raw, _channelEnd, 0);
    out.write(raw.substring(0, at));
    while (at < raw.length) {
      final call = raw.indexOf(_callStart, at);
      if (call < 0) break;
      final channel = raw.indexOf(_channelStart, at);
      if (channel >= 0 && channel < call) {
        final next = _after(raw, _channelEnd, channel);
        out.write(raw.substring(at, next));
        at = next;
        continue;
      }
      final open = raw.indexOf('{', call);
      final close = raw.indexOf(_callEnd, call);
      if (open < 0 || (close >= 0 && close < open)) {
        // No braces: not a call llamadart reads.
        final next = close < 0 ? raw.length : close + _callEnd.length;
        envelopes.add((text: raw.substring(call, next), hasArguments: false));
        out.write(raw.substring(at, next));
        at = next;
        continue;
      }
      out.write(raw.substring(at, open));
      final end = _arguments(raw, open, out);
      envelopes.add((
        text: raw.substring(call, end),
        hasArguments: raw.substring(open + 1, math.max(open + 1, end - 1)).trim().isNotEmpty,
      ));
      at = end;
    }
    out.write(raw.substring(at));
    return _GemmaAnswer._(out.toString(), envelopes);
  }

  /// The answer to hand to llamadart.
  final String text;

  /// The tool-call envelopes of the raw answer, in order: their text, and whether their braces hold anything.
  final List<({String text, bool hasArguments})> envelopes;

  static const String _callStart = '<|tool_call>';
  static const String _callEnd = '<tool_call|>';
  static const String _channelStart = '<|channel>';
  static const String _channelEnd = '<channel|>';
  static final RegExp _quote = RegExp(r'<\|\\?"\|>');

  /// The index after the first [marker] from [from] on; [text]'s length when there is none.
  static int _after(String text, String marker, int from) {
    final at = text.indexOf(marker, from);
    return at < 0 ? text.length : at + marker.length;
  }

  /// Copies the braces at [open] to [out] with their strings rewritten; returns the index after the closing brace
  /// ([raw]'s length when it does not close).
  static int _arguments(String raw, int open, StringBuffer out) {
    var depth = 0;
    var at = open;
    while (at < raw.length) {
      final quote = _quote.matchAsPrefix(raw, at);
      if (quote != null) {
        final close = _quote.firstMatch(raw.substring(quote.end));
        if (close == null) break;
        out.write(_safeString(raw.substring(quote.end, quote.end + close.start)));
        at = quote.end + close.end;
        continue;
      }
      final char = raw[at];
      if (char == '"') {
        final end = _jsonStringEnd(raw, at);
        if (end < 0) break;
        final literal = raw.substring(at, end);
        String? value;
        try {
          value = jsonDecode(literal) as String;
        } on FormatException {
          value = null;
        }
        out.write(value == null ? literal : _safeString(value));
        at = end;
        continue;
      }
      out.write(char);
      at++;
      if (char == '{') {
        depth++;
      } else if (char == '}' && --depth == 0) {
        return at;
      }
    }
    out.write(raw.substring(at));
    return raw.length;
  }

  /// The index after the JSON string that starts at [start]; -1 when it does not end.
  static int _jsonStringEnd(String text, int start) {
    for (var at = start + 1; at < text.length; at++) {
      final char = text[at];
      if (char == r'\') {
        at++;
      } else if (char == '"') {
        return at + 1;
      }
    }
    return -1;
  }

  /// [value] as a JSON string with no comma, brace or `<` left for llamadart's pseudo-JSON pass to act on.
  static String _safeString(String value) => jsonEncode(
    value,
  ).replaceAllMapped(_unsafe, (match) => '\\u${match[0]!.codeUnitAt(0).toRadixString(16).padLeft(4, '0')}');

  static final RegExp _unsafe = RegExp('[,{}<]');
}

/// The calls of an LFM2 envelope's [payload]: a JSON list (what the grammar of `ToolMode.required` admits) or object,
/// or LFM2's Python-style list `[name(key=value, …), …]`; null when it is neither.
List<ToolCall>? _lfm2Calls(String payload) {
  final text = payload.trim();
  if (text.isEmpty) return const [];
  Object? json;
  try {
    json = jsonDecode(text);
  } on FormatException {
    return _PythonCalls(text).read();
  }
  final calls = <ToolCall>[];
  for (final item in json is List ? json : [json]) {
    if (item is! Map<Object?, Object?>) return null;
    final function = switch (item['function']) {
      final Map<Object?, Object?> function => function,
      _ => item,
    };
    final name = function['name'];
    final arguments = switch (function['arguments'] ?? function['parameters']) {
      null => const <String, Object?>{},
      final Map<Object?, Object?> map => {for (final entry in map.entries) entry.key.toString(): entry.value},
      final String text => _decodeObject(text),
      _ => null,
    };
    if (name is! String || name.isEmpty || arguments == null) return null;
    calls.add(ToolCall(name, arguments));
  }
  return calls;
}

/// A reader of LFM2's Python-style call list, `[name(key=value, …), …]` (the brackets optional), whose values are
/// Python literals: strings with their escapes, numbers, `True`, `False`, `None` (JSON's words too), lists, tuples and
/// dicts. An argument's value that is none of them is its text up to the next comma or parenthesis, as llamadart
/// reads it (`unit=celsius`).
final class _PythonCalls {
  _PythonCalls(this._text);

  final String _text;
  int _at = 0;

  /// The calls; null when the text is not such a list.
  List<ToolCall>? read() {
    try {
      _space();
      final calls = _items(_take('[') ? ']' : null, _call);
      _space();
      return _at == _text.length ? calls : null;
    } on FormatException {
      return null;
    }
  }

  ToolCall _call() {
    final name = _word(_name);
    _expect('(');
    return ToolCall(name, {for (final (key, value) in _items(')', _argument)) key: value});
  }

  (String, Object?) _argument() {
    final key = _word(_identifier);
    _expect('=');
    final start = _at;
    try {
      final value = _value();
      _space();
      if (_at < _text.length && (_text[_at] == ',' || _text[_at] == ')')) return (key, value);
    } on FormatException {
      // Not a Python literal: read as text below.
    }
    final end = _text.indexOf(_valueEnd, start);
    final text = end < 0 ? '' : _text.substring(start, end).trim();
    if (text.isEmpty || '"\'[({'.contains(text[0])) throw FormatException('a value expected', _text, start);
    _at = end;
    return (key, text);
  }

  (String, Object?) _entry() {
    _space();
    final key = _at < _text.length && (_text[_at] == '"' || _text[_at] == "'") ? _string() : _word(_identifier);
    _expect(':');
    return (key, _value());
  }

  Object? _value() {
    _space();
    if (_at < _text.length && (_text[_at] == '"' || _text[_at] == "'")) return _string();
    if (_take('[')) return _items(']', _value);
    if (_take('(')) return _items(')', _value);
    if (_take('{')) return {for (final (key, value) in _items('}', _entry)) key: value};
    return switch (_word(_literal)) {
      'True' || 'true' => true,
      'False' || 'false' => false,
      'None' || 'null' => null,
      final word => int.tryParse(word) ?? double.tryParse(word) ?? (throw FormatException('not a value: $word')),
    };
  }

  /// Items read by [item], separated by commas (a trailing one allowed), up to [close] (read), or to the end of the
  /// text when [close] is null.
  List<T> _items<T>(String? close, T Function() item) {
    final items = <T>[];
    while (true) {
      _space();
      if (close == null ? _at == _text.length : _take(close)) return items;
      items.add(item());
      _space();
      if (_take(',')) continue;
      if (close == null ? _at == _text.length : _take(close)) return items;
      throw FormatException('"," or "${close ?? 'the end'}" expected', _text, _at);
    }
  }

  /// A quoted string, its escapes resolved.
  String _string() {
    final quote = _text[_at++];
    final out = StringBuffer();
    while (_at < _text.length) {
      final char = _text[_at++];
      if (char == quote) return out.toString();
      if (char != r'\' || _at == _text.length) {
        out.write(char);
        continue;
      }
      final escaped = _text[_at++];
      final hex = switch (escaped) {
        'x' => 2,
        'u' => 4,
        'U' => 8,
        _ => 0,
      };
      if (hex > 0) {
        final code = _at + hex <= _text.length ? int.tryParse(_text.substring(_at, _at + hex), radix: 16) : null;
        if (code == null) throw FormatException('a bad \\$escaped escape', _text, _at);
        out.writeCharCode(code);
        _at += hex;
        continue;
      }
      out.write(switch (escaped) {
        'n' => '\n',
        't' => '\t',
        'r' => '\r',
        'b' => '\b',
        'f' => '\f',
        '0' => '\x00',
        '\n' => '',
        r'\' || '"' || "'" => escaped,
        _ => '\\$escaped',
      });
    }
    throw FormatException('an unterminated string', _text, _at);
  }

  String _word(RegExp pattern) {
    _space();
    final match = pattern.matchAsPrefix(_text, _at);
    if (match == null) throw FormatException('a name or a value expected', _text, _at);
    _at = match.end;
    return match[0]!;
  }

  void _expect(String symbol) {
    _space();
    if (!_take(symbol)) throw FormatException('"$symbol" expected', _text, _at);
  }

  bool _take(String symbol) {
    if (!_text.startsWith(symbol, _at)) return false;
    _at += symbol.length;
    return true;
  }

  void _space() {
    while (_at < _text.length && _text[_at].trim().isEmpty) {
      _at++;
    }
  }

  static final RegExp _valueEnd = RegExp('[,)]');
  static final RegExp _name = RegExp(r'[A-Za-z_][\w.-]*');
  static final RegExp _identifier = RegExp(r'[A-Za-z_]\w*');
  static final RegExp _literal = RegExp(r'[+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?|[A-Za-z_]\w*');
}
