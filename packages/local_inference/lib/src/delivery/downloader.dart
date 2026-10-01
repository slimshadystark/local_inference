/// The model download itself, behind an interface: local_inference_flutter's background downloader on phones,
/// [HttpModelDownloader] in the foreground elsewhere, fakes in tests.
library;

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import 'manifest.dart';

/// A download's state as the downloader reports it; the manager turns it into a `ModelState`.
enum ModelDownloadState { queued, running, paused, waitingForWifi, waitingForNetwork, complete, failed, canceled }

/// Why a download failed. The UI turns it into text (local_inference_flutter's `ModelSetupStrings`).
enum DownloadErrorCode {
  /// The server has no such file (404).
  notFound,

  /// The server answered with an error status ([DownloadError.httpStatus]).
  httpStatus,

  /// The connection dropped or could not be made.
  connection,

  /// No room left on the device.
  diskFull,

  /// The file could not be written.
  fileSystem,

  /// The downloader could not start the task.
  cannotStart,

  /// A paused or failed download could not continue.
  cannotResume,

  /// The server sent a web page instead of the file.
  webPageInsteadOfFile,

  /// Anything else.
  unknown,
}

/// Why a download failed: a [code] for the UI, the [httpStatus] when the server answered, and a technical [detail].
@immutable
final class DownloadError {
  const DownloadError(this.code, {this.httpStatus, this.detail});

  /// What a downloader reports when the finished file is neither a GGUF model nor a web page; the manager turns it
  /// into `ModelErrorCode.notAModelFile`.
  static const notAGgufFile = DownloadError(DownloadErrorCode.unknown, detail: 'not a GGUF file');

  final DownloadErrorCode code;

  /// The response status, for [DownloadErrorCode.httpStatus] (and [DownloadErrorCode.notFound] when known).
  final int? httpStatus;

  /// The underlying error's text, for technical details; never shown as the reason.
  final String? detail;

  @override
  bool operator ==(Object other) =>
      other is DownloadError && other.code == code && other.httpStatus == httpStatus && other.detail == detail;

  @override
  int get hashCode => Object.hash(code, httpStatus, detail);

  @override
  String toString() =>
      'DownloadError(${code.name}${httpStatus == null ? '' : ' $httpStatus'}${detail == null ? '' : ': $detail'})';
}

/// One report of a download, by model id: its state and, when known, the progress, size, speed and time left; the
/// [error] when it failed.
@immutable
final class ModelDownloadUpdate {
  const ModelDownloadUpdate({
    required this.id,
    required this.state,
    this.progress,
    this.expectedBytes,
    this.bytesPerSecond,
    this.timeRemaining,
    this.error,
  });

  /// The model id (also the task id).
  final String id;
  final ModelDownloadState state;

  /// 0..1, when the update carries progress.
  final double? progress;

  /// The server's Content-Length.
  final int? expectedBytes;

  /// The measured transfer rate.
  final double? bytesPerSecond;
  final Duration? timeRemaining;

  /// Why [ModelDownloadState.failed].
  final DownloadError? error;

  @override
  bool operator ==(Object other) =>
      other is ModelDownloadUpdate &&
      other.id == id &&
      other.state == state &&
      other.progress == progress &&
      other.expectedBytes == expectedBytes &&
      other.bytesPerSecond == bytesPerSecond &&
      other.timeRemaining == timeRemaining &&
      other.error == error;

  @override
  int get hashCode => Object.hash(id, state, progress, expectedBytes, bytesPerSecond, timeRemaining, error);

  @override
  String toString() => 'ModelDownloadUpdate($id, ${state.name}, progress: $progress${error == null ? '' : ', $error'})';
}

/// What the first bytes of a downloaded file show, before anything trusts it as a model.
enum DownloadedContent {
  /// The GGUF magic, `GGUF`.
  gguf,

  /// A web page: the first byte that is not blank is `<`.
  webPage,

  /// Neither.
  other;

  /// Reads [head], the first bytes of the file: at least 4 unless the file is shorter.
  static DownloadedContent of(List<int> head) {
    final first = head.indexWhere((b) => b != 0x20 && b != 0x09 && b != 0x0a && b != 0x0d);
    if (first >= 0 && head[first] == 0x3c) return webPage;
    const magic = [0x47, 0x47, 0x55, 0x46];
    if (head.length >= 4 && Iterable<int>.generate(4).every((i) => head[i] == magic[i])) return gguf;
    return other;
  }
}

/// Where the download of [entry] writes its file: `<directory>/<partFileName>`, as [ModelDownloader.start] names it.
@immutable
final class DownloadTarget {
  const DownloadTarget(this.entry, {required this.directory, required this.partFileName});

  final ModelEntry entry;

  /// The absolute folder.
  final String directory;
  final String partFileName;

  /// `<directory>/<partFileName>`.
  String get path => p.join(directory, partFileName);

  @override
  bool operator ==(Object other) =>
      other is DownloadTarget &&
      other.entry == entry &&
      other.directory == directory &&
      other.partFileName == partFileName;

  @override
  int get hashCode => Object.hash(entry, directory, partFileName);

  @override
  String toString() => 'DownloadTarget(${entry.id}, $path)';
}

/// Runs the model downloads of a manager: one download per model id, written to `<directory>/<partFileName>`, each
/// change reported on [updates].
abstract interface class ModelDownloader {
  /// Starts downloading [entry] into the absolute folder [directory] as [partFileName], from the first byte. [wifiOnly]
  /// asks for Wi-Fi (a downloader that cannot tell networks apart ignores it).
  Future<void> start(
    ModelEntry entry, {
    required String directory,
    required String partFileName,
    required bool wifiOnly,
  });

  /// Pauses the download of [id], keeping what it received.
  Future<void> pause(String id);

  /// Resumes a paused download, or a failed one whose partial data [canResume] reports, with the network rule it was
  /// started with; starts it again when it cannot resume. A resume that fails later on, because the kept data turned
  /// out unusable, fails with [DownloadErrorCode.cannotResume].
  Future<void> resume(String id);

  /// Whether the partial data of [id] can still be resumed, also after a relaunch: a failed download whose data the
  /// downloader kept, or a part file an earlier process left ([restore]).
  Future<bool> canResume(String id);

  /// Deletes the partial data of [id], also what an earlier process left.
  Future<void> discard(String id);

  /// Stops the download of [id] and deletes its part file; [updates] then reports it canceled.
  Future<void> cancel(String id);

  /// Every change of every download (a broadcast stream).
  Stream<ModelDownloadUpdate> get updates;

  /// Reattaches to downloads that ran while the app was suspended or closed, and reports their state. [targets] name
  /// where the manager's models would be written: a downloader that keeps no records of its own (the foreground
  /// `HttpModelDownloader`) reports a part file an earlier process left there as a paused download, which it can
  /// then resume or discard; one that keeps its records ignores them.
  Future<void> restore({Iterable<DownloadTarget> targets = const []});
}
