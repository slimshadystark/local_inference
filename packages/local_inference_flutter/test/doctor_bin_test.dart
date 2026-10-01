// bin/doctor.dart: `dart run local_inference_flutter:doctor` runs local_inference's doctor (its checks are tested in
// packages/local_inference/test/doctor/).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../bin/doctor.dart' as doctor;

void main() {
  test('bin/doctor.dart runs local_inference\'s doctor', () {
    doctor.main(const ['--help']);
    expect(exitCode, 0);
  });
}
