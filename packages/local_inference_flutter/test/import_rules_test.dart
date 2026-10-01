// Import rules of local_inference_flutter: the engine binding
// stays in local_inference, dart:io stays in the platform layer, background_downloader in the downloader, and the
// plugin's channels in device_channel.dart.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final files = _dartFiles('lib');

  test('lib/ has Dart files', () => expect(files, isNotEmpty));

  test('lib/ does not import package:llamadart', () {
    expect(_imports(files, (file, uri) => uri.startsWith('package:llamadart')), isEmpty);
  });

  test('lib/ imports only the public libraries of local_inference', () {
    expect(_imports(files, (file, uri) => uri.startsWith('package:local_inference/src/')), isEmpty);
  });

  test('dart:io is imported only under lib/src/platform/', () {
    expect(_imports(files, (file, uri) => uri == 'dart:io' && !file.startsWith('lib/src/platform/')), isEmpty);
  });

  test('the UI and the adapters decide by defaultTargetPlatform, never dart:io\'s Platform', () {
    final layers = [
      for (final file in files)
        if (file.startsWith('lib/src/ui/') || file.startsWith('lib/src/adapters/')) file,
    ];
    expect(layers, isNotEmpty);
    expect(_imports(layers, (file, uri) => uri == 'dart:io'), isEmpty);
    expect([
      for (final file in layers)
        if (RegExp(r'\bPlatform\.(is|operatingSystem|environment)').hasMatch(File(file).readAsStringSync())) file,
    ], isEmpty);
  });

  test('package:background_downloader is imported only by the downloader files', () {
    const allowed = [
      'lib/src/platform/background_model_downloader.dart',
      'lib/src/platform/download_config.dart',
      'lib/src/platform/retaining_resume_storage.dart',
    ];
    expect(
      _imports(files, (file, uri) => uri.startsWith('package:background_downloader') && !allowed.contains(file)),
      isEmpty,
    );
  });

  test('MethodChannel and EventChannel appear only in lib/src/platform/device_channel.dart', () {
    final users = [
      for (final file in files)
        if (file != 'lib/src/platform/device_channel.dart' &&
            RegExp(r'\b(MethodChannel|EventChannel)\b').hasMatch(File(file).readAsStringSync()))
          file,
    ];
    expect(users, isEmpty);
  });

  test('lib/ never imports flutter_test (a dev dependency)', () {
    expect(_imports(files, (file, uri) => uri.startsWith('package:flutter_test')), isEmpty);
  });
}

/// Every .dart file under [dir], as a '/'-separated path relative to the package root.
List<String> _dartFiles(String dir) => [
  for (final entity in Directory(dir).listSync(recursive: true))
    if (entity is File && entity.path.endsWith('.dart')) entity.path.replaceAll(r'\', '/'),
]..sort();

/// 'file: uri' for every import or export in [files] that [breaks] the rule.
List<String> _imports(List<String> files, bool Function(String file, String uri) breaks) => [
  for (final file in files)
    for (final uri in _directiveUris(File(file).readAsStringSync()))
      if (breaks(file, uri)) '$file: $uri',
];

/// The URIs of the import and export directives in [source], conditional ones included.
List<String> _directiveUris(String source) => [
  for (final directive in RegExp(r'^[ \t]*(?:import|export)\b([^;]*);', multiLine: true).allMatches(source))
    for (final uri in RegExp(r'''['"]([^'"]+)['"]''').allMatches(directive.group(1)!)) uri.group(1)!,
];
