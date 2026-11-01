import Flutter
import UIKit
import AVFoundation
import AetherEngine

/// Per-player channels share a registry; views can be recreated without losing a session.
@MainActor
final class AetherPlayerController: NSObject, FlutterPlatformViewFactory {
  private var sessions: [Int: AetherSession] = [:]
  private var nextID = 0

  static func register(with registrar: FlutterPluginRegistrar) {
    let controller = AetherPlayerController()
    registrar.register(controller, withId: "lumebox/aether_view")
    let channel = FlutterMethodChannel(name: "lumebox/aether", binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { [controller] call, result in
      Task { @MainActor in await controller.handle(call, result: result) }
    }
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol { FlutterStandardMessageCodec.sharedInstance() }
  func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
    let id = (args as? [String: Any])?["id"] as? Int
    return AetherSurface(frame: frame, session: id.flatMap { sessions[$0] })
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) async {
    do {
      if call.method == "create" {
        let session = try AetherSession()
        nextID += 1; sessions[nextID] = session; result(nextID); return
      }
      let args = call.arguments as? [String: Any] ?? [:]
      guard let id = args["id"] as? Int, let session = sessions[id] else {
        if call.method == "dispose" { result(nil); return }
        result(FlutterError(code: "aether_session", message: "播放器已释放", details: nil)); return
      }
      switch call.method {
      case "load":
        guard let text = args["url"] as? String, let url = URL(string: text) else {
          result(FlutterError(code: "aether_url", message: "无效播放地址", details: nil)); return
        }
        session.options = args["options"] as? [String: Any] ?? [:]
        let options = session.loadOptions(headers: args["headers"] as? [String: String] ?? [:])
        session.loadTask?.cancel()
        let task = Task { @MainActor in
          try await session.engine.load(url: url, options: options)
          try Task.checkCancellation()
        }
        session.loadTask = task
        _ = try await task.value
        guard sessions[id] === session else { throw CancellationError() }
        session.loaded = true
        session.applyTransportOptions()
        session.chooseAudioPreference()
        result(nil)
      case "settings":
        let previous = session.options
        session.options = args["options"] as? [String: Any] ?? [:]
        // Rebuild only options that affect native routing, retaining the timeline and tracks.
        if session.loaded && ["wantsHdr", "dolbyVision"].contains(where: {
          (previous[$0] as? Bool) != (session.options[$0] as? Bool)
        }) {
          let hdr = session.options["wantsHdr"] as? Bool ?? true
          let dv = session.options["dolbyVision"] as? Bool ?? true
          try await session.engine.reloadAtCurrentPosition { options in
            options.matchContentEnabled = hdr
            options.attemptsHDRMasterOnUnprovenPanel = hdr
            options.dolbyVisionHandling = dv ? .automatic : .baseLayerOnly
          }
        }
        session.applyTransportOptions()
        if session.loaded && (previous["dolbyAudio"] as? Bool) != (session.options["dolbyAudio"] as? Bool) {
          session.chooseAudioPreference()
        }
        result(nil)
      case "play": session.engine.play(); result(nil)
      case "pause": session.engine.pause(); result(nil)
      case "stop": session.loadTask?.cancel(); session.engine.stop(); session.loaded = false; result(nil)
      case "dispose":
        sessions.removeValue(forKey: id)
        session.loadTask?.cancel(); session.engine.stop(); session.loaded = false
        result(nil)
      case "seek": await session.engine.seek(to: (args["seconds"] as? Double ?? 0)); result(nil)
      case "volume": session.engine.volume = Float(args["value"] as? Double ?? 1); result(nil)
      case "snapshot": result(session.snapshot())
      case "audioTracks": result(session.tracks(subtitle: false))
      case "subtitleTracks": result(session.tracks(subtitle: true))
      case "selectAudio":
        if let index = args["track"] as? Int { session.engine.selectAudioTrack(index: index) }
        result(nil)
      case "selectSubtitle":
        if let index = args["track"] as? Int { session.engine.selectSubtitleTrack(index: index) }
        else { session.engine.clearSubtitle() }
        result(nil)
      case "externalSubtitle":
        guard let path = args["path"] as? String else { result(false); return }
        let url = path.hasPrefix("file:") ? URL(string: path) : URL(fileURLWithPath: path)
        guard let url = url, FileManager.default.fileExists(atPath: url.path) else { result(false); return }
        session.engine.selectSidecarSubtitle(url: url)
        result(true)
      default: result(FlutterMethodNotImplemented)
      }
    } catch {
      result(FlutterError(code: "aether", message: error.localizedDescription, details: nil))
    }
  }
}

@MainActor
private final class AetherSession {
  let engine: AetherEngine
  var options: [String: Any] = [:]
  var loaded = false
  var loadTask: Task<Void, Error>?
  weak var surface: AetherSurface?

