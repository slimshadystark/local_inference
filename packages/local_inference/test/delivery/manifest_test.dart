// The model manifest: malformed manifests are rejected with the field's path, model selection by RAM (unknown
// values pass), JSON round trips, host-built entries, and the README's example.
import 'dart:convert';
import 'dart:io';

import 'package:local_inference/local_inference.dart';
import 'package:test/test.dart';

/// The requirements of a two-model manifest: a 4B and a 2B.
String get _bundled => jsonEncode({
  'schemaVersion': 1,
  'manifestVersion': '2026-09-17',
  'models': [
    _model(id: 'qwen3.5-4b-tuned-q5km', url: 'https://example.org/models/model-4b-Q5_K_M.gguf'),
    _model(
      id: 'qwen3.5-2b-tuned-q5km',
      url: 'https://example.org/models/model-2b-Q5_K_M.gguf',
      size: 1454787104,
      recommended: false,
      params: '2B',
      ram: 5500,
      available: 2000,
      disk: 2027,
    ),
  ],
});

Map<String, dynamic> _model({
  String id = 'test-4b',
  String url = 'https://example.org/models/model-4b-Q5_K_M.gguf',
  Object? sha = 'ab',
  Object? size = 3074986592,
  bool recommended = true,
  String params = '4B',
  int ram = 7000,
  int available = 3800,
  int disk = 3726,
}) => {
  'id': id,
  'version': 1,
  'displayName': 'Assistant $params',
  'params': params,
  'quant': 'Q5_K_M',
  'format': 'gguf',
  'status': 'active',
  'recommended': recommended,
  'file': {'url': url, 'sizeBytes': size, 'sha256': sha == 'ab' ? 'AB' * 32 : sha},
  'requirements': {'minPhysicalRamMB': ram, 'minAvailableMemoryMB': available, 'minFreeDiskMB': disk},
};

String _manifest(List<Map<String, dynamic>> models, {int schema = 1}) =>
    jsonEncode({'schemaVersion': schema, 'manifestVersion': '2026-09-17', 'models': models});

Matcher _rejects(String fragment) =>
    throwsA(isA<ModelManifestException>().having((e) => e.message, 'message', contains(fragment)));

