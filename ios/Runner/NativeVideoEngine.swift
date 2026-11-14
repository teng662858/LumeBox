import UIKit
import AVFoundation

struct NativeVideoItem {
  let url: URL
  let headers: [String: String]
  let title: String
  let identity: String
  let position: Double
  let payload: [String: Any]

  init(_ payload: [String: Any]) throws {
    guard let value = payload["url"] as? String, let url = URL(string: value),
          ["http", "https", "file", "rtsp", "rtmp", "rtmps", "udp", "tcp"].contains(url.scheme?.lowercased() ?? "") else {
      throw NSError(domain: "NativeVideo", code: 1, userInfo: [NSLocalizedDescriptionKey: "无效播放地址"])
    }
    self.url = url
    headers = (payload["headers"] as? [String: String] ?? [:]).filter {
      !$0.key.contains("\r") && !$0.key.contains("\n") && !$0.value.contains("\r") && !$0.value.contains("\n")
    }
    title = payload["title"] as? String ?? "播放"
    identity = payload["identity"] as? String ?? value
    let resume = (payload["position"] as? NSNumber)?.doubleValue ?? 0
    position = resume.isFinite ? max(0, resume) : 0
    self.payload = payload
  }
}

struct NativeVideoState {
  var position = 0.0, duration = 0.0, buffered = 0.0
  var ready = false, playing = false, buffering = true, ended = false, firstFrame = false
  var width = 0, height = 0
  var error: String?
  var tracks: [[String: Any]] = []
  mutating func updateFromMPV(_ data: [String: Any]) {
    if let message = data["error"] as? String {
      // Failure notifications may contain no timing fields, or zeroed fields
      // after libmpv unloads the file. Keep the last usable resume position.
      error = message; ready = false; playing = false; buffering = false
      return
    }
    error = nil
    position = (data["position"] as? NSNumber)?.doubleValue ?? 0
    duration = (data["duration"] as? NSNumber)?.doubleValue ?? 0
    buffered = (data["buffered"] as? NSNumber)?.doubleValue ?? 0
    ready = data["ready"] as? Bool ?? false
    buffering = data["buffering"] as? Bool ?? false
    ended = data["ended"] as? Bool ?? false
    playing = data["playing"] as? Bool == true && ready && !buffering && !ended
    width = (data["width"] as? NSNumber)?.intValue ?? 0
    height = (data["height"] as? NSNumber)?.intValue ?? 0
    tracks = data["tracks"] as? [[String: Any]] ?? []
  }
  var dictionary: [String: Any] {
    var data: [String: Any] = ["position": position, "duration": duration, "buffered": buffered,
      "ready": ready, "playing": playing, "buffering": buffering, "ended": ended,
      "firstFrame": firstFrame, "width": width, "height": height]
    if let error { data["error"] = error }
    return data
  }
}

@MainActor protocol NativeVideoEngine: AnyObject {
  // The decoder clock may still be zero while an opening resume or seek is pending.
  var resumePosition: Double? { get }
  var view: UIView { get }
  var player: AVPlayer? { get }
  var sampleLayer: AVSampleBufferDisplayLayer? { get }
  var state: NativeVideoState { get }
  var changed: ((NativeVideoState) -> Void)? { get set }
  func load(_ item: NativeVideoItem)
  func play(rate: Double)
  func setRate(_ rate: Double)
  func pause()
  func seek(_ seconds: Double, completion: @escaping (Bool) -> Void)
  func volume(_ value: Double)
  func rendering(_ enabled: Bool)
  func tracks(_ completion: @escaping ([[String: Any]]) -> Void)
  func selectTrack(_ track: [String: Any])
  func subtitle(_ url: URL)
  func aspect(_ fill: Bool)
  func dispose(_ completion: @escaping () -> Void)
}

