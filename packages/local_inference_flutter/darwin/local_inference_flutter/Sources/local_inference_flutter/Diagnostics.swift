import Foundation
import Metal

#if os(iOS)
  import UIKit
  import os
#endif

/// A snapshot of the conditions that change on-device speed: heat, Low Power Mode, charging, and the memory this
/// process and its GPU may use. The keys: machine, ios, thermal_state, low_power_mode, battery, physical_memory_mb,
/// process_available_memory_mb, metal_*, platform, os_version, is_simulator and battery_percent.
enum Diagnostics {
  static func snapshot() -> [String: Any] {
    let info = ProcessInfo.processInfo
    let metal = MTLCreateSystemDefaultDevice()
    var snapshot: [String: Any] = [
      "machine": machine(),
      "thermal_state": thermalStateName(info.thermalState),
      "low_power_mode": info.isLowPowerModeEnabled,
      "physical_memory_mb": Int(info.physicalMemory / 1_048_576),
      "metal_device": metal?.name ?? "none",
      "metal_recommended_working_set_mb": Int((metal?.recommendedMaxWorkingSetSize ?? 0) / 1_048_576),
      "metal_current_allocated_mb": Int((metal?.currentAllocatedSize ?? 0) / 1_048_576),
    ]
    #if targetEnvironment(simulator)
      snapshot["is_simulator"] = true
    #else
      snapshot["is_simulator"] = false
    #endif
    #if os(iOS)
      snapshot["platform"] = "ios"
      snapshot["ios"] = UIDevice.current.systemVersion
      snapshot["os_version"] = UIDevice.current.systemVersion
      UIDevice.current.isBatteryMonitoringEnabled = true
      snapshot["battery"] = batteryName(UIDevice.current.batteryState)
      let level = UIDevice.current.batteryLevel
      if level >= 0 {
        snapshot["battery_percent"] = Int((level * 100).rounded())
      }
      snapshot["process_available_memory_mb"] = Int(os_proc_available_memory() / 1_048_576)
    #else
      snapshot["platform"] = "macos"
      snapshot["macos"] = macosVersion()
      snapshot["os_version"] = macosVersion()
      snapshot["battery"] = "unknown"
    #endif
    return snapshot
  }

  static func thermalStateName(_ state: ProcessInfo.ThermalState) -> String {
    switch state {
    case .nominal: return "nominal"
    case .fair: return "fair"
    case .serious: return "serious"
    case .critical: return "critical"
    @unknown default: return "unknown"
    }
  }

  /// "14.6.1".
  static func macosVersion() -> String {
    let version = ProcessInfo.processInfo.operatingSystemVersion
    return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
  }

  #if os(iOS)
    private static func batteryName(_ state: UIDevice.BatteryState) -> String {
      switch state {
      case .charging: return "charging"
      case .full: return "full"
      case .unplugged: return "unplugged"
      default: return "unknown"
      }
    }
  #endif

  /// The hardware model: "iPhone17,2" (uname), or "Mac14,6" (hw.model) on a Mac.
  private static func machine() -> String {
    #if os(macOS)
      var size = 0
      if sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 {
        var model = [CChar](repeating: 0, count: size)
        if sysctlbyname("hw.model", &model, &size, nil, 0) == 0 {
          return model.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        }
      }
    #endif
    var system = utsname()
    uname(&system)
    return withUnsafePointer(to: &system.machine) {
      $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
    }
  }
}
