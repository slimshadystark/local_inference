import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_inference_flutter/local_inference_flutter.dart';

void main() {
  test('localInferenceFlutterVersion equals the pubspec version', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final versions = RegExp(r'^version:[ \t]*(\S+)[ \t]*$', multiLine: true).allMatches(pubspec);
    expect(versions.map((m) => m.group(1)), [localInferenceFlutterVersion]);
  });

  test('the barrel re-exports local_inference', () {
    expect(localInferenceVersion, localInferenceFlutterVersion);
  });
}
