/// How the background model download is set up: its group, request headers, notifications and platform settings.
library;

import 'package:flutter/foundation.dart';
import 'package:local_inference/local_inference.dart';

/// Whether Android runs the download as a foreground service. The plugin adds no foreground-service entries;
/// WorkManager merges FOREGROUND_SERVICE and its SystemForegroundService. A host that opts in adds
/// FOREGROUND_SERVICE_DATA_SYNC, `android:foregroundServiceType="dataSync"` on that service and the Play declaration
/// itself. background_downloader keeps the setting across launches, so [AndroidForeground.never] sets it too.
@immutable
sealed class AndroidForeground {
  const AndroidForeground();

  /// No foreground service (the default).
  const factory AndroidForeground.never() = _Never;

  /// Always a foreground service.
  const factory AndroidForeground.always() = _Always;

  /// A foreground service for files larger than [megabytes].
  const factory AndroidForeground.largerThan(int megabytes) = _LargerThan;
}

final class _Never extends AndroidForeground {
  const _Never();

  @override
  bool operator ==(Object other) => other is _Never;

  @override
  int get hashCode => 0;
}

final class _Always extends AndroidForeground {
  const _Always();

  @override
  bool operator ==(Object other) => other is _Always;

  @override
  int get hashCode => 1;
}

final class _LargerThan extends AndroidForeground {
  const _LargerThan(this.megabytes);

  final int megabytes;

  @override
  bool operator ==(Object other) => other is _LargerThan && other.megabytes == megabytes;

  @override
  int get hashCode => megabytes.hashCode;
}

/// The foreground-service setting of [foreground]: null for [AndroidForeground.never] (no foreground service), else
/// `(always: true, megabytes: null)` or `(always: false, megabytes: n)`.
({bool always, int? megabytes})? androidForegroundSetting(AndroidForeground foreground) => switch (foreground) {
  _Never() => null,
  _Always() => (always: true, megabytes: null),
  _LargerThan(:final megabytes) => (always: false, megabytes: megabytes),
};

/// One notification: a title and a body. background_downloader replaces `{progress}` and `{displayName}`.
@immutable
final class DownloadNotificationText {
  const DownloadNotificationText(this.title, this.body);

  final String title;
  final String body;

  @override
  bool operator ==(Object other) => other is DownloadNotificationText && other.title == title && other.body == body;

  @override
  int get hashCode => Object.hash(title, body);

  @override
  String toString() => 'DownloadNotificationText($title, $body)';
}

/// The notifications of a model download, and the words of the iOS notification buttons.
@immutable
final class DownloadNotifications {
  const DownloadNotifications({
    this.running,
    this.paused,
    this.complete,
    this.error,
    this.progressBar = true,
    this.actionLabels,
  });

  /// Italian texts. With [appName] they name the app ("Scarico" and the name, …); without it they speak of the model.
  /// The complete notification is neutral: the system posts it when the transfer ends, before the file is checked.
  factory DownloadNotifications.italian({String? appName}) => DownloadNotifications(
    running: DownloadNotificationText(appName == null ? 'Scarico il modello' : 'Scarico $appName', '{progress}'),
    paused: DownloadNotificationText(
      appName == null ? 'Download del modello in pausa' : 'Download di $appName in pausa',
      "Apri l'app per riprenderlo.",
    ),
    complete: DownloadNotificationText(
      appName == null ? 'Download del modello terminato' : 'Download di $appName terminato',
      "Apri l'app per controllarlo e iniziare.",
    ),
    error: DownloadNotificationText(
      appName == null ? 'Download del modello non riuscito' : 'Download di $appName non riuscito',
      "Apri l'app per riprovare.",
    ),
    actionLabels: const {'Cancel': 'Annulla', 'Pause': 'Pausa', 'Resume': 'Riprendi'},
  );

