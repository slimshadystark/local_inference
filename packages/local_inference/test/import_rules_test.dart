// Import rules of local_inference: the package is pure Dart, only the engine and the
// model families of lib/src/llamadart/ import llamadart, and dart:io stays out of the engine-agnostic code and of the
// delivery values (manifest, catalog, downloader interface).
import 'dart:io';

import 'package:test/test.dart';

void main() {
  final files = _dartFiles('lib');

  test('lib/ has Dart files', () => expect(files, isNotEmpty));

  test('lib/ imports no Flutter library', () {
    expect(_imports(files, (file, uri) => _isFlutter(uri)), isEmpty);
  });

  test('package:llamadart is imported only by the engine and the model families of lib/src/llamadart/, as its '
      'public library', () {
    expect(_imports(files, (file, uri) => uri.startsWith('package:llamadart')), [
      'lib/src/llamadart/llamadart_engine.dart: package:llamadart/llamadart.dart',
      'lib/src/llamadart/llamadart_families.dart: package:llamadart/llamadart.dart',
    ]);
  });

  test('dart:io is imported only under lib/src/llamadart/, lib/src/testing/ and lib/src/doctor/, by the model '
      'identity and the file store of lib/src/model/prefix/, by the delivery files that touch files or the network, '
      "and by the assistant's conversation store", () {
    const allowedFolders = ['lib/src/llamadart/', 'lib/src/testing/', 'lib/src/doctor/'];
    const allowedFiles = [
      'lib/src/model/prefix/model_identity.dart',
      'lib/src/model/prefix/file_prefix_state_store.dart',
      'lib/src/delivery/device.dart',
      'lib/src/delivery/http_downloader.dart',
      'lib/src/delivery/manifest_fetch.dart',
      'lib/src/delivery/model_manager.dart',
      'lib/src/agent/conversation_store.dart',
    ];
    expect(
      _imports(
        files,
        (file, uri) => uri == 'dart:io' && !allowedFolders.any(file.startsWith) && !allowedFiles.contains(file),
      ),
      isEmpty,
    );
  });

  test('the model layer (outside those two files) and the grammar builder have files, and none imports dart:io', () {
    final pure = [
      for (final file in files)
        if (file.startsWith('lib/src/grammar/') || file.startsWith('lib/src/model/')) file,
    ];
    expect(pure.length, greaterThan(20));
    expect(
      _imports(
        pure,
        (file, uri) =>
            uri == 'dart:io' &&
            !file.endsWith('/model_identity.dart') &&
            !file.endsWith('/file_prefix_state_store.dart'),
      ),
      isEmpty,
    );
  });

  test('the assistant (lib/src/agent/) has files, and only its conversation store imports dart:io', () {
    final agent = [
      for (final file in files)
        if (file.startsWith('lib/src/agent/')) file,
    ];
    expect(agent.length, greaterThan(15));
    expect(agent, contains('lib/src/agent/conversation_store.dart'));
    expect(
      _imports(agent, (file, uri) => uri == 'dart:io' && file != 'lib/src/agent/conversation_store.dart'),
      isEmpty,
    );
  });

  test('the doctor (lib/doctor.dart, lib/src/doctor/) is a tool library: only lib/doctor.dart exports it, and it '
      'imports neither the engine nor the rest of the package', () {
    final doctor = [
      for (final file in files)
        if (file.startsWith('lib/src/doctor/')) file,
    ];
    expect(doctor.length, greaterThan(8));
    expect(_imports(files, (file, uri) => uri.contains('src/doctor/') && !file.startsWith('lib/src/doctor/')), [
      'lib/doctor.dart: src/doctor/doctor.dart',
      'lib/doctor.dart: src/doctor/natives.dart',
      'lib/doctor.dart: '
          'src/doctor/report.dart',
    ]);
    expect(
      _imports(
        doctor,
        (file, uri) => uri.startsWith('package:llamadart') || (uri.startsWith('../') && uri != '../version.dart'),
      ),
      isEmpty,
    );
  });

  test('the directive scanner sees multi-line and conditional imports', () {
    const source = '''
// import 'package:flutter/commented_out.dart';
import 'package:a/a.dart'
    if (dart.library.io) 'package:b/b.dart' as b;
export "package:c/c.dart" show C;
''';
    expect(_directiveUris(source), ['package:a/a.dart', 'package:b/b.dart', 'package:c/c.dart']);
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

bool _isFlutter(String uri) =>
    uri.startsWith('package:flutter') || uri.startsWith('dart:ui') || uri.startsWith('package:sky_engine');