  init() throws {
    engine = try AetherEngine()
    engine.backgroundPlaybackEnabled = true
    // LumeBox owns lock-screen actions via PlaybackSessionController.
    engine.ownsVideoNowPlayingSession = false
    engine.ownsSoftwareNowPlaying = false
  }

  func loadOptions(headers: [String: String]) -> LoadOptions {
    var result = LoadOptions()
    result.httpHeaders = headers
    result.autoplay = false
    result.matchContentEnabled = options["wantsHdr"] as? Bool ?? true
    result.attemptsHDRMasterOnUnprovenPanel = result.matchContentEnabled
    result.dolbyVisionHandling = (options["dolbyVision"] as? Bool ?? true) ? .automatic : .baseLayerOnly
    // Keep the remux path: audio switching/headers/HDR work for MKV and HLS alike.
    result.nativeRemoteHLS = false
    result.preserveASSMarkup = false // Plain native caption overlay; libass stays available in MPV.
    result.confirmAtmos = true
    let language = options["subtitleLanguage"] as? String ?? "source"
    if language != "source" && language != "off" { result.preferredSubtitleLanguages = [language] }
    let seconds = options["forwardBufferSeconds"] as? Double ?? 15
    result.forwardBufferSegments = max(1, Int(ceil(seconds / 2)))
    result.sessionCacheByteBudget = options["maxBufferBytes"] as? Int ?? 64 * 1024 * 1024
    return result
  }

  func applyTransportOptions() {
    engine.setRate(Float(options["speed"] as? Double ?? 1))
    if options["subtitlesEnabled"] as? Bool == false { surface?.hideSubtitles() }
  }

  func chooseAudioPreference() {
    let preferDolby = options["dolbyAudio"] as? Bool ?? true
    let tracks = engine.audioTracks
    if let track = tracks.first(where: {
      let dolby = ["ac3", "eac3", "truehd"].contains($0.codec.lowercased()) || $0.isAtmos
      return dolby == preferDolby
    }) { engine.selectAudioTrack(index: track.id) }
  }

  func tracks(subtitle: Bool) -> [[String: Any]] {
    let selected = subtitle ? engine.activeSubtitleTrackIndex : engine.activeAudioTrackIndex
    return (subtitle ? engine.subtitleTracks : engine.audioTracks).map { track in
      var value: [String: Any] = ["id": track.id, "label": track.name.isEmpty ? track.codec : track.name,
        "selected": selected == track.id]
      if let language = track.language { value["language"] = language }
      return value
    }
  }

