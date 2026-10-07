import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  /// 画中画控制器：生命周期跟随 App（方法通道由它注册）。
  private let pip = PipController()

  /// 语音朗读控制器（AVSpeechSynthesizer）：生命周期跟随 App。
  private let speech = SpeechController()

  /// 屏幕亮度控制器（UIScreen.brightness）：生命周期跟随 App。
  private let brightness = BrightnessController()

  /// 播放缓冲参数控制器：把 Dart 侧给的参数传给 AVPlayer 内核
  /// （经 UserDefaults 与 vendored 插件交接，见该文件文档）。
  private let buffering = BufferingController()

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    // 画中画通道：与 Dart 侧 `MethodChannelPipBackend` 的契约一一对应。
    // 用插件注册器的 binaryMessenger 注册，保证与 Flutter 引擎同一条消息通道。
    if let messenger = engineBridge.pluginRegistry
      .registrar(forPlugin: "LumeBoxPip")?.messenger() {
      pip.register(with: messenger)
    }

    // 语音朗读通道：与 Dart 侧 `MethodChannelSpeechBackend` 的契约一一对应。
    if let messenger = engineBridge.pluginRegistry
      .registrar(forPlugin: "LumeBoxSpeech")?.messenger() {
      speech.register(with: messenger)
    }

    // 屏幕亮度通道：与 Dart 侧 `MethodChannelBrightnessBackend` 的契约一一对应。
    if let messenger = engineBridge.pluginRegistry
      .registrar(forPlugin: "LumeBoxBrightness")?.messenger() {
      brightness.register(with: messenger)
    }

    // 播放缓冲参数通道：与 Dart 侧 `MethodChannelBufferingBackend` 的契约一一对应。
    if let messenger = engineBridge.pluginRegistry
      .registrar(forPlugin: "LumeBoxBuffering")?.messenger() {
      buffering.register(with: messenger)
    }
  }
}
