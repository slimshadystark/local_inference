/// The model-download views: consent (the App Store asks to show the size and ask before a download the app needs on
/// first use), progress, the mobile-data prompt and the model picker. Their texts come from [ModelSetupStrings].
library;

import 'package:flutter/material.dart';
import 'package:local_inference/local_inference.dart';

import '../../adapters/model_setup_controller.dart';
import '../builders.dart';
import '../chat/status_panel.dart';
import '../internal/confirm_dialog.dart';
import '../internal/resolved.dart';
import '../internal/setup_panels.dart';
import '../keys.dart';
import '../l10n/strings.dart';
import '../theme/local_inference_theme.dart';

/// A narrow scrolling column in the middle of the screen.
class _Narrow extends StatelessWidget {
  const _Narrow({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: LocalInferenceStyle.of(context).panelMaxWidth),
        child: Column(mainAxisSize: MainAxisSize.min, children: children),
      ),
    ),
  );
}

/// Asks before downloading [entry], showing its size. With [problem] the button is off and the reason shows in the
/// error color; with only a [notice] (why the last attempt failed) the reason shows and the button, now "Retry",
/// stays on.
class ModelConsentView extends StatelessWidget {
  const ModelConsentView({
    super.key,
    required this.entry,
    required this.assistantName,
    required this.onDownload,
    this.problem,
    this.notice,
    this.onChooseOther,
  });

  final ModelEntry entry;
  final String assistantName;
  final VoidCallback onDownload;

  /// Why this device cannot download the model now (memory, space).
  final String? problem;

  /// Why the last download failed; unlike [problem] it does not stop a new attempt.
  final String? notice;

  final VoidCallback? onChooseOther;

  @override
  Widget build(BuildContext context) {
    final style = LocalInferenceStyle.of(context);
    final strings = LocalInferenceStrings.of(context);
    final setup = strings.setup;
    final reason = problem ?? notice;
    final retry = problem == null && notice != null;
    return _Narrow(
      children: [
        PanelIcon(icon: Icons.cloud_download_outlined, size: style.setupIconSize),
        const SizedBox(height: 20),
        Text(
          setup.consentTitle(assistantName),
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: style.onAssistant),
        ),
        const SizedBox(height: 8),
        Text(
          setup.sizeApprox(strings.formats.bytes(entry.sizeBytes)),
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: style.accent),
        ),
        Text(
          entry.displayName,
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 13, color: style.secondaryText),
        ),
        const SizedBox(height: 12),
        Text(
          setup.consentBody(assistantName),
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 15, height: 1.4, color: style.onAssistant),
        ),
        const SizedBox(height: 24),
        FilledButton.icon(
          key: LocalInferenceKeys.setupDownload,
          onPressed: problem == null ? onDownload : null,
          style: style.filledButton,
          icon: Icon(retry ? Icons.refresh : Icons.download),
          label: Text(retry ? setup.retryButton : setup.downloadButton),
        ),
        if (reason != null) ...[
          const SizedBox(height: 12),
          Text(
            reason,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, color: style.error),
          ),
        ],
        if (onChooseOther != null) ...[
          const SizedBox(height: 8),
          TextButton(
            key: LocalInferenceKeys.setupChooseOther,
            onPressed: onChooseOther,
            style: style.textButton,
            child: Text(setup.chooseOther),
          ),
        ],
      ],
    );
  }
}

/// The download of [entry]: the bar, percent and gigabytes, speed and time left, pause, resume and cancel.
class ModelProgressView extends StatelessWidget {
  const ModelProgressView({
    super.key,
    required this.entry,
    required this.status,
    this.onPause,
    this.onResume,
    this.onCancel,
    this.onUseCellular,
  });

  final ModelEntry entry;
  final ModelStatus status;
  final VoidCallback? onPause;

  /// Also "Retry" after a failure.
  final VoidCallback? onResume;
  final VoidCallback? onCancel;

