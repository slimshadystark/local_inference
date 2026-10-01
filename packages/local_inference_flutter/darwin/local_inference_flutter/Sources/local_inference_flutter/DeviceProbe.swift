import CryptoKit
import Foundation

#if os(iOS)
  import UIKit
  import os
#endif

/// What the model download needs from the device: the platform, memory and disk figures, a file's SHA-256 and the
/// backup flag.
enum DeviceProbe {
  /// The OS, its version, the ABI, whether the process is 64-bit and whether it runs in a simulator.
  static func platformInfo() -> [String: Any] {
    #if os(iOS)
      let system = "ios"
      let version = UIDevice.current.systemVersion
    #else
      let system = "macos"
      let version = Diagnostics.macosVersion()
    #endif
    #if targetEnvironment(simulator)
      let simulator = true
    #else
      let simulator = false
    #endif
    #if arch(arm64)
      let abi = "arm64"
    #elseif arch(x86_64)
      let abi = "x86_64"
    #else
      let abi = "unknown"
    #endif
    return [
      "apiVersion": 1,
      "os": system,
      "osVersion": version,
      "abis": [abi],
      "is64Bit": MemoryLayout<Int>.size == 8,
      "isSimulator": simulator,
    ]
  }

  /// Physical RAM, the memory this process may still allocate (iOS: raised by the increased-memory-limit
  /// entitlement), and the space for important data on the volume of [volumePath] (default: Application Support),
  /// in MB.
  static func capabilities(volumePath: String?) -> [String: Any] {
    var caps: [String: Any] = [
      "physicalMemoryMB": Int(ProcessInfo.processInfo.physicalMemory / 1_048_576)
    ]
    #if os(iOS)
      caps["availableMemoryMB"] = Int(os_proc_available_memory() / 1_048_576)
    #endif
    if let volume = existingFolder(volumePath),
      let values = try? volume.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
      let free = values.volumeAvailableCapacityForImportantUsage
    {
      caps["freeDiskMB"] = Int(free / 1_048_576)
    }
    return caps
  }

  /// Lowercase hex SHA-256, reading 8 MB at a time so memory stays flat on a multi-GB file.
  static func sha256Hex(path: String) throws -> String {
    let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
    defer { try? handle.close() }
    var hasher = SHA256()
    while true {
      let chunk: Data? = try autoreleasepool { try handle.read(upToCount: 8 * 1024 * 1024) }
      guard let data = chunk, !data.isEmpty else { break }
      hasher.update(data: data)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  /// Marks the file and its folder as not backed up: the model can be downloaded again.
  static func excludeFromBackup(path: String) throws {
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    var file = URL(fileURLWithPath: path)
    try file.setResourceValues(values)
    var folder = file.deletingLastPathComponent()
    try folder.setResourceValues(values)
  }

  /// [path] or its nearest existing parent; Application Support (created when missing) without a path.
  private static func existingFolder(_ path: String?) -> URL? {
    let fileManager = FileManager.default
    guard let path = path else {
      guard let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
        return nil
      }
      try? fileManager.createDirectory(at: support, withIntermediateDirectories: true)
      return support
    }
    var url = URL(fileURLWithPath: path)
    while !fileManager.fileExists(atPath: url.path) {
      let parent = url.deletingLastPathComponent()
      if parent.path == url.path { return nil }
      url = parent
    }
    return url
  }
}
