/// The list of downloadable models, schema 1 (the package README, "Model manifest", shows the format).
///
/// Models change without an app release: the app fetches the manifest from its hosting at launch and
/// falls back to the copy bundled in the app. Each entry carries what the app needs to decide, before
/// any byte is downloaded, whether the phone can run the model (RAM) and store it (disk), and what to
/// check afterwards (exact size and SHA-256). Parsing is strict: a malformed manifest is rejected as a
/// whole with the path of the first bad field, so a bad upload falls back to the bundled list instead of
/// offering a model the app cannot verify.
library;

import 'dart:convert';

import 'package:meta/meta.dart';

import 'device.dart';

/// Thrown by [ModelManifest.parse] with the path of the offending field.
final class ModelManifestException implements Exception {
  const ModelManifestException(this.message);
  final String message;

  @override
  String toString() => 'ModelManifestException: $message';
}

/// Whether a model is offered.
enum ModelAvailability {
  /// Offered.
  active,

  /// Kept if installed, not offered.
  deprecated,

  /// Not offered.
  revoked,
}

/// One downloadable model: where its file is, its exact size and SHA-256, and what the device needs to run and store
/// it.
final class ModelEntry {
  /// An entry built by the host (for [ModelManifest.parse] every field is required). [sha256] null skips the
  /// content check: only the size is verified. [id] names the model's folder: letters, digits, '.', '_' and '-'.
  const ModelEntry({
    required this.id,
    required this.url,
    required this.sizeBytes,
    this.sha256,
    this.version = 1,
    this.displayName = '',
    this.params = '',
    this.quant = '',
    this.format = 'gguf',
    this.availability = ModelAvailability.active,
    this.recommended = false,
    this.minPhysicalRamMB = 0,
    this.minAvailableMemoryMB = 0,
    this.minFreeDiskMB = 0,
  });

  final String id;
  final int version;
  final String displayName;
  final String params;
  final String quant;
  final String format;
  final ModelAvailability availability;
  final bool recommended;
  final Uri url;
  final int sizeBytes;

  /// Lowercase hex; null only in an entry the host built.
  final String? sha256;
  final int minPhysicalRamMB;
  final int minAvailableMemoryMB;
  final int minFreeDiskMB;

  bool get isActive => availability == ModelAvailability.active;

  /// The file name the model is stored under (the URL's last segment), e.g. qwen3.5-4b-…-Q5_K_M.gguf.
  String get fileName => url.pathSegments.last;

  /// Name of the file while it downloads and until its SHA-256 matches.
  String get partFileName => '$fileName.part';

  /// Whether RAM allows this model; unknown values pass.
  bool fitsMemory(DeviceCapabilities device) =>
      (device.physicalMemoryMB == null || device.physicalMemoryMB! >= minPhysicalRamMB) &&
      (device.availableMemoryMB == null || device.availableMemoryMB! >= minAvailableMemoryMB);

  /// Whether the disk has room for the download; unknown passes (the downloader checks again natively).
  bool fitsDisk(DeviceCapabilities device) => device.freeDiskMB == null || device.freeDiskMB! >= minFreeDiskMB;

  /// Parses one entry of a published manifest: every field is set, `format` is `gguf`, and `file.url` is an https URL
  /// ending in a .gguf file name. [requireSha256] false also accepts an entry without `file.sha256`.
  static ModelEntry fromJson(Object? json, {String path = 'model', bool requireSha256 = true}) =>
      _parse(json, path, strict: true, requireSha256: requireSha256);

  /// Reads back whatever [toJson] wrote, also for an entry built with the constructor, as the model index does for
  /// the entries its models were verified against: the texts may be empty, `file.sha256` may be missing, `format` may
  /// be another name, and the URL may use another scheme or file name. The id and the file name are still checked,
  /// since they name the model's folder and file. Never for a manifest read from the network: that is [fromJson].
  @internal
  static ModelEntry fromIndexJson(Object? json, {String path = 'model'}) =>
      _parse(json, path, strict: false, requireSha256: false);

