/// The models on the device and in the catalog, for a settings page: download, pause, use, delete.
library;

import 'package:flutter/material.dart';
import 'package:local_inference/local_inference.dart';

import '../../adapters/assistant_controller.dart';
import '../../adapters/change_source_listenable.dart';
import '../builders.dart';
import '../internal/confirm_dialog.dart';
import '../internal/resolved.dart';
import '../internal/status_badge.dart';
import '../internal/surface_card.dart';
import '../keys.dart';
import '../l10n/strings.dart';
import '../theme/local_inference_theme.dart';
import 'model_views.dart';

/// The models of [manager]: their total size, a card per model (state, progress, actions), the Wi-Fi-only switch and
/// where the model list came from. It reads the free space again when it opens, so a model refused for lack of space
/// can be downloaded once the user has made room.
class ModelLibrary extends StatefulWidget {
  const ModelLibrary({
    super.key,
    required this.manager,
    this.activeModelPath,
    this.locked = false,
    this.onUseModel,
    this.showWifiOnlySwitch = true,
    this.showCatalogOrigin = true,
    this.builders = const ModelSetupBuilders(),
    this.strings,
    this.theme,
  }) : assistant = null;

  /// The library of [assistant]'s chat: the model it has loaded cannot be deleted, and nothing can be switched or
  /// deleted while it loads a model or answers. [onUseModel] defaults to loading the model.
  const ModelLibrary.forAssistant(
    AssistantController this.assistant, {
    super.key,
    required this.manager,
    this.onUseModel,
    this.showWifiOnlySwitch = true,
    this.showCatalogOrigin = true,
    this.builders = const ModelSetupBuilders(),
    this.strings,
    this.theme,
  }) : activeModelPath = null,
       locked = false;

  final ModelManager manager;

  /// The model the chat has loaded, which cannot be deleted from here.
  final String? activeModelPath;

  /// The chat is loading a model or answering: no model can be switched or deleted (while it loads,
  /// [activeModelPath] is still unknown, so it would not be protected otherwise).
  final bool locked;

  /// Makes the chat use a downloaded model; null hides "Use".
  final ValueChanged<InstalledModel>? onUseModel;

  final bool showWifiOnlySwitch;
  final bool showCatalogOrigin;
  final ModelSetupBuilders builders;
  final LocalInferenceStrings? strings;
  final LocalInferenceTheme? theme;

  /// The chat that [ModelLibrary.forAssistant] follows.
  final AssistantController? assistant;

  @override
  State<ModelLibrary> createState() => _ModelLibraryState();
}

class _ModelLibraryState extends State<ModelLibrary> {
  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void didUpdateWidget(covariant ModelLibrary oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.manager, widget.manager)) _refresh();
  }

  Future<void> _refresh() async {
    final manager = widget.manager;
    try {
      if (!manager.isReady) await manager.init();
      await manager.refreshCapabilities();
    } on Object {
      // Shown by the build through manager.loadError.
    }
  }

  @override
  Widget build(BuildContext context) => ResolvedLook.wrap(
    context,
    theme: widget.theme,
    strings: widget.strings,
    child: switch (widget.assistant) {
      final assistant? => ValueListenableBuilder<AssistantPhase>(
        valueListenable: assistant.phase,
        builder: (context, phase, _) => _library(
          context,
          activeModelPath: assistant.assistant.state.modelPath,
          locked: const {AssistantPhase.loading, AssistantPhase.preparing, AssistantPhase.busy}.contains(phase),
          onUseModel: widget.onUseModel ?? (model) => assistant.loadModel(model.path).ignore(),
        ),
      ),
      null => _library(
        context,
        activeModelPath: widget.activeModelPath,
        locked: widget.locked,
        onUseModel: widget.onUseModel,
      ),
    },
  );

  Widget _library(
    BuildContext context, {
    required String? activeModelPath,
    required bool locked,
    required ValueChanged<InstalledModel>? onUseModel,
  }) {
    final manager = widget.manager;
    return ListenableBuilder(
      listenable: ChangeSourceListenable(manager),
      builder: (context, _) {
        final style = LocalInferenceStyle.of(context);
        final strings = LocalInferenceStrings.of(context);
        if (!manager.isReady) {
          return Padding(
            padding: const EdgeInsets.all(16),
            child: Center(
              child: manager.loadError == null
                  ? CircularProgressIndicator(color: style.progress, backgroundColor: Colors.transparent)
                  : Text(strings.setup.libraryUnavailable, style: TextStyle(fontSize: 14, color: style.error)),
            ),
          );
        }
        final shown = [
          for (final entry in manager.entries)
            if (entry.isActive || manager.pathOf(entry.id) != null) entry,
          for (final model in manager.installed)
            if (manager.manifest.byId(model.entry.id) == null) model.entry,
        ];
        final bytes = manager.installedBytes;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    strings.setup.libraryTitle,
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: style.onAssistant),
                  ),
                ),
                Text(
                  bytes == 0 ? strings.setup.libraryNone : strings.formats.bytes(bytes),
                  style: TextStyle(fontSize: 14, color: style.secondaryText),
                ),
              ],
            ),
            for (final entry in shown)
              ModelTile(
                key: LocalInferenceKeys.libraryTile(entry.id),
                manager: manager,
                entry: entry,
                activeModelPath: activeModelPath,
                onUseModel: onUseModel,
                locked: locked,
                builders: widget.builders,
              ),
            if (widget.showWifiOnlySwitch) ...[
              const SizedBox(height: 4),
              SwitchListTile.adaptive(
                key: LocalInferenceKeys.wifiOnlySwitch,
                contentPadding: EdgeInsets.zero,
                title: Text(strings.setup.wifiOnly, style: TextStyle(fontSize: 15, color: style.onAssistant)),
                value: manager.wifiOnly,
                activeTrackColor: style.accent,
                onChanged: (value) => manager.setWifiOnly(value).ignore(),
              ),
            ],
            if (widget.showCatalogOrigin)
              Text(
                strings.setup.catalogOrigin(manager.catalogOrigin),
                style: TextStyle(fontSize: 12, color: style.secondaryText),
              ),
          ],
        );
      },
    );
  }
}

