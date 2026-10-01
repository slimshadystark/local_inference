/// Where models, their partial downloads and the prefix states live on each platform.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'device.dart';

/// Where a background download writes and how its tasks name the folder.
@immutable
sealed class ModelStorageLocation {
  const ModelStorageLocation();

  /// Application Support; tasks keep paths relative to it, so they survive the iOS container moving on an update.
  const factory ModelStorageLocation.applicationSupport() = ApplicationSupportLocation;

  /// An absolute folder, such as Android's noBackupFilesDir; tasks keep absolute paths.
  const factory ModelStorageLocation.absolute(String root) = AbsoluteLocation;
}

/// See [ModelStorageLocation.applicationSupport].
final class ApplicationSupportLocation extends ModelStorageLocation {
  const ApplicationSupportLocation();

  @override
  bool operator ==(Object other) => other is ApplicationSupportLocation;

  @override
  int get hashCode => (ApplicationSupportLocation).hashCode;

  @override
  String toString() => 'ModelStorageLocation.applicationSupport()';
}

/// See [ModelStorageLocation.absolute].
final class AbsoluteLocation extends ModelStorageLocation {
  const AbsoluteLocation(this.root);

  final String root;

  @override
  bool operator ==(Object other) => other is AbsoluteLocation && other.root == root;

  @override
  int get hashCode => root.hashCode;

  @override
  String toString() => 'ModelStorageLocation.absolute($root)';
}

/// Which folder [LocalInferencePaths.resolve] picks for the models.
enum ModelStoragePreference {
  /// Application Support on iOS and macOS; Android's noBackupFilesDir, unless an earlier version left files in
  /// Application Support's `models` folder.
  platformDefault,

  /// Application Support everywhere.
  applicationSupport,

  /// The folder the host names (`customModelsRoot`).
  custom,
}

/// Where this platform keeps the models, their partial downloads and the prefix states ([resolve]).
@immutable
final class LocalInferencePaths {
  const LocalInferencePaths({
    required this.modelsRoot,
    required this.prefixStates,
    required this.downloadLocation,
    this.backupExcludedByLocation = false,
    this.androidTempDirectory,
  });

  /// The model manager's root: files live in `<modelsRoot>/models/<id>/`.
  final String modelsRoot;

  /// Where prefix states go: `<caches>/prefix_states`. The system may purge it; the states are rebuilt.
  final String prefixStates;

  /// How the background downloader names the models' folder.
  final ModelStorageLocation downloadLocation;

  /// Whether the folder itself keeps the models out of backups (Android's noBackupFilesDir).
  final bool backupExcludedByLocation;

  /// Android: where background_downloader keeps a download in progress, `<modelsRoot>/models/.partial`.
  final String? androidTempDirectory;

  /// The folders of this platform. iOS and macOS: Application Support, where apps commonly keep downloaded models,
  /// so models an app installed there before stay where they are. Android: noBackupFilesDir from the plugin, unless
  /// `<Application Support>/models` already holds files from an earlier version (an index, the settings or a download
  /// under way), or the plugin is missing.
  static Future<LocalInferencePaths> resolve({
    ModelStoragePreference models = ModelStoragePreference.platformDefault,
    String? customModelsRoot,
    LocalInferenceDevice device = const LocalInferenceDevice(),
  }) async {
    final support = (await getApplicationSupportDirectory()).path;
    final prefixStates = p.join((await getApplicationCacheDirectory()).path, 'prefix_states');
    final android = defaultTargetPlatform == TargetPlatform.android;
    LocalInferencePaths at(String root, ModelStorageLocation location, {bool excluded = false}) => LocalInferencePaths(
      modelsRoot: root,
      prefixStates: prefixStates,
      downloadLocation: location,
      backupExcludedByLocation: excluded,
      androidTempDirectory: android ? p.join(root, 'models', '.partial') : null,
    );
    switch (models) {
      case ModelStoragePreference.custom:
        final root = customModelsRoot ?? (throw ArgumentError.notNull('customModelsRoot'));
        return at(root, ModelStorageLocation.absolute(root));
      case ModelStoragePreference.applicationSupport:
        return at(support, const ModelStorageLocation.applicationSupport());
      case ModelStoragePreference.platformDefault:
        if (!android || _holdsFiles(p.join(support, 'models'))) {
          return at(support, const ModelStorageLocation.applicationSupport());
        }
        final noBackup = await device.noBackupDirectory();
        if (noBackup == null) return at(support, const ModelStorageLocation.applicationSupport());
        return at(noBackup, ModelStorageLocation.absolute(noBackup), excluded: true);
    }
  }

  /// Whether [folder] exists and is not empty; a folder that cannot be listed counts as holding files.
  static bool _holdsFiles(String folder) {
    final dir = Directory(folder);
    try {
      return dir.existsSync() && dir.listSync().isNotEmpty;
    } on FileSystemException {
      return true;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is LocalInferencePaths &&
      other.modelsRoot == modelsRoot &&
      other.prefixStates == prefixStates &&
      other.downloadLocation == downloadLocation &&
      other.backupExcludedByLocation == backupExcludedByLocation &&
      other.androidTempDirectory == androidTempDirectory;

  @override
  int get hashCode =>
      Object.hash(modelsRoot, prefixStates, downloadLocation, backupExcludedByLocation, androidTempDirectory);

  @override
  String toString() => 'LocalInferencePaths(models: $modelsRoot, $downloadLocation, prefix states: $prefixStates)';
}