@MainActor final class NativeAVSurface: UIView {
  override class var layerClass: AnyClass { AVPlayerLayer.self }
  var videoLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

@MainActor final class NativeAVEngine: NativeVideoEngine {
  private(set) var resumePosition: Double?
  private let surface = NativeAVSurface()
  let player: AVPlayer? = AVPlayer()
  var sampleLayer: AVSampleBufferDisplayLayer? { nil }
  var view: UIView { surface }
  private(set) var state = NativeVideoState()
  var changed: ((NativeVideoState) -> Void)?
  var playbackIntentChanged: ((Bool) -> Void)?
  private var observation: NSKeyValueObservation?
  private var endObserver: NSObjectProtocol?
  private var rateObserver: NSObjectProtocol?
  private var timer: Timer?
  private var metadata: Task<Void, Never>?
  private var subtitleSelection: Task<Void, Never>?
  private var groups: [String: AVMediaSelectionGroup] = [:]
  private var intent = false, seeking = false, disposed = false
  private var speed = 1.0, pendingResume = 0.0
  private let forwardBuffer: Double
  private let subtitlesEnabled: Bool
  private var seekRevision = 0

  init(options: [String: Any] = [:]) {
    let buffer = (options["forwardBufferSeconds"] as? NSNumber)?.doubleValue ?? 0
    forwardBuffer = buffer.isFinite ? min(86400, max(0, buffer)) : 0
    subtitlesEnabled = options["subtitlesEnabled"] as? Bool ?? true
    surface.backgroundColor = .black
    surface.isUserInteractionEnabled = false
    surface.videoLayer.player = player
    player?.automaticallyWaitsToMinimizeStalling = false
    player?.allowsExternalPlayback = true
    player?.usesExternalPlaybackWhileExternalScreenIsActive = true
    rateObserver = NotificationCenter.default.addObserver(forName: AVPlayer.rateDidChangeNotification, object: player, queue: .main) { [weak self] note in
      MainActor.assumeIsolated {
        self?.handleRateChange(note.userInfo?[AVPlayer.rateDidChangeReasonKey] as? AVPlayer.RateDidChangeReason)
      }
    }
  }
  private func handleRateChange(_ reason: AVPlayer.RateDidChangeReason?) {
    // PiP controls the AVPlayer directly. A buffer underrun also sets rate to
    // zero, but must retain the play intent so tick() can resume after refill.
    guard !disposed, state.ready, reason == .setRateCalled, let player else { return }
    let playing = player.rate != 0
    guard intent != playing else { return }
    intent = playing
    if playing { state.ended = false }
    tick()
    playbackIntentChanged?(playing)
  }
  func load(_ media: NativeVideoItem) {
    guard !disposed, let player else { return }
    metadata?.cancel(); metadata = nil; groups.removeAll()
    observation = nil
    if let endObserver { NotificationCenter.default.removeObserver(endObserver) }; endObserver = nil
    intent = false
    player.pause(); player.currentItem?.cancelPendingSeeks(); player.currentItem?.asset.cancelLoading()
    let asset = AVURLAsset(url: media.url, options: media.headers.isEmpty ? nil : ["AVURLAssetHTTPHeaderFieldsKey": media.headers])
    let item = AVPlayerItem(asset: asset)
    // This is playback read-ahead, never a startup precondition.
    item.preferredForwardBufferDuration = forwardBuffer
    seekRevision += 1
    state = NativeVideoState(); pendingResume = media.position; resumePosition = media.position; seeking = false
    player.replaceCurrentItem(with: item)
    subtitleSelection?.cancel()
    if !subtitlesEnabled { disableEmbeddedSubtitles() }
    observation = item.observe(\.status, options: [.initial, .new]) { [weak self, weak item] _, _ in
      DispatchQueue.main.async {
        guard let self, let item, self.player?.currentItem === item, !self.disposed else { return }
        if item.status == .failed {
          if let error = item.error as NSError? {
            self.state.error = "\(error.localizedDescription) (\(error.domain) \(error.code))\(error.localizedFailureReason.map { "\n" + $0 } ?? "")"
          } else { self.state.error = "系统播放器装载失败" }
          self.state.buffering = false; self.changed?(self.state)
        } else if item.status == .readyToPlay {
          self.state.ready = true
          if self.pendingResume > 0 {
            let resume = self.pendingResume; self.pendingResume = 0
            self.seek(resume) { _ in }
          } else {
            if !self.seeking { self.resumePosition = nil }
            self.resume()
          }
          self.tick()
        }
      }
    }
    endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated {
      guard let self else { return }
      self.intent = false; self.state.ended = true; self.state.playing = false; self.state.buffering = false
      self.changed?(self.state)
          }
    }
    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.tick()       }
    }
    changed?(state)
  }
  private func tick() {
    guard !disposed, let player, let item = player.currentItem else { return }
    func finite(_ value: Double) -> Double { value.isFinite ? max(0, value) : 0 }
    state.position = finite(player.currentTime().seconds)
    // Item timing is nonblocking; querying an unloaded asset duration is forbidden.
    state.duration = finite(item.duration.seconds)
    state.width = Int(max(0, item.presentationSize.width)); state.height = Int(max(0, item.presentationSize.height))
    state.firstFrame = surface.videoLayer.isReadyForDisplay
    state.ready = item.status == .readyToPlay
    state.buffered = item.loadedTimeRanges.compactMap { value -> Double? in
      let range = value.timeRangeValue
      guard range.start.seconds <= state.position + 0.05, range.end.seconds >= state.position else { return nil }
      return finite(range.end.seconds - state.position)
    }.max() ?? 0
    if state.ready && intent && !seeking && player.rate == 0 && state.buffered >= 0.25 { resume() }
    state.playing = intent && player.timeControlStatus == .playing && !seeking && !state.ended
    state.buffering = state.error == nil && !state.ended && (!state.ready || seeking || (intent && player.timeControlStatus != .playing))
    changed?(state)
  }
  private func resume() {
    if intent && state.ready && !seeking && !disposed { player?.playImmediately(atRate: Float(speed)) }
  }
  func play(rate: Double) {
    intent = true; state.ended = false; setRate(rate)
  }
  func setRate(_ rate: Double) {
    speed = rate; player?.defaultRate = Float(rate)
    resume()
  }
  func pause() { intent = false; player?.pause(); tick() }
  func seek(_ seconds: Double, completion: @escaping (Bool) -> Void) {
    guard !disposed, let player else { completion(false); return }
    seeking = true
    resumePosition = max(0, seconds)
    seekRevision += 1; let revision = seekRevision
    let current = player.currentItem
    player.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600), toleranceBefore: CMTime(seconds: 0.25, preferredTimescale: 600), toleranceAfter: CMTime(seconds: 0.25, preferredTimescale: 600)) { [weak self] finished in
      DispatchQueue.main.async {
        guard let self, !self.disposed, self.seekRevision == revision, self.player?.currentItem === current else { completion(false); return }
        self.seeking = false; self.resumePosition = nil
        if finished { self.state.ended = false }
        self.resume(); self.tick(); completion(finished)
      }
    }
  }
  func volume(_ value: Double) { player?.volume = Float(value) }
  func rendering(_ enabled: Bool) { surface.videoLayer.player = enabled ? player : nil }
  func aspect(_ fill: Bool) { surface.videoLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect }
  func tracks(_ completion: @escaping ([[String: Any]]) -> Void) {
    guard let item = player?.currentItem else { completion([]); return }
    metadata?.cancel()
    metadata = Task { @MainActor [weak self, weak item] in
      guard let self, let item else { completion([]); return }
      var tracks: [[String: Any]] = []
      for (type, characteristic) in [("audio", AVMediaCharacteristic.audible), ("sub", .legible)] {
        let group = try? await item.asset.loadMediaSelectionGroup(for: characteristic)
        guard !Task.isCancelled, !self.disposed, self.player?.currentItem === item else { completion([]); return }
        self.groups[type] = group
        if let group {
          let selected = item.currentMediaSelection.selectedMediaOption(in: group)
          for (index, option) in group.options.enumerated() {
            tracks.append(["type": type, "id": String(index), "label": option.displayName, "selected": selected == option])
          }
        }
      }
      completion(tracks)
    }
  }
  func selectTrack(_ track: [String: Any]) {
    guard let type = track["type"] as? String, let group = groups[type], let item = player?.currentItem else { return }
    if type == "sub" { subtitleSelection?.cancel() }
    let id = Int(track["id"] as? String ?? "") ?? -1
    item.select(group.options.indices.contains(id) ? group.options[id] : nil, in: group)
  }
  func subtitle(_ url: URL) {
    // The screen draws the external captions. Hide the previously selected embedded track.
    disableEmbeddedSubtitles()
  }
  private func disableEmbeddedSubtitles() {
    subtitleSelection?.cancel()
    guard let item = player?.currentItem else { return }
    subtitleSelection = Task { @MainActor [weak self, weak item] in
      guard let self, let item else { return }
      let group = try? await item.asset.loadMediaSelectionGroup(for: .legible)
      guard !Task.isCancelled, !self.disposed, self.player?.currentItem === item else { return }
      if let group { item.select(nil, in: group) }
    }
  }
  func dispose(_ completion: @escaping () -> Void) {
    guard !disposed else { completion(); return }
    disposed = true; intent = false
    timer?.invalidate(); timer = nil; metadata?.cancel(); metadata = nil
    subtitleSelection?.cancel(); subtitleSelection = nil
    observation = nil
    if let endObserver { NotificationCenter.default.removeObserver(endObserver) }; endObserver = nil
    if let rateObserver { NotificationCenter.default.removeObserver(rateObserver) }; rateObserver = nil
    playbackIntentChanged = nil
    player?.pause(); player?.currentItem?.cancelPendingSeeks(); player?.currentItem?.asset.cancelLoading()
    player?.replaceCurrentItem(with: nil); surface.videoLayer.player = nil; changed = nil
    completion()
  }
}