/// A model's card: its name (and "recommended"), parameters, quantization and size, its state or progress, why it
/// cannot be used, and the actions of its state.
class ModelTile extends StatelessWidget {
  const ModelTile({
    super.key,
    required this.manager,
    required this.entry,
    this.activeModelPath,
    this.onUseModel,
    this.locked = false,
    this.builders = const ModelSetupBuilders(),
  });

  final ModelManager manager;
  final ModelEntry entry;

  /// The model the chat uses: "in use", and it cannot be deleted.
  final String? activeModelPath;

  final ValueChanged<InstalledModel>? onUseModel;

  /// Nothing can be used or deleted.
  final bool locked;

  /// [ModelSetupBuilders.tile] replaces the card; [ModelSetupBuilders.confirmDialog] the confirmations.
  final ModelSetupBuilders builders;

  @override
  Widget build(BuildContext context) {
    final style = LocalInferenceStyle.of(context);
    final strings = LocalInferenceStrings.of(context);
    final setup = strings.setup;
    final formats = strings.formats;
    final id = entry.id;
    final status = manager.statusOf(id);
    final path = manager.pathOf(id);
    final inUse = path != null && path == activeModelPath;
    final installed = path == null ? null : manager.installed.where((model) => model.entry.id == id).firstOrNull;
    final problem = switch (manager.problemFor(entry)) {
      final problem? => setup.problem(problem, formats),
      null => null,
    };
    final onUseModel = this.onUseModel;
    final actions = ModelTileActions(
      download: const {ModelState.notDownloaded, ModelState.failed}.contains(status.state) && problem == null
          ? () => manager.download(id).ignore()
          : null,
      pause: status.state == ModelState.downloading ? () => manager.pause(id).ignore() : null,
      resume: status.state == ModelState.paused ? () => manager.resume(id).ignore() : null,
      cancel:
          const {
            ModelState.queued,
            ModelState.downloading,
            ModelState.waitingForWifi,
            ModelState.paused,
          }.contains(status.state)
          ? () => manager.cancel(id).ignore()
          : null,
      useCellular: status.state == ModelState.waitingForWifi
          ? () async {
              if (await showCellularDialog(context, entry, presenter: builders.confirmDialog)) {
                await manager.download(id, allowCellular: true);
              }
            }
          : null,
      use: status.state == ModelState.ready && !inUse && !locked && installed != null && onUseModel != null
          ? () => onUseModel(installed)
          : null,
      delete: status.state == ModelState.ready && !inUse && !locked ? () => _confirmDelete(context) : null,
    );
    Widget build() => _card(context, style, strings, status, inUse, problem, actions);
    final builder = builders.tile;
    if (builder == null) return build();
    return builder(
      context,
      ModelTileContext(
        style: style,
        strings: strings,
        defaultBuilder: build,
        manager: manager,
        entry: entry,
        status: status,
        actions: actions,
        inUse: inUse,
      ),
    );
  }

