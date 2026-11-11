import AVFoundation
import AVKit
import Flutter
import UIKit
import Security

/// 画中画的原生实现（iOS）。
///
/// 契约见 Dart 侧 `MethodChannelPipBackend`：
/// - 方法通道 `lumebox/pip`：`isSupported` / `start` / `stop`；
/// - 事件通道 `lumebox/pip/events`：`entered` / `exited` / `restored` / `failed`。
///
/// 实现方式：`AVPictureInPictureController(contentSource:)` 绑定一个
/// `AVSampleBufferDisplayLayer` 作为内容源。这是 iOS 15+ 给**非 AVPlayer 内核**
/// （本项目里的 MPV / MDK）准备的官方通路——内核把解码后的帧交给这个 layer，
/// 系统负责画中画窗口与手势。
///
/// AVPlayer 直接绑定插件持有的真实 AVPlayer；MDK / MPV 转发解码帧。
/// 各内核保留当前媒体和进度，不为开启画中画重建播放器。
final class PipController: NSObject {
  static weak var shared: PipController?
  private var externalActive: ((Bool) -> Void)?
  private var externalTimeRange: (() -> CMTimeRange)?
  private var externalPaused: (() -> Bool)?
  private let methodChannelName = "lumebox/pip"
  private let eventChannelName = "lumebox/pip/events"

  private var eventSink: FlutterEventSink?
  private var controller: AVPictureInPictureController?
  private var frameLayer: AVSampleBufferDisplayLayer?
  private var frameHost: UIView?
  // Owned by the video plugin. Never reparent it or clear its player.
  private weak var inlineAvLayer: AVPlayerLayer?
  private var avObserver: NSObjectProtocol?
  private var paused = false
  private var starting = false
  private var playbackRate: Float = 1
  private var durationSeconds: Double = 0

  /// 帧泵：把 Dart 送来的 BGRA 帧包成 CMSampleBuffer 上屏。
  private let framePump = PipFramePump()
  private var avPlayer: AVPlayer?
  private var avOutput: AVPlayerItemVideoOutput?
  private var avOutputItem: AVPlayerItem?
  private var avTimer: Timer?
  private var avUsesFrames = false
  private var avTransform = CGAffineTransform.identity


  /// 帧通道：与 Dart 侧 `PipFrameSource` 的帧提交一一对应。
  private let frameChannelName = "lumebox/pip/frames"


  deinit {
    avTimer?.invalidate()
    if let avObserver { NotificationCenter.default.removeObserver(avObserver) }
  }

  func register(with messenger: FlutterBinaryMessenger) {
    Self.shared = self
    avObserver = NotificationCenter.default.addObserver(
      forName: Notification.Name("LumeBox.avplayer.pip"), object: nil, queue: .main
    ) { [weak self] note in
      guard let player = note.object as? AVPlayer else { return }
      self?.attach(player: player, inlineLayer: note.userInfo?["playerLayer"] as? AVPlayerLayer)
    }
    let credentials = FlutterMethodChannel(name: "lumebox/danmaku_credentials", binaryMessenger: messenger)
    credentials.setMethodCallHandler { call, result in
      let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.lumebox.dandanplay",
        kSecAttrAccount as String: "application"
      ]
      switch call.method {
      case "read":
        var readQuery = query
        readQuery[kSecReturnData as String] = true
        readQuery[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(readQuery as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data,
           let value = try? JSONSerialization.jsonObject(with: data) {
          result(value)
        } else if status == errSecItemNotFound { result(nil) }
        else { result(FlutterError(code: "keychain", message: "无法读取弹幕服务凭证", details: nil)) }
      case "write":
        guard let args = call.arguments as? [String: String],
              let data = try? JSONSerialization.data(withJSONObject: args) else {
          result(FlutterError(code: "invalid", message: "凭证格式无效", details: nil)); return
        }
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
          var insert = query
          insert[kSecValueData as String] = data
          insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
          status = SecItemAdd(insert as CFDictionary, nil)
        }
        if status == errSecSuccess { result(nil) }
        else { result(FlutterError(code: "keychain", message: "无法保存弹幕服务凭证", details: nil)) }
      default: result(FlutterMethodNotImplemented)
      }
    }

    let methods = FlutterMethodChannel(name: methodChannelName, binaryMessenger: messenger)
    methods.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }

