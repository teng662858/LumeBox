import Flutter
import UIKit
import Network

/// On-device network and disk checks for optional offline policies.
final class NativeExperienceController {
  func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "lumebox/experience", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "freeDiskBytes":
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        result(values?.volumeAvailableCapacityForImportantUsage)
      case "networkAndStorage":
        let monitor = NWPathMonitor()
        let queue = DispatchQueue(label: "lumebox.offline-policy")
        var finished = false
        let finish: (Bool) -> Void = { wifi in
          guard !finished else { return }; finished = true; monitor.cancel()
          let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
          let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
          DispatchQueue.main.async { result(["wifi": wifi, "freeBytes": values?.volumeAvailableCapacityForImportantUsage ?? 0]) }
        }
        monitor.pathUpdateHandler = { path in finish(path.status == .satisfied && path.usesInterfaceType(.wifi) && !path.isExpensive) }
        monitor.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 3) { finish(false) }
      default: result(FlutterMethodNotImplemented)
      }
    }
  }
}
