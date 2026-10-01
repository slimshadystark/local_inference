/// A foreground model download on dart:io, for CLI, desktop, server and tests.
library;

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'downloader.dart';
import 'manifest.dart';

/// Downloads in the foreground with dart:io's [HttpClient], into `<directory>/<partFileName>` (the folder is created).
///
/// - A resumed download sends `Range: bytes=<part length>-`, with `If-Range` on the strong ETag (or the
///   Last-Modified date) of the last answer: a 206 is appended, a 200 (the file changed, or no range support)
///   starts the part file again.
/// - A `text/html` answer, or a body whose first non-blank byte is `<`, fails as
///   [DownloadErrorCode.webPageInsteadOfFile] before anything is written; so does, as [DownloadError.notAGgufFile], a
///   GGUF entry's body that does not start with the GGUF magic. A resumed answer (206) is checked only against the
///   size the entry names: another total means the file changed, and the download starts again.
/// - A dropped connection, a stall of [stallTimeout], or a 408, 429 or 5xx answer is retried [retries] times,
///   after [retryDelay], then twice as long each time; each retry resumes.
/// - Every request sends [defaultHeaders] plus what the `headers` provider gives for the model; a key the provider
///   gives replaces the default one.
/// - `wifiOnly` is ignored: dart:io cannot tell networks apart.
/// - Progress is reported at most every 250 ms. [canResume] is true while a non-empty part file of a download
///   started by this downloader, or found by [restore], exists; [discard] deletes it.
/// - [restore] finds the part files an earlier process left at the targets the manager names, and reports each as a
///   paused download, which [resume] continues with a Range request (without If-Range: the validator of the last
///   answer is not kept, so the size check and the manager's SHA-256 check catch a file that changed meanwhile).
final class HttpModelDownloader implements ModelDownloader {
  HttpModelDownloader({
    FutureOr<Map<String, String>> Function(ModelEntry entry)? headers,
    this.retries = 3,
    HttpClient Function()? client,
    this.retryDelay = const Duration(seconds: 1),
    this.stallTimeout = const Duration(seconds: 60),
  }) : _headers = headers,
       _client = client ?? HttpClient.new;

  /// Asks Azure Blob Storage for a recent API version (byte ranges and a quoted ETag) and any server for the stored
  /// bytes (a CDN that gzips a .gguf sends no length and only a weak ETag).
  static const defaultHeaders = {'x-ms-version': '2021-08-06', 'Accept-Encoding': 'identity'};

  /// How many times a failed attempt is tried again.
  final int retries;

  /// The wait before the first retry; it doubles for each next one.
  final Duration retryDelay;

  /// How long the body may stay silent before the attempt counts as a dropped connection.
  final Duration stallTimeout;

  final FutureOr<Map<String, String>> Function(ModelEntry entry)? _headers;
  final HttpClient Function() _client;
  final _tasks = <String, _Task>{};
  final _controller = StreamController<ModelDownloadUpdate>.broadcast();
  bool _closed = false;

  @override
  Stream<ModelDownloadUpdate> get updates => _controller.stream;

  @override
  Future<void> start(
    ModelEntry entry, {
    required String directory,
    required String partFileName,
    required bool wifiOnly,
  }) async {
    _check();
    _tasks[entry.id]?.stop();
    final task = _tasks[entry.id] = _Task(entry, p.join(directory, partFileName));
    _emit(ModelDownloadUpdate(id: entry.id, state: ModelDownloadState.queued, expectedBytes: entry.sizeBytes));
    unawaited(_run(task, task.next(), fresh: true));
  }

  @override
  Future<void> pause(String id) async {
    final task = _tasks[id];
    if (task == null || !task.active) return;
    task.stop();
    final done = await _length(task.path);
    _emit(ModelDownloadUpdate(id: id, state: ModelDownloadState.paused, progress: _fraction(done, task.total)));
  }

