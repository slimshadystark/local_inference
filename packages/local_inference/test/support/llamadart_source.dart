// llamadart's own sources as resolved for this run, so a test can tell when a llamadart upgrade adds or drops a field
// that a field-by-field dump must cover.
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

/// The root folder of the llamadart package this run resolved.
Future<Directory> llamadartRoot() async {
  final library = await Isolate.resolvePackageUri(Uri.parse('package:llamadart/llamadart.dart'));
  return File.fromUri(library!).parent.parent;
}

/// The `version:` of the llamadart package this run resolved.
Future<String> llamadartVersion() async {
  final pubspec = File('${(await llamadartRoot()).path}/pubspec.yaml').readAsStringSync();
  return RegExp(r'^version:\s*(\S+)', multiLine: true).firstMatch(pubspec)!.group(1)!;
}

/// A llamadart source file, by its path under lib/src/.
Future<String> llamadartSource(String path) async =>
    File('${(await llamadartRoot()).path}/lib/src/$path').readAsStringSync();

/// A file of the llamadart package, by its path from the package root (the chat templates of its own tests:
/// test/fixtures/templates/, tool/litert_lm_templates/).
Future<String> llamadartFile(String path) async => File('${(await llamadartRoot()).path}/$path').readAsStringSync();

/// The instance fields `final Type name;` declared at the top level of [className]'s body in [source].
List<String> declaredFields(String source, String className) {
  final start = source.indexOf(RegExp('class $className\\b[^{]*\\{'));
  if (start < 0) throw StateError('class $className not found');
  final field = RegExp(r'^\s*final\s+[\w<>?, ]+?\s+(\w+)\s*;');
  final fields = <String>[];
  var depth = 0;
  for (final line in const LineSplitter().convert(source.substring(start))) {
    final code = line.replaceFirst(RegExp(r'//.*'), '');
    if (depth == 1) {
      final match = field.firstMatch(code);
      if (match != null) fields.add(match.group(1)!);
    }
    depth += '{'.allMatches(code).length - '}'.allMatches(code).length;
    if (depth == 0 && code.contains('}')) break;
  }
  return fields;
}
