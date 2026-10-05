import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  /// 画中画控制器：生命周期跟随 App（方法通道由它注册）。
  private let pip = PipController()

  /// 语音朗读控制器（AVSpeechSynthesizer）：生命周期跟随 App。
  private let speech = SpeechController()

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
  }
}
