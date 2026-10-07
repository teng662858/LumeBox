import AVFoundation
import Flutter
import MediaPlayer

/// 播放会话的原生实现（iOS）：后台音频 + 锁屏 / 控制中心的媒体控制器。
///
/// 契约见 Dart 侧 `MethodChannelPlaybackBackend`：
/// 方法通道 `lumebox/playback` 的 `isSupported` / `start` / `update` / `stop`，
/// 事件通道 `lumebox/playback/events` 回 `{command: play|pause|toggle|next|previous}`。
///
/// ## 为什么要这一层
///
/// - **后台音频继续播放**：只有把 `AVAudioSession` 的 category 设成 `.playback`
///   并在 `UIBackgroundModes` 里声明 `audio`（本项目已有，见 Info.plist），
///   切到后台后声音才不会被系统掐掉；
/// - **锁屏 / 控制中心的播放条**：`MPNowPlayingInfoCenter` 与
///   `MPRemoteCommandCenter` 只在原生侧存在——播放 / 暂停 / 上一集 / 下一集
///   这些按钮点下去，宿主才知道用户想干什么。
///
/// ## 与听书（SpeechController）的关系
///
/// 两处都会用 `MPRemoteCommandCenter`。这里的原则是**谁在用、谁启用**：
/// 视频会话结束时把命令处理器置空并清掉播放条，听书那套再接管；反之亦然。
/// 系统的播放条只有一条，谁最后设置谁显示——这符合「用户最后一次操作的那个」。
final class PlaybackSessionController: NSObject {
  private let methodChannelName = "lumebox/playback"
  private let eventChannelName = "lumebox/playback/events"

  private var eventSink: FlutterEventSink?

  /// 最近一次已知状态（`update` 只传变化项，其余沿用）。
  private var playing = false
  private var position: Double = 0
  private var duration: Double = 0
  private var speed: Double = 1

  func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: methodChannelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(FlutterError(code: "disposed", message: "播放会话已释放", details: nil))
        return
      }
      switch call.method {
      case "isSupported":
        result(true)
      case "start":
        guard let args = call.arguments as? [String: Any] else {
          result(FlutterError(code: "badArgs", message: "缺少播放信息", details: nil))
          return
        }
        self.start(
          title: args["title"] as? String ?? "Lume Box",
          subtitle: args["subtitle"] as? String,
          durationMs: (args["durationMs"] as? NSNumber)?.doubleValue ?? 0,
          speed: (args["speed"] as? NSNumber)?.doubleValue ?? 1
        )
        result(nil)
      case "update":
        let args = call.arguments as? [String: Any] ?? [:]
        self.update(args)
        result(nil)
      case "stop":
        self.stop()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    let events = FlutterEventChannel(name: eventChannelName, binaryMessenger: messenger)
    events.setStreamHandler(self)
  }

  // ------------------------------------------------------------------ 会话

  private func start(title: String, subtitle: String?, durationMs: Double, speed: Double) {
    position = 0
    duration = durationMs / 1000
    self.speed = speed
    playing = true

    // 后台音频：播放类会话 + 允许与其他音频共存的选择交给系统。
    // 只升不降（如果已经在 .playback 就不动），与 video_player 插件的口径一致。
    do {
      let session = AVAudioSession.sharedInstance()
      if session.category != .playback {
        try session.setCategory(.playback, mode: .moviePlayback)
      }
      try session.setActive(true)
    } catch {
      NSLog("[LumeBox] 设置音频会话失败: \(error)")
    }

    var info: [String: Any] = [
      MPMediaItemPropertyTitle: title,
      MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
      MPNowPlayingInfoPropertyPlaybackRate: playing ? speed : 0,
    ]
    if let subtitle, !subtitle.isEmpty {
      info[MPMediaItemPropertyArtist] = subtitle
    }
    if duration > 0 {
      info[MPMediaItemPropertyPlaybackDuration] = duration
    }
    MPNowPlayingInfoCenter.default().nowPlayingInfo = info

    configureCommands(enabled: true)
  }

  private func update(_ args: [String: Any]) {
    if let value = (args["positionMs"] as? NSNumber)?.doubleValue {
      position = value / 1000
    }
    if let value = (args["durationMs"] as? NSNumber)?.doubleValue {
      duration = value / 1000
    }
    if let value = (args["speed"] as? NSNumber)?.doubleValue {
      speed = value
    }
    if let value = args["playing"] as? NSNumber {
      playing = value.boolValue
    }

    var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
    info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position
    info[MPNowPlayingInfoPropertyPlaybackRate] = playing ? speed : 0
    if duration > 0 {
      info[MPMediaItemPropertyPlaybackDuration] = duration
    }
    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
  }

  private func stop() {
    playing = false
    MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    configureCommands(enabled: false)
    // 不主动把 AVAudioSession 置为 inactive：视频可能只是退出页面，音频还在播
    // （画中画 / 后台播放是独立状态）；系统会在会话无人使用时自行降级。
  }

  /// 注册 / 注销系统控件命令。
  ///
  /// 「切集」映射到 next / previous：播放列表概念由 Dart 侧维护（下一集 = 连播的
  /// 那一集），原生只负责把按钮点击转成事件。
  private func configureCommands(enabled: Bool) {
    let center = MPRemoteCommandCenter.shared()
    let commands: [(MPRemoteCommand, Selector, String)] = [
      (center.playCommand, #selector(handlePlay), "play"),
      (center.pauseCommand, #selector(handlePause), "pause"),
      (center.togglePlayPauseCommand, #selector(handleToggle), "toggle"),
      (center.nextTrackCommand, #selector(handleNext), "next"),
      (center.previousTrackCommand, #selector(handlePrevious), "previous"),
    ]

    for (command, selector, _) in commands {
      command.removeTarget(nil)
      if enabled {
        command.isEnabled = true
        command.addTarget(self, action: selector)
      } else {
        command.isEnabled = false
      }
    }
  }

  @objc private func handlePlay() -> MPRemoteCommandHandlerStatus {
    emit("play")
    return .success
  }

  @objc private func handlePause() -> MPRemoteCommandHandlerStatus {
    emit("pause")
    return .success
  }

  @objc private func handleToggle() -> MPRemoteCommandHandlerStatus {
    emit("toggle")
    return .success
  }

  @objc private func handleNext() -> MPRemoteCommandHandlerStatus {
    emit("next")
    return .success
  }

  @objc private func handlePrevious() -> MPRemoteCommandHandlerStatus {
    emit("previous")
    return .success
  }

  private func emit(_ command: String) {
    eventSink?(["command": command])
  }
}

extension PlaybackSessionController: FlutterStreamHandler {
  func onListen(
    withArguments arguments: Any?,
    eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    eventSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }
}
