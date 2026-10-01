/// The long-lived pieces of a chat above the Navigator, and what happens when the app leaves the foreground.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:local_inference/local_inference.dart';

import '../ui/features.dart';
import '../ui/l10n/strings.dart';
import '../ui/theme/local_inference_theme.dart';
import 'assistant_controller.dart';
import 'model_setup_controller.dart';

/// What a [LocalInferenceScope] does when the app goes to the background and comes back.
///
/// By default a turn running when the app goes to the background goes on: the system suspends the app and the reply
/// continues when it comes back (seen on an iPhone 16 Pro Max with iOS 27, during a reply and during the first
/// prefix build, on 2026-10-01). A model whose load failed while the app was away is loaded again on return. The
/// model is not unloaded on memory pressure unless asked. [cancelTurnOnBackground] stops the turn instead, keeping
/// its text so far: iOS forbids GPU work in the background, so a host that sees a turn fail there can choose it.
@immutable
final class LifecyclePolicy {
  const LifecyclePolicy({
    this.cancelTurnOnBackground = false,
    this.retryPrefixOnResume = true,
    this.unloadOnMemoryPressure = false,
  });

  /// Nothing happens on lifecycle changes.
  static const LifecyclePolicy none = LifecyclePolicy(
    cancelTurnOnBackground: false,
    retryPrefixOnResume: false,
    unloadOnMemoryPressure: false,
  );

  /// Stop the running turn when the app is paused: in the background on iOS and Android (only they pause an app;
  /// a desktop window that is minimized, hidden but not paused, keeps its turn).
  final bool cancelTurnOnBackground;

  /// When a load failed that ran while the app was away (the app left the foreground during it, or it started in the
  /// background, as when a download finishes there), load the model again once the app is back.
  final bool retryPrefixOnResume;

  /// Unload the model when the system reports memory pressure (not during a turn or a load); it loads again when
  /// the app returns to the foreground.
  final bool unloadOnMemoryPressure;

  @override
  bool operator ==(Object other) =>
      other is LifecyclePolicy &&
      other.cancelTurnOnBackground == cancelTurnOnBackground &&
      other.retryPrefixOnResume == retryPrefixOnResume &&
      other.unloadOnMemoryPressure == unloadOnMemoryPressure;

  @override
  int get hashCode => Object.hash(cancelTurnOnBackground, retryPrefixOnResume, unloadOnMemoryPressure);
}

/// What a [LocalInferenceScope] provides.
@immutable
final class LocalInferenceScopeData {
  const LocalInferenceScopeData({
    this.assistant,
    this.setup,
    this.models,
    this.strings,
    this.stringsOverride,
    this.theme,
    this.features,
    this.lifecycle = const LifecyclePolicy(),
  });

  final AssistantController? assistant;
  final ModelSetupController? setup;
  final ModelManager? models;

  /// The texts; null resolves them from the locale.
  final LocalInferenceStrings? strings;

  /// Changes the resolved texts (after the locale's pack is chosen).
  final LocalInferenceStrings Function(LocalInferenceStrings resolved)? stringsOverride;

  final LocalInferenceTheme? theme;
  final ChatFeatures? features;
  final LifecyclePolicy lifecycle;
}

/// Provides a chat's long-lived pieces (the [assistant], its [setup], the [models]) and its look, texts and switches
/// to every chat widget below, and applies [lifecycle]. Put it above the Navigator (in `MaterialApp.builder`), so
/// the chat survives pages pushed on top, and sheets, dialogs and SnackBars get the same texts.
///
/// Precedence of the look, texts and switches: a widget's own parameter, then this scope, then the app theme's
/// [LocalInferenceTheme] extension and [LocalInferenceLocalizations.delegate], then the defaults.
class LocalInferenceScope extends StatefulWidget {
  const LocalInferenceScope({
    super.key,
    this.assistant,
    this.setup,
    this.models,
    this.strings,
    this.stringsOverride,
    this.theme,
    this.features,
    this.lifecycle = const LifecyclePolicy(),
    this.disposeControllers = false,
    required this.child,
  });

  final AssistantController? assistant;
  final ModelSetupController? setup;
  final ModelManager? models;
  final LocalInferenceStrings? strings;
  final LocalInferenceStrings Function(LocalInferenceStrings resolved)? stringsOverride;
  final LocalInferenceTheme? theme;
  final ChatFeatures? features;
  final LifecyclePolicy lifecycle;

  /// Whether the scope disposes [assistant], [setup] and [models] when it goes.
  final bool disposeControllers;

  final Widget child;

  /// The nearest scope's data; throws when there is none.
  static LocalInferenceScopeData of(BuildContext context) =>
      maybeOf(context) ??
      (throw FlutterError(
        'No LocalInferenceScope above this widget: put one above the Navigator (MaterialApp.builder), or pass the '
        'controller to the widget.',
      ));