  /// Offered while waiting for Wi-Fi (ask first with [showCellularDialog]).
  final VoidCallback? onUseCellular;

  @override
  Widget build(BuildContext context) {
    final style = LocalInferenceStyle.of(context);
    final strings = LocalInferenceStrings.of(context);
    final setup = strings.setup;
    final formats = strings.formats;
    final state = status.state;
    final verifying = state == ModelState.verifying;
    final title = switch (state) {
      ModelState.verifying => setup.progressVerifying,
      ModelState.waitingForWifi => setup.progressWaitingForWifi,
      ModelState.queued when status.waitingForNetwork => setup.progressWaitingForNetwork,
      ModelState.paused => setup.progressPaused,
      ModelState.failed => setup.progressFailed,
      _ => setup.progressDownloading,
    };
    final total = status.bytesTotal > 0 ? status.bytesTotal : entry.sizeBytes;
    final rates = [?formats.speed(status.bytesPerSecond), ?formats.remaining(status.timeRemaining)];
    final message = setup.statusMessage(status, formats);
    final canPause = onPause != null && state == ModelState.downloading;
    final canResume = onResume != null && (state == ModelState.paused || state == ModelState.failed);
    final text = TextStyle(fontSize: 14, color: style.onAssistant);
    final secondary = TextStyle(fontSize: 13, color: style.secondaryText);
    return _Narrow(
      children: [
        PanelIcon(icon: verifying ? Icons.verified_outlined : Icons.cloud_download_outlined, size: style.setupIconSize),
        const SizedBox(height: 20),
        Text(
          title,
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: style.onAssistant),
        ),
        const SizedBox(height: 4),
        Text(entry.displayName, textAlign: TextAlign.center, style: secondary),
        const SizedBox(height: 20),
        ClipRRect(
          borderRadius: BorderRadius.circular(style.progressRadius),
          child: LinearProgressIndicator(
            value: verifying ? null : status.progress,
            minHeight: 8,
            color: style.progress,
            backgroundColor: style.progressTrack,
            semanticsLabel: setup.progressSemanticsLabel,
            semanticsValue: verifying ? null : formats.percent(status.progress),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(formats.percent(status.progress), style: text),
            const SizedBox(width: 12),
            Expanded(
              child: Text(formats.gigabytesPair(status.bytesDone, total), textAlign: TextAlign.end, style: text),
            ),
          ],
        ),
        if (rates.isNotEmpty && state == ModelState.downloading) ...[
          const SizedBox(height: 4),
          Text(rates.join(' · '), style: secondary),
        ],
        if (state == ModelState.failed && message != null) ...[
          const SizedBox(height: 12),
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, color: style.error),
          ),
        ],
        const SizedBox(height: 16),
        Text(
          setup.downloadHint,
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 14, height: 1.4, color: style.secondaryText),
        ),
        const SizedBox(height: 24),
        if (canPause)
          OutlinedButton(
            key: LocalInferenceKeys.progressPause,
            onPressed: onPause,
            style: OutlinedButton.styleFrom(
              foregroundColor: style.accent,
              side: BorderSide(color: style.accent),
              minimumSize: Size.fromHeight(style.buttonMinHeight),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(style.buttonRadius)),
            ),
            child: Text(setup.pause),
          ),
        if (canResume)
          FilledButton(
            key: LocalInferenceKeys.progressResume,
            onPressed: onResume,
            style: style.filledButton,
            child: Text(state == ModelState.failed ? setup.retryButton : setup.resume),
          ),
        if (state == ModelState.waitingForWifi && onUseCellular != null)
          TextButton(
            key: LocalInferenceKeys.progressUseCellular,
            onPressed: onUseCellular,
            style: style.textButton,
            child: Text(setup.useCellular),
          ),
        if (onCancel != null && !verifying) ...[
          const SizedBox(height: 8),
          TextButton(
            key: LocalInferenceKeys.progressCancel,
            onPressed: onCancel,
            style: style.textButton,
            child: Text(setup.cancel),
          ),
        ],
      ],
    );
  }
}