  @override
  Future<void> resume(String id) async {
    _check();
    final task = _tasks[id];
    if (task == null) {
      _emit(
        ModelDownloadUpdate(
          id: id,
          state: ModelDownloadState.failed,
          error: const DownloadError(DownloadErrorCode.cannotResume, detail: 'no download of this id in this process'),
        ),
      );
      return;
    }
    if (task.active) return;
    _emit(ModelDownloadUpdate(id: id, state: ModelDownloadState.queued));
    unawaited(_run(task, task.next(), fresh: false));
  }

  @override
  Future<bool> canResume(String id) async {
    final task = _tasks[id];
    return task != null && await _length(task.path) > 0;
  }

  @override
  Future<void> discard(String id) async {
    final task = _tasks[id];
    if (task == null) return;
    task.stop();
    await _delete(task.path);
  }

  @override
  Future<void> cancel(String id) async {
    final task = _tasks.remove(id);
    if (task == null) return;
    task.stop();
    await _delete(task.path);
    _emit(ModelDownloadUpdate(id: id, state: ModelDownloadState.canceled));
  }

  /// Reports each partial part file at [targets] (a download an earlier process left) as paused, so it can resume
  /// or be discarded. A complete one is left to the manager's check at launch.
  @override
  Future<void> restore({Iterable<DownloadTarget> targets = const []}) async {
    _check();
    for (final target in targets) {
      final id = target.entry.id;
      if (_tasks[id] != null) continue;
      final length = await _length(target.path);
      final size = target.entry.sizeBytes;
      if (length <= 0 || size > 0 && length >= size) continue;
      final task = _tasks[id] = _Task(target.entry, target.path)..total = size > 0 ? size : null;
      _emit(
        ModelDownloadUpdate(
          id: id,
          state: ModelDownloadState.paused,
          progress: _fraction(length, task.total),
          expectedBytes: task.total,
        ),
      );
    }
  }

