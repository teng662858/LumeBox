import Flutter
import UIKit
import AVKit
import MediaPlayer
import UniformTypeIdentifiers

/// Flutter owns source resolution and persistence. One native controller owns
/// the complete visible playback session; no player state is duplicated in Dart.
@MainActor final class NativeVideoPlayerController {
  private var channel: FlutterMethodChannel?
  private var active: NativeVideoScreen?

  func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "lumebox/native_video", binaryMessenger: messenger)
    self.channel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { result(FlutterError(code: "unavailable", message: "原生播放不可用", details: nil)); return }
      let args = call.arguments as? [String: Any] ?? [:]
      switch call.method {
      case "open":
        guard UIApplication.shared.applicationState == .active else {
          result(FlutterError(code: "inactive", message: "请在前台打开播放页", details: nil)); return
        }
        guard self.active == nil, let session = args["session"] as? String,
              let payload = args["media"] as? [String: Any] else {
          result(FlutterError(code: "busy", message: "已有播放会话，或参数不完整", details: nil)); return
        }
        do {
          let item = try NativeVideoItem(payload)
          guard var presenter = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows }).first(where: { $0.isKeyWindow })?.rootViewController else {
            result(FlutterError(code: "presenter", message: "无法打开播放页", details: nil)); return
          }
          while let next = presenter.presentedViewController { presenter = next }
          let screen = NativeVideoScreen(session: session, item: item, options: args["options"] as? [String: Any] ?? [:])
          screen.event = { [weak self] event in self?.channel?.invokeMethod("event", arguments: event) }
          screen.request = { [weak self] action, arguments, completion in
            guard let self else { completion(nil); return }
            self.channel?.invokeMethod("request", arguments: ["session": session, "action": action, "arguments": arguments]) { reply in
              completion(reply as? [String: Any])
            }
          }
          screen.closed = { [weak self, weak screen] in
            if self?.active === screen { self?.active = nil }
          }
          self.active = screen
          screen.modalPresentationStyle = .fullScreen
          presenter.present(screen, animated: false) { result(["session": session]) }
        } catch { result(FlutterError(code: "media", message: error.localizedDescription, details: nil)) }
      case "close":
        guard let screen = self.active, screen.session == args["session"] as? String else { result(nil); return }
        screen.finish { result(nil) }
      #if DEBUG
      case "debug":
        guard let screen = self.active, screen.session == args["session"] as? String else { result(nil); return }
        screen.debugAction(args); result(screen.debugState)
      #endif
      default: result(FlutterMethodNotImplemented)
      }
    }
  }
}

