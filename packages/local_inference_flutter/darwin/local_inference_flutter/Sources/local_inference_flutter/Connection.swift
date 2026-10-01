import Foundation
import Network

/// The connection in use (`network`), for the waiting states of the model download on background_downloader 9.5.9,
/// which does not track it. A path monitor keeps the latest reading.
final class Connection {
  private let monitor = NWPathMonitor()
  private let queue = DispatchQueue(label: "it.asfweb.local_inference_flutter.network", qos: .utility)
  private let lock = NSLock()
  private var latest: [String: Bool]?

  func start() {
    monitor.pathUpdateHandler = { [weak self] path in
      self?.store(Connection.stateOf(satisfied: path.status == .satisfied,
                                     wifi: path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)))
    }
    monitor.start(queue: queue)
  }

  /// `connected` and `wifi` (Wi-Fi or wired Ethernet: what iOS lets a task use when it may not use mobile data), or
  /// nil before the first reading.
  func state() -> [String: Bool]? {
    lock.lock()
    defer { lock.unlock() }
    return latest
  }

  private func store(_ state: [String: Bool]) {
    lock.lock()
    latest = state
    lock.unlock()
  }

  /// The answer Dart reads: Wi-Fi counts only with a connection.
  static func stateOf(satisfied: Bool, wifi: Bool) -> [String: Bool] {
    ["connected": satisfied, "wifi": satisfied && wifi]
  }
}
