/// The host doctor of local_inference, for tools only (it uses dart:io and dart:ffi): it checks an app or package
/// against what the packages need and cannot set themselves (the hooks block, the pinned versions, how the packages
/// are listed, the llama.cpp bundles, and the iOS, Android and macOS settings of the host), and says for each check
/// what it found and how to fix it.
///
/// From a host: `dart run local_inference:doctor` (or `local_inference_flutter:doctor` in a Flutter app); `--help`
/// lists the options.
library;

export 'src/doctor/doctor.dart' show Doctor, doctorChecks, doctorUsage, runDoctor;
export 'src/doctor/natives.dart' show NativeManifest;
export 'src/doctor/report.dart' show CheckResult, CheckStatus, DoctorReport;
