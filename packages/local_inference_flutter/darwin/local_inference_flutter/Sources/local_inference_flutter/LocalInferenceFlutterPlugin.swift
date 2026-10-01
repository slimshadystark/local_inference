#if os(iOS)
  import Flutter
  import UIKit
#elseif os(macOS)
  import Cocoa
  import FlutterMacOS
#endif

/// The device probe of local_inference_flutter: the methods of `local_inference_flutter/device` (platform,
/// capabilities, sha256, excludeFromBackup, noBackupDirectory, network, diagnostics) and the thermal states of
/// `local_inference_flutter/thermal`.
public class LocalInferenceFlutterPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  /// Hashes run one at a time, off the main thread.
  private let hashing = DispatchQueue(label: "it.asfweb.local_inference_flutter.sha256", qos: .userInitiated)
  private var thermalObserver: NSObjectProtocol?
  private let connection = Connection()

  public static func register(with registrar: FlutterPluginRegistrar) {
    // The registrar's messenger is a method on iOS and a property on macOS.
    #if os(iOS)
      let messenger = registrar.messenger()
    #else
      let messenger = registrar.messenger
    #endif
    let instance = LocalInferenceFlutterPlugin()
    instance.connection.start()
    let methods = FlutterMethodChannel(name: "local_inference_flutter/device", binaryMessenger: messenger)
    registrar.addMethodCallDelegate(instance, channel: methods)
    let thermal = FlutterEventChannel(name: "local_inference_flutter/thermal", binaryMessenger: messenger)
    thermal.setStreamHandler(instance)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let path = (call.arguments as? [String: Any])?["path"] as? String
    switch call.method {
    case "platform":
      result(DeviceProbe.platformInfo())
    case "capabilities":
      result(DeviceProbe.capabilities(volumePath: path))
    case "sha256":
      guard let path = path else {
        result(FlutterError(code: "bad_args", message: "path missing", details: nil))
        return
      }
      // A 3 GB file takes a few seconds: hash off the main thread, answer on it.
      hashing.async {
        do {
          let hex = try DeviceProbe.sha256Hex(path: path)
          DispatchQueue.main.async { result(hex) }
        } catch {
          DispatchQueue.main.async {
            result(FlutterError(code: "sha256_failed", message: error.localizedDescription, details: nil))
          }
        }
      }
    case "excludeFromBackup":
      guard let path = path else {
        result(FlutterError(code: "bad_args", message: "path missing", details: nil))
        return
      }
      do {
        try DeviceProbe.excludeFromBackup(path: path)
        result(nil)
      } catch {
        result(FlutterError(code: "exclude_failed", message: error.localizedDescription, details: nil))
      }
    case "noBackupDirectory":
      // Apple platforms keep files out of backups with a flag (excludeFromBackup), not a folder.
      result(nil)
    case "network":
      result(connection.state())
    case "diagnostics":
      result(Diagnostics.snapshot())
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    events(Diagnostics.thermalStateName(ProcessInfo.processInfo.thermalState))
    thermalObserver = NotificationCenter.default.addObserver(
      forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
    ) { _ in
      events(Diagnostics.thermalStateName(ProcessInfo.processInfo.thermalState))
    }
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    if let observer = thermalObserver {
      NotificationCenter.default.removeObserver(observer)
    }
    thermalObserver = nil
    return nil
  }
}