  Widget _card(
    BuildContext context,
    LocalInferenceStyle style,
    LocalInferenceStrings strings,
    ModelStatus status,
    bool inUse,
    String? problem,
    ModelTileActions actions,
  ) {
    final setup = strings.setup;
    final formats = strings.formats;
    final percent = formats.percent(status.progress);
    final (line, lineColor) = switch (status.state) {
      ModelState.notDownloaded => (setup.tileNotDownloaded, style.secondaryText),
      ModelState.queued =>
        status.waitingForNetwork
            ? (setup.tileWaitingForNetwork, style.pending)
            : (setup.tileQueued, style.secondaryText),
      ModelState.downloading => (
        [setup.tileDownloading(percent), ?formats.speed(status.bytesPerSecond)].join(' · '),
        style.onAssistant,
      ),
      ModelState.paused => (setup.tilePaused(percent), style.pending),
      ModelState.waitingForWifi => (setup.tileWaitingForWifi, style.pending),
      ModelState.verifying => (setup.tileVerifying, style.onAssistant),
      ModelState.ready => (inUse ? setup.tileInUse : setup.tileReady, inUse ? style.accent : style.onAssistant),
      ModelState.failed => (setup.statusMessage(status, formats) ?? setup.tileFailed, style.error),
    };
    final showBar = const {
      ModelState.queued,
      ModelState.downloading,
      ModelState.paused,
      ModelState.waitingForWifi,
      ModelState.verifying,
    }.contains(status.state);
    Widget action(String label, VoidCallback? onPressed, {Key? key, Color? color}) => TextButton(
      key: key,
      onPressed: onPressed,
      style: TextButton.styleFrom(foregroundColor: color ?? style.accent),
      child: Text(label),
    );
    final id = entry.id;
    final buttons = <Widget>[
      ...switch (status.state) {
        ModelState.notDownloaded || ModelState.failed => [action(setup.actionDownload, actions.download)],
        ModelState.queued || ModelState.downloading => [
          if (status.state == ModelState.downloading) action(setup.actionPause, actions.pause),
          action(setup.actionCancel, actions.cancel),
        ],
        ModelState.waitingForWifi => [
          action(setup.actionUseCellular, actions.useCellular),
          action(setup.actionCancel, actions.cancel),
        ],
        ModelState.paused => [action(setup.actionResume, actions.resume), action(setup.actionCancel, actions.cancel)],
        ModelState.verifying => const <Widget>[],
        ModelState.ready => [
          if (onUseModel != null) action(setup.actionUse, actions.use, key: LocalInferenceKeys.libraryUse(id)),
          action(setup.actionDelete, actions.delete, key: LocalInferenceKeys.libraryDelete(id), color: style.error),
        ],
      },
    ];
    return SurfaceCard(
      margin: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  entry.displayName,
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: style.onAssistant),
                ),
              ),
              if (manager.recommended?.id == id) StatusBadge(label: setup.recommendedBadge),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            '${entry.params} · ${entry.quant} · ${formats.bytes(entry.sizeBytes)}',
            style: TextStyle(fontSize: 13, color: style.secondaryText),
          ),
          const SizedBox(height: 4),
          Text(line, style: TextStyle(fontSize: 14, color: lineColor)),
          if (showBar) ...[
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(style.progressRadius),
              child: LinearProgressIndicator(
                value: status.state == ModelState.verifying ? null : status.progress,
                minHeight: 6,
                color: style.progress,
                backgroundColor: style.progressTrack,
              ),
            ),
          ],
          if (problem != null && status.state != ModelState.failed) ...[
            const SizedBox(height: 4),
            Text(problem, style: TextStyle(fontSize: 13, color: style.error)),
          ],
          if (buttons.isNotEmpty) Wrap(spacing: 4, children: buttons),
        ],
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final setup = LocalInferenceStrings.of(context).setup;
    final confirmed = await showConfirmDialog(
      context,
      ConfirmDialogRequest(
        title: setup.deleteTitle,
        message: setup.deleteBody,
        action: setup.deleteAction,
        destructive: true,
      ),
      presenter: builders.confirmDialog,
    );
    if (confirmed) await manager.delete(entry.id);
  }
}
