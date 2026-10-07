import Flutter
import Foundation

/// 播放缓冲参数的原生写入侧（iOS）。
///
/// 契约见 Dart 侧 `MethodChannelBufferingBackend`：方法通道 `lumebox/buffering`
/// 的 `isSupported` / `apply`。
///
/// ## 为什么必须有这一层
///
/// AVPlayer 的缓冲策略只有原生对象上才有（`AVPlayerItem.preferredForwardBuffer
/// Duration`、`AVPlayer.automaticallyWaitsToMinimizeStalling`），而本项目 AVPlayer
/// 内核走 `video_player` 插件——插件的 Dart API 没有暴露这两项，原生插件对象
/// 也不对宿主公开。因此：
///
/// 1. 本控制器把参数写进 `UserDefaults`（同进程立即可读）；
/// 2. vendored 的 `video_player_avfoundation`（见
///    `third_party/video_player_avfoundation/PATCHES.md`）在建 AVPlayer 时读取
///    并应用，未写入时**行为与上游完全一致**（默认值不碰）。
///
/// ## 为什么不做「退出还原」
///
/// 参数只在播放期间有意义（AVPlayer 随播放器释放），用户不需要它被记住或还原；
/// 这里保存的目的是**跨插件边界传参**，不是持久化用户设置——真正的设置值由 Dart
/// 侧每次起播前重写一遍，因此不存在「上次的残留影响这次播放」。
final class BufferingController: NSObject {
  private let channelName = "lumebox/buffering"

  /// 是否已经由 Dart 侧配置过。未配置时插件侧不做任何改动。
  static let appliedKey = "lumebox.buffering.applied"

  /// 前向缓冲时长（秒）。0 表示交给 AVFoundation 自动决定。
  static let forwardBufferKey = "lumebox.buffering.forwardBufferSeconds"

  /// 是否让 AVPlayer 等缓冲填够再播（false = 拿到可播数据就起播）。
  static let minimizeStallingKey = "lumebox.buffering.minimizeStalling"

  func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "isSupported":
        // 写侧与 vendored 插件都在 iOS 上；其他平台由 Dart 侧如实降级。
        result(true)
      case "apply":
        guard let args = call.arguments as? [String: Any] else {
          result(FlutterError(code: "badArgs", message: "缓冲参数缺失", details: nil))
          return
        }
        let seconds = (args["forwardBufferSeconds"] as? NSNumber)?.doubleValue ?? 0
        let minimizeStalling = (args["minimizeStalling"] as? NSNumber)?.boolValue ?? true
        let defaults = UserDefaults.standard
        defaults.set(max(0, seconds), forKey: Self.forwardBufferKey)
        defaults.set(minimizeStalling, forKey: Self.minimizeStallingKey)
        // 最后写这个标记：插件侧只在它存在时才改 AVPlayer 的参数。
        defaults.set(true, forKey: Self.appliedKey)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
