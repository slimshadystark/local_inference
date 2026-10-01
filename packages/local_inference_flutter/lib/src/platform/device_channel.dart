/// The plugin's channels. This is the only file that talks to them.
library;

import 'package:flutter/services.dart';

/// A platform call's answer: [available] is false when the plugin, or the method, is missing on this platform.
typedef DeviceCallResult<T> = ({bool available, T? value});

/// The native side of local_inference_flutter: `local_inference_flutter/device` (methods) and
/// `local_inference_flutter/thermal` (events).
abstract final class DeviceChannel {
  static const _methods = MethodChannel('local_inference_flutter/device');
  static const _thermal = EventChannel('local_inference_flutter/thermal');

  /// Calls [method]. A missing plugin or an unimplemented method gives `available: false`; a native failure
  /// (`bad_args`, `sha256_failed`, `exclude_failed`) throws its [PlatformException].
  static Future<DeviceCallResult<T>> call<T>(String method, [Map<String, Object?>? arguments]) async {
    try {
      return (available: true, value: await _methods.invokeMethod<T>(method, arguments));
    } on MissingPluginException {
      return (available: false, value: null);
    }
  }

  /// The thermal state names the native side sends, the current one first. Nothing arrives where the plugin is
  /// missing.
  static Stream<String> thermalStates() => _thermal
      .receiveBroadcastStream()
      .handleError((Object _) {}, test: (error) => error is MissingPluginException)
      .where((event) => event is String)
      .cast<String>();
}
