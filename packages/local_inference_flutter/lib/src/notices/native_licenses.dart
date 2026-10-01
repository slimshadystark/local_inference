/// The license texts of the native libraries in every app built on this package, for Flutter's license page.
library;

import 'package:flutter/foundation.dart';

import 'native_licenses.g.dart';

/// The notices of the native libraries that llamadart's build hook puts into every app built on this package:
/// llama.cpp and ggml, and the others of local_inference's NATIVE_LICENSES.txt (its NOTICE, section 2, says which
/// library holds what). Flutter's license page lists only the Dart packages by itself.
///
/// The plugin registers them before `main()` runs, on every platform it declares (Android, iOS, macOS, and Linux and
/// Windows with this Dart class only): this is its Dart plugin class, whose [registerWith] Flutter's generated plugin
/// registrant calls. A license page the app opens (`showLicensePage`, `AboutDialog`, `AboutListTile`) then lists them
/// next to the Dart packages, with no other code in the app. A widget test, where no registrant runs, calls [register].
abstract final class NativeLicenses {
  /// One entry per component of NATIVE_LICENSES.txt, its section verbatim, with the package names the license page
  /// lists it under: llama.cpp and ggml; llamadart-native; nlohmann/json; cpp-httplib; stb_image; rotate-bits;
  /// SHA-256, subprocess.h and miniaudio (public domain); KleidiAI; ggml again, for its KleidiAI glue; YaRN, in ggml's
  /// rope operation.
  static const List<LicenseEntry> entries = nativeLicenseEntries;

  static bool _registered = false;

  /// Adds [entries] to Flutter's `LicenseRegistry`. Only the first call adds them; later calls do nothing.
  static void register() {
    if (_registered) return;
    _registered = true;
    LicenseRegistry.addLicense(() => Stream<LicenseEntry>.fromIterable(entries));
  }

  /// [register], called by Flutter's generated plugin registrant before `main()`.
  static void registerWith() => register();
}
