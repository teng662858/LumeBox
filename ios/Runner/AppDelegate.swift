import Flutter
import UIKit
import Security

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  /// 画中画控制器：生命周期跟随 App（方法通道由它注册）。
  private let pip = PipController()
  private let nativeVideo = NativeVideoPlayerController()

  /// 语音朗读控制器（AVSpeechSynthesizer）：生命周期跟随 App。
  private let speech = SpeechController()
  private let mediaTracks = MediaTrackProbe()
  private let experience = NativeExperienceController()

  /// 屏幕亮度控制器（UIScreen.brightness）：生命周期跟随 App。
  private let brightness = BrightnessController()
  private let readerKeys = ReaderVolumeKeysController()

  /// 播放缓冲参数控制器：把 Dart 侧给的参数传给 AVPlayer 内核
  /// （经 UserDefaults 与 vendored 插件交接，见该文件文档）。
  private let buffering = BufferingController()

  /// 播放会话控制器：后台音频 + 锁屏 / 控制中心的媒体控制器。
  private let playback = PlaybackSessionController()
  private let wafCookies = WafCookieController()
  private let sourceWeb = SourceWebController()
  private let battery = BatteryController()
  private let configurationExport = ConfigurationExportController()
  private let videoMerge = OfflineVideoMergeController()
  private let comicImages = ComicImageToolsController()
  private let privacy = PrivacyController()
  private let introRecognition = IntroRecognitionController()
  private let referenceCredentials = ReferenceDanmakuCredentialsController()

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let messenger = engineBridge.pluginRegistry.registrar(forPlugin: "LumeBoxNativeVideo")?.messenger() {
      nativeVideo.register(with: messenger)
    }

    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "LumeBoxPython") {
      LumePythonController.register(with: registrar)
    }
    if let messenger = engineBridge.pluginRegistry.registrar(forPlugin: "LumeBoxConfiguration")?.messenger() {
      configurationExport.register(with: messenger)
      experience.register(with: messenger)
      videoMerge.register(with: messenger)
      introRecognition.register(with: messenger)
      referenceCredentials.register(with: messenger)
      SourceRepositoryCredentials.register(with: messenger)
      FlutterMethodChannel(name: "lumebox/app_icon", binaryMessenger: messenger).setMethodCallHandler { call, result in
        if call.method == "current" { result(UIApplication.shared.alternateIconName ?? "default"); return }
        guard call.method == "set" else { result(FlutterMethodNotImplemented); return }
        guard UIApplication.shared.supportsAlternateIcons else { result(FlutterError(code: "unsupported", message: "This device does not support alternate icons", details: nil)); return }
        guard let name = call.arguments as? String, ["default", "Aurora", "Obsidian", "Solar", "Orbit", "Prism", "Spark"].contains(name) else { result(FlutterError(code: "icon", message: "Unknown icon", details: nil)); return }
        UIApplication.shared.setAlternateIconName(name == "default" ? nil : name) { error in
          if let error = error { result(FlutterError(code: "icon", message: error.localizedDescription, details: nil)) }
          else { result(true) }
        }
      }
    }
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
      mediaTracks.register(with: messenger)
    }

    // 屏幕亮度通道：与 Dart 侧 `MethodChannelBrightnessBackend` 的契约一一对应。
    if let messenger = engineBridge.pluginRegistry
      .registrar(forPlugin: "LumeBoxBrightness")?.messenger() {
      brightness.register(with: messenger)
      readerKeys.register(with: messenger)
    }

    // 播放缓冲参数通道：与 Dart 侧 `MethodChannelBufferingBackend` 的契约一一对应。
    if let messenger = engineBridge.pluginRegistry
      .registrar(forPlugin: "LumeBoxBuffering")?.messenger() {
      buffering.register(with: messenger)
    }

    // 播放会话通道（后台音频 + 锁屏控制）：与 Dart 侧
    // `MethodChannelPlaybackBackend` 的契约一一对应。
    if let messenger = engineBridge.pluginRegistry
      .registrar(forPlugin: "LumeBoxPlayback")?.messenger() {
      playback.register(with: messenger)
    }

    // 网页视图的 Cookie 仓库（内置 WebView 过完 Cloudflare 校验后取回会话）：
    // 与 Dart 侧 `WafWebViewPage` 的契约一一对应。
    if let messenger = engineBridge.pluginRegistry
      .registrar(forPlugin: "LumeBoxWafCookies")?.messenger() {
      wafCookies.register(with: messenger)
      sourceWeb.register(with: messenger)
    }

    if let messenger = engineBridge.pluginRegistry
      .registrar(forPlugin: "LumeBoxBattery")?.messenger() {
      battery.register(with: messenger)
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "LumeBoxComicImages") {
      comicImages.register(with: registrar)
    }
    if let messenger = engineBridge.pluginRegistry.registrar(forPlugin: "LumeBoxPrivacy")?.messenger() {
      privacy.register(with: messenger)
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "LumeBoxSystemTabBar") {
      LumeSystemTabBarFactory.register(with: registrar)
    }
    // 液态玻璃 A/B 对比：iOS 原生系统材质底座（Dart 侧 UiKitView）。
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "LumeBoxGlassBackdrop") {
      registrar.register(
        LumeGlassBackdropFactory(messenger: registrar.messenger()),
        withId: "lumebox/glass_backdrop"
      )
    }
    // 辅助功能：降低透明度 / 增强对比度（Flutter MediaQuery 不包含这两项）。
    if let messenger = engineBridge.pluginRegistry.registrar(forPlugin: "LumeBoxAccessibility")?.messenger() {
      let channel = FlutterMethodChannel(name: "lumebox/accessibility", binaryMessenger: messenger)
      // 正确 API：iOS 没有 isIncreaseContrastEnabled；UIKit 的对应项是
      // isDarkerSystemColorsEnabled（系统设置「增强对比度」）。
      func flags() -> [String: Bool] {
        [
          "reduceTransparency": UIAccessibility.isReduceTransparencyEnabled,
          "increaseContrast": UIAccessibility.isDarkerSystemColorsEnabled,
        ]
      }
      channel.setMethodCallHandler { call, result in
        guard call.method == "flags" else {
          result(FlutterMethodNotImplemented)
          return
        }
        result(flags())
      }
      // 用户在系统设置里切换这两项时主动通知 Flutter，底栏不必重启才生效。
      for name in [
        UIAccessibility.darkerSystemColorsStatusDidChangeNotification,
        UIAccessibility.reduceTransparencyStatusDidChangeNotification,
      ] {
        NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak channel] _ in
          channel?.invokeMethod("changed", arguments: flags())
        }
      }
    }
  }
}