@MainActor private final class NativeVideoScreen: UIViewController, @preconcurrency AVPictureInPictureControllerDelegate,
  @preconcurrency AVPictureInPictureSampleBufferPlaybackDelegate, UIDocumentPickerDelegate {
  let session: String
  private var mediaOwner: String { "native-video:\(session)" }
  private var item: NativeVideoItem
  private var options: [String: Any]
  var event: (([String: Any]) -> Void)?
  var request: ((String, [String: Any], @escaping ([String: Any]?) -> Void) -> Void)?
  var closed: (() -> Void)?
  private var engine: NativeVideoEngine?
  private var pendingEngine: (() -> Void)?
  private var state = NativeVideoState()
  private var kernel: String
  private var generation = 0, requestGeneration = 0
  private var wantsPlay = true, closing = false, switching = false, resolving = false
  private var speed = 1.0, volume = 1.0, fill = false, locked = false, scrubbing = false
  private var hardware = true, autoNext = true, interrupted = false, resumeAfterInterruption = false
  private var landscape = false, chromeVisible = true, readyRecorded = false, frameRecorded = false
  private var pip: AVPictureInPictureController?
  private var pipStarting = false
  private var timeout: Timer?, autoHide: Timer?, sleepTimer: Timer?
  private var notifications: [NSObjectProtocol] = []
  private var remoteTargets: [(MPRemoteCommand, Any)] = []
  private var lastEvent = 0.0, scrubOrigin = 0.0, panVolume = 1.0, panBrightness = 0.5
  private var loadStarted = CACurrentMediaTime()
  private var fatalMessage: String?
  private var subtitleCues: [(Double, Double, String)] = []
  private var subtitleText = ""
  private var danmaku: [(Double, String)] = []
  private var danmakuIndex = 0, danmakuRow = 0
  private var danmakuPosition = 0.0, danmakuEnabled = false, danmakuPaused = false
  private let picture = UIView(), bullets = UIView(), chrome = UIView()
  private let top = UIStackView(), bottom = UIStackView(), progressRow = UIStackView(), buttons = UIStackView()
  private let titleLabel = UILabel(), statusLabel = UILabel(), caption = UILabel(), elapsed = UILabel(), duration = UILabel()
  private let slider = UISlider(), spinner = UIActivityIndicatorView(style: .large)
  private var controls: [String: UIButton] = [:]
  private let lockButton = UIButton(type: .system)

  init(session: String, item: NativeVideoItem, options: [String: Any]) {
    self.session = session; self.item = item; self.options = options
    kernel = options["kernel"] as? String == "mpv" ? "mpv" : "avplayer"
    super.init(nibName: nil, bundle: nil)
    let value = (options["speed"] as? NSNumber)?.doubleValue ?? 1
    speed = value.isFinite ? min(4, max(0.25, value)) : 1
    hardware = options["hardwareDecoding"] as? Bool ?? true
    autoNext = options["autoNext"] as? Bool ?? true
    landscape = options["landscape"] as? Bool ?? false
    fill = options["fill"] as? Bool ?? false
  }
  required init?(coder: NSCoder) { fatalError("Use init(session:item:options:)") }
  override var prefersStatusBarHidden: Bool { true }
  override var prefersHomeIndicatorAutoHidden: Bool { !chromeVisible }
  override var shouldAutorotate: Bool { true }
  override var supportedInterfaceOrientations: UIInterfaceOrientationMask { landscape ? .landscape : .allButUpsideDown }
  override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation { landscape ? .landscapeRight : .portrait }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .black; view.accessibilityIdentifier = "native-video-screen"
    picture.backgroundColor = .black; bullets.isUserInteractionEnabled = false
    for child in [picture, bullets, caption, chrome, spinner, statusLabel, lockButton] {
      child.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(child)
    }
    chrome.addSubview(top); chrome.addSubview(bottom)
    top.axis = .horizontal; top.alignment = .center; top.spacing = 8
    bottom.axis = .vertical; bottom.spacing = 8; bottom.backgroundColor = UIColor.black.withAlphaComponent(0.55)
    top.backgroundColor = UIColor.black.withAlphaComponent(0.45)
    titleLabel.text = item.title; titleLabel.textColor = .white; titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
    titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
    titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let back = button("close", "chevron.backward", "返回") { [weak self] in self?.finish() }
    top.addArrangedSubview(back); top.addArrangedSubview(titleLabel)
    let pipButton = button("pip", "pip.enter", "画中画") { [weak self] in self?.togglePip() }
    top.addArrangedSubview(pipButton)
    let menu = button("settings", "gearshape", "播放设置") { [weak self] in self?.settings() }
    top.addArrangedSubview(menu)
    progressRow.axis = .horizontal; progressRow.spacing = 8; progressRow.alignment = .center
    for label in [elapsed, duration] {
      label.textColor = .white; label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
      label.setContentHuggingPriority(.required, for: .horizontal)
    }
    elapsed.text = "00:00"; duration.text = "00:00"
    slider.minimumValue = 0; slider.maximumValue = 1; slider.accessibilityIdentifier = "native-video-progress"
    slider.addTarget(self, action: #selector(scrubBegin), for: .touchDown)
    slider.addTarget(self, action: #selector(scrubPreview), for: .valueChanged)
    slider.addTarget(self, action: #selector(scrubEnd), for: [.touchUpInside, .touchUpOutside, .touchCancel])
    progressRow.addArrangedSubview(elapsed); progressRow.addArrangedSubview(slider); progressRow.addArrangedSubview(duration)
    buttons.axis = .horizontal; buttons.distribution = .equalSpacing; buttons.alignment = .center
    buttons.addArrangedSubview(button("previous", "backward.end", "上一集") { [weak self] in self?.resolve("previous") })
    buttons.addArrangedSubview(button("back10", "gobackward.10", "后退十秒") { [weak self] in self?.seekBy(-10) })
    buttons.addArrangedSubview(button("play", "pause.fill", "播放或暂停") { [weak self] in self?.togglePlay() })
    buttons.addArrangedSubview(button("forward10", "goforward.10", "快进十秒") { [weak self] in self?.seekBy(10) })
    buttons.addArrangedSubview(button("next", "forward.end", "下一集") { [weak self] in self?.resolve("next") })
    buttons.addArrangedSubview(button("episodes", "list.bullet", "选集与线路") { [weak self] in self?.choices("episodes") })
    buttons.addArrangedSubview(button("kernel", "arrow.triangle.2.circlepath", "切换内核") { [weak self] in self?.chooseKernel() })
    buttons.addArrangedSubview(button("rotate", "rotate.right", "旋转画面") { [weak self] in self?.rotate() })
    bottom.addArrangedSubview(progressRow); bottom.addArrangedSubview(buttons)
    for child in [top, bottom] { child.translatesAutoresizingMaskIntoConstraints = false; child.isLayoutMarginsRelativeArrangement = true; child.directionalLayoutMargins = .init(top: 4, leading: 8, bottom: 4, trailing: 8) }
    statusLabel.textColor = .white; statusLabel.font = .systemFont(ofSize: 14); statusLabel.textAlignment = .center
    statusLabel.numberOfLines = 4; statusLabel.isUserInteractionEnabled = true
    statusLabel.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(retry)))
    spinner.color = .white
    caption.textColor = .white; caption.font = .systemFont(ofSize: 22, weight: .semibold); caption.textAlignment = .center
    caption.numberOfLines = 3; caption.isUserInteractionEnabled = false
    caption.layer.shadowColor = UIColor.black.cgColor; caption.layer.shadowOpacity = 1; caption.layer.shadowRadius = 2
    lockButton.setImage(UIImage(systemName: "lock.open"), for: .normal); lockButton.tintColor = .white
    lockButton.accessibilityLabel = "锁定或解除锁定"; lockButton.accessibilityIdentifier = "native-video-lock"
    lockButton.addAction(UIAction { [weak self] _ in self?.toggleLock() }, for: .touchUpInside)
    NSLayoutConstraint.activate([
      picture.leadingAnchor.constraint(equalTo: view.leadingAnchor), picture.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      picture.topAnchor.constraint(equalTo: view.topAnchor), picture.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      bullets.leadingAnchor.constraint(equalTo: picture.leadingAnchor), bullets.trailingAnchor.constraint(equalTo: picture.trailingAnchor),
      bullets.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor), bullets.bottomAnchor.constraint(equalTo: picture.bottomAnchor),
      chrome.leadingAnchor.constraint(equalTo: view.leadingAnchor), chrome.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      chrome.topAnchor.constraint(equalTo: view.topAnchor), chrome.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      top.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 8), top.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -8),
      top.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 4), top.heightAnchor.constraint(equalToConstant: 48),
      bottom.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 8), bottom.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -8),
      bottom.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
      buttons.heightAnchor.constraint(equalToConstant: 44), progressRow.heightAnchor.constraint(equalToConstant: 32),
      spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor), spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
      statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor), statusLabel.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 12),
      statusLabel.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.85),
      caption.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20), caption.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
      caption.bottomAnchor.constraint(equalTo: bottom.topAnchor, constant: -8),
      lockButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 8), lockButton.centerYAnchor.constraint(equalTo: view.centerYAnchor),
      lockButton.widthAnchor.constraint(equalToConstant: 44), lockButton.heightAnchor.constraint(equalToConstant: 44),
    ])
    // A transparent chrome container lets gestures outside controls reach the picture.
    chrome.isUserInteractionEnabled = true
    for child in [top, bottom] { child.isUserInteractionEnabled = true }
    let tap = UITapGestureRecognizer(target: self, action: #selector(toggleChrome))
    tap.delegate = self; view.addGestureRecognizer(tap)
    let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTap(_:))); doubleTap.numberOfTapsRequired = 2
    doubleTap.delegate = self; view.addGestureRecognizer(doubleTap); tap.require(toFail: doubleTap)
    let pan = UIPanGestureRecognizer(target: self, action: #selector(pan(_:))); pan.delegate = self; view.addGestureRecognizer(pan)
    let hold = UILongPressGestureRecognizer(target: self, action: #selector(hold(_:))); hold.minimumPressDuration = 0.5
    hold.delegate = self; view.addGestureRecognizer(hold)
    installLifecycle(); installRemote()
    switchEngine(kernel, resume: item.position)
    emit("opened"); scheduleHide()
  }

  override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); engine?.view.frame = picture.bounds }
  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    if isBeingDismissed || presentingViewController == nil { finish(dismiss: false) }
  }
  private func button(_ id: String, _ image: String, _ label: String, action: @escaping () -> Void) -> UIButton {
    let button = UIButton(type: .system); button.tintColor = .white
    button.setImage(UIImage(systemName: image, withConfiguration: UIImage.SymbolConfiguration(pointSize: 20)), for: .normal)
    button.accessibilityIdentifier = "native-video-\(id)"; button.accessibilityLabel = label
    // The title absorbs spare width; a back button must never stretch across
    // the navigation bar and move its centered symbol towards the middle.
    button.widthAnchor.constraint(equalToConstant: ["close", "pip", "settings"].contains(id) ? 44 : 36).isActive = true
    button.heightAnchor.constraint(equalToConstant: 44).isActive = true
    button.addAction(UIAction { [weak self] _ in guard let self, !self.closing, !self.locked else { return }; action(); self.scheduleHide() }, for: .touchUpInside)
    controls[id] = button; return button
  }
  private func emit(_ type: String, extra: [String: Any] = [:]) {
    var data = state.dictionary
    data.merge(["session": session, "type": type, "identity": item.identity, "kernel": kernel, "generation": generation]) { _, new in new }
    if ["load-start", "ready", "firstFrame", "error"].contains(type) {
      data["elapsedMs"] = Int(max(0, CACurrentMediaTime() - loadStarted) * 1000)
    }
    data.merge(extra) { _, new in new }; event?(data)
  }

  private func switchEngine(_ selected: String, resume: Double? = nil, emitProgress: Bool = true) {
    guard !closing else { return }
    generation += 1; let revision = generation
    switching = true; timeout?.invalidate(); resetPip()
    if emitProgress { emit("progress") }; readyRecorded = false; frameRecorded = false
    kernel = selected == "mpv" ? "mpv" : "avplayer"
    loadStarted = CACurrentMediaTime()
    let at = resume ?? state.position
    let previous = engine; engine = nil
    previous?.pause(); previous?.view.removeFromSuperview(); fatalMessage = nil
    state = NativeVideoState(); renderState()
    emit("load-start")
    let create = { [weak self] in
      guard let self, !self.closing, self.generation == revision else { return }
      var engineOptions = self.options; engineOptions["hardwareDecoding"] = self.hardware
      let next: NativeVideoEngine = self.kernel == "mpv" ? NativeMPVEngine(options: engineOptions) : NativeAVEngine(options: engineOptions)
      self.engine = next; self.picture.addSubview(next.view); next.view.frame = self.picture.bounds
      next.aspect(self.fill); next.volume(self.volume)
      next.changed = { [weak self, weak next] value in
        guard let self, let next, !self.closing, self.generation == revision, self.engine === next else { return }
        self.state = value
        if let message = self.fatalMessage { self.state.error = message; self.state.buffering = false; self.state.playing = false }
        self.renderState()
      }
      do {
        var payload = self.item.payload; payload["position"] = at
        let media = try NativeVideoItem(payload)
        next.load(media)
        if self.wantsPlay { next.play(rate: self.speed) }
        self.switching = false; self.armTimeout(revision)
        self.emit("settings", extra: ["speed": self.speed, "hardwareDecoding": self.hardware, "autoNext": self.autoNext])
      } catch { self.showError(error.localizedDescription) }
    }
    let start = { [weak self] in
      guard let self else { return }
      if UIApplication.shared.applicationState == .active { create() }
      else { self.pendingEngine = create }
    }
    if let previous { previous.dispose(start) } else { start() }
  }
  private func armTimeout(_ revision: Int) {
    timeout?.invalidate()
    timeout = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated {
      guard let self, !self.closing, self.generation == revision, !self.state.firstFrame, self.state.error == nil else { return }
      self.engine?.pause(); self.showError("30 秒内未输出画面。点此重试，或手动更换内核、线路。")
          }
    }
  }
  private func renderState() {
    guard isViewLoaded, !closing else { return }
    if state.ready && !readyRecorded { readyRecorded = true; emit("ready") }
    if state.firstFrame && !frameRecorded { frameRecorded = true; timeout?.invalidate(); emit("firstFrame") }
    if state.firstFrame && pip == nil { preparePip() }
    if !scrubbing {
      slider.maximumValue = Float(max(1, state.duration)); slider.value = Float(state.position)
      elapsed.text = Self.clock(state.position)
    }
    duration.text = Self.clock(state.duration)
    controls["play"]?.setImage(UIImage(systemName: wantsPlay ? "pause.fill" : "play.fill"), for: .normal)
    if let error = state.error { spinner.stopAnimating(); statusLabel.text = "\(error)\n点此重试"; chromeVisible = true }
    else if resolving { spinner.startAnimating(); statusLabel.text = "正在解析播放地址…" }
    else if switching || state.buffering { spinner.startAnimating(); statusLabel.text = state.ready ? "缓冲中…" : "正在打开 \(kernel == "mpv" ? "MPV" : "系统播放器")…" }
    else { spinner.stopAnimating(); statusLabel.text = nil }
    // Controls are siblings of the native picture; no UIKit platform view can cover them.
    top.isHidden = !chromeVisible || locked; bottom.isHidden = !chromeVisible || locked
    lockButton.isHidden = !chromeVisible && !locked
    let cue = subtitleCues.first { $0.0 <= state.position && state.position < $0.1 }?.2 ?? ""
    if cue != subtitleText { subtitleText = cue; caption.text = cue }
    updateDanmaku()
    if CACurrentMediaTime() - lastEvent >= 1 || state.ended || state.error != nil {
      lastEvent = CACurrentMediaTime(); emit("progress")
      if UserDefaults.standard.string(forKey: "lumebox.mediaOwner") == mediaOwner {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [MPMediaItemPropertyTitle: item.title,
        MPMediaItemPropertyPlaybackDuration: state.duration, MPNowPlayingInfoPropertyElapsedPlaybackTime: state.position,
          MPNowPlayingInfoPropertyPlaybackRate: state.playing ? speed : 0]
      }
    }
    if state.ended && autoNext && !resolving { wantsPlay = false; resolve("next", automatic: true) }
  }
  private func showError(_ message: String) {
    fatalMessage = message
    state.error = message; state.buffering = false; state.playing = false; switching = false; resolving = false
    timeout?.invalidate(); renderState(); emit("error")
  }
  private func togglePlay() {
    guard !switching else { return }
    wantsPlay.toggle()
    if wantsPlay {
      if state.error != nil { resolve("retry"); return }
      if state.ended { engine?.seek(0) {} }
      engine?.play(rate: speed)
    } else { engine?.pause() }
    renderState(); emit("progress")
  }
  private func seekBy(_ delta: Double) { commitSeek(state.position + delta) }
  private func commitSeek(_ seconds: Double) {
    guard !closing, !switching, state.ready else { return }
    let target = max(0, state.duration > 0 ? min(state.duration - 0.05, seconds) : seconds)
    let revision = generation
    engine?.seek(target) { [weak self] in
      guard let self, self.generation == revision else { return }; self.emit("seek")
    }
    danmakuPosition = -100; bullets.subviews.forEach { $0.removeFromSuperview() }
  }
  @objc private func scrubBegin() { guard !locked else { return }; scrubbing = true; autoHide?.invalidate() }
  @objc private func scrubPreview() { elapsed.text = Self.clock(Double(slider.value)) }
  @objc private func scrubEnd() { guard scrubbing else { return }; scrubbing = false; commitSeek(Double(slider.value)); scheduleHide() }
  @objc private func retry() { if state.error != nil { resolve("retry") } }

  private func resolve(_ action: String, arguments: [String: Any] = [:], automatic: Bool = false) {
    guard !closing, let request else { return }
    guard !switching else { toast("正在切换播放内核，请稍候"); return }
    requestGeneration += 1; let revision = requestGeneration
    resolving = true; chromeVisible = true; emit("progress"); renderState()
    request(action, arguments) { [weak self] response in
      guard let self, !self.closing, self.requestGeneration == revision else { return }
      self.resolving = false
      if let error = response?["error"] as? String { self.showError(error); return }
      guard let payload = response?["media"] as? [String: Any] else {
        if action == "retry" { self.switchEngine(self.kernel); return }
        if automatic { self.autoNext = false; self.state.ended = false }
        self.toast(response?["message"] as? String ?? "没有可播放的下一项"); self.renderState(); return
      }
      do {
        // Flush the previous episode with its own identity before replacing it.
        self.emit("progress")
        self.item = try NativeVideoItem(payload); self.titleLabel.text = self.item.title
        self.subtitleCues = []; self.caption.text = nil; self.danmaku = []; self.danmakuIndex = 0
        self.bullets.subviews.forEach { $0.removeFromSuperview() }
        let requested = action == "kernel" ? arguments["id"] as? String : nil
        let selected = response?["kernel"] as? String ?? requested ?? self.kernel
        if selected != self.kernel, let rate = (response?["speed"] as? NSNumber)?.doubleValue,
           rate.isFinite, (0.25...4).contains(rate) {
          self.speed = rate
        }
        self.wantsPlay = automatic || action == "episode" || action == "next" || action == "previous" ? true : self.wantsPlay
        self.switchEngine(selected, resume: self.item.position, emitProgress: false)
        if self.danmakuEnabled { self.loadDanmaku() }
      } catch { self.showError(error.localizedDescription) }
    }
  }
  private func choices(_ action: String) {
    guard let request, !closing else { return }
    let revision = requestGeneration
    request(action, [:]) { [weak self] response in
      guard let self, !self.closing, revision == self.requestGeneration else { return }
      if let error = response?["error"] as? String { self.toast(error); return }
      let rows = response?["items"] as? [[String: Any]] ?? []
      guard !rows.isEmpty else { self.toast(response?["message"] as? String ?? "没有可选项目"); return }
      self.showList(action == "episodes" ? "选集" : action == "lines" ? "线路" : "画质", rows: rows) { [weak self] row in
        self?.resolve(action == "episodes" ? "episode" : action == "lines" ? "line" : "quality", arguments: row)
      }
    }
  }
  private func chooseKernel() {
    guard !switching else { toast("正在切换播放内核，请稍候"); return }
    showList("播放内核", rows: [["title": "系统播放器 · HDR / AirPlay", "id": "avplayer", "selected": kernel == "avplayer"],
      ["title": "MPV · 更多媒体格式", "id": "mpv", "selected": kernel == "mpv"]]) { [weak self] row in
      guard let self, let selected = row["id"] as? String, selected != self.kernel else { return }
      self.emit("progress")
      self.resolve("kernel", arguments: ["id": selected])
    }
  }
  private func settings() {
    let rows: [[String: Any]] = [
      ["title": "倍速 · \(speed)×", "id": "speed"], ["title": "音轨与字幕", "id": "tracks"],
      ["title": "导入字幕", "id": "subtitle"], ["title": "切换线路", "id": "lines"], ["title": "切换画质", "id": "qualities"],
      ["title": "弹幕 · \(danmakuEnabled ? "开" : "关")", "id": "danmaku"],
      ["title": "画面 · \(fill ? "填满" : "原比例")", "id": "aspect"],
      ["title": "自动下一集 · \(autoNext ? "开" : "关")", "id": "autoNext"],
      ["title": "MPV 硬解 · \(hardware ? "开" : "关")", "id": "hardware"],
      ["title": "定时暂停", "id": "sleep"], ["title": "重试当前资源", "id": "retry"]]
      + [["title": "播放信息与复制地址", "id": "info"]]
    showList("播放设置", rows: rows) { [weak self] row in
      guard let self else { return }
      switch row["id"] as? String {
      case "speed": self.showList("播放速度", rows: [0.5, 0.75, 1, 1.25, 1.5, 2, 3, 4].map { ["title": "\($0)×", "value": $0] }) { [weak self] row in
        guard let self, let rate = row["value"] as? Double else { return }; self.speed = rate
        if self.wantsPlay { self.engine?.play(rate: rate) }; self.emit("settings", extra: ["speed": rate])
      }
      case "tracks": self.showTracks()
      case "subtitle": self.present(UIDocumentPickerViewController(forOpeningContentTypes: [.plainText, .data], asCopy: true), animated: true) { [weak self] in
        (self?.presentedViewController as? UIDocumentPickerViewController)?.delegate = self
      }
      case "lines": self.choices("lines")
      case "qualities": self.choices("qualities")
      case "danmaku": self.danmakuEnabled.toggle(); self.bullets.subviews.forEach { $0.removeFromSuperview() }; if self.danmakuEnabled { self.loadDanmaku() }
      case "aspect": self.fill.toggle(); self.engine?.aspect(self.fill)
      case "autoNext": self.autoNext.toggle(); self.emit("settings", extra: ["autoNext": self.autoNext])
      case "hardware": self.hardware.toggle(); if self.kernel == "mpv" { self.switchEngine("mpv") }; self.emit("settings", extra: ["hardwareDecoding": self.hardware])
      case "sleep": self.sleepOptions()
      case "retry": self.resolve("retry")
      case "info":
        let address = self.item.payload["sourceUrl"] as? String ?? self.item.url.absoluteString
        let message = "\(self.kernel == "mpv" ? "MPV" : "系统 AVPlayer") · \(self.state.width)×\(self.state.height)\n\(Self.clock(self.state.position)) / \(Self.clock(self.state.duration))\n缓冲 \(Int(self.state.buffered)) 秒\n\(address)"
        let info = UIAlertController(title: "播放信息", message: message, preferredStyle: .alert)
        info.addAction(UIAlertAction(title: "复制地址", style: .default) { _ in UIPasteboard.general.string = address })
        info.addAction(UIAlertAction(title: "关闭", style: .cancel)); self.present(info, animated: true)
      default: break
      }
    }
  }
  private func showTracks() {
    let revision = generation
    toast("正在读取轨道…")
    engine?.tracks { [weak self] tracks in
      guard let self, !self.closing, revision == self.generation else { return }
      var rows = tracks.map { track -> [String: Any] in
        var row = track; row["title"] = "\((track["type"] as? String) == "audio" ? "音轨" : "字幕") · \(track["label"] ?? "")"; return row
      }
      rows.append(["title": "关闭字幕", "type": "sub", "id": "no"])
      self.showList("音轨与字幕", rows: rows) { [weak self] track in
        self?.engine?.selectTrack(track)
        if (track["type"] as? String) == "sub" { self?.subtitleCues = []; self?.caption.text = nil }
      }
    }
  }
  private func showList(_ title: String, rows: [[String: Any]], selected: @escaping ([String: Any]) -> Void) {
    guard !closing, presentedViewController == nil else { return }
    autoHide?.invalidate()
    let list = NativeVideoChoices(title: title, rows: rows, selected: selected)
    let navigation = UINavigationController(rootViewController: list)
    navigation.overrideUserInterfaceStyle = .dark
    if let sheet = navigation.sheetPresentationController { sheet.detents = [.medium(), .large()]; sheet.prefersGrabberVisible = true }
    present(navigation, animated: true)
  }
  private func sleepOptions() {
    showList("定时暂停", rows: [0, 15, 30, 60, 90].map { ["title": $0 == 0 ? "取消定时" : "\($0) 分钟后暂停", "value": $0] }) { [weak self] row in
      guard let self, let minutes = row["value"] as? Int else { return }
      self.sleepTimer?.invalidate()
      if minutes > 0 {
        self.sleepTimer = Timer.scheduledTimer(withTimeInterval: Double(minutes * 60), repeats: false) { [weak self] _ in
      MainActor.assumeIsolated {
          self?.wantsPlay = false; self?.engine?.pause(); self?.chromeVisible = true; self?.renderState()
              }
    }
      }
    }
  }

  private func preparePip() {
    guard kernel == "avplayer", pip == nil, let engine, state.ready, AVPictureInPictureController.isPictureInPictureSupported() else { return }
    if let av = engine.view as? NativeAVSurface { pip = AVPictureInPictureController(playerLayer: av.videoLayer) }
    else if let layer = engine.sampleLayer {
      pip = AVPictureInPictureController(contentSource: .init(sampleBufferDisplayLayer: layer, playbackDelegate: self))
    }
    pip?.delegate = self; pip?.canStartPictureInPictureAutomaticallyFromInline = true
  }
  private func togglePip() {
    guard kernel == "avplayer" else { toast("MPV 暂不支持画中画，请切换系统播放器"); return }
    preparePip()
    guard let pip else { toast("请等画面就绪后再开启画中画"); return }
    if pip.isPictureInPictureActive { pip.stopPictureInPicture() }
    else if pip.isPictureInPicturePossible { pipStarting = true; pip.startPictureInPicture() }
    else { toast("系统暂未允许画中画，请稍后重试") }
  }
  private func resetPip() {
    pipStarting = false; pip?.delegate = nil; pip?.canStartPictureInPictureAutomaticallyFromInline = false
    pip?.stopPictureInPicture(); pip = nil
  }
  func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
    pipStarting = true; engine?.rendering(true)
  }
  func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
    pipStarting = false; engine?.rendering(true); emit("pip", extra: ["active": true])
  }
  func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
    pipStarting = false; emit("pip", extra: ["active": false])
  }
  func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
    pipStarting = false; toast(error.localizedDescription)
  }
  func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) { completionHandler(!closing) }
  func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
    wantsPlay = playing; if playing { engine?.play(rate: speed) } else { engine?.pause() }
  }
  func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
    CMTimeRange(start: .zero, duration: CMTime(seconds: max(1, state.duration), preferredTimescale: 600))
  }
  func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool { !state.playing }
  func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}
  func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) {
    engine?.seek(max(0, state.position + skipInterval.seconds), completion: completionHandler)
    if engine == nil { completionHandler() }
  }

  private func installLifecycle() {
    UserDefaults.standard.set(mediaOwner, forKey: "lumebox.mediaOwner")
    let audio = AVAudioSession.sharedInstance()
    do { try audio.setCategory(.playback, mode: .moviePlayback); try audio.setActive(true) }
    catch { toast("音频会话未激活：\(error.localizedDescription)") }
    UIApplication.shared.isIdleTimerDisabled = true
    notifications.append(NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, self.kernel == "mpv" else { return }
        self.engine?.rendering(false)
      }
    })
    notifications.append(NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        let pending = self.pendingEngine; self.pendingEngine = nil; pending?()
        self.engine?.rendering(true)
      }
    })
    notifications.append(NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated {
      guard let self else { return }
      let inPip = self.pip?.isPictureInPictureActive == true || self.pipStarting
      if !inPip && self.options["backgroundPlayback"] as? Bool == false {
        self.wantsPlay = false; self.engine?.pause()
      }
      self.emit("progress"); self.engine?.rendering(inPip)
          }
    })
    notifications.append(NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated {
      self?.engine?.rendering(true)
          }
    })
    notifications.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
      MainActor.assumeIsolated {
      guard let self, let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt else { return }
      if type == AVAudioSession.InterruptionType.began.rawValue {
        self.interrupted = true; self.resumeAfterInterruption = self.wantsPlay; self.engine?.pause()
      } else {
        self.interrupted = false
        let flags = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
        if self.resumeAfterInterruption && self.wantsPlay && AVAudioSession.InterruptionOptions(rawValue: flags).contains(.shouldResume) {
          try? audio.setActive(true); self.engine?.play(rate: self.speed)
        }
      }
          }
    })
    notifications.append(NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
      MainActor.assumeIsolated {
      if (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
        self?.wantsPlay = false; self?.engine?.pause()
      }
          }
    })
  }
  private func installRemote() {
    let remote = MPRemoteCommandCenter.shared()
    func bind(_ command: MPRemoteCommand, action: @escaping () -> Void) {
      command.isEnabled = true
      let target = command.addTarget { _ in DispatchQueue.main.async(execute: action); return .success }
      remoteTargets.append((command, target))
    }
    bind(remote.playCommand) { [weak self] in self?.wantsPlay = true; if let self { self.engine?.play(rate: self.speed) } }
    bind(remote.pauseCommand) { [weak self] in self?.wantsPlay = false; self?.engine?.pause() }
    bind(remote.togglePlayPauseCommand) { [weak self] in self?.togglePlay() }
    bind(remote.nextTrackCommand) { [weak self] in self?.resolve("next") }
    bind(remote.previousTrackCommand) { [weak self] in self?.resolve("previous") }
    remote.skipForwardCommand.preferredIntervals = [10]; remote.skipBackwardCommand.preferredIntervals = [10]
    bind(remote.skipForwardCommand) { [weak self] in self?.seekBy(10) }
    bind(remote.skipBackwardCommand) { [weak self] in self?.seekBy(-10) }
    let target = remote.changePlaybackPositionCommand.addTarget { [weak self] event in
      guard let position = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
      DispatchQueue.main.async { self?.commitSeek(position.positionTime) }; return .success
    }
    remoteTargets.append((remote.changePlaybackPositionCommand, target))
  }

  @objc private func toggleChrome() { chromeVisible.toggle(); renderState(); scheduleHide() }
  private func toggleLock() {
    locked.toggle(); chromeVisible = true; lockButton.setImage(UIImage(systemName: locked ? "lock.fill" : "lock.open"), for: .normal)
    renderState(); scheduleHide()
  }
  private func scheduleHide() {
    autoHide?.invalidate()
    autoHide = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated {
      guard let self, self.wantsPlay, !self.scrubbing, self.presentedViewController == nil, self.state.error == nil else { return }
      self.chromeVisible = false; self.renderState(); self.setNeedsUpdateOfHomeIndicatorAutoHidden()
          }
    }
  }
  private func rotate() {
    landscape.toggle(); setNeedsUpdateOfSupportedInterfaceOrientations()
    view.window?.windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: landscape ? .landscape : .portrait)) { [weak self] error in self?.toast(error.localizedDescription) }
  }
  @objc private func doubleTap(_ gesture: UITapGestureRecognizer) {
    guard !locked else { return }
    let x = gesture.location(in: view).x
    if x < view.bounds.width * 0.35 { seekBy(-10) }
    else if x > view.bounds.width * 0.65 { seekBy(10) }
    else { togglePlay() }
  }
  @objc private func pan(_ gesture: UIPanGestureRecognizer) {
    guard !locked else { return }
    let delta = gesture.translation(in: view)
    if gesture.state == .began {
      autoHide?.invalidate(); scrubOrigin = state.position; panVolume = volume
      panBrightness = Double(view.window?.windowScene?.screen.brightness ?? 0.5)
    }
    if abs(delta.x) > abs(delta.y) && state.duration > 0 {
      if gesture.state == .changed { scrubbing = true; elapsed.text = Self.clock(max(0, scrubOrigin + Double(delta.x / view.bounds.width) * 120)); chromeVisible = true; top.isHidden = false; bottom.isHidden = false }
      if gesture.state == .ended { scrubbing = false; commitSeek(scrubOrigin + Double(delta.x / view.bounds.width) * 120) }
    } else if gesture.state == .changed {
      let amount = Double(-delta.y / max(1, view.bounds.height))
      if gesture.location(in: view).x < view.bounds.width / 2 {
        view.window?.windowScene?.screen.brightness = CGFloat(min(1, max(0.05, panBrightness + amount)))
      } else { volume = min(1, max(0, panVolume + amount)); engine?.volume(volume) }
    }
    if gesture.state == .ended || gesture.state == .cancelled { scrubbing = false; scheduleHide() }
  }
  @objc private func hold(_ gesture: UILongPressGestureRecognizer) {
    guard !locked, wantsPlay else { return }
    if gesture.state == .began { engine?.play(rate: max(2, speed)) }
    if [.ended, .cancelled, .failed].contains(gesture.state) { engine?.play(rate: speed) }
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    guard let url = urls.first else { return }
    if kernel == "mpv" { engine?.subtitle(url); return }
    let revision = generation
    Task { @MainActor [weak self] in
      let cues = await Task.detached(priority: .utility) { NativeVideoSubtitles.read(url) }.value
      guard let self, !self.closing, self.generation == revision else { return }
      self.subtitleCues = cues
      if cues.isEmpty { self.toast("系统播放器支持外挂 SRT / VTT；ASS 可使用 MPV") }
    }
  }
  private func loadDanmaku() {
    let identity = item.identity
    request?("danmaku", [:]) { [weak self] reply in
      guard let self, !self.closing, self.item.identity == identity else { return }
      self.danmaku = (reply?["items"] as? [[String: Any]] ?? []).compactMap { row in
        guard let text = row["text"] as? String, !text.isEmpty, let time = row["time"] as? Double, time.isFinite else { return nil }
        return (max(0, time), String(text.prefix(180)))
      }.sorted { $0.0 < $1.0 }
      self.danmakuPosition = -100
      if self.danmaku.isEmpty { self.toast("本集暂未提供弹幕") }
    }
  }
  private func updateDanmaku() {
    guard danmakuEnabled else { return }
    if state.playing == danmakuPaused {
      let layer = bullets.layer
      if state.playing {
        let paused = layer.timeOffset; layer.speed = 1; layer.timeOffset = 0; layer.beginTime = 0
        layer.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) - paused
      } else { let at = layer.convertTime(CACurrentMediaTime(), from: nil); layer.speed = 0; layer.timeOffset = at }
      danmakuPaused = !state.playing
    }
    if abs(state.position - danmakuPosition) > 2 {
      bullets.subviews.forEach { $0.removeFromSuperview() }
      danmakuIndex = danmaku.firstIndex { $0.0 >= state.position } ?? danmaku.count
    }
    danmakuPosition = state.position
    guard state.playing else { return }
    var emitted = 0
    while danmakuIndex < danmaku.count && danmaku[danmakuIndex].0 <= state.position && emitted < 6 {
      let text = danmaku[danmakuIndex].1; danmakuIndex += 1; emitted += 1
      guard bullets.subviews.count < 40 else { continue }
      let label = UILabel(); label.text = text; label.textColor = .white; label.font = .systemFont(ofSize: 19, weight: .medium)
      label.layer.shadowColor = UIColor.black.cgColor; label.layer.shadowOpacity = 1; label.layer.shadowRadius = 1
      label.sizeToFit(); label.frame.origin = CGPoint(x: bullets.bounds.width, y: CGFloat(danmakuRow % 6) * 28 + 56); danmakuRow += 1
      bullets.addSubview(label)
      UIView.animate(withDuration: 8, delay: 0, options: .curveLinear) { label.frame.origin.x = -label.bounds.width } completion: { _ in label.removeFromSuperview() }
    }
  }
  private func toast(_ text: String) {
    statusLabel.text = text
    let revision = generation
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in if self?.generation == revision { self?.renderState() } }
  }
  static func clock(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max) else { return "00:00" }
    let value = Int(seconds)
    return value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, (value / 60) % 60, value % 60) : String(format: "%02d:%02d", value / 60, value % 60)
  }
  func finish(dismiss: Bool = true, completion: @escaping () -> Void = {}) {
    guard !closing else { completion(); return }
    emit("progress"); closing = true; generation += 1; requestGeneration += 1; pendingEngine = nil
    timeout?.invalidate(); autoHide?.invalidate(); sleepTimer?.invalidate(); resetPip()
    notifications.forEach { NotificationCenter.default.removeObserver($0) }; notifications.removeAll()
    for (command, target) in remoteTargets { command.removeTarget(target) }; remoteTargets.removeAll()
    if UserDefaults.standard.string(forKey: "lumebox.mediaOwner") == mediaOwner {
      MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
      UserDefaults.standard.removeObject(forKey: "lumebox.mediaOwner")
    }
    UIApplication.shared.isIdleTimerDisabled = false
    let previous = engine; engine = nil
    let done = { [weak self] in
      guard let self else { completion(); return }
      self.emit("closed"); self.closed?(); self.closed = nil; self.event = nil; self.request = nil
      completion()
    }
    // Dismiss promptly; asynchronous decoder teardown must never freeze navigation.
    if dismiss && presentingViewController != nil { self.dismiss(animated: false) }
    if let previous { previous.dispose(done) } else { done() }
  }
  #if DEBUG
  var debugState: [String: Any] {
    var result = state.dictionary
    result["session"] = session; result["kernel"] = kernel; result["generation"] = generation
    result["closing"] = closing; result["resolving"] = resolving; result["switching"] = switching
    result["nativeControls"] = controls.count; result["wantsPlay"] = wantsPlay
    result["speed"] = speed
    result["pipSupported"] = kernel == "avplayer"
    result["viewAttached"] = engine?.view.window != nil
    if let back = controls["close"] {
      let rect = back.convert(back.bounds, to: view)
      result["closeWidth"] = rect.width
      result["closeLeadingInset"] = rect.minX - view.safeAreaLayoutGuide.layoutFrame.minX
    }
    result["layoutLandscape"] = view.bounds.width > view.bounds.height
    result["loadElapsedMs"] = Int(max(0, CACurrentMediaTime() - loadStarted) * 1000)
    if let mpv = engine as? NativeMPVEngine { result["frameUpright"] = mpv.debugFrameUpright }
    if let window = view.window {
      for id in ["play", "close"] {
        if let button = controls[id] {
          let point = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: window)
          let hit = window.hitTest(point, with: nil)
          result["\(id)HitTest"] = hit === button || hit?.isDescendant(of: button) == true
        }
      }
    }
    return result
  }
  func debugAction(_ args: [String: Any]) {
    chromeVisible = true; renderState(); view.layoutIfNeeded()
    switch args["action"] as? String {
    case "tap": if let id = args["control"] as? String { controls[id]?.sendActions(for: .touchUpInside) }
    case "seek": if let at = args["position"] as? Double { commitSeek(at) }
    case "kernel": if let value = args["kernel"] as? String { switchEngine(value) }
    case "pip": preparePip()
    default: break
    }
  }
  #endif
}

