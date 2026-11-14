// Appended to the production controller file for a standalone UIKit simulator
// host. Exercises private production code, not a second player implementation.
extension NativeVideoScreen {
  fileprivate static func checkPausedPlaybackRate(_ item: NativeVideoItem) {
    let screen = NativeVideoScreen(session: "paused-rate", item: item, options: [:])
    let engine = NativeAVEngine()
    screen.engine = engine
    screen.holdState(.began)
    precondition(engine.player?.defaultRate == 2, "hold temporarily changes the engine rate")
    screen.setPlaying(false)
    precondition(engine.player?.defaultRate == 1, "pause must clear temporary speed before a system resume")
    screen.holdState(.ended)
    precondition(engine.player?.rate == 0 && !screen.wantsPlay, "ending a paused hold must not play")
    screen.setPlaybackSpeed(1.5)
    precondition(engine.player?.defaultRate == 1.5 && engine.player?.rate == 0, "paused speed selection must update the system resume rate")
    screen.wantsPlay = true
    screen.holdState(.began)
    screen.locked = true
    screen.holdState(.cancelled)
    precondition(engine.player?.defaultRate == 1.5, "lock cannot strand a temporary hold rate")
    screen.locked = false
    screen.wantsPlay = false
    screen.holdState(.began)
    precondition(engine.player?.defaultRate == 1.5 && engine.player?.rate == 0, "a paused hold must neither accelerate nor play")
    engine.dispose({})
  }
  fileprivate static func checkStartupTimeout(_ item: NativeVideoItem) {
    let screen = NativeVideoScreen(session: "startup-timeout", item: item, options: [:])
    screen.armTimeout(screen.generation)
    let initial = screen.timeout
    precondition(initial?.isValid == true, "opening playback needs a first-frame deadline")
    screen.setPlaying(false)
    precondition(initial?.isValid == false && screen.timeout == nil, "pause must cancel the startup deadline")
    initial?.fire()
    precondition(screen.state.error == nil, "a paused startup must not become a playback failure")
    screen.armTimeout(screen.generation)
    precondition(screen.timeout == nil, "reloading while paused must not arm a deadline")
    screen.setPlaying(true)
    let resumed = screen.timeout
    precondition(resumed?.isValid == true && resumed !== initial, "resume must get a fresh startup deadline")
    resumed?.fire()
    precondition(screen.state.error != nil, "a real playing startup timeout must still fail")
    screen.state.error = nil
    screen.state.firstFrame = true
    screen.armTimeout(screen.generation)
    precondition(screen.timeout == nil, "rendered playback must not restart the first-frame deadline")
    screen.state.firstFrame = false
    screen.switching = true
    screen.armTimeout(screen.generation)
    precondition(screen.timeout == nil, "decoder teardown must not consume the new engine's startup budget")
  }
  fileprivate static func checkBackgroundPlaybackPolicy(_ item: NativeVideoItem) {
    let screen = NativeVideoScreen(session: "background-policy", item: item, options: ["backgroundPlayback": false])
    screen.applyBackgroundPlaybackPolicy(inPip: true)
    precondition(screen.wantsPlay, "active/starting PiP may continue in background")
    screen.applyBackgroundPlaybackPolicy(inPip: false)
    precondition(!screen.wantsPlay, "losing PiP must restore the disabled background policy")
    screen.options["backgroundPlayback"] = true
    screen.wantsPlay = true
    screen.applyBackgroundPlaybackPolicy(inPip: false)
    precondition(screen.wantsPlay, "enabled background audio must keep playing")
    screen.wantsPlay = false
    screen.applyBackgroundPlaybackPolicy(inPip: true)
    precondition(!screen.wantsPlay, "PiP must not resume an explicit pause")
  }
  fileprivate static func checkSubtitlePreference(_ item: NativeVideoItem) {
    let screen = NativeVideoScreen(session: "subtitle-preference", item: item, options: ["subtitlesEnabled": true])
    screen.selectPlaybackTrack(["type": "sub", "id": "no"])
    precondition(screen.options["subtitlesEnabled"] as? Bool == false, "subtitle off must survive engine recreation")
    screen.selectPlaybackTrack(["type": "audio", "id": "1"])
    precondition(screen.options["subtitlesEnabled"] as? Bool == false, "audio selection must preserve subtitle off")
    screen.selectPlaybackTrack(["type": "sub", "id": "1"])
    precondition(screen.options["subtitlesEnabled"] as? Bool == true, "selecting subtitles must enable future engines")
    screen.selectPlaybackTrack(["type": "sub", "id": "no"])
    screen.kernel = "mpv"
    screen.selectPlaybackTrack(["type": "sub", "id": "4", "externalPath": "/captions.vtt"])
    precondition(screen.options["subtitlesEnabled"] as? Bool == true && screen.externalSubtitleURL != nil)
    screen.selectPlaybackTrack(["type": "sub", "id": "no"])
    precondition(screen.options["subtitlesEnabled"] as? Bool == false && screen.externalSubtitleURL == nil)
  }
  fileprivate func importTestSubtitle(_ url: URL, stale: Bool = false) {
    subtitlePickerGeneration = stale ? generation - 1 : generation
    documentPicker(UIDocumentPickerViewController(forOpeningContentTypes: [.data]), didPickDocumentsAt: [url])
  }
  fileprivate var displayedSubtitle: String? { caption.text }
  fileprivate var rememberedSubtitle: URL? { externalSubtitleURL }
  fileprivate var selectedExternalSubtitle: Bool {
    state.tracks.contains { $0["type"] as? String == "sub" && $0["external"] as? Bool == true && $0["selected"] as? Bool == true }
  }
  fileprivate func toggleTestHardware() { hardware.toggle(); switchEngine("mpv") }
  fileprivate func reselectTestSubtitle() {
    engine?.tracks { [weak self] tracks in
      if let track = tracks.first(where: { $0["type"] as? String == "sub" && $0["selected"] as? Bool == true }) {
        self?.selectPlaybackTrack(track)
      }
    }
  }
  fileprivate var displayedStatus: String? { statusLabel.text }
  fileprivate func retryTestMedia() { resolve("retry") }
  fileprivate func pauseTestPlayback() { setPlaying(false) }
  fileprivate func selectTestPlaybackSpeed(_ rate: Double) { setPlaybackSpeed(rate) }
  fileprivate var systemPlaybackRate: Float? { engine?.player?.rate }
  fileprivate func systemTestPlayback(_ playing: Bool) {
    // AVPlayer-layer PiP changes the player directly, bypassing screen controls.
    if playing { engine?.player?.play() } else { engine?.player?.pause() }
  }
  fileprivate func reloadTestWhileOpening() {
    // Trigger before the decoder can report readiness, then again while MPV's
    // asynchronous teardown may still be pending.
    switchEngine(kernel)
    switchEngine(kernel)
  }
  fileprivate static func checkDanmakuTiming(_ item: NativeVideoItem) {
    let screen = NativeVideoScreen(session: "danmaku-check", item: item, options: [:])
    var replies: [([String: Any]?) -> Void] = []
    screen.request = { _, _, reply in replies.append(reply) }
    screen.danmakuEnabled = true
    screen.loadDanmaku()
    screen.loadDanmaku()
    var rows: [[String: Any]] = Array(repeating: ["time": 1.0, "text": "burst"], count: 240)
    rows.append(["time": 2.0, "text": "on time"])
    replies[1](["items": rows])
    replies[0](["items": []])
    precondition(screen.danmaku.count == 241)
    screen.state.playing = true
    func sample(_ position: Double) -> [String] {
      screen.state.position = position
      screen.updateDanmaku()
      return screen.bullets.subviews.compactMap { ($0 as? UILabel)?.text }
    }
    _ = sample(0)
    _ = sample(1)
    precondition(screen.danmakuIndex == 240)
    precondition(sample(2).contains("on time"))
    screen.state.playing = false
    precondition(sample(0.75).isEmpty)
    screen.pendingSeek = 2
    screen.danmakuPosition = nil
    screen.state.playing = true
    precondition(sample(1).isEmpty)
    screen.pendingSeek = nil
    precondition(sample(2) == ["on time"])
  }
}