    let events = FlutterEventChannel(name: eventChannelName, binaryMessenger: messenger)
    events.setStreamHandler(self)

    // 帧通道：Dart 每送一帧（BGRA 字节），这里包成 CMSampleBuffer 上屏。
    let frames = FlutterMethodChannel(name: frameChannelName, binaryMessenger: messenger)
    frames.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(nil)
        return
      }
      switch call.method {
      case "setDanmaku":
        self.framePump.danmaku.update(call.arguments as? [String: Any] ?? [:])
        if let player = self.avPlayer, self.controller?.isPictureInPictureActive != true {
          self.attach(player: player)
        }
        result(nil)
      case "submitFrame":
        self.handleFrame(call, result: result)
      case "teardown":
        self.clearExternalSource()
        self.stopAvFrames()
        self.avPlayer = nil
        self.inlineAvLayer = nil
        self.avUsesFrames = false
        self.controller?.delegate = nil
        self.controller?.canStartPictureInPictureAutomaticallyFromInline = false
        self.controller?.stopPictureInPicture()
        self.framePump.teardown()
        self.frameHost?.removeFromSuperview()
        self.frameHost = nil
        self.frameLayer = nil
        self.controller = nil
        result(nil)
      case "stats":
        result([
          "received": self.framePump.receivedFrames,
          "dropped": self.framePump.droppedFrames,
        ])
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// 收一帧：BGRA 字节 → CMSampleBuffer → 显示层。
  // The engine owns these layers: never reparent them or clear their player.
  func attachExternal(playerLayer: AVPlayerLayer?, sampleLayer: AVSampleBufferDisplayLayer?,
                      active: @escaping (Bool) -> Void,
                      timeRange: @escaping () -> CMTimeRange,
                      isPaused: @escaping () -> Bool) -> Bool {
    guard controller?.isPictureInPictureActive != true else { return false }
    clearExternalSource()
    controller?.delegate = nil
    controller?.stopPictureInPicture()
    controller = nil
    stopAvFrames()
    avPlayer = nil
    inlineAvLayer = nil
    avUsesFrames = false
    frameHost?.removeFromSuperview()
    frameHost = nil
    frameLayer = nil
    framePump.teardown()
    if let layer = playerLayer {
      controller = AVPictureInPictureController(playerLayer: layer)
    } else if let layer = sampleLayer {
      let source = AVPictureInPictureController.ContentSource(
        sampleBufferDisplayLayer: layer, playbackDelegate: self)
      controller = AVPictureInPictureController(contentSource: source)
    }
    guard let controller else { return false }
    externalActive = active
    externalTimeRange = timeRange
    externalPaused = isPaused
    controller.delegate = self
    // Preparation occurs on the explicit PiP action; stale sources cannot auto-enter.
    controller.canStartPictureInPictureAutomaticallyFromInline = false
    return true
  }

  private func clearExternalSource() {
    externalActive?(false)
    externalActive = nil
    externalTimeRange = nil
    externalPaused = nil
  }

  private func handleFrame(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    if avPlayer != nil { stopAvFrames(); avPlayer = nil; inlineAvLayer = nil; avUsesFrames = false }

    guard let args = call.arguments as? [String: Any],
          let data = args["pixels"] as? FlutterStandardTypedData,
          let width = args["width"] as? Int,
          let height = args["height"] as? Int
    else {
      result(false)
      return
    }
    let timestampMs = (args["timestampMs"] as? Int) ?? 0

    // 首帧到达时才建层并绑定内容源——没有帧就没有内容源，避免「支持但黑屏」。
    if frameLayer == nil {
      framePump.ensureDisplayLayer()
      if let layer = framePump.displayLayer {
        attach(frameLayer: layer)
      }
    }

    let ok = framePump.submit(
      pixels: data.data,
      width: width,
      height: height,
      timestampMs: timestampMs
    )
    result(ok)
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isSupported":
      result(isSupported())
    case "start":
      start(result: result)
    case "stop":
      stop(result: result)
    case "updateState":
      let args = call.arguments as? [String: Any] ?? [:]
      if let rate = args["playbackRate"] as? Double, rate.isFinite, rate > 0 { playbackRate = Float(rate) }
      paused = !(((args["playing"] as? Bool) ?? false) || starting)
      framePump.danmaku.playing = !paused
      framePump.setPlaybackState(playing: !paused, rate: Double(playbackRate))
      durationSeconds = (args["durationMs"] as? Double ?? 0) / 1000
      if #available(iOS 15.0, *) { controller?.invalidatePlaybackState() }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// 能力判定不依赖首帧；内容源由开窗前的准备步骤建立。
  private func isSupported() -> Bool {
    guard #available(iOS 15.0, *) else { return false }
    guard AVPictureInPictureController.isPictureInPictureSupported() else { return false }
    return true
  }

  /// 绑定内容源：内核把解码帧写进这个 layer，系统据此渲染画中画窗口。
  ///
  /// 首帧到达时绑定内容源并挂入窗口视图。
  @available(iOS 15.0, *)
  func attach(frameLayer layer: AVSampleBufferDisplayLayer) {
    frameHost?.removeFromSuperview()
    frameLayer = layer
    if let host = UIApplication.shared.connectedScenes
      .compactMap({ $0 as? UIWindowScene }).flatMap({ $0.windows })
      .first(where: { $0.isKeyWindow })?.rootViewController?.view {
      // Flutter's root layer must remain the only visible inline renderer.
      // A sibling below it keeps the PiP source attached without painting over
      // Flutter textures or retaining an obsolete full-screen frame.
      if let parent = host.superview {
        let sourceView = PipSourceView(frame: host.frame, displayLayer: layer)
        sourceView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        sourceView.isUserInteractionEnabled = false
        parent.insertSubview(sourceView, belowSubview: host)
        frameHost = sourceView
      }
    }
    let source = AVPictureInPictureController.ContentSource(
      sampleBufferDisplayLayer: layer,
      playbackDelegate: self
    )
    let controller = AVPictureInPictureController(contentSource: source)
    controller.delegate = self
    controller.canStartPictureInPictureAutomaticallyFromInline = true
    self.controller = controller
  }

  private func attach(player: AVPlayer, inlineLayer: AVPlayerLayer? = nil) {
    if #available(iOS 15.0, *) { player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible }
    let visibleLayer = inlineLayer ?? (avPlayer === player ? inlineAvLayer : nil)
    // A texture player has no inline AVPlayerLayer. Use its decoded frames,
    // including when danmaku is off, instead of attaching a competing layer.
    let needsFrames = framePump.danmaku.enabled || visibleLayer == nil
    if avPlayer === player && inlineAvLayer === visibleLayer && avUsesFrames == needsFrames && controller != nil { return }
    if controller?.isPictureInPictureActive == true { return }
    stopAvFrames()
    avPlayer = player
    inlineAvLayer = visibleLayer
    avUsesFrames = needsFrames
    if needsFrames, let item = player.currentItem {
      controller?.delegate = nil
      controller?.stopPictureInPicture()
      frameHost?.removeFromSuperview()
      framePump.ensureDisplayLayer()
      if let layer = framePump.displayLayer { attach(frameLayer: layer) }
      let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
      // Resolve track metadata once, never synchronously on every frame.
      Task { @MainActor [weak self, weak item] in
        guard let item else { return }
        do {
          let tracks = try await item.asset.loadTracks(withMediaType: .video)
          guard let track = tracks.first else { return }
          let transform = try await track.load(.preferredTransform)
          guard let self, self.avOutputItem === item else { return }
          self.avTransform = transform
        } catch { /* PiP can use the untransformed priming frame. */ }
      }
      item.add(output)
      avOutput = output
      avOutputItem = item
      startAvFrames()
      return
    }

    controller?.delegate = nil
    controller?.stopPictureInPicture()
    frameHost?.removeFromSuperview()
    frameLayer = nil
    frameHost = nil
    guard let visibleLayer else { return }
    controller = AVPictureInPictureController(playerLayer: visibleLayer)
    controller?.delegate = self
    controller?.canStartPictureInPictureAutomaticallyFromInline = true
  }

  private func stopAvFrames() {
    avTimer?.invalidate(); avTimer = nil
    if let output = avOutput, let item = avOutputItem { item.remove(output) }
    avOutput = nil; avOutputItem = nil
    avTransform = .identity
  }

  private func startAvFrames() {
    guard avUsesFrames, avTimer == nil else { return }
    avTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
      guard let self = self, let player = self.avPlayer, let output = self.avOutput else { return }
      let time = player.currentTime()
      guard time.isValid, time.seconds.isFinite,
            let pixels = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else { return }
      self.framePump.danmaku.playing = player.rate > 0
      self.framePump.submit(buffer: pixels, timestampMs: Int(time.seconds * 1000), transform: self.avTransform)
      // Inline preparation only needs a priming frame; resume the pump on PiP start.
      if self.controller?.isPictureInPictureActive != true && !self.starting {
        self.avTimer?.invalidate(); self.avTimer = nil
      }
    }
  }

  private func start(result: @escaping FlutterResult) {
    guard #available(iOS 15.0, *) else {
      result(FlutterError(code: "unsupported", message: "画中画需要 iOS 15 及以上", details: nil))
      return
    }
    guard AVPictureInPictureController.isPictureInPictureSupported() else {
      result(FlutterError(code: "unsupported", message: "当前设备不支持画中画", details: nil))
      return
    }
    startAvFrames()
    guard let controller else {
      // 首帧还未到达时不能请求开窗。
      result(FlutterError(
        code: "noContentSource",
        message: "画中画视频帧未就绪，请等画面出现后重试",
        details: nil
      ))
      return
    }
    startWhenReady(controller, attempts: 20, result: result)
  }

  @available(iOS 15.0, *)
  private func startWhenReady(_ candidate: AVPictureInPictureController,
                             attempts: Int, result: @escaping FlutterResult) {
    guard controller === candidate else {
      result(FlutterError(code: "cancelled", message: "画中画内容源已释放", details: nil))
      return
    }
    if candidate.isPictureInPicturePossible {
      starting = true
      startAvFrames()
      paused = false
      let currentRate = avPlayer?.rate ?? 0
      if currentRate > 0 { playbackRate = currentRate }
      framePump.setPlaybackState(playing: true, rate: Double(playbackRate))
      avPlayer?.playImmediately(atRate: playbackRate)
      candidate.invalidatePlaybackState()
      candidate.startPictureInPicture()
      result(nil)
    } else if attempts > 0 {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
        guard let self else { result(nil); return }
        self.startWhenReady(candidate, attempts: attempts - 1, result: result)
      }
    } else {
      result(FlutterError(code: "notReady", message: "系统画中画尚未就绪，请重试", details: nil))
    }
  }

  private func stop(result: @escaping FlutterResult) {
    controller?.stopPictureInPicture()
    result(nil)
  }

  private func emit(kind: String, message: String?) {
    var payload: [String: Any] = ["kind": kind]
    if let message { payload["message"] = message }
    eventSink?(payload)
  }
}