  /// The nearest scope's data, or null.
  static LocalInferenceScopeData? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_ScopeData>()?.data;

  @override
  State<LocalInferenceScope> createState() => _LocalInferenceScopeState();
}

class _LocalInferenceScopeState extends State<LocalInferenceScope> with WidgetsBindingObserver {
  bool _foreground = true;

  /// A load ran while the app was away: its failure is retried on return.
  bool _retryPending = false;

  /// The model unloaded on memory pressure, loaded again on return.
  String? _unloaded;

  AssistantController? _listening;

  @override
  void initState() {
    super.initState();
    // An app the system started in the background (iOS relaunches one for its downloads) is not in the foreground.
    _foreground = switch (WidgetsBinding.instance.lifecycleState) {
      AppLifecycleState.hidden || AppLifecycleState.paused => false,
      _ => true,
    };
    WidgetsBinding.instance.addObserver(this);
    _listen(widget.assistant);
  }

  @override
  void didUpdateWidget(covariant LocalInferenceScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.assistant, widget.assistant)) _listen(widget.assistant);
  }

  void _listen(AssistantController? assistant) {
    _listening?.phase.removeListener(_onPhase);
    _listening = assistant;
    assistant?.phase.addListener(_onPhase);
    _retryPending = false;
    _unloaded = null;
    // A load already running while the app is away.
    _onPhase();
  }

  AssistantPhase? get _phase => widget.assistant?.phase.value;

  void _onPhase() {
    switch (_phase) {
      case AssistantPhase.ready || AssistantPhase.busy || AssistantPhase.noModel:
        _retryPending = false;
      // A load that starts while the app is away (a download that finished in the background).
      case AssistantPhase.loading || AssistantPhase.preparing when !_foreground && widget.lifecycle.retryPrefixOnResume:
        _retryPending = true;
      case AssistantPhase.failed when _retryPending && _foreground:
        _retryPending = false;
        _retry();
      default:
        break;
    }
  }

  void _retry() {
    final assistant = widget.assistant;
    if (assistant == null) return;
    // Outside the assistant's notification.
    scheduleMicrotask(() => unawaited(assistant.retryLoad()));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final assistant = widget.assistant;
    final policy = widget.lifecycle;
    switch (state) {
      case AppLifecycleState.hidden || AppLifecycleState.paused:
        _foreground = false;
        if (assistant == null) return;
        if (state == AppLifecycleState.paused && policy.cancelTurnOnBackground && _phase == AssistantPhase.busy) {
          assistant.stop();
        }
        if (policy.retryPrefixOnResume && (_phase == AssistantPhase.loading || _phase == AssistantPhase.preparing)) {
          _retryPending = true;
        }
      case AppLifecycleState.resumed:
        _foreground = true;
        if (assistant == null) return;
        if (_retryPending && _phase == AssistantPhase.failed) {
          _retryPending = false;
          _retry();
        }
        final unloaded = _unloaded;
        if (unloaded != null) {
          _unloaded = null;
          if (_phase == AssistantPhase.noModel) unawaited(assistant.loadModel(unloaded));
        }
      case AppLifecycleState.inactive || AppLifecycleState.detached:
        break;
    }
  }

  @override
  void didHaveMemoryPressure() {
    final assistant = widget.assistant;
    if (assistant == null || !widget.lifecycle.unloadOnMemoryPressure || _phase != AssistantPhase.ready) return;
    final path = assistant.assistant.state.modelPath;
    if (path == null) return;
    _unloaded = path;
    unawaited(assistant.unloadModel());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _listening?.phase.removeListener(_onPhase);
    if (widget.disposeControllers) {
      widget.setup?.dispose();
      unawaited(widget.assistant?.dispose());
      unawaited(widget.models?.dispose());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _ScopeData(
    data: LocalInferenceScopeData(
      assistant: widget.assistant,
      setup: widget.setup,
      models: widget.models,
      strings: widget.strings,
      stringsOverride: widget.stringsOverride,
      theme: widget.theme,
      features: widget.features,
      lifecycle: widget.lifecycle,
    ),
    child: widget.child,
  );
}

class _ScopeData extends InheritedWidget {
  const _ScopeData({required this.data, required super.child});

  final LocalInferenceScopeData data;

  @override
  bool updateShouldNotify(_ScopeData oldWidget) {
    final a = oldWidget.data;
    final b = data;
    return !identical(a.assistant, b.assistant) ||
        !identical(a.setup, b.setup) ||
        !identical(a.models, b.models) ||
        !identical(a.strings, b.strings) ||
        a.stringsOverride != b.stringsOverride ||
        a.theme != b.theme ||
        a.features != b.features ||
        a.lifecycle != b.lifecycle;
  }
}