@MainActor final class NativeMPVSurface: UIView {
  override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
  var videoLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
}

@MainActor final class NativeMPVEngine: NativeVideoEngine {
  private(set) var resumePosition: Double?
  private let surface = NativeMPVSurface()
  var player: AVPlayer? { nil }
  var sampleLayer: AVSampleBufferDisplayLayer? { surface.videoLayer }
  var view: UIView { surface }
  private(set) var state = NativeVideoState()
  var changed: ((NativeVideoState) -> Void)?
  private var bridge: NativeMPVBridge?
  private var disposed = false, desiredPlay = false
  private var speed = 1.0
  private var pendingResume = 0.0
  private var pendingSubtitle: URL?
  private var seekRevision = 0
  private var seekCompletion: ((Bool) -> Void)?
  #if DEBUG
  // The native smoke fixture has a red top stripe and a blue bottom stripe.
  // Inspect decoded pixels, rather than treating an advancing clock as upright video.
  private(set) var debugFrameUpright = false
  #endif
  init(options: [String: Any]) {
    surface.backgroundColor = .black; surface.isUserInteractionEnabled = false
    bridge = NativeMPVBridge(options: options, state: { [weak self] data in
      guard let self, !self.disposed else { return }
      let wasEnded = self.state.ended
      self.state.updateFromMPV(data)
      if self.state.error != nil {
        let complete = self.seekCompletion; self.seekCompletion = nil
        self.changed?(self.state)
        complete?(false)
        return
      }
      if self.state.ended && !wasEnded { self.desiredPlay = false }
      if self.state.ready, self.state.error == nil, let url = self.pendingSubtitle {
        self.subtitle(url)
      }
      if self.state.ready && self.pendingResume > 0 {
        let target = self.pendingResume; self.pendingResume = 0
        self.seek(target) { _ in }
      } else if self.state.ready && self.seekCompletion == nil {
        self.resumePosition = nil
      }
      if self.state.ready && self.desiredPlay && !self.state.playing && !self.state.buffering && !self.state.ended {
        self.bridge?.setProperty("pause", value: "no")
      }
      self.changed?(self.state)
      if let revision = data["seekRevision"] as? Int, revision == self.seekRevision {
        let complete = self.seekCompletion
        self.seekCompletion = nil
        complete?(data["seekSucceeded"] as? Bool == true)
      }
    }, frame: { [weak self] sample in
      guard let self, !self.disposed else { return }
      #if DEBUG
      if let buffer = CMSampleBufferGetImageBuffer(sample) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        if let base = CVPixelBufferGetBaseAddress(buffer) {
          let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
          let stride = CVPixelBufferGetBytesPerRow(buffer)
          let pixels = base.assumingMemoryBound(to: UInt8.self)
          let top = (height / 16) * stride + (width / 2) * 4
          let bottom = (height - 1 - height / 16) * stride + (width / 2) * 4
          self.debugFrameUpright = pixels[top + 2] > 160 && pixels[top] < 80 &&
            pixels[bottom] > 160 && pixels[bottom + 2] < 80
        }
        CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
      }
      #endif
      if self.surface.videoLayer.status == .failed { self.surface.videoLayer.flush() }
      self.surface.videoLayer.enqueue(sample)
      self.state.firstFrame = true
    })
  }
  func load(_ item: NativeVideoItem) {
    seekCompletion?(false); seekCompletion = nil; seekRevision += 1
    pendingResume = item.position
    resumePosition = item.position
    pendingSubtitle = nil
    state = NativeVideoState(); surface.videoLayer.flushAndRemoveImage()
    bridge?.openURL(item.url.absoluteString, headers: item.headers, position: item.position)
  }
  func play(rate: Double) {
    desiredPlay = true; setRate(rate)
    if state.ready { bridge?.setProperty("pause", value: "no") }
  }
  func setRate(_ rate: Double) {
    speed = rate
    bridge?.setProperty("speed", value: String(rate))
  }
  func pause() { desiredPlay = false; bridge?.setProperty("pause", value: "yes") }
  func seek(_ seconds: Double, completion: @escaping (Bool) -> Void) {
    guard !disposed, let bridge else { completion(false); return }
    seekCompletion?(false)
    seekRevision += 1
    resumePosition = max(0, seconds)
    seekCompletion = { [weak self] finished in
      self?.resumePosition = nil
      completion(finished)
    }
    bridge.seek(to: max(0, seconds), revision: seekRevision)
  }
  func volume(_ value: Double) { bridge?.setProperty("volume", value: String(value * 100)) }
  func rendering(_ enabled: Bool) { bridge?.setRenderingEnabled(enabled) }
  func aspect(_ fill: Bool) { surface.videoLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect }
  func tracks(_ completion: @escaping ([[String: Any]]) -> Void) {
    completion(state.tracks.compactMap { track in
      guard let type = track["type"] as? String, ["audio", "sub"].contains(type) else { return nil }
      let label = track["title"] as? String ?? track["lang"] as? String ?? track["codec"] as? String ?? "轨道"
      var row: [String: Any] = ["type": type, "id": "\(track["id"] ?? "")", "label": label, "selected": track["selected"] as? Bool ?? false]
      if let path = track["external-filename"] as? String { row["externalPath"] = path }
      return row
    })
  }
  func selectTrack(_ track: [String: Any]) {
    if (track["type"] as? String) == "sub" { pendingSubtitle = nil }
    bridge?.setProperty((track["type"] as? String) == "audio" ? "aid" : "sid", value: track["id"] as? String ?? "no")
  }
  func subtitle(_ url: URL) {
    guard !disposed else { return }
    guard state.ready, state.error == nil else { pendingSubtitle = url; return }
    pendingSubtitle = nil
    bridge?.command(["sub-add", url.path, "select"])
  }
  func dispose(_ completion: @escaping () -> Void) {
    guard !disposed else { completion(); return }
    disposed = true; changed = nil; surface.videoLayer.flushAndRemoveImage()
    pendingSubtitle = nil
    seekCompletion?(false); seekCompletion = nil
    let pending = bridge; bridge = nil
    // GL resources cannot be destroyed in the background either. Audio pauses
    // immediately; keep the resource owner until foreground cleanup is legal.
    if UIApplication.shared.applicationState != .active {
      pending?.setProperty("pause", value: "yes")
      var observer: NSObjectProtocol?
      observer = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
        if let observer { NotificationCenter.default.removeObserver(observer) }
        pending?.dispose(completion)
      }
    } else { pending?.dispose(completion) }
  }
}
