import Flutter
import UIKit

/// 屏幕亮度的原生实现（iOS）：`UIScreen.main.brightness`。
///
/// 契约见 Dart 侧 `MethodChannelBrightnessBackend`：
/// 方法通道 `lumebox/brightness` 的 `isSupported` / `set` / `current`。
///
/// 三点取舍：
/// - **写系统亮度**：`UIScreen.main.brightness` 是 App 内唯一能改的亮度（改的是
///   全局值，退出 App 后仍保持——与主流播放器一致）；
/// - **不做「退出恢复」**：用户调暗是有意为之，退到别的页面又亮回来才叫奇怪。
///   真正需要还原的场景（比如系统自动亮度）交给系统；
/// - **set 时不要动画**：手势是连续的，每次都做动画会跟手迟滞。
final class BrightnessController: NSObject {
  private let channelName = "lumebox/brightness"

  func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "isSupported":
        // 主屏亮度在所有 iOS 设备上都可写。
        result(true)
      case "set":
        guard let args = call.arguments as? [String: Any],
              let value = (args["value"] as? NSNumber)?.doubleValue
        else {
          result(FlutterError(code: "badArgs", message: "亮度值缺失", details: nil))
          return
        }
        // 必须在主线程改 UI 相关状态。
        DispatchQueue.main.async {
          UIScreen.main.brightness = CGFloat(min(max(value, 0.0), 1.0))
        }
        result(nil)
      case "current":
        result(Double(UIScreen.main.brightness))
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