  static ModelEntry _parse(Object? json, String path, {required bool strict, required bool requireSha256}) {
    final m = _object(json, path);
    final file = _object(m['file'], '$path.file');
    final req = _object(m['requirements'], '$path.requirements');
    String text(Map<String, Object?> map, String key, String where) =>
        strict ? _string(map, key, where) : _anyString(map, key, where);
    final id = _string(m, 'id', path);
    if (!RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(id)) {
      throw ModelManifestException("$path.id: '$id' may only use letters, digits, '.', '_' and '-'");
    }
    final format = _string(m, 'format', path);
    if (strict && format != 'gguf') throw ModelManifestException("$path.format: expected 'gguf', got '$format'");
    final status = m.containsKey('status') ? _string(m, 'status', path) : 'active';
    final availability = ModelAvailability.values.where((a) => a.name == status).firstOrNull;
    if (availability == null) {
      final statuses = ModelAvailability.values.map((a) => a.name);
      throw ModelManifestException('$path.status: expected one of ${statuses.join(', ')}, got \'$status\'');
    }
    final recommended = m['recommended'] ?? false;
    if (recommended is! bool) throw ModelManifestException('$path.recommended: expected true or false');
    final urlText = _string(file, 'url', '$path.file');
    final url = Uri.tryParse(urlText);
    if (url == null || strict && (url.scheme != 'https' || url.host.isEmpty)) {
      throw ModelManifestException('$path.file.url: expected an https URL, got \'$urlText\'');
    }
    if (url.pathSegments.isEmpty || strict && !url.pathSegments.last.toLowerCase().endsWith('.gguf')) {
      throw ModelManifestException('$path.file.url: expected a URL ending in a .gguf file name');
    }
    final fileName = url.pathSegments.last;
    if (fileName.isEmpty || fileName.contains('/') || fileName.contains(r'\') || fileName.startsWith('.')) {
      throw ModelManifestException('$path.file.url: unsafe file name \'$fileName\'');
    }
    String? sha;
    if (requireSha256 || file['sha256'] != null) {
      sha = _string(file, 'sha256', '$path.file').toLowerCase();
      if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(sha)) {
        throw ModelManifestException('$path.file.sha256: expected 64 hexadecimal characters');
      }
    }
    return ModelEntry(
      id: id,
      version: _int(m, 'version', path, min: 0),
      displayName: text(m, 'displayName', path),
      params: text(m, 'params', path),
      quant: text(m, 'quant', path),
      format: format,
      availability: availability,
      recommended: recommended,
      url: url,
      sizeBytes: _int(file, 'sizeBytes', '$path.file', min: 1),
      sha256: sha,
      minPhysicalRamMB: _int(req, 'minPhysicalRamMB', '$path.requirements', min: 0),
      minAvailableMemoryMB: _int(req, 'minAvailableMemoryMB', '$path.requirements', min: 0),
      minFreeDiskMB: _int(req, 'minFreeDiskMB', '$path.requirements', min: 0),
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'version': version,
    'displayName': displayName,
    'params': params,
    'quant': quant,
    'format': format,
    'status': availability.name,
    'recommended': recommended,
    'file': {'url': '$url', 'sizeBytes': sizeBytes, 'sha256': ?sha256},
    'requirements': {
      'minPhysicalRamMB': minPhysicalRamMB,
      'minAvailableMemoryMB': minAvailableMemoryMB,
      'minFreeDiskMB': minFreeDiskMB,
    },
  };

  @override
  bool operator ==(Object other) =>
      other is ModelEntry &&
      other.id == id &&
      other.version == version &&
      other.displayName == displayName &&
      other.params == params &&
      other.quant == quant &&
      other.format == format &&
      other.availability == availability &&
      other.recommended == recommended &&
      other.url == url &&
      other.sizeBytes == sizeBytes &&
      other.sha256 == sha256 &&
      other.minPhysicalRamMB == minPhysicalRamMB &&
      other.minAvailableMemoryMB == minAvailableMemoryMB &&
      other.minFreeDiskMB == minFreeDiskMB;

  @override
  int get hashCode => Object.hash(id, version, url, sizeBytes, sha256);

  @override
  String toString() => 'ModelEntry($id, $sizeBytes)';
}

/// The models on offer, in order ([parse] reads a published schema-1 manifest).
final class ModelManifest {
  /// A manifest built by the host; [parse] reads a published one.
  const ModelManifest({required this.models, this.schemaVersion = supportedSchemaVersion, this.manifestVersion = ''});

