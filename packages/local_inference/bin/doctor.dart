// dart run local_inference:doctor [--json] [--strict] [--verify-natives] [--install-ios-script] [host folder]
// Checks a host app or package against what the local_inference packages need; --help lists the options.
import 'dart:io';

import 'package:local_inference/doctor.dart';

void main(List<String> args) => exitCode = runDoctor(args);