// MARK: - FlutterStreamHandler

extension PipController: FlutterStreamHandler {
  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }
}

// MARK: - AVPictureInPictureControllerDelegate

extension PipController: AVPictureInPictureControllerDelegate {
  func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
    externalActive?(true)
    starting = true
    startAvFrames()
    if let rate = avPlayer?.rate, rate > 0 { playbackRate = rate }
    paused = false
  }
  func pictureInPictureController(
    _ controller: AVPictureInPictureController,
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
  ) {
    emit(kind: "restored", message: nil)
    completionHandler(true)
  }
  func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
    starting = false
    paused = false
    framePump.danmaku.playing = true
    framePump.setPlaybackState(playing: true, rate: Double(playbackRate))
    startAvFrames()
    avPlayer?.playImmediately(atRate: playbackRate)
    controller.invalidatePlaybackState()
    emit(kind: "play", message: nil)
    emit(kind: "entered", message: nil)
  }

  func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
    externalActive?(false)
    starting = false
    emit(kind: "exited", message: nil)
  }

  func pictureInPictureController(
    _ controller: AVPictureInPictureController,
    failedToStartPictureInPictureWithError error: Error
  ) {
    externalActive?(false)
    starting = false
    emit(kind: "failed", message: error.localizedDescription)
  }
}

