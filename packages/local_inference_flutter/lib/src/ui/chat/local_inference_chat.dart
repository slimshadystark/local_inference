/// The zero-ceremony chat: one widget that makes, starts and disposes the model manager, the assistant and the setup.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:local_inference/local_inference.dart';

import '../../adapters/assistant_controller.dart';
import '../../adapters/model_setup_controller.dart';
import '../../adapters/scope.dart';
import '../../adapters/screen_request_dispatcher.dart';
import '../../platform/download_config.dart';
import '../../platform/factories.dart';
import '../builders.dart';
import '../callbacks.dart';
import '../features.dart';
import '../internal/resolved.dart';
import '../l10n/strings.dart';
import '../theme/local_inference_theme.dart';
import 'chat_view.dart';
import 'controls.dart';
import 'status_panel.dart';

/// Where [LocalInferenceChat] gets its model.
@immutable
sealed class ModelOrigin {
  const ModelOrigin();

  /// Models listed by [catalog], downloaded (after the user's consent) with [download].
  const factory ModelOrigin.catalog(ModelCatalog catalog, {BackgroundDownloadConfig download}) = CatalogModelOrigin;

  /// A model file already on the device (a sandboxed macOS app reads only its container and the files the user
  /// picked).
  const factory ModelOrigin.file(String path) = FileModelOrigin;

  /// Models listed by the manifest at [url] (schema 1, as `ModelManifest` reads it), downloaded with [download].
  const factory ModelOrigin.manifest(Uri url, {BackgroundDownloadConfig download}) = ManifestModelOrigin;
}

/// See [ModelOrigin.catalog].
final class CatalogModelOrigin extends ModelOrigin {
  const CatalogModelOrigin(this.catalog, {this.download = const BackgroundDownloadConfig()});

  final ModelCatalog catalog;
  final BackgroundDownloadConfig download;
}

/// See [ModelOrigin.file].
final class FileModelOrigin extends ModelOrigin {
  const FileModelOrigin(this.path);

  final String path;
}

/// See [ModelOrigin.manifest].
final class ManifestModelOrigin extends ModelOrigin {
  const ManifestModelOrigin(this.url, {this.download = const BackgroundDownloadConfig()});

  final Uri url;
  final BackgroundDownloadConfig download;
}

/// A complete chat page for [config] and [model]: it makes the model manager (for a catalog or a manifest), the
/// assistant ([LocalInferenceFlutter.createAssistantController]) and the setup, starts them, and disposes them when
/// it goes. The first launch asks before downloading; the model loads by itself once it is there.
///
/// Call `LocalInferenceFlutter.installDownloaderStorage()` first in `main` when the model downloads. For a chat that
/// survives the page or shares its assistant with other screens, make the controllers yourself and use [ChatPage]
/// under a [LocalInferenceScope].
class LocalInferenceChat extends StatefulWidget {
  const LocalInferenceChat({
    super.key,
    required this.config,
    required this.model,
    this.title,
    this.assistantName,
    this.welcome,
    this.suggestions = const [],
    this.theme,
    this.strings,
    this.builders = const ChatBuilders(),
    this.callbacks = const ChatCallbacks(),
    this.features,
    this.screenRequestPolicy = const ScreenRequestPolicy(),
    this.lifecycle = const LifecyclePolicy(),
    this.load,
    this.engine,
    this.prefixStore,
  });

  /// The assistant's behavior; a new config (another identity) reconfigures it, after the turn or load under way.
  final AssistantConfig config;

  /// Read once, when the chat starts; for another model, give the widget a new key (`ValueKey(path)`).
  final ModelOrigin model;

  /// The app bar's title; null uses [assistantName].
  final String? title;
  final String? assistantName;
  final String? welcome;
  final List<String> suggestions;
  final LocalInferenceTheme? theme;
  final LocalInferenceStrings? strings;
  final ChatBuilders builders;
  final ChatCallbacks callbacks;
  final ChatFeatures? features;
  final ScreenRequestPolicy screenRequestPolicy;
  final LifecyclePolicy lifecycle;

  /// The engine's load options; null uses the device's ([LocalInferenceFlutter.platformLoadOptions]).
  final LoadOptions? load;

  /// Makes each model's engine; null uses llama.cpp (a test passes a scripted engine).
  final EngineFactory? engine;

  /// Where prefix states are kept; null uses the caches folder.
  final PrefixStateStore? prefixStore;

  @override
  State<LocalInferenceChat> createState() => _LocalInferenceChatState();
}

class _LocalInferenceChatState extends State<LocalInferenceChat> {
  ModelManager? _models;
  AssistantController? _assistant;
  ModelSetupController? _setup;
  Object? _error;
  int _attempt = 0;

