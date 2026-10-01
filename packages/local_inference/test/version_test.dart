import 'dart:io';

import 'package:local_inference/local_inference.dart';
import 'package:test/test.dart';

void main() {
  test('localInferenceVersion equals the pubspec version', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final versions = RegExp(r'^version:[ \t]*(\S+)[ \t]*$', multiLine: true).allMatches(pubspec);
    expect(versions.map((m) => m.group(1)), [localInferenceVersion]);
  });
}