/// Shared device-only danmaku profiles. The historical channel/item names are
/// retained so existing reference-player credentials continue to load.
private final class ReferenceDanmakuCredentialsController {
  func register(with messenger: FlutterBinaryMessenger) {
    FlutterMethodChannel(name: "lumebox/reference_danmaku_credentials", binaryMessenger: messenger).setMethodCallHandler { call, result in
      let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.lumebox.reference.danmaku", kSecAttrAccount as String: "profiles"]
      if call.method == "read" {
        var read = query; read[kSecReturnData as String] = true; read[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(read as CFDictionary, &value)
        if status == errSecItemNotFound { result([String: String]()); return }
        guard status == errSecSuccess, let data = value as? Data,
          let dictionary = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
          result(FlutterError(code: "credentials", message: "Unable to read reference credentials", details: nil)); return
        }
        result(dictionary)
      } else if call.method == "write" {
        guard let dictionary = call.arguments as? [String: String],
          let data = try? JSONSerialization.data(withJSONObject: dictionary), data.count <= 256 * 1024 else {
          result(FlutterError(code: "credentials", message: "Invalid reference credentials", details: nil)); return
        }
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        var finalStatus = status
        if status == errSecItemNotFound {
          var add = query; add[kSecValueData as String] = data
          add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
          finalStatus = SecItemAdd(add as CFDictionary, nil)
        }
        if finalStatus == errSecSuccess { result(nil) }
        else { result(FlutterError(code: "credentials", message: "Unable to save reference credentials", details: nil)) }
      } else { result(FlutterMethodNotImplemented) }
    }
  }
}

private final class ConfigurationExportController: NSObject, UIDocumentPickerDelegate {
  private var pending: FlutterResult?
  private var temporary: URL?
  func register(with messenger: FlutterBinaryMessenger) {
    FlutterMethodChannel(name: "lumebox/configuration", binaryMessenger: messenger)
      .setMethodCallHandler { [weak self] call, result in
        guard ["export", "share", "exportPath"].contains(call.method) else { result(FlutterMethodNotImplemented); return }
        guard let self = self else { result(false); return }
        guard self.pending == nil else { result(FlutterError(code: "busy", message: "An export is already open", details: nil)); return }
        if call.method == "exportPath" {
          guard let args = call.arguments as? [String: Any], let path = args["path"] as? String else {
            result(FlutterError(code: "arguments", message: "Missing local file", details: nil)); return
          }
          let url = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
          let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().standardizedFileURL.path
          var directory: ObjCBool = false
          guard url.path.hasPrefix(home + "/"), FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), !directory.boolValue else {
            result(FlutterError(code: "arguments", message: "Invalid local file", details: nil)); return
          }
          var presenter = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }.first(where: { $0.isKeyWindow })?.rootViewController
          while let next = presenter?.presentedViewController { presenter = next }
          guard let viewController = presenter else { result(false); return }
          let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
          self.pending = result
          self.temporary = nil // This is the user's download; never delete it on picker dismissal.
          picker.delegate = self
          viewController.present(picker, animated: true)
          return
        }
        guard let args = call.arguments as? [String: Any],
              let name = args["name"] as? String, !name.isEmpty, name == (name as NSString).lastPathComponent,
              let data = (args["bytes"] as? FlutterStandardTypedData)?.data ?? (args["text"] as? String)?.data(using: .utf8),
              data.count <= 32 * 1024 * 1024 else {
          result(FlutterError(code: "arguments", message: "Invalid backup", details: nil)); return
        }
        do {
          let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
          try data.write(to: url, options: .atomic)
          var presenter = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }.first(where: { $0.isKeyWindow })?.rootViewController
          while let next = presenter?.presentedViewController { presenter = next }
          guard let viewController = presenter else { result(false); return }
          if call.method == "share" {
            self.pending = result
            self.temporary = url
            let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            activity.popoverPresentationController?.sourceView = viewController.view
            activity.popoverPresentationController?.sourceRect = CGRect(x: viewController.view.bounds.midX, y: viewController.view.bounds.midY, width: 1, height: 1)
            activity.completionWithItemsHandler = { [weak self] _, completed, _, _ in self?.finish(completed) }
            viewController.present(activity, animated: true)
            return
          }
          let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
          self.pending = result
          self.temporary = url
          picker.delegate = self
          viewController.present(picker, animated: true)
        } catch { result(FlutterError(code: "export", message: error.localizedDescription, details: nil)) }
      }
  }
  private func finish(_ saved: Bool) {
    let callback = pending
    pending = nil
    if let url = temporary { try? FileManager.default.removeItem(at: url) }
    temporary = nil
    callback?(saved)
  }
  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { finish(!urls.isEmpty) }
  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finish(false) }
}