private final class PipSourceView: UIView {
  private let displayLayer: AVSampleBufferDisplayLayer

  init(frame: CGRect, displayLayer: AVSampleBufferDisplayLayer) {
    self.displayLayer = displayLayer
    super.init(frame: frame)
    backgroundColor = .black
    layer.addSublayer(displayLayer)
    displayLayer.frame = bounds
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func layoutSubviews() {
    super.layoutSubviews()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    displayLayer.frame = bounds
    CATransaction.commit()
  }
}

// MARK: - AVPictureInPictureSampleBufferPlaybackDelegate

/// 播放控制委托：系统画中画窗口上的播放 / 暂停 / 进度条都经这里回到内核。
///
/// 系统窗口操作经事件通道回到 Dart；播放状态由 updateState 同步。
extension PipController: AVPictureInPictureSampleBufferPlaybackDelegate {
  func pictureInPictureController(
    _ controller: AVPictureInPictureController,
    setPlaying playing: Bool
  ) {
    // Ignore the transient pause while the system moves the content source.
    // After entry, all PiP play/pause gestures are forwarded normally.
    if starting && !playing { return }
    paused = !playing
    framePump.danmaku.playing = playing
    framePump.setPlaybackState(playing: playing, rate: Double(playbackRate))
    if playing { avPlayer?.playImmediately(atRate: playbackRate) }
    else { avPlayer?.pause() }
    emit(kind: playing ? "play" : "pause", message: nil)
  }

  func pictureInPictureControllerTimeRangeForPlayback(
    _ controller: AVPictureInPictureController
  ) -> CMTimeRange {
    if let externalTimeRange { return externalTimeRange() }
    if durationSeconds > 0 {
      return CMTimeRange(start: .zero, duration: CMTime(seconds: durationSeconds, preferredTimescale: 1000))
    }
    return CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
  }

  func pictureInPictureControllerIsPlaybackPaused(
    _ controller: AVPictureInPictureController
  ) -> Bool {
    if let externalPaused { return externalPaused() }
    return paused
  }

  func pictureInPictureController(
    _ controller: AVPictureInPictureController,
    didTransitionToRenderSize newRenderSize: CMVideoDimensions
  ) {}

  func pictureInPictureController(
    _ controller: AVPictureInPictureController,
    skipByInterval skipInterval: CMTime,
    completion completionHandler: @escaping () -> Void
  ) {
    let seconds = CMTimeGetSeconds(skipInterval)
    if seconds.isFinite { emit(kind: "skip", message: String(Int(seconds * 1000))) }
    completionHandler()
  }
}