/// Asks before downloading [entry] over mobile data, showing its size; true when the user accepts. [presenter]
/// replaces the dialog.
Future<bool> showCellularDialog(BuildContext context, ModelEntry entry, {ConfirmDialogPresenter? presenter}) {
  final strings = LocalInferenceStrings.of(context);
  return showConfirmDialog(
    context,
    ConfirmDialogRequest(
      title: strings.setup.cellularTitle,
      message: strings.setup.cellularBody(strings.formats.bytes(entry.sizeBytes)),
      action: strings.setup.cellularAction,
    ),
    presenter: presenter,
  );
}

/// The "choose another model" sheet of [setup]: the offered models with their size, the one recommended for this
/// device and why a model cannot be used. It reads the device's free space and memory first (other apps may have
/// closed). The chosen model becomes the setup's ([ModelSetupController.choose]); null when the user kept the same.
Future<ModelEntry?> showModelPicker(BuildContext context, ModelSetupController setup) async {
  final manager = setup.manager;
  final current = setup.entry;
  if (manager == null || current == null) return null;
  await manager.refreshCapabilities().catchError((Object _) {});
  if (!context.mounted) return null;
  final style = LocalInferenceStyle.of(context);
  final strings = LocalInferenceStrings.of(context);
  final picked = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    backgroundColor: style.background,
    builder: (sheet) => ResolvedLook.carry(
      context,
      SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final entry in manager.entries.where((entry) => entry.isActive))
              ListTile(
                key: LocalInferenceKeys.pickerEntry(entry.id),
                title: Text(entry.displayName),
                subtitle: Text(
                  [
                    strings.formats.bytes(entry.sizeBytes),
                    if (manager.recommended?.id == entry.id) strings.setup.recommendedForDevice,
                    if (manager.problemFor(entry) case final problem?) strings.setup.problem(problem, strings.formats),
                  ].join(' · '),
                ),
                trailing: entry.id == current.id ? Icon(Icons.check, color: style.accent) : null,
                onTap: () => Navigator.of(sheet).pop(entry.id),
              ),
          ],
        ),
      ),
    ),
  );
  if (picked == null || picked == current.id || !context.mounted) return null;
  await setup.choose(picked);
  return manager.entryFor(picked);
}

/// The first-launch model setup of [controller], stage by stage: preparing while the manager starts or a model
/// loads, "retry" when the model list could not be read, "none offered", the consent to download, the download's
/// progress, "load" for a model that nothing loads by itself. [onReady] runs once the setup is done
/// ([SetupStage.ready]: a model loaded, or its load failed, or, without an assistant, one installed).
class ModelSetupView extends StatefulWidget {
  const ModelSetupView({
    super.key,
    required this.controller,
    this.assistantName,
    this.onReady,
    this.builders = const ModelSetupBuilders(),
    this.strings,
    this.theme,
  });

  final ModelSetupController controller;

  /// The name in the consent; null uses [ChatStrings.defaultAssistantName].
  final String? assistantName;
  final VoidCallback? onReady;
  final ModelSetupBuilders builders;
  final LocalInferenceStrings? strings;
  final LocalInferenceTheme? theme;

  @override
  State<ModelSetupView> createState() => _ModelSetupViewState();
}

class _ModelSetupViewState extends State<ModelSetupView> {
  SetupStage? _last;

  @override
  void initState() {
    super.initState();
    _listen(widget.controller);
  }