  /// English texts; iOS keeps its own button words. The complete notification is neutral, as in [italian].
  factory DownloadNotifications.english({String? appName}) => DownloadNotifications(
    running: DownloadNotificationText(appName == null ? 'Downloading the model' : 'Downloading $appName', '{progress}'),
    paused: DownloadNotificationText(
      appName == null ? 'Model download paused' : '$appName download paused',
      'Open the app to resume it.',
    ),
    complete: DownloadNotificationText(
      appName == null ? 'Model download finished' : '$appName download finished',
      'Open the app to check it and start.',
    ),
    error: DownloadNotificationText(
      appName == null ? 'Model download failed' : '$appName download failed',
      'Open the app to try again.',
    ),
  );

  final DownloadNotificationText? running;
  final DownloadNotificationText? paused;
  final DownloadNotificationText? complete;
  final DownloadNotificationText? error;

  /// Whether the running notification shows a progress bar.
  final bool progressBar;

  /// iOS notification buttons, by their English word (`Cancel`, `Pause`, `Resume`); null keeps the system's.
  final Map<String, String>? actionLabels;

  @override
  bool operator ==(Object other) =>
      other is DownloadNotifications &&
      other.running == running &&
      other.paused == paused &&
      other.complete == complete &&
      other.error == error &&
      other.progressBar == progressBar &&
      mapEquals(other.actionLabels, actionLabels);

  @override
  int get hashCode => Object.hash(
    running,
    paused,
    complete,
    error,
    progressBar,
    Object.hashAllUnordered([...?actionLabels?.entries.map((e) => '${e.key}=${e.value}')]),
  );
}

/// The setup of [BackgroundModelDownloader]. The defaults suit a phone app; an app sets its own [group] and its
/// notification texts ([appName], or [notifications]).
@immutable
final class BackgroundDownloadConfig {
  const BackgroundDownloadConfig({
    this.group = 'local_inference_models',
    this.headers = HttpModelDownloader.defaultHeaders,
    this.appName,
    this.notifications,
    this.androidForeground = const AndroidForeground.never(),
    this.retries = 3,
    this.checkAvailableSpaceMB = 500,
    this.iosResourceTimeout = const Duration(hours: 24),
    this.networkCheckInterval = const Duration(seconds: 2),
    this.verifyContent = true,
    this.configureFileDownloader = true,
  });

  /// background_downloader's group of the model tasks. Keep it across releases: a download in progress is found
  /// again by its group.
  final String group;

  /// Sent with every request, added to [HttpModelDownloader.defaultHeaders]: a key given here replaces the default
  /// one, the other defaults stay.
  final Map<String, String> headers;

  /// The app's name in the default notifications.
  final String? appName;

  /// Null: `DownloadNotifications.italian(appName: appName)`.
  final DownloadNotifications? notifications;

  /// Whether Android runs the download as a foreground service.
  final AndroidForeground androidForeground;

  /// background_downloader's retries of a failed task.
  final int retries;

  /// A download needs this much free space, in MB, besides the file.
  final int checkAvailableSpaceMB;

  /// iOS: how long a download may take in all (the system default, 4 h, is short for 3 GB on a slow line).
  final Duration iosResourceTimeout;

  /// How often a queued download checks whether it waits for a connection or for Wi-Fi; on background_downloader
  /// 9.5.9 on Android also how often a Wi-Fi-only download checks that it is still on Wi-Fi.
  final Duration networkCheckInterval;

  /// Whether a finished download is checked before it is reported complete: a `text/html` answer, a status other
  /// than 200 or 206, or (for a GGUF entry) a file without the GGUF magic fails, and the file is deleted.
  final bool verifyContent;

  /// Whether the downloader sets background_downloader's configuration, which holds for every task of the app:
  /// [checkAvailableSpaceMB]; on Android no cache folder, the temporary folder `<models>/.partial` and
  /// [androidForeground] (never included); on iOS [iosResourceTimeout], no iCloud backup and the words of the
  /// notification actions. False: a host with tasks of its own calls `FileDownloader().configure` itself.
  final bool configureFileDownloader;

  /// [notifications], or the Italian defaults for [appName].
  DownloadNotifications get resolvedNotifications => notifications ?? DownloadNotifications.italian(appName: appName);
}
