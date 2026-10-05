import AVFoundation
import AVKit
import Flutter
import UIKit

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
/// AVPlayer 内核不经过这里：它自带 `AVPictureInPictureController(playerLayer:)`，
/// 由 video_player 插件在原生侧直接处理（见播放器文档的画中画规范）。
///
/// 帧喂入：内核侧（MPV 的帧转发）尚未接入，因此当前 [start] 会如实返回失败原因，
/// 不假装成功。契约与控制器生命周期已经就位，接上帧转发即可生效。
final class PipController: NSObject {
  private let methodChannelName = "lumebox/pip"
  private let eventChannelName = "lumebox/pip/events"

  private var eventSink: FlutterEventSink?
  private var controller: AVPictureInPictureController?
  private var frameLayer: AVSampleBufferDisplayLayer?

  /// 是否已绑定内容源（绑定后才可能开启画中画）。
  private var hasContentSource: Bool { frameLayer != nil }

  func register(with messenger: FlutterBinaryMessenger) {
    let methods = FlutterMethodChannel(name: methodChannelName, binaryMessenger: messenger)
    methods.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }

    let events = FlutterEventChannel(name: eventChannelName, binaryMessenger: messenger)
    events.setStreamHandler(self)
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isSupported":
      result(isSupported())
    case "start":
      start(result: result)
    case "stop":
      stop(result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// 能力判定：系统版本 + 设备支持 + 内容源已就绪。
  ///
  /// 只有三者都满足才说「支持」——不然按钮会亮着但点了没反应。
  private func isSupported() -> Bool {
    guard #available(iOS 15.0, *) else { return false }
    guard AVPictureInPictureController.isPictureInPictureSupported() else { return false }
    return hasContentSource
  }

  /// 绑定内容源：内核把解码帧写进这个 layer，系统据此渲染画中画窗口。
  ///
  /// 由帧转发层在播放器就绪时调用（尚未接入）。
  @available(iOS 15.0, *)
  func attach(frameLayer layer: AVSampleBufferDisplayLayer) {
    frameLayer = layer
    let source = AVPictureInPictureController.ContentSource(
      sampleBufferDisplayLayer: layer,
      playbackDelegate: self
    )
    let controller = AVPictureInPictureController(contentSource: source)
    controller.delegate = self
    self.controller = controller
    emit(kind: "restored", message: nil)
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
    guard let controller else {
      // 帧转发未接入：如实报「内容源未就绪」，不假装成功。
      result(FlutterError(
        code: "noContentSource",
        message: "画中画内容源未就绪（当前内核的帧转发尚未接入）",
        details: nil
      ))
      return
    }
    controller.startPictureInPicture()
    result(nil)
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
  func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
    emit(kind: "entered", message: nil)
  }

  func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
    emit(kind: "exited", message: nil)
  }

  func pictureInPictureController(
    _ controller: AVPictureInPictureController,
    failedToStartPictureInPictureWithError error: Error
  ) {
    emit(kind: "failed", message: error.localizedDescription)
  }
}

// MARK: - AVPictureInPictureSampleBufferPlaybackDelegate

/// 播放控制委托：系统画中画窗口上的播放 / 暂停 / 进度条都经这里回到内核。
///
/// 当前内核侧尚未接帧转发，因此播放状态一律按「未知」回报（时长无穷、不暂停），
/// 让系统画出基础窗口；接上内核后在这里转成真实的 seek / pause 调用。
extension PipController: AVPictureInPictureSampleBufferPlaybackDelegate {
  func pictureInPictureController(
    _ controller: AVPictureInPictureController,
    setPlaying playing: Bool
  ) {
    // 由内核决定是否响应（帧转发接入后在此转发）。
  }

  func pictureInPictureControllerTimeRangeForPlayback(
    _ controller: AVPictureInPictureController
  ) -> CMTimeRange {
    return CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
  }

  func pictureInPictureControllerIsPlaybackPaused(
    _ controller: AVPictureInPictureController
  ) -> Bool {
    return false
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
    completionHandler()
  }
}