void main() {
  test('malformed manifests are rejected with the path of the bad field', () {
    expect(() => ModelManifest.parse('{'), _rejects('not valid JSON'));
    expect(() => ModelManifest.parse('[]'), _rejects('manifest: expected an object'));
    expect(() => ModelManifest.parse(_manifest([_model()], schema: 2)), _rejects('schemaVersion: 2 is not supported'));
    expect(() => ModelManifest.parse(_manifest([])), _rejects('manifest.models: expected a non-empty list'));
    expect(() => ModelManifest.parse(_manifest([_model(sha: 'xyz')])), _rejects('models[0].file.sha256'));
    expect(() => ModelManifest.parse(_manifest([_model(sha: null)])), _rejects('models[0].file.sha256'));
    expect(() => ModelManifest.parse(_manifest([_model(size: -1)])), _rejects('models[0].file.sizeBytes'));
    expect(() => ModelManifest.parse(_manifest([_model(size: '3 GB')])), _rejects('models[0].file.sizeBytes'));
    expect(
      () => ModelManifest.parse(_manifest([_model(url: 'http://example.org/a.gguf')])),
      _rejects('expected an https URL'),
    );
    expect(
      () => ModelManifest.parse(_manifest([_model(url: 'https://example.org/a.bin')])),
      _rejects('.gguf file name'),
    );
    expect(() => ModelManifest.parse(_manifest([_model(id: '../x')])), _rejects('models[0].id'));
    expect(() => ModelManifest.parse(_manifest([_model(), _model()])), _rejects("duplicate id 'test-4b'"));
    final noRequirements = _model()..remove('requirements');
    expect(
      () => ModelManifest.parse(_manifest([noRequirements])),
      _rejects('models[0].requirements: expected an object'),
    );
    final badFormat = _model()..['format'] = 'litertlm';
    expect(() => ModelManifest.parse(_manifest([badFormat])), _rejects("expected 'gguf'"));
    final badStatus = _model()..['status'] = 'beta';
    expect(
      () => ModelManifest.parse(_manifest([_model(id: 'ok'), badStatus])),
      _rejects("models[1].status: expected one of active, deprecated, revoked, got 'beta'"),
    );
    expect(ModelManifest.parse(_manifest([_model()])).models.single.sha256, 'ab' * 32);
  });

  test('selection: RAM decides between 4B and 2B, unknown values pass, inactive models are never offered', () {
    final manifest = ModelManifest.parse(_bundled);
    const iphone16ProMax = DeviceCapabilities(physicalMemoryMB: 7622, availableMemoryMB: 5960, freeDiskMB: 50000);
    const sixGigabytes = DeviceCapabilities(physicalMemoryMB: 5731, availableMemoryMB: 3100);
    const fourGigabytes = DeviceCapabilities(physicalMemoryMB: 3700, availableMemoryMB: 1800);
    const busyEightGigabytes = DeviceCapabilities(physicalMemoryMB: 7622, availableMemoryMB: 2500);

    expect(manifest.eligible(iphone16ProMax).map((m) => m.params), ['4B', '2B']);
    expect(manifest.recommendedFor(iphone16ProMax)!.params, '4B');
    expect(manifest.eligible(sixGigabytes).map((m) => m.params), ['2B']);
    expect(manifest.recommendedFor(sixGigabytes)!.params, '2B');
    expect(manifest.recommendedFor(busyEightGigabytes)!.params, '2B');
    expect(manifest.eligible(fourGigabytes), isEmpty);
    expect(manifest.recommendedFor(fourGigabytes), isNull);
    expect(manifest.recommendedFor(DeviceCapabilities.unknown)!.params, '4B');
    expect(manifest.eligible(const DeviceCapabilities(physicalMemoryMB: 7622)).length, 2);

    final json = jsonDecode(_bundled) as Map<String, dynamic>;
    (json['models'] as List).first['status'] = 'revoked';
    final revoked = ModelManifest.parse(jsonEncode(json));
    expect(revoked.models.first.availability, ModelAvailability.revoked);
    expect(revoked.recommendedFor(iphone16ProMax)!.params, '2B');
    expect(revoked.recommendedFor(DeviceCapabilities.unknown)!.params, '2B');

    const tightDisk = DeviceCapabilities(freeDiskMB: 3000);
    expect(manifest.models.first.fitsDisk(tightDisk), isFalse);
    expect(manifest.models.last.fitsDisk(tightDisk), isTrue);
    expect(manifest.models.first.fitsDisk(DeviceCapabilities.unknown), isTrue);
  });

  test('entries round-trip through JSON; the file names come from the URL', () {
    final big = ModelManifest.parse(_bundled).models.first;
    expect(big.fileName, 'model-4b-Q5_K_M.gguf');
    expect(big.partFileName, 'model-4b-Q5_K_M.gguf.part');
    expect(ModelEntry.fromJson(big.toJson()), big);
    expect(ModelEntry.fromJson(big.toJson()).toJson(), big.toJson());
    expect((big.toJson()['file'] as Map)['sha256'], 'ab' * 32);
    expect('$big', 'ModelEntry(qwen3.5-4b-tuned-q5km, 3074986592)');
  });

  test('a host-built entry: defaults, no SHA-256 in its JSON, which the index still reads back', () {
    final entry = ModelEntry(id: 'host', url: Uri.parse('https://example.org/m/host-Q4_0.gguf'), sizeBytes: 42);
    expect(
      (entry.version, entry.format, entry.availability, entry.recommended, entry.sha256, entry.minFreeDiskMB),
      (1, 'gguf', ModelAvailability.active, false, null, 0),
    );
    final file = entry.toJson()['file'] as Map;
    expect(file.containsKey('sha256'), isFalse);
    // The index reads it back as it was built: empty texts, no SHA-256.
    expect(ModelEntry.fromIndexJson(entry.toJson()), entry);
    expect(() => ModelEntry.fromJson(entry.toJson()), _rejects('model.file.sha256'));
    final hashed = entry.toJson()..['file'] = {...file, 'sha256': 'ab' * 32};
    expect(() => ModelEntry.fromJson(hashed), _rejects('model.displayName'));
    final named = ModelEntry.fromJson(
      entry.toJson()
        ..['displayName'] = 'Host'
        ..['params'] = '1B'
        ..['quant'] = 'Q4_0',
      requireSha256: false,
    );
    expect((named.id, named.sha256, named.sizeBytes, named.displayName), ('host', null, 42, 'Host'));
    expect(() => ModelEntry.fromJson(named.toJson()), _rejects('model.file.sha256'));
    final manifest = ModelManifest(models: [entry]);
    expect((manifest.schemaVersion, manifest.manifestVersion, manifest.byId('host')), (1, '', entry));
  });

  test('the index reads back any URL and format a host-built entry has, but not an unsafe id or file name', () {
    final local = ModelEntry(
      id: 'local',
      url: Uri.parse('http://127.0.0.1:8080/files/download'),
      sizeBytes: 7,
      sha256: 'cd' * 32,
      format: 'bin',
    );
    expect(ModelEntry.fromIndexJson(local.toJson()), local);
    expect(() => ModelEntry.fromJson(local.toJson()), _rejects('model.format'));
    // The public parse stays strict: requireSha256 false relaxes the SHA-256 only.
    final published = local.toJson()..['format'] = 'gguf';
    expect(() => ModelEntry.fromJson(published, requireSha256: false), _rejects('model.file.url: expected an https'));
    Map<String, Object?> withUrl(String url) => local.toJson()..['file'] = {'url': url, 'sizeBytes': 7};
    expect(
      () => ModelEntry.fromIndexJson(withUrl('http://127.0.0.1/m/.hidden')),
      _rejects('model.file.url: unsafe file name'),
    );
    expect(() => ModelEntry.fromIndexJson(withUrl('http://127.0.0.1/')), _rejects('model.file.url'));
    expect(() => ModelEntry.fromIndexJson(local.toJson()..['id'] = '../up'), _rejects("model.id: '../up'"));
    expect(() => ModelEntry.fromIndexJson(local.toJson()..['params'] = 4), _rejects('model.params'));
  });

  test('the README\'s manifest example ("Model manifest") parses', () {
    final readme = File('README.md').readAsStringSync();
    final section = readme.substring(readme.indexOf('### Model manifest'));
    final json = RegExp(r'```json\n(.*?)```', dotAll: true).firstMatch(section)![1]!;
    final manifest = ModelManifest.parse(json);
    final model = manifest.models.single;
    expect(
      (model.id, model.fileName, model.isActive, model.recommended),
      ('qwen3.5-2b-q4_0', 'Qwen3.5-2B-Q4_0.gguf', true, true),
    );
    expect(manifest.recommendedFor(DeviceCapabilities.unknown), model);
  });
}