  static const supportedSchemaVersion = 1;

  final int schemaVersion;
  final String manifestVersion;
  final List<ModelEntry> models;

  static ModelManifest parse(String json) {
    final Object? decoded;
    try {
      decoded = jsonDecode(json);
    } on FormatException catch (e) {
      throw ModelManifestException('not valid JSON: ${e.message}');
    }
    final root = _object(decoded, 'manifest');
    final schema = _int(root, 'schemaVersion', 'manifest', min: 1);
    if (schema != supportedSchemaVersion) {
      throw ModelManifestException(
        'manifest.schemaVersion: $schema is not supported (expected $supportedSchemaVersion)',
      );
    }
    final list = root['models'];
    if (list is! List || list.isEmpty) throw const ModelManifestException('manifest.models: expected a non-empty list');
    final models = [for (var i = 0; i < list.length; i++) ModelEntry.fromJson(list[i], path: 'models[$i]')];
    final seen = <String>{};
    for (final m in models) {
      if (!seen.add(m.id)) throw ModelManifestException("manifest.models: duplicate id '${m.id}'");
    }
    return ModelManifest(
      schemaVersion: schema,
      manifestVersion: _string(root, 'manifestVersion', 'manifest'),
      models: List.unmodifiable(models),
    );
  }

  ModelEntry? byId(String id) {
    for (final m in models) {
      if (m.id == id) return m;
    }
    return null;
  }

  /// Active models the phone's memory can run, best first (see [recommendedFor]).
  List<ModelEntry> eligible(DeviceCapabilities device) => [
    for (final m in models)
      if (m.isActive && m.fitsMemory(device)) m,
  ]..sort(_better);

  /// The model to offer: the best eligible one, or the manifest's recommended one when nothing is known
  /// about the phone. Null when no active model fits.
  ModelEntry? recommendedFor(DeviceCapabilities device) {
    if (device.isUnknown) {
      final active = [
        for (final m in models)
          if (m.isActive) m,
      ]..sort(_better);
      return active.isEmpty ? null : active.first;
    }
    final fits = eligible(device);
    return fits.isEmpty ? null : fits.first;
  }

  /// The manifest's recommended flag first, then the more demanding (larger) model.
  static int _better(ModelEntry a, ModelEntry b) {
    if (a.recommended != b.recommended) return a.recommended ? -1 : 1;
    if (a.minPhysicalRamMB != b.minPhysicalRamMB) return b.minPhysicalRamMB.compareTo(a.minPhysicalRamMB);
    return b.sizeBytes.compareTo(a.sizeBytes);
  }
}

Map<String, Object?> _object(Object? value, String path) {
  if (value is Map<String, Object?>) return value;
  if (value is Map) return value.cast<String, Object?>();
  throw ModelManifestException('$path: expected an object');
}

String _string(Map<String, Object?> m, String key, String path) {
  final v = m[key];
  if (v is String && v.trim().isNotEmpty) return v;
  throw ModelManifestException('$path.$key: expected a non-empty string');
}

String _anyString(Map<String, Object?> m, String key, String path) {
  final v = m[key];
  if (v is String) return v;
  throw ModelManifestException('$path.$key: expected a string');
}

int _int(Map<String, Object?> m, String key, String path, {required int min}) {
  final v = m[key];
  if (v is int && v >= min) return v;
  throw ModelManifestException('$path.$key: expected an integer ≥ $min');
}