extension NativeVideoScreen: UIGestureRecognizerDelegate {
  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
    var view = touch.view
    while let candidate = view {
      if candidate is UIControl || candidate === statusLabel { return false }
      view = candidate.superview
    }
    return true
  }
}

@MainActor private final class NativeVideoChoices: UITableViewController {
  private let rows: [[String: Any]]
  private let selected: ([String: Any]) -> Void
  init(title: String, rows: [[String: Any]], selected: @escaping ([String: Any]) -> Void) {
    self.rows = rows; self.selected = selected
    super.init(style: .insetGrouped); self.title = title
    navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
  }
  required init?(coder: NSCoder) { fatalError("Use init(title:rows:selected:)") }
  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { rows.count }
  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "choice") ?? UITableViewCell(style: .subtitle, reuseIdentifier: "choice")
    let row = rows[indexPath.row]
    cell.textLabel?.text = row["title"] as? String ?? row["label"] as? String ?? ""
    cell.textLabel?.numberOfLines = 2; cell.detailTextLabel?.text = row["line"] as? String
    cell.accessoryType = row["selected"] as? Bool == true ? .checkmark : .none
    return cell
  }
  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    let row = rows[indexPath.row], action = selected
    dismiss(animated: true) { action(row) }
  }
}

enum NativeVideoSubtitles {
  static func read(_ url: URL) -> [(Double, Double, String)] {
    guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]), (values.fileSize ?? 0) <= 2 * 1024 * 1024,
          let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
    func seconds(_ value: String) -> Double? {
      let components = value.replacingOccurrences(of: ",", with: ".").split(separator: ":").compactMap { Double($0) }
      guard components.count == 2 || components.count == 3 else { return nil }
      return components.reversed().enumerated().reduce(0) { $0 + $1.element * pow(60, Double($1.offset)) }
    }
    let blocks = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n")
    return blocks.compactMap { block in
      let lines = block.components(separatedBy: "\n")
      guard let index = lines.firstIndex(where: { $0.contains("-->") }) else { return nil }
      let times = lines[index].components(separatedBy: "-->").map { $0.trimmingCharacters(in: .whitespaces).components(separatedBy: " ").first ?? "" }
      guard times.count == 2, let start = seconds(times[0]), let end = seconds(times[1]), end > start else { return nil }
      let caption = lines.dropFirst(index + 1).joined(separator: "\n").replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
      return (start, end, caption)
    }.sorted { $0.0 < $1.0 }
  }
}