  @override
  void didUpdateWidget(covariant ModelSetupView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.removeListener(_onChange);
      _listen(widget.controller);
    }
  }

  void _listen(ModelSetupController controller) {
    _last = controller.stage;
    controller.addListener(_onChange);
    controller.init().ignore();
  }

  void _onChange() {
    final stage = widget.controller.stage;
    if (stage == SetupStage.ready && _last != SetupStage.ready) widget.onReady?.call();
    _last = stage;
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChange);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ResolvedLook.wrap(
    context,
    theme: widget.theme,
    strings: widget.strings,
    child: ListenableBuilder(listenable: widget.controller, builder: (context, _) => _stage(context)),
  );

  Widget _stage(BuildContext context) {
    final setup = widget.controller;
    final style = LocalInferenceStyle.of(context);
    final strings = LocalInferenceStrings.of(context);
    final stage = setup.stage;
    Widget slot(SetupSlotBuilder<SetupStageContext>? builder, Widget Function() build) => builder == null
        ? build()
        : builder(
            context,
            SetupStageContext(style: style, strings: strings, defaultBuilder: build, setup: setup, stage: stage),
          );
    final entry = setup.entry;
    final status = setup.status;
    switch (stage) {
      case SetupStage.starting || SetupStage.loadingModel:
        return SetupPanels.panel(
          context,
          ChatPanelKind.preparing,
          ChatPanelData(icon: Icons.memory_outlined, title: strings.chat.preparingTitle, progress: true),
        );
      case SetupStage.catalogUnavailable:
        return slot(
          widget.builders.catalogUnavailable,
          () => SetupPanels.panel(
            context,
            ChatPanelKind.catalogUnavailable,
            ChatPanelData(
              icon: Icons.cloud_off_outlined,
              title: strings.setup.libraryUnavailable,
              action: FilledButton.tonalIcon(
                key: LocalInferenceKeys.retryLoad,
                onPressed: () => setup.retry().ignore(),
                icon: const Icon(Icons.refresh),
                label: Text(strings.setup.retryButton),
              ),
            ),
          ),
        );
      case SetupStage.noneOffered:
        return slot(
          widget.builders.noneOffered,
          () => SetupPanels.panel(
            context,
            ChatPanelKind.noneOffered,
            ChatPanelData(
              icon: Icons.cloud_off_outlined,
              title: strings.setup.noneOfferedTitle,
              subtitle: strings.setup.noneOfferedSubtitle,
            ),
          ),
        );
      case SetupStage.modelAvailable:
        return SetupPanels.panel(
          context,
          ChatPanelKind.modelAvailable,
          modelAvailablePanel(context, () => setup.refresh().ignore()),
        );
      case SetupStage.consent when entry != null && status != null:
        final failed = status.state == ModelState.failed;
        final problem = setup.problem;
        return slot(
          widget.builders.consent,
          () => ModelConsentView(
            entry: entry,
            assistantName: widget.assistantName ?? strings.chat.defaultAssistantName,
            problem: problem == null ? null : strings.setup.problem(problem, strings.formats),
            // A failed attempt leaves the button on: the download resumes or starts again, and checks space and
            // memory once more.
            notice: failed
                ? strings.setup.statusMessage(status, strings.formats) ?? strings.setup.downloadFailedError
                : null,
            onDownload: () => _download(context, strings),
            onChooseOther: setup.alternatives.isEmpty ? null : () => showModelPicker(context, setup).ignore(),
          ),
        );
      case SetupStage.downloading when entry != null && status != null:
        return slot(
          widget.builders.progress,
          () => ModelProgressView(
            entry: entry,
            status: status,
            onPause: () => setup.pause().ignore(),
            onResume: () => setup.resume().ignore(),
            onCancel: () => setup.cancel().ignore(),
            onUseCellular: () async {
              if (await showCellularDialog(context, entry, presenter: widget.builders.confirmDialog)) {
                await setup.download(allowCellular: true);
              }
            },
          ),
        );
      case SetupStage.ready || SetupStage.consent || SetupStage.downloading:
        return const SizedBox.shrink();
    }
  }

  void _download(BuildContext context, LocalInferenceStrings strings) {
    widget.controller.download().catchError((Object error) {
      if (!context.mounted) return;
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text(strings.setup.downloadStartFailed(error))));
    });
  }
}