  func snapshot() -> [String: Any] {
    surface?.updateSubtitles()
    let audio = engine.audioTracks.first { $0.id == engine.activeAudioTrackIndex }
    var presentation = [
      "片源动态范围：\(engine.sourceVideoFormat)",
      "内核报告动态范围：\(engine.videoFormat)",
      "显示路径：\(engine.videoRoute.rawValue) / \(engine.playbackBackend.rawValue)（原生显示层）",
      "音频路径：\(engine.audioDelivery.rawValue)",
      "HDR / Atmos 实际输出取决于片源、设备与输出路由；格式标签不等于输出认证",
    ]
    if options["wantsHdr"] as? Bool == false {
      presentation.append("偏好 SDR：优先选择 SDR 变体，关闭动态范围匹配；单一 HDR 片源由系统处理")
    }
    if options["dolbyVision"] as? Bool == false {
      presentation.append("杜比视界关闭：兼容片源使用基础层；无兼容基础层的 Profile 5 保留原生路径")
    }
    if options["enhancementEnabled"] as? Bool == true { presentation.append("画质增强：当前内核未接入，请切换 MPV") }
    var value: [String: Any] = [
      "position": engine.currentTime.isFinite ? engine.currentTime : 0,
      "duration": engine.duration.isFinite ? engine.duration : 0,
      "playing": engine.state == .playing,
      "buffering": engine.isBuffering || engine.state == .loading,
      "width": Int(engine.sourceVideoWidth), "height": Int(engine.sourceVideoHeight),
      "bitrate": Double(engine.sourceVideoBitrate) / 1000,
      "presentation": presentation,
    ]
    if let codec = engine.sourceVideoCodecName { value["videoCodec"] = codec }
    if let audio = audio { value["audioCodec"] = audio.isAtmos ? "\(audio.codec) (Atmos 音轨)" : audio.codec }
    if let fps = engine.sourceVideoFrameRate { value["fps"] = fps }
    if case .error(let message) = engine.state { value["error"] = message }
    return value
  }
}

@MainActor
private final class AetherSurface: NSObject, FlutterPlatformView {
  private let container = UIView()
  private let video = AetherPlayerView(frame: .zero)
  private let caption = UILabel()
  private let bitmap = UIImageView()
  private weak var session: AetherSession?

  init(frame: CGRect, session: AetherSession?) {
    self.session = session
    super.init()
    container.frame = frame; container.backgroundColor = .black
    for view in [video, bitmap, caption] { view.translatesAutoresizingMaskIntoConstraints = false; container.addSubview(view) }
    caption.textColor = .white; caption.font = .systemFont(ofSize: 22, weight: .medium)
    caption.numberOfLines = 0; caption.textAlignment = .center
    caption.layer.shadowColor = UIColor.black.cgColor; caption.layer.shadowOpacity = 1
    caption.layer.shadowRadius = 2; caption.layer.shadowOffset = .zero
    bitmap.contentMode = .scaleAspectFit
    NSLayoutConstraint.activate([
      video.leadingAnchor.constraint(equalTo: container.leadingAnchor), video.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      video.topAnchor.constraint(equalTo: container.topAnchor), video.bottomAnchor.constraint(equalTo: container.bottomAnchor),
      bitmap.leadingAnchor.constraint(equalTo: container.leadingAnchor), bitmap.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      bitmap.topAnchor.constraint(equalTo: container.topAnchor), bitmap.bottomAnchor.constraint(equalTo: container.bottomAnchor),
      caption.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
      caption.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
      caption.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -24),
    ])
    session?.surface = self
    session?.engine.bind(view: video)
  }
  func view() -> UIView { container }
  func hideSubtitles() { caption.text = nil; bitmap.image = nil }
  func updateSubtitles() {
    guard let session = session, session.options["subtitlesEnabled"] as? Bool != false else { hideSubtitles(); return }
    let time = session.engine.currentTime
    let cues = session.engine.subtitleCues.filter { $0.startTime <= time && time < $0.endTime }
    caption.text = cues.compactMap { $0.text }.joined(separator: "\n")
    // Preserve the bitmap canvas geometry; subtitles are not stretched to fill the picture.
    guard !container.bounds.isEmpty else { bitmap.image = nil; return }
    let renderer = UIGraphicsImageRenderer(size: container.bounds.size)
    let images = cues.compactMap { cue -> SubtitleImage? in
      if case .image(let image) = cue.body { return image }; return nil
    }
    bitmap.image = images.isEmpty ? nil : renderer.image { _ in
      for image in images {
        let rect = image.position
        UIImage(cgImage: image.cgImage).draw(in: CGRect(x: rect.minX * container.bounds.width,
          y: rect.minY * container.bounds.height, width: rect.width * container.bounds.width,
          height: rect.height * container.bounds.height))
      }
    }
  }
}