@main @MainActor final class NativeVideoSmokeApp: UIResponder, UIApplicationDelegate {
  var window: UIWindow?
  private var screen: NativeVideoScreen?
  private var timer: Timer?
  private var caseIndex = 0, phase = 0, swaps = 0
  private var nextRequests = 0
  private var seekEvents: [Double] = []
  private let captionURL = FileManager.default.temporaryDirectory.appendingPathComponent("native-smoke.vtt")
  private var started = Date(), pausedAt = Date(), pausedPosition = 0.0
  private let cases = [("avplayer", "smoke.mp4"), ("avplayer", "smoke.m3u8"), ("mpv", "smoke.mp4"), ("mpv", "smoke.m3u8")]

  func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    checkNativeMPVState()
    do { try checkNativeSubtitles() } catch { check(false, "subtitle fixture: \(error)") }
    let host = UIWindow(frame: UIScreen.main.bounds); host.rootViewController = UIViewController()
    host.makeKeyAndVisible(); window = host
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.next() }
    return true
  }
  private func check(_ condition: Bool, _ message: String) {
    if !condition { print("NATIVE_VIDEO_FAIL \(message)"); fflush(stdout); exit(1) }
  }
  private func interruptAudio(_ type: AVAudioSession.InterruptionType, mayResume: Bool = false) {
    NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(),
      userInfo: [AVAudioSessionInterruptionTypeKey: type.rawValue,
                 AVAudioSessionInterruptionOptionKey: mayResume ? AVAudioSession.InterruptionOptions.shouldResume.rawValue : 0])
  }
  private func next() {
    guard caseIndex < cases.count else { print("NATIVE_VIDEO_ALL_OK"); fflush(stdout); exit(0) }
    let test = cases[caseIndex]; phase = 0; swaps = 0; nextRequests = 0; started = Date()
    do {
      let item = try NativeVideoItem(["url": "http://127.0.0.1:18765/protected/\(test.1)", "headers": ["X-Lume-Test": "ticket=a,b\\c"], "title": "\(test.0) \(test.1)", "identity": "native-check-\(caseIndex)", "position": 2.0])
      if caseIndex == 0 {
        NativeVideoScreen.checkDanmakuTiming(item)
        NativeVideoScreen.checkSubtitlePreference(item)
        NativeVideoScreen.checkStartupTimeout(item)
        NativeVideoScreen.checkPausedPlaybackRate(item)
        NativeVideoScreen.checkBackgroundPlaybackPolicy(item)
      }
      let view = NativeVideoScreen(session: "native-check", item: item, options: ["kernel": test.0, "autoNext": test.1 == "smoke.mp4", "headlessAudio": true])
      // Speech disables scrubbing; stale audiobook actions must also be reset.
      let remote = MPRemoteCommandCenter.shared()
      remote.changePlaybackPositionCommand.isEnabled = false
      remote.changeRepeatModeCommand.isEnabled = true
      remote.stopCommand.isEnabled = true
      view.event = { [weak self] data in
        if data["type"] as? String == "seek", let position = data["position"] as? Double {
          self?.seekEvents.append(position)
        }
      }
      view.request = { [weak self] action, _, completion in
        if action == "previous" { completion(["error": "上一集取址失败"]); return }
        if action == "retry" {
          var refreshed = item.payload
          refreshed["position"] = 5.0
          completion(["media": refreshed])
          return
        }
        guard let self, action == "next" else { completion([:]); return }
        if self.caseIndex == 0 && self.phase == 2 {
          var next = item.payload
          next["identity"] = "second-episode"
          completion(["media": next, "kernel": "mpv", "speed": 1.75])
          return
        }
        self.nextRequests += 1
        self.check(self.nextRequests <= 2, "one next request per end of playback")
        completion(self.nextRequests == 2 ? ["error": "fixture next unavailable"] : [:])
      }
      screen = view
      view.loadViewIfNeeded()
      view.reloadTestWhileOpening()
      window?.rootViewController?.present(view, animated: false) {
        self.timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in MainActor.assumeIsolated { self.tick() } }
      }
    } catch { check(false, error.localizedDescription) }
  }
  private func tick() {
    guard let screen else { return }
    let state = screen.debugState
    check(state["error"] == nil, "\(cases[caseIndex]) \(state)")
    check(Date().timeIntervalSince(started) < 40, "timeout phase=\(phase) state=\(state)")
    let position = (state["position"] as? NSNumber)?.doubleValue ?? 0
    if phase == 0 && state["firstFrame"] as? Bool == true && position > 0.5 {
      check(position >= 1.7, "opening reloads preserve the requested resume position")
      screen.debugAction([:])
      let state = screen.debugState
      let remote = MPRemoteCommandCenter.shared()
      check(remote.changePlaybackPositionCommand.isEnabled, "video re-enables lock-screen seeking after speech")
      check(!remote.changeRepeatModeCommand.isEnabled && !remote.stopCommand.isEnabled, "video disables unsupported inherited remote actions")
      check(state["playHitTest"] as? Bool == true, "UIKit play button hit test")
      check(state["closeHitTest"] as? Bool == true, "UIKit close button hit test")
      check(state["viewAttached"] as? Bool == true, "visible native picture")
      screen.debugAction(["action": "tap", "control": "previous"])
      screen.debugAction([:]) // A decoder update redraws the controls.
      check(screen.debugState["error"] == nil && screen.debugState["wantsPlay"] as? Bool == true,
            "failed episode request keeps the current video playing")
      check(screen.displayedStatus == "上一集取址失败", "resolution error survives a redraw")
      if cases[caseIndex].0 == "mpv" {
        check(state["frameUpright"] as? Bool == true, "decoded red-top/blue-bottom fixture is upright")
      }
      let original = screen.view.frame
      for size in [CGSize(width: 320, height: 568), CGSize(width: 390, height: 844), CGSize(width: 844, height: 390)] {
        screen.view.frame = CGRect(origin: .zero, size: size)
        screen.view.setNeedsLayout(); screen.view.layoutIfNeeded()
        let layout = screen.debugState
        check((layout["closeWidth"] as? CGFloat ?? 0) == 44, "back button stays 44pt at \(size)")
        check(abs((layout["closeLeadingInset"] as? CGFloat ?? 0) - 16) < 1, "back button stays at leading edge at \(size)")
      }
      screen.view.frame = original; screen.view.setNeedsLayout(); screen.view.layoutIfNeeded()
      interruptAudio(.began)
      check(screen.debugState["wantsPlay"] as? Bool == false, "interruption pauses playback controls")
      interruptAudio(.began)
      interruptAudio(.ended, mayResume: true)
      check(screen.debugState["wantsPlay"] as? Bool == true, "permitted end resumes a previously playing video once")
      interruptAudio(.began)
      screen.pauseTestPlayback()
      interruptAudio(.ended, mayResume: true)
      check(screen.debugState["wantsPlay"] as? Bool == false, "explicit pause during interruption cancels auto-resume")
      screen.debugAction(["action": "tap", "control": "play"])
      interruptAudio(.began)
      interruptAudio(.ended)
      check(screen.debugState["wantsPlay"] as? Bool == false, "no resume hint leaves the play button ready")
      if caseIndex == 0 {
        do {
          try "WEBVTT\n\n00:00.000 --> 00:12.000\n&lt;captions&gt;".write(to: captionURL, atomically: true, encoding: .utf8)
          screen.importTestSubtitle(captionURL)
        } catch { check(false, "write subtitle fixture: \(error)") }
      }
      pausedAt = Date(); pausedPosition = position; phase = 1
    } else if phase == 1 && Date().timeIntervalSince(pausedAt) > 0.9 {
      check(abs(position - pausedPosition) < 0.6, "explicit pause must hold the clock")
      check(state["wantsPlay"] as? Bool == false, "pause intent")
      screen.debugAction(["action": "tap", "control": "previous"])
      check(screen.debugState["error"] == nil && screen.debugState["wantsPlay"] as? Bool == false,
            "failed episode request keeps the current video paused")
      if caseIndex == 0 {
        check(screen.displayedSubtitle == "<captions>", "external captions appear while paused")
        do {
          let invalidURL = captionURL.appendingPathExtension("invalid.vtt")
          try "invalid".write(to: invalidURL, atomically: true, encoding: .utf8)
          screen.importTestSubtitle(invalidURL)
        } catch { check(false, "write invalid subtitle fixture: \(error)") }
      }
      if cases[caseIndex].0 == "avplayer" {
        screen.selectTestPlaybackSpeed(1.5)
        check(screen.systemPlaybackRate == 0, "speed selection must keep system playback paused")
        pausedPosition = position; screen.systemTestPlayback(true); phase = 16
      } else { checkPausedSeeks() }
    } else if phase == 16 && state["playing"] as? Bool == true && position > pausedPosition + 0.2 {
      check(state["wantsPlay"] as? Bool == true, "system play updates the screen intent")
      check(screen.systemPlaybackRate == 1.5, "system resume uses the speed selected while paused")
      screen.systemTestPlayback(false)
      pausedAt = Date(); pausedPosition = position; phase = 17
    } else if phase == 17 && Date().timeIntervalSince(pausedAt) > 0.9 {
      check(state["wantsPlay"] as? Bool == false && state["playing"] as? Bool == false,
            "system pause updates the screen and stays paused")
      check(abs(position - pausedPosition) < 0.6, "buffer recovery must not undo system pause")
      screen.selectTestPlaybackSpeed(1)
      checkPausedSeeks()
    } else if phase == 11 && !seekEvents.isEmpty {
      check(seekEvents.count == 1 && seekEvents[0] < 0.26, "only the final paused seek is saved, at the start")
      check(position < 0.26 && state["wantsPlay"] as? Bool == false, "paused seek updates the decoder clock")
      if caseIndex == 0 {
        check(screen.rememberedSubtitle == captionURL, "invalid import preserves the selected file")
        screen.debugAction(["action": "kernel", "kernel": "mpv"])
        phase = 13
        return
      }
      if cases[caseIndex].0 == "mpv" {
        screen.debugAction(["action": "seek", "position": 1.5])
        screen.retryTestMedia()
        phase = 12
        return
      }
      screen.debugAction(["action": "seek", "position": 3.0])
      screen.debugAction(["action": "tap", "control": "play"]); phase = 2
    } else if phase == 13 && screen.selectedExternalSubtitle {
      check(state["wantsPlay"] as? Bool == false, "subtitle restore keeps playback paused")
      screen.reselectTestSubtitle()
      check(screen.rememberedSubtitle == captionURL, "reselecting the external track preserves its file")
      screen.toggleTestHardware(); phase = 14
    } else if phase == 14 && screen.selectedExternalSubtitle {
      screen.debugAction(["action": "kernel", "kernel": "avplayer"]); phase = 15
    } else if phase == 15 && state["firstFrame"] as? Bool == true && screen.displayedSubtitle == "<captions>" {
      check(screen.rememberedSubtitle == captionURL, "subtitle survives kernel and hardware changes")
      screen.debugAction(["action": "seek", "position": 3.0])
      screen.debugAction(["action": "tap", "control": "play"]); phase = 2
    } else if phase == 12 && state["firstFrame"] as? Bool == true && abs(position - 1.5) < 0.26 {
      check(state["wantsPlay"] as? Bool == false, "retry preserves pending seek and pause")
      screen.debugAction(["action": "seek", "position": 3.0])
      screen.debugAction(["action": "tap", "control": "play"]); phase = 2
    } else if phase == 2 && position > 3.3 {
      screen.debugAction(["action": "pip"])
      check(screen.debugState["viewAttached"] as? Bool == true, "PiP preparation keeps inline layer")
      if caseIndex == 0 {
        check(screen.displayedSubtitle == "<captions>", "invalid import preserves existing captions")
        screen.debugAction(["action": "tap", "control": "next"])
        check((screen.debugState["loadElapsedMs"] as? Int ?? Int.max) < 1000, "kernel switch resets the load clock")
        phase = 3; swaps = 1
      } else { checkEnding() }
    } else if phase == 3 && state["firstFrame"] as? Bool == true && state["switching"] as? Bool == false {
      if swaps == 1 {
        check(screen.displayedSubtitle == nil, "new episode clears previous captions")
        check(screen.rememberedSubtitle == nil, "new episode clears the selected subtitle file")
        check(state["kernel"] as? String == "mpv", "switch to MPV")
        check(state["speed"] as? Double == 1.75, "next episode restores the MPV rate")
        screen.debugAction(["action": "kernel", "kernel": "avplayer"]); swaps = 2
      } else {
        check(state["kernel"] as? String == "avplayer", "switch back to AVPlayer")
        do {
          try "WEBVTT\n\n00:00.000 --> 01:00.000\nstale".write(to: captionURL, atomically: true, encoding: .utf8)
          screen.importTestSubtitle(captionURL, stale: true)
        } catch { check(false, "write stale subtitle fixture: \(error)") }
        print("NATIVE_VIDEO_SWITCH_OK"); checkEnding()
      }
    } else if phase == 4 && state["ended"] as? Bool == true {
      if caseIndex == 0 { check(screen.displayedSubtitle == nil, "old picker cannot attach captions to new media") }
      let enabled = cases[caseIndex].1 == "smoke.mp4"
      check(nextRequests == (enabled ? 1 : 0), "next is requested only when enabled")
      check(state["autoNext"] as? Bool == enabled, "catalog end preserves auto-next preference")
      check(state["wantsPlay"] as? Bool == false, "finished video offers replay")
      pausedAt = Date(); phase = 5
    } else if phase == 5 && Date().timeIntervalSince(pausedAt) > 0.8 {
      check(nextRequests == (cases[caseIndex].1 == "smoke.mp4" ? 1 : 0), "end notification is consumed once")
      if cases[caseIndex].1 == "smoke.m3u8" {
        phase = 9; screen.debugAction(["action": "seek", "position": 0.5]); return
      }
      screen.debugAction(["action": "tap", "control": "play"]); phase = 6
    } else if phase == 9 && state["ended"] as? Bool == false && position < 2 {
      pausedAt = Date(); pausedPosition = position; phase = 10
    } else if phase == 10 && Date().timeIntervalSince(pausedAt) > 0.8 {
      check(state["playing"] as? Bool == false && abs(position - pausedPosition) < 0.4, "seeking after EOF keeps the player paused")
      screen.debugAction(["action": "tap", "control": "play"]); phase = 6
    } else if phase == 6 && position > 0.2 && position < 2.5 && state["playing"] as? Bool == true {
      if cases[caseIndex].1 != "smoke.mp4" { complete(); return }
      phase = 7; screen.debugAction(["action": "seek", "position": 11.0])
    } else if phase == 7 && nextRequests == 2 {
      check(state["autoNext"] as? Bool == true, "failed next preserves preference")
      check(state["ended"] as? Bool == true, "failed next preserves the current item for replay")
      screen.debugAction(["action": "tap", "control": "play"]); phase = 8
    } else if phase == 8 && position > 0.2 && position < 2.5 && state["playing"] as? Bool == true {
      print("NATIVE_VIDEO_REPLAY_OK \(cases[caseIndex].0)"); complete()
    }
  }
  private func checkPausedSeeks() {
    seekEvents.removeAll()
    screen?.debugAction(["action": "seek", "position": 5.0])
    screen?.debugAction(["action": "seek", "position": 0.0])
    phase = 11
  }
  private func checkEnding() {
    phase = 4; screen?.debugAction(["action": "seek", "position": 11.0])
  }
  private func complete() {
    timer?.invalidate(); timer = nil
    print("NATIVE_VIDEO_OK \(cases[caseIndex].0) \(cases[caseIndex].1)")
    let transferred = caseIndex == 0
    if transferred {
      UserDefaults.standard.set("fixture-audio", forKey: "lumebox.mediaOwner")
      MPNowPlayingInfoCenter.default().nowPlayingInfo = [MPMediaItemPropertyTitle: "other audio"]
    }
    screen?.finish { [weak self] in
      guard let self else { return }
      if transferred {
        self.check(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] as? String == "other audio", "closing video must preserve the next audio owner's controls")
      } else {
        self.check(UserDefaults.standard.string(forKey: "lumebox.mediaOwner") == nil, "video releases its own lock-screen ownership")
      }
      self.screen = nil; self.caseIndex += 1
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.next() }
    }
  }
}
