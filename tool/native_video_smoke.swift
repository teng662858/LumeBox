// Appended to the production controller file for a standalone UIKit simulator
// host. Exercises private production code, not a second player implementation.
@main @MainActor final class NativeVideoSmokeApp: UIResponder, UIApplicationDelegate {
  var window: UIWindow?
  private var screen: NativeVideoScreen?
  private var timer: Timer?
  private var caseIndex = 0, phase = 0, swaps = 0
  private var started = Date(), pausedAt = Date(), pausedPosition = 0.0
  private let cases = [("avplayer", "smoke.mp4"), ("avplayer", "smoke.m3u8"), ("mpv", "smoke.mp4"), ("mpv", "smoke.m3u8")]

  func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    let host = UIWindow(frame: UIScreen.main.bounds); host.rootViewController = UIViewController()
    host.makeKeyAndVisible(); window = host
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.next() }
    return true
  }
  private func check(_ condition: Bool, _ message: String) {
    if !condition { print("NATIVE_VIDEO_FAIL \(message)"); fflush(stdout); exit(1) }
  }
  private func next() {
    guard caseIndex < cases.count else { print("NATIVE_VIDEO_ALL_OK"); fflush(stdout); exit(0) }
    let test = cases[caseIndex]; phase = 0; swaps = 0; started = Date()
    do {
      let item = try NativeVideoItem(["url": "http://127.0.0.1:18765/protected/\(test.1)", "headers": ["X-Lume-Test": "ticket=a,b\\c"], "title": "\(test.0) \(test.1)", "identity": "native-check-\(caseIndex)"])
      let view = NativeVideoScreen(session: "native-check", item: item, options: ["kernel": test.0, "autoNext": false, "headlessAudio": true])
      view.request = { _, _, completion in completion([:]) }
      screen = view
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
      screen.debugAction([:])
      let state = screen.debugState
      check(state["playHitTest"] as? Bool == true, "UIKit play button hit test")
      check(state["closeHitTest"] as? Bool == true, "UIKit close button hit test")
      check(state["viewAttached"] as? Bool == true, "visible native picture")
      screen.debugAction(["action": "tap", "control": "play"])
      pausedAt = Date(); pausedPosition = position; phase = 1
    } else if phase == 1 && Date().timeIntervalSince(pausedAt) > 0.9 {
      check(abs(position - pausedPosition) < 0.6, "explicit pause must hold the clock")
      check(state["wantsPlay"] as? Bool == false, "pause intent")
      screen.debugAction(["action": "seek", "position": 3.0])
      screen.debugAction(["action": "tap", "control": "play"]); phase = 2
    } else if phase == 2 && position > 3.3 {
      screen.debugAction(["action": "pip"])
      check(screen.debugState["viewAttached"] as? Bool == true, "PiP preparation keeps inline layer")
      if caseIndex == 0 {
        screen.debugAction(["action": "kernel", "kernel": "mpv"]); phase = 3; swaps = 1
      } else { complete() }
    } else if phase == 3 && state["firstFrame"] as? Bool == true && state["switching"] as? Bool == false {
      if swaps == 1 {
        check(state["kernel"] as? String == "mpv", "switch to MPV")
        screen.debugAction(["action": "kernel", "kernel": "avplayer"]); swaps = 2
      } else {
        check(state["kernel"] as? String == "avplayer", "switch back to AVPlayer")
        print("NATIVE_VIDEO_SWITCH_OK"); complete()
      }
    }
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