  /// Stops every download (their part files stay) and closes [updates].
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final task in _tasks.values) {
      task.stop();
    }
    await _controller.close();
  }

  /// One download: attempts until the file is complete, the error is final or [run] is no longer the task's.
  Future<void> _run(_Task task, int run, {required bool fresh}) async {
    task.active = true;
    if (fresh) await _delete(task.path);
    try {
      await File(task.path).parent.create(recursive: true);
    } on FileSystemException {
      // The first write reports it.
    }
    var attempt = 0;
    while (task.run == run) {
      try {
        if (await _attempt(task, run)) {
          task.active = false;
          _emit(ModelDownloadUpdate(id: task.entry.id, state: ModelDownloadState.complete, progress: 1));
        }
        return;
      } catch (e) {
        if (task.run != run) return;
        final error = _errorOf(e);
        if (attempt < retries && _retryable(error)) {
          await Future<void>.delayed(retryDelay * (1 << attempt));
          attempt++;
          continue;
        }
        task.active = false;
        _emit(ModelDownloadUpdate(id: task.entry.id, state: ModelDownloadState.failed, error: error));
        return;
      }
    }
  }

  /// One request. True when the part file is complete; false when [run] stopped meanwhile.
  Future<bool> _attempt(_Task task, int run) async {
    final file = File(task.path);
    final offset = await _length(task.path);
    final client = task.client = _client()..connectionTimeout ??= const Duration(seconds: 30);
    try {
      final request = await client.getUrl(task.entry.url);
      final headers = {...defaultHeaders, ...?await _headers?.call(task.entry)};
      headers.forEach(request.headers.set);
      if (offset > 0) {
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=$offset-');
        final validator = task.validator;
        if (validator != null) request.headers.set(HttpHeaders.ifRangeHeader, validator);
      }
      final response = await request.close();
      if (task.run != run) return false;
      final status = response.statusCode;
      if (status == HttpStatus.requestedRangeNotSatisfiable && offset > 0) {
        final total = _totalOf(response.headers.value(HttpHeaders.contentRangeHeader));
        await response.drain<void>();
        if (total == offset) {
          task.total = total;
          return true;
        }
        await _delete(task.path);
        throw const _Failure(DownloadError(DownloadErrorCode.connection, detail: 'range refused: starting again'));
      }
      final appending = status == HttpStatus.partialContent && offset > 0;
      if (status != HttpStatus.ok && status != HttpStatus.partialContent) {
        await response.drain<void>();
        throw _Failure(
          status == HttpStatus.notFound
              ? const DownloadError(DownloadErrorCode.notFound, httpStatus: HttpStatus.notFound)
              : DownloadError(DownloadErrorCode.httpStatus, httpStatus: status),
        );
      }
      final contentRange = response.headers.value(HttpHeaders.contentRangeHeader);
      if (appending && _startOf(contentRange) != offset) {
        await response.drain<void>();
        await _delete(task.path);
        throw const _Failure(DownloadError(DownloadErrorCode.connection, detail: 'the range started elsewhere'));
      }
      final size = task.entry.sizeBytes;
      final announced = _totalOf(contentRange);
      if (appending && size > 0 && announced != null && announced != size) {
        await response.drain<void>();
        await _delete(task.path);
        throw _Failure(
          DownloadError(DownloadErrorCode.connection, detail: 'the file has $announced bytes, expected $size'),
        );
      }
      final type = response.headers.contentType;
      if (type != null && type.mimeType == 'text/html') {
        await response.drain<void>();
        throw const _Failure(DownloadError(DownloadErrorCode.webPageInsteadOfFile, detail: 'Content-Type text/html'));
      }
      task.validator = _validatorOf(response.headers) ?? task.validator;
      final length = response.contentLength;
      final total = task.total = length < 0 ? null : (appending ? offset : 0) + length;
      return await _receive(task, run, response, file, from: appending ? offset : 0, total: total);
    } finally {
      client.close(force: true);
      if (identical(task.client, client)) task.client = null;
    }
  }

  /// Writes the body after [from] bytes of the part file; checks the start of a whole body for a web page and, for a
  /// GGUF entry, for the GGUF magic.
  Future<bool> _receive(
    _Task task,
    int run,
    HttpClientResponse response,
    File file, {
    required int from,
    required int? total,
  }) async {
    RandomAccessFile? out;
    var received = from;
    // The first bytes wait until they show what the body is, so a web page never truncates the part file.
    final head = <int>[];
    var looked = from > 0;
    final gguf = task.entry.format == 'gguf';
    final clock = Stopwatch()..start();
    var reported = -1;
    try {
      await for (final chunk in response.timeout(stallTimeout)) {
        if (task.run != run) return false;
        var bytes = chunk;
        if (!looked) {
          head.addAll(chunk);
          if (!_shows(head, gguf: gguf)) continue;
          _checkHead(head, gguf: gguf);
          looked = true;
          bytes = List.of(head);
          head.clear();
        }
        out ??= await file.open(mode: from > 0 ? FileMode.append : FileMode.write);
        await out.writeFrom(bytes);
        received += bytes.length;
        final now = clock.elapsedMilliseconds;
        if (task.run != run) return false;
        if (reported < 0 || now - reported >= 250) {
          reported = now;
          final seconds = now / 1000;
          final speed = seconds > 0 ? (received - from) / seconds : null;
          _emit(
            ModelDownloadUpdate(
              id: task.entry.id,
              state: ModelDownloadState.running,
              progress: _fraction(received, total),
              expectedBytes: total,
              bytesPerSecond: speed,
              timeRemaining: speed == null || speed <= 0 || total == null
                  ? null
                  : Duration(milliseconds: ((total - received) / speed * 1000).round()),
            ),
          );
        }
      }
      if (task.run != run) return false;
      if (!looked) _checkHead(head, gguf: gguf);
      out ??= await file.open(mode: from > 0 ? FileMode.append : FileMode.write);
      if (head.isNotEmpty) {
        await out.writeFrom(head);
        received += head.length;
      }
      await out.flush();
      if (total != null && received != total) {
        throw HttpException('the body ended after $received of $total bytes', uri: task.entry.url);
      }
      return true;
    } finally {
      await out?.close();
    }
  }

  void _check() {
    if (_closed) throw StateError('HttpModelDownloader is closed');
  }

  /// Whether [head] is long enough to tell a web page (its first non-blank byte) and, for a GGUF entry, the magic.
  static bool _shows(List<int> head, {required bool gguf}) {
    final blank = head.every((b) => b == 0x20 || b == 0x09 || b == 0x0a || b == 0x0d);
    return !blank && (!gguf || head.length >= 4 || head.contains(0x3c));
  }

  /// Fails a body whose start [head] is a web page, or, for a GGUF entry, not a GGUF file.
  static void _checkHead(List<int> head, {required bool gguf}) {
    switch (DownloadedContent.of(head)) {
      case DownloadedContent.webPage:
        throw const _Failure(DownloadError(DownloadErrorCode.webPageInsteadOfFile, detail: 'the body starts with <'));
      case DownloadedContent.other when gguf:
        throw const _Failure(DownloadError.notAGgufFile);
      case DownloadedContent.gguf || DownloadedContent.other:
        return;
    }
  }

  void _emit(ModelDownloadUpdate update) {
    if (!_controller.isClosed) _controller.add(update);
  }

  static bool _retryable(DownloadError error) => switch (error.code) {
    DownloadErrorCode.connection => true,
    DownloadErrorCode.httpStatus => const {408, 429}.contains(error.httpStatus) || (error.httpStatus ?? 0) >= 500,
    _ => false,
  };

  static DownloadError _errorOf(Object e) => switch (e) {
    _Failure(:final error) => error,
    FileSystemException(:final osError, :final message) when osError?.errorCode == 28 || '$e'.contains('space') =>
      DownloadError(DownloadErrorCode.diskFull, detail: osError?.message ?? message),
    FileSystemException() => DownloadError(DownloadErrorCode.fileSystem, detail: '$e'),
    IOException() || TimeoutException() => DownloadError(DownloadErrorCode.connection, detail: '$e'),
    _ => DownloadError(DownloadErrorCode.unknown, detail: '$e'),
  };

  /// The strong ETag, else the Last-Modified date: what If-Range may carry.
  static String? _validatorOf(HttpHeaders headers) {
    final etag = headers.value(HttpHeaders.etagHeader);
    if (etag != null && etag.startsWith('"')) return etag;
    return headers.value(HttpHeaders.lastModifiedHeader);
  }

  /// The first byte of `bytes <start>-<end>/<total>`.
  static int? _startOf(String? contentRange) =>
      int.tryParse(RegExp(r'^bytes (\d+)-').firstMatch(contentRange ?? '')?.group(1) ?? '');

  /// The total of `bytes <range>/<total>` or `bytes */<total>`.
  static int? _totalOf(String? contentRange) =>
      int.tryParse(RegExp(r'/(\d+)$').firstMatch(contentRange ?? '')?.group(1) ?? '');

  static double? _fraction(int done, int? total) => total == null || total <= 0 ? null : (done / total).clamp(0.0, 1.0);

  static Future<int> _length(String path) async {
    try {
      return await File(path).length();
    } on FileSystemException {
      return 0;
    }
  }

  static Future<void> _delete(String path) async {
    try {
      await File(path).delete();
    } on FileSystemException {
      return;
    }
  }
}

/// A download this process started; [run] changes whenever it is stopped, so a stale attempt knows to quit.
final class _Task {
  _Task(this.entry, this.path);

  final ModelEntry entry;
  final String path;
  int run = 0;
  bool active = false;
  int? total;
  String? validator;
  HttpClient? client;

  /// The id of a new run; the attempts of the earlier runs quit.
  int next() => ++run;

  /// Ends the current attempt.
  void stop() {
    active = false;
    client?.close(force: true);
    run++;
  }
}

final class _Failure implements Exception {
  const _Failure(this.error);

  final DownloadError error;

  @override
  String toString() => '$error';
}