  /// The config the assistant has; a newer one waits while a turn or a load runs (the assistant refuses it then).
  AssistantConfig? _applied;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  Future<void> _start() async {
    final attempt = ++_attempt;
    ModelManager? models;
    AssistantController? assistant;
    final config = widget.config;
    try {
      final origin = widget.model;
      models = switch (origin) {
        FileModelOrigin() => null,
        CatalogModelOrigin(:final catalog, :final download) => await LocalInferenceFlutter.createModelManager(
          catalog: catalog,
          download: download,
        ),
        ManifestModelOrigin(:final url, :final download) => await LocalInferenceFlutter.createModelManager(
          catalog: ModelCatalog.bundled(() async => throw StateError('no bundled manifest'), remote: url),
          download: download,
        ),
      };
      assistant = await LocalInferenceFlutter.createAssistantController(
        config,
        load: widget.load,
        engine: widget.engine,
        prefixStore: widget.prefixStore,
      );
      if (!mounted || attempt != _attempt) {
        await assistant.dispose();
        await _disposeModels(models);
        return;
      }
      final setup = ModelSetupController(
        manager: models,
        assistant: assistant,
        candidates: origin is FileModelOrigin ? (_) => [ModelCandidate(path: origin.path)] : null,
      );
      setState(() {
        _models = models;
        _assistant = assistant;
        _setup = setup;
        _error = null;
      });
      _applied = config;
      assistant.phase.addListener(_onPhase);
      // A config that came while the chat started.
      _reconfigure();
      unawaited(setup.init());
    } on Object catch (error, stack) {
      // The panel names the kind of failure only: in debug builds the cause goes to the console.
      assert(() {
        debugPrint('LocalInferenceChat could not start: $error\n$stack');
        return true;
      }());
      await assistant?.dispose();
      await _disposeModels(models);
      if (mounted && attempt == _attempt) setState(() => _error = error);
    }
  }

  /// A desktop manager's foreground downloader outlives the manager: it is closed too, so no download goes on.
  static Future<void> _disposeModels(ModelManager? models) async {
    if (models == null) return;
    await models.dispose();
    if (models.downloader case final HttpModelDownloader downloader) await downloader.close();
  }

  // Not inside the assistant's notification: a reconfiguration notifies it.
  void _onPhase() => scheduleMicrotask(_reconfigure);

  /// Gives the assistant the latest config once no turn or load runs.
  void _reconfigure() {
    final assistant = _assistant;
    if (!mounted || assistant == null || identical(_applied, widget.config)) return;
    final phase = assistant.phase.value;
    if (phase == AssistantPhase.busy || phase == AssistantPhase.loading || phase == AssistantPhase.preparing) return;
    _applied = widget.config;
    unawaited(assistant.assistant.reconfigure(widget.config));
  }

  @override
  void didUpdateWidget(covariant LocalInferenceChat oldWidget) {
    super.didUpdateWidget(oldWidget);
    _reconfigure();
  }

  @override
  void dispose() {
    _attempt++;
    _assistant?.phase.removeListener(_onPhase);
    _setup?.dispose();
    unawaited(_assistant?.dispose());
    unawaited(_disposeModels(_models));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final assistant = _assistant;
    final outer = LocalInferenceScope.maybeOf(context);
    if (assistant == null) {
      return ResolvedLook.wrap(
        context,
        theme: widget.theme,
        strings: widget.strings,
        features: widget.features,
        child: Builder(
          builder: (context) {
            final style = LocalInferenceStyle.of(context);
            final strings = LocalInferenceStrings.of(context).chat;
            final error = _error;
            return Scaffold(
              backgroundColor: style.background,
              // The chat's title, and the way back of a pushed page, while it starts or when it cannot.
              appBar: ChatAppBar(
                title: widget.title ?? widget.assistantName ?? strings.defaultAssistantName,
                showNewConversation: false,
              ),
              body: SafeArea(
                top: false,
                child: error == null
                    ? ChatStatusPanel(icon: Icons.memory_outlined, title: strings.preparingTitle, progress: true)
                    : ChatStatusPanel(
                        icon: Icons.error_outline,
                        title: strings.loadFailedTitle,
                        subtitle: strings.loadFailed(error),
                        details: ChatFeatures.of(context).showDetails ? '$error' : null,
                        isError: true,
                        action: FilledButton.tonalIcon(
                          onPressed: () {
                            setState(() => _error = null);
                            unawaited(_start());
                          },
                          icon: const Icon(Icons.refresh),
                          label: Text(strings.retry),
                        ),
                      ),
              ),
            );
          },
        ),
      );
    }
    return LocalInferenceScope(
      assistant: assistant,
      setup: _setup,
      models: _models,
      strings: outer?.strings,
      stringsOverride: outer?.stringsOverride,
      theme: outer?.theme,
      features: outer?.features,
      lifecycle: widget.lifecycle,
      child: ChatPage(
        title: widget.title,
        assistantName: widget.assistantName,
        welcome: widget.welcome,
        suggestions: widget.suggestions,
        theme: widget.theme,
        strings: widget.strings,
        features: widget.features,
        builders: widget.builders,
        callbacks: widget.callbacks,
        screenRequestPolicy: widget.screenRequestPolicy,
      ),
    );
  }
}
