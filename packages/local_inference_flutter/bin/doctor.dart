// dart run local_inference_flutter:doctor [--json] [--strict] [--verify-natives] [--install-ios-script] [host folder]
// The doctor of local_inference (package:local_inference/doctor.dart), for a host that depends on this package:
// `dart run` needs an immediate dependency. --help lists the options.
import 'dart:io';

import 'package:local_inference/doctor.dart';

void main(List<String> args) => exitCode = runDoctor(args, command: 'local_inference_flutter:doctor');
