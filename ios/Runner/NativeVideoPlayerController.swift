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
  private var pendingEngineResume: Double?
  private var state = NativeVideoState()
  private var kernel: String
  private var generation = 0, requestGeneration = 0
  private var pendingSeek: Double?
  private var seekRevision = 0
  private var wantsPlay = true, closing = false, switching = false, resolving = false
  private var playIntentRevision = 0
  private var handledEnd = false
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
  private var toastMessage: String?
  private var toastTimer: Timer?
  private var subtitles = NativeVideoSubtitles()
  private var externalSubtitleURL: URL?
  private var subtitleRevision = 0
  private var subtitlePickerGeneration: Int?
  private var danmaku: [(Double, String)] = []
  private var danmakuIndex = 0, danmakuRow = 0
  private var danmakuPosition: Double?
  private var danmakuRevision = 0, danmakuEnabled = false, danmakuPaused = false
  private let picture = UIView(), bullets = UIView(), chrome = UIView()
  private let top = UIStackView(), bottom = UIStackView(), progressRow = UIStackView(), buttons = UIStackView()
  private let transport = UIStackView(), playbackOptions = UIStackView(), controlSpacer = UIView()
  private let topMaterial = UIVisualEffectView(), bottomMaterial = UIVisualEffectView()
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
    for surface in [topMaterial, bottomMaterial] {
      surface.translatesAutoresizingMaskIntoConstraints = false
      surface.isUserInteractionEnabled = false
      surface.overrideUserInterfaceStyle = .dark
      surface.layer.cornerRadius = 22; surface.layer.cornerCurve = .continuous
      surface.clipsToBounds = true
      #if compiler(>=6.2)
      if #available(iOS 26.0, *) { surface.cornerConfiguration = .fixed(22) }
      #endif
      chrome.addSubview(surface)
    }
    updateControlMaterials()
    chrome.addSubview(top); chrome.addSubview(bottom)
    top.axis = .horizontal; top.alignment = .center; top.spacing = 8
    bottom.axis = .vertical; bottom.spacing = 4
    titleLabel.text = item.title; titleLabel.textColor = .white; titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
    titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
    titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let back = button("close", "chevron.backward", "返回") { [weak self] in self?.finish() }
    top.addArrangedSubview(back); top.addArrangedSubview(titleLabel)
    let pipButton = button("pip", "pip.enter", "画中画") { [weak self] in self?.togglePip() }
    top.addArrangedSubview(pipButton)
    top.addArrangedSubview(textButton("kernel", kernel == "mpv" ? "MPV" : "系统", "切换内核") { [weak self] in self?.chooseKernel() })
    let menu = button("settings", "ellipsis", "播放设置") { [weak self] in self?.settings() }
    top.addArrangedSubview(menu)
    progressRow.axis = .horizontal; progressRow.spacing = 8; progressRow.alignment = .center
    for label in [elapsed, duration] {
      label.textColor = .white; label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
      label.setContentHuggingPriority(.required, for: .horizontal)
    }
    elapsed.text = "00:00"; duration.text = "00:00"
    // Keep the former compact progress handle instead of iOS 26's wide capsule.
    let thumb = UIGraphicsImageRenderer(size: CGSize(width: 12, height: 12)).image { _ in
      UIColor.white.setFill(); UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: 12, height: 12)).fill()
    }
    slider.setThumbImage(thumb, for: .normal); slider.setThumbImage(thumb, for: .highlighted)
    slider.minimumTrackTintColor = .white; slider.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.3)
    slider.minimumValue = 0; slider.maximumValue = 1; slider.accessibilityIdentifier = "native-video-progress"
    slider.addTarget(self, action: #selector(scrubBegin), for: .touchDown)
    slider.addTarget(self, action: #selector(scrubPreview), for: .valueChanged)
    slider.addTarget(self, action: #selector(scrubEnd), for: [.touchUpInside, .touchUpOutside, .touchCancel])
    progressRow.addArrangedSubview(elapsed); progressRow.addArrangedSubview(slider); progressRow.addArrangedSubview(duration)
    buttons.axis = .horizontal; buttons.alignment = .center; buttons.spacing = 8
    for group in [transport, playbackOptions] {
      group.axis = .horizontal; group.alignment = .center; group.spacing = 0
    }
    transport.accessibilityIdentifier = "native-video-transport"
    playbackOptions.accessibilityIdentifier = "native-video-options"
    transport.addArrangedSubview(button("play", "pause.fill", "播放或暂停") { [weak self] in self?.togglePlay() })
    transport.addArrangedSubview(button("next", "forward.end.fill", "下一集") { [weak self] in self?.resolve("next") })
    transport.addArrangedSubview(textButton("skip", "跳转", "快进、后退与上一集") { [weak self] in self?.skipOptions() })
    playbackOptions.addArrangedSubview(textButton("danmaku", "弹幕", "弹幕开关") { [weak self] in self?.toggleDanmaku() })
    playbackOptions.addArrangedSubview(textButton("speed", "1×", "播放速度") { [weak self] in self?.chooseSpeed() })
    playbackOptions.addArrangedSubview(textButton("episodes", "选集", "选集与线路") { [weak self] in self?.episodeOptions() })
    playbackOptions.addArrangedSubview(button("rotate", "rotate.right", "旋转画面") { [weak self] in self?.rotate() })
    buttons.addArrangedSubview(transport); buttons.addArrangedSubview(controlSpacer); buttons.addArrangedSubview(playbackOptions)
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
      progressRow.heightAnchor.constraint(equalToConstant: 28),
      spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor), spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
      statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor), statusLabel.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 12),
      statusLabel.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.85),
      caption.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20), caption.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
      caption.bottomAnchor.constraint(equalTo: bottom.topAnchor, constant: -8),
      lockButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 8), lockButton.centerYAnchor.constraint(equalTo: view.centerYAnchor),
      lockButton.widthAnchor.constraint(equalToConstant: 44), lockButton.heightAnchor.constraint(equalToConstant: 44),
    ])
    for (surface, stack) in [(topMaterial, top), (bottomMaterial, bottom)] {
      NSLayoutConstraint.activate([
        surface.leadingAnchor.constraint(equalTo: stack.leadingAnchor), surface.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
        surface.topAnchor.constraint(equalTo: stack.topAnchor), surface.bottomAnchor.constraint(equalTo: stack.bottomAnchor),
      ])
    }
    notifications.append(NotificationCenter.default.addObserver(forName: UIAccessibility.reduceTransparencyStatusDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.updateControlMaterials() }
    })
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
  override func viewWillLayoutSubviews() {
    super.viewWillLayoutSubviews()
    // Keep all hit targets at 44pt. Small portrait windows get two rows;
    // landscape preserves the original left transport / right options layout.
    let compact = view.safeAreaLayoutGuide.layoutFrame.width - 32 < 7 * 44 + 8
    let axis: NSLayoutConstraint.Axis = compact ? .vertical : .horizontal
    if buttons.axis != axis {
      buttons.axis = axis; buttons.alignment = compact ? .trailing : .center
      controlSpacer.isHidden = compact
    }
  }

  private func updateControlMaterials() {
    for surface in [topMaterial, bottomMaterial] {
      #if compiler(>=6.2)
      if #available(iOS 26.0, *), !UIAccessibility.isReduceTransparencyEnabled {
        let glass = UIGlassEffect(style: .clear)
        glass.tintColor = UIColor.black.withAlphaComponent(0.12)
        surface.effect = glass
        continue
      }
      #endif
      surface.effect = UIBlurEffect(style: UIAccessibility.isReduceTransparencyEnabled ? .systemThickMaterialDark : .systemThinMaterialDark)
    }
  }

  private func textButton(_ id: String, _ title: String, _ label: String, action: @escaping () -> Void) -> UIButton {
    let control = button(id, "", label, action: action)
    control.setImage(nil, for: .normal); control.setTitle(title, for: .normal)
    control.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
    return control
  }
  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    if isBeingDismissed || presentingViewController == nil { finish(dismiss: false) }
  }
  private func button(_ id: String, _ image: String, _ label: String, action: @escaping () -> Void) -> UIButton {
    let button = UIButton(type: .system); button.tintColor = .white
    if !image.isEmpty { button.setImage(UIImage(systemName: image, withConfiguration: UIImage.SymbolConfiguration(pointSize: 20)), for: .normal) }
    button.accessibilityIdentifier = "native-video-\(id)"; button.accessibilityLabel = label
    // The title absorbs spare width; a back button must never stretch across
    // the navigation bar and move its centered symbol towards the middle.
    button.widthAnchor.constraint(equalToConstant: 44).isActive = true
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
    if kernel == "mpv" { subtitles = NativeVideoSubtitles() }
    loadStarted = CACurrentMediaTime()
    let at = resume ?? pendingSeek ?? engine?.resumePosition ?? pendingEngineResume ?? state.position
    pendingEngineResume = at
    pendingSeek = nil
    let previous = engine; engine = nil
    previous?.pause(); previous?.view.removeFromSuperview(); fatalMessage = nil; toastMessage = nil
    handledEnd = false; state = NativeVideoState(); renderState()
    emit("load-start")
    let create = { [weak self] in
      guard let self, !self.closing, self.generation == revision else { return }
      var engineOptions = self.options; engineOptions["hardwareDecoding"] = self.hardware
      if !self.subtitles.isEmpty { engineOptions["subtitlesEnabled"] = false }
      let next: NativeVideoEngine = self.kernel == "mpv" ? NativeMPVEngine(options: engineOptions) : NativeAVEngine(options: engineOptions)
      self.engine = next; self.picture.addSubview(next.view); next.view.frame = self.picture.bounds
      next.aspect(self.fill); next.volume(self.volume)
      next.changed = { [weak self, weak next] value in
        guard let self, let next, !self.closing, self.generation == revision, self.engine === next else { return }
        self.state = value
        if let message = self.fatalMessage { self.state.error = message; self.state.buffering = false; self.state.playing = false }
        self.renderState()
      }
      (next as? NativeAVEngine)?.playbackIntentChanged = { [weak self, weak next] playing in
        guard let self, let next, !self.closing, self.generation == revision, self.engine === next else { return }
        self.playIntentRevision += 1
        self.resumeAfterInterruption = false
        self.wantsPlay = playing
        if !playing { next.setRate(self.speed) }
        if playing { self.interrupted = false }
        self.armTimeout(self.generation)
        self.renderState(); self.emit("progress")
      }
      do {
        var payload = self.item.payload; payload["position"] = at
        let media = try NativeVideoItem(payload)
        next.load(media)
        next.setRate(self.speed)
        self.pendingEngineResume = nil
        if let url = self.externalSubtitleURL { self.loadExternalSubtitle(url) }
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
    timeout?.invalidate(); timeout = nil
    // A deliberately paused decoder need not produce a first frame. Resume
    // receives a fresh budget, including when PiP changes AVPlayer directly.
    guard !closing, !switching, wantsPlay, !state.firstFrame, state.error == nil else { return }
    timeout = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] timer in
      MainActor.assumeIsolated {
      guard let self, self.timeout === timer, !self.closing, self.wantsPlay,
            self.generation == revision, !self.state.firstFrame, self.state.error == nil else { return }
      self.engine?.pause(); self.showError("30 秒内未输出画面。点此重试，或手动更换内核、线路。")
          }
    }
  }
  private func renderState() {
    guard isViewLoaded, !closing else { return }
    if state.ready && !readyRecorded { readyRecorded = true; emit("ready") }
    if state.firstFrame && !frameRecorded { frameRecorded = true; timeout?.invalidate(); emit("firstFrame") }
    if state.firstFrame && pip == nil { preparePip() }
    let reachedEnd = state.ended && !handledEnd
    if reachedEnd { wantsPlay = false }
    handledEnd = state.ended
    if !scrubbing {
      slider.maximumValue = Float(max(1, state.duration)); slider.value = Float(state.position)
      elapsed.text = Self.clock(state.position)
    }
    duration.text = Self.clock(state.duration)
    controls["play"]?.setImage(UIImage(systemName: wantsPlay ? "pause.fill" : "play.fill"), for: .normal)
    if let error = state.error { spinner.stopAnimating(); statusLabel.text = toastMessage ?? "\(error)\n点此重试"; chromeVisible = true }
    else if resolving { spinner.startAnimating(); statusLabel.text = "正在解析播放地址…" }
    else if switching || state.buffering { spinner.startAnimating(); statusLabel.text = toastMessage ?? (state.ready ? "缓冲中…" : "正在打开 \(kernel == "mpv" ? "MPV" : "系统播放器")…") }
    else { spinner.stopAnimating(); statusLabel.text = toastMessage }
    // Controls are siblings of the native picture; no UIKit platform view can cover them.
    top.isHidden = !chromeVisible || locked; bottom.isHidden = !chromeVisible || locked
    topMaterial.isHidden = top.isHidden; bottomMaterial.isHidden = bottom.isHidden
    controls["speed"]?.setTitle(String(format: "%g×", speed), for: .normal)
    controls["kernel"]?.setTitle(kernel == "mpv" ? "MPV" : "系统", for: .normal)
    controls["danmaku"]?.accessibilityValue = danmakuEnabled ? "开" : "关"
    lockButton.isHidden = !chromeVisible && !locked
    let cue = subtitles.caption(at: state.position)
    if cue != caption.text { caption.text = cue }
    updateDanmaku()
    if CACurrentMediaTime() - lastEvent >= 1 || reachedEnd || state.error != nil {
      lastEvent = CACurrentMediaTime(); emit("progress")
      if UserDefaults.standard.string(forKey: "lumebox.mediaOwner") == mediaOwner {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [MPMediaItemPropertyTitle: item.title,
        MPMediaItemPropertyPlaybackDuration: state.duration, MPNowPlayingInfoPropertyElapsedPlaybackTime: state.position,
          MPNowPlayingInfoPropertyPlaybackRate: state.playing ? speed : 0]
      }
    }
    if reachedEnd && autoNext && !resolving && !switching && state.error == nil {
      resolve("next", automatic: true)
    }
  }
  private func showError(_ message: String) {
    fatalMessage = message
    state.error = message; state.buffering = false; state.playing = false; switching = false; resolving = false
    timeout?.invalidate(); renderState(); emit("error")
  }
  private func togglePlay() {
    guard !switching else { return }
    setPlaying(!wantsPlay)
  }
  private func setPlaying(_ playing: Bool) {
    guard !closing else { return }
    playIntentRevision += 1
    resumeAfterInterruption = false
    if playing && !wantsPlay {
      // An interruption need not deliver an end notification. An explicit
      // play can resume once the system lets us reactivate the session.
      guard activateAudio() else { return }
      interrupted = false
    }
    wantsPlay = playing
    armTimeout(generation)
    if switching { return }
    if wantsPlay {
      if state.error != nil { resolve("retry"); return }
      if state.ended { commitSeek(0) }
      engine?.play(rate: speed)
    } else { engine?.pause(); engine?.setRate(speed) }
    renderState(); emit("progress")
  }
  private func seekBy(_ delta: Double) { commitSeek((pendingSeek ?? state.position) + delta) }
  private func commitSeek(_ seconds: Double, completion: @escaping () -> Void = {}) {
    guard !closing, !switching, state.ready, let engine else { completion(); return }
    let target = max(0, state.duration > 0 ? min(state.duration - 0.05, seconds) : seconds)
    let revision = generation
    seekRevision += 1
    let seek = seekRevision
    pendingSeek = target
    danmakuPosition = nil; bullets.subviews.forEach { $0.removeFromSuperview() }
    engine.seek(target) { [weak self] finished in
      defer { completion() }
      guard let self, self.generation == revision, self.seekRevision == seek else { return }
      self.pendingSeek = nil
      self.updateDanmaku()
      if finished { self.emit("seek") }
    }
  }
  @objc private func scrubBegin() { guard !locked else { return }; scrubbing = true; autoHide?.invalidate() }
  @objc private func scrubPreview() { elapsed.text = Self.clock(Double(slider.value)) }
  @objc private func scrubEnd() { guard scrubbing else { return }; scrubbing = false; commitSeek(Double(slider.value)); scheduleHide() }
  @objc private func retry() { if state.error != nil { resolve("retry") } }

  private func resolve(_ action: String, arguments: [String: Any] = [:], automatic: Bool = false) {
    guard !closing, let request else { return }
    guard !switching else { toast("正在切换播放内核，请稍候"); return }
    requestGeneration += 1; let revision = requestGeneration
    let intentAtRequest = playIntentRevision
    let startsEpisode = !interrupted && (automatic || ["episode", "next", "previous"].contains(action))
    let seekAtRequest = seekRevision, wasSeeking = pendingSeek != nil
    toastMessage = nil
    resolving = true; chromeVisible = true; emit("progress"); renderState()
    request(action, arguments) { [weak self] response in
      guard let self, !self.closing, self.requestGeneration == revision else { return }
      self.resolving = false
      if let error = response?["error"] as? String {
        self.showResolutionError(error)
        return
      }
      guard let payload = response?["media"] as? [String: Any] else {
        if action == "retry" { self.switchEngine(self.kernel); return }
        self.toast(response?["message"] as? String ?? "没有可播放的下一项"); return
      }
      do {
        // Flush the previous episode with its own identity before replacing it.
        self.emit("progress")
        let next = try NativeVideoItem(payload)
        if self.item.identity != next.identity { self.clearExternalSubtitle() }
        self.item = next; self.titleLabel.text = next.title
        self.danmaku = []; self.danmakuIndex = 0
        self.bullets.subviews.forEach { $0.removeFromSuperview() }
        let requested = action == "kernel" ? arguments["id"] as? String : nil
        let selected = response?["kernel"] as? String ?? requested ?? self.kernel
        if selected != self.kernel, let rate = (response?["speed"] as? NSNumber)?.doubleValue,
           rate.isFinite, (0.25...4).contains(rate) {
          self.speed = rate
        }
        if startsEpisode && intentAtRequest == self.playIntentRevision {
          self.wantsPlay = self.wantsPlay || self.activateAudio()
        }
        let carriesPosition = ["retry", "quality", "line", "kernel"].contains(action)
        var resume = next.position
        if carriesPosition && (wasSeeking || self.seekRevision != seekAtRequest || self.pendingSeek != nil) {
          resume = self.pendingSeek ?? self.state.position
          self.emit("seek", extra: ["position": resume])
        }
        self.switchEngine(selected, resume: resume, emitProgress: false)
        if self.danmakuEnabled { self.loadDanmaku() }
      } catch { self.showResolutionError(error.localizedDescription) }
    }
  }
  private func showResolutionError(_ message: String) {
    // Until replacement media is accepted, the current engine still owns playback.
    if state.error != nil { showError(message) } else { toast(message) }
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
  private func chooseSpeed() {
    showList("播放速度", rows: [0.5, 0.75, 1, 1.25, 1.5, 2, 3, 4].map {
      ["title": "\($0)×", "value": $0, "selected": $0 == speed]
    }) { [weak self] row in
      guard let rate = row["value"] as? Double else { return }
      self?.setPlaybackSpeed(rate)
    }
  }
  private func toggleDanmaku() {
    danmakuEnabled.toggle(); bullets.subviews.forEach { $0.removeFromSuperview() }; danmaku = []
    if danmakuEnabled { loadDanmaku() }
    renderState()
  }
  private func skipOptions() {
    showList("播放跳转", rows: [["title": "后退十秒", "id": "back10"],
      ["title": "快进十秒", "id": "forward10"], ["title": "上一集", "id": "previous"]]) { [weak self] row in
      switch row["id"] as? String {
      case "back10": self?.seekBy(-10)
      case "forward10": self?.seekBy(10)
      case "previous": self?.resolve("previous")
      default: break
      }
    }
  }
  private func episodeOptions() {
    showList("选集与线路", rows: [["title": "选集", "id": "episodes"], ["title": "切换线路", "id": "lines"]]) { [weak self] row in
      if let action = row["id"] as? String { self?.choices(action) }
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
      case "speed": self.chooseSpeed()
      case "tracks": self.showTracks()
      case "subtitle":
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.plainText, .data], asCopy: true)
        self.subtitlePickerGeneration = self.generation
        picker.delegate = self
        self.present(picker, animated: true)
      case "lines": self.choices("lines")
      case "qualities": self.choices("qualities")
      case "danmaku": self.toggleDanmaku()
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
        guard let self, !self.closing, self.generation == revision else { return }
        self.selectPlaybackTrack(track)
      }
    }
  }
  private func selectPlaybackTrack(_ track: [String: Any]) {
    engine?.selectTrack(track)
    guard (track["type"] as? String) == "sub" else { return }
    // Recreated engines must retain an explicit subtitle-off selection.
    options["subtitlesEnabled"] = (track["id"] as? String) != "no"
    clearExternalSubtitle()
    if kernel == "mpv", let path = track["externalPath"] as? String, path.hasPrefix("/") {
      externalSubtitleURL = URL(fileURLWithPath: path)
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
          self?.chromeVisible = true; self?.setPlaying(false)
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
    guard !closing, pip === pictureInPictureController else { return }
    pipStarting = false
    if UIApplication.shared.applicationState == .background { applyBackgroundPlaybackPolicy(inPip: false) }
    emit("pip", extra: ["active": false])
  }
  func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
    guard !closing, pip === pictureInPictureController else { return }
    pipStarting = false
    if UIApplication.shared.applicationState == .background { applyBackgroundPlaybackPolicy(inPip: false) }
    toast(error.localizedDescription)
  }
  func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) { completionHandler(!closing) }
  func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
    setPlaying(playing)
  }
  func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
    CMTimeRange(start: .zero, duration: CMTime(seconds: max(1, state.duration), preferredTimescale: 600))
  }
  func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool { !state.playing }
  func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}
  func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) {
    commitSeek((pendingSeek ?? state.position) + skipInterval.seconds, completion: completionHandler)
  }

  private func applyBackgroundPlaybackPolicy(inPip: Bool) {
    guard !closing else { return }
    if !inPip && options["backgroundPlayback"] as? Bool == false {
      setPlaying(false)
    } else { emit("progress") }
    engine?.rendering(inPip)
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
        self.applyBackgroundPlaybackPolicy(inPip: inPip)
      }
    })
    notifications.append(NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated {
      self?.engine?.rendering(true)
          }
    })
    notifications.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
      MainActor.assumeIsolated {
        guard let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt else { return }
        let flags = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
        self?.handleInterruption(type, options: AVAudioSession.InterruptionOptions(rawValue: flags))
      }
    })
    notifications.append(NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
      MainActor.assumeIsolated {
        if (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
          self?.setPlaying(false)
        }
      }
    })
  }
  private func activateAudio() -> Bool {
    do { try AVAudioSession.sharedInstance().setActive(true); return true }
    catch { toast("音频会话未激活：\(error.localizedDescription)"); return false }
  }
  private func handleInterruption(_ type: UInt, options: AVAudioSession.InterruptionOptions) {
    guard !closing else { return }
    if type == AVAudioSession.InterruptionType.began.rawValue {
      guard !interrupted else { return }
      let wasPlaying = wantsPlay
      interrupted = true
      setPlaying(false)
      resumeAfterInterruption = wasPlaying
    } else if type == AVAudioSession.InterruptionType.ended.rawValue && interrupted {
      let shouldResume = resumeAfterInterruption && options.contains(.shouldResume)
      resumeAfterInterruption = false
      if shouldResume { setPlaying(true) } else { interrupted = false }
    }
  }
  private func installRemote() {
    let remote = MPRemoteCommandCenter.shared()
    let owner = mediaOwner
    // TTS and audiobooks share the same system command center. Reclaim both
    // callbacks and enabled flags when the native video session takes over.
    [remote.playCommand, remote.pauseCommand, remote.stopCommand, remote.togglePlayPauseCommand,
     remote.nextTrackCommand, remote.previousTrackCommand, remote.skipForwardCommand, remote.skipBackwardCommand,
     remote.changePlaybackPositionCommand, remote.changePlaybackRateCommand,
     remote.seekForwardCommand, remote.seekBackwardCommand, remote.changeRepeatModeCommand, remote.changeShuffleModeCommand]
      .forEach { $0.removeTarget(nil); $0.isEnabled = false }
    func bind(_ command: MPRemoteCommand, action: @escaping () -> Void) {
      command.isEnabled = true
      let target = command.addTarget { [weak self] _ in
        guard UserDefaults.standard.string(forKey: "lumebox.mediaOwner") == owner else { return .commandFailed }
        DispatchQueue.main.async {
          guard let self, !self.closing, UserDefaults.standard.string(forKey: "lumebox.mediaOwner") == owner else { return }
          action()
        }
        return .success
      }
      remoteTargets.append((command, target))
    }
    bind(remote.playCommand) { [weak self] in self?.setPlaying(true) }
    bind(remote.pauseCommand) { [weak self] in self?.setPlaying(false) }
    bind(remote.togglePlayPauseCommand) { [weak self] in self?.togglePlay() }
    bind(remote.nextTrackCommand) { [weak self] in self?.resolve("next") }
    bind(remote.previousTrackCommand) { [weak self] in self?.resolve("previous") }
    remote.skipForwardCommand.preferredIntervals = [10]; remote.skipBackwardCommand.preferredIntervals = [10]
    bind(remote.skipForwardCommand) { [weak self] in self?.seekBy(10) }
    bind(remote.skipBackwardCommand) { [weak self] in self?.seekBy(-10) }
    remote.changePlaybackPositionCommand.isEnabled = true
    let target = remote.changePlaybackPositionCommand.addTarget { [weak self] event in
      guard let position = event as? MPChangePlaybackPositionCommandEvent,
            UserDefaults.standard.string(forKey: "lumebox.mediaOwner") == owner else { return .commandFailed }
      DispatchQueue.main.async {
        guard let self, !self.closing, UserDefaults.standard.string(forKey: "lumebox.mediaOwner") == owner else { return }
        self.commitSeek(position.positionTime)
      }
      return .success
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
    holdState(gesture.state)
  }
  private func setPlaybackSpeed(_ rate: Double) {
    speed = rate; engine?.setRate(rate)
    controls["speed"]?.setTitle(String(format: "%g×", rate), for: .normal)
    emit("settings", extra: ["speed": rate])
  }
  private func holdState(_ phase: UIGestureRecognizer.State) {
    guard !closing else { return }
    // End/cancel must restore the stored rate even if pause or screen lock
    // happened during the hold. Changing rate must never resume playback.
    if [.ended, .cancelled, .failed].contains(phase) { engine?.setRate(speed); return }
    guard !locked, wantsPlay, !switching else { return }
    if phase == .began { engine?.setRate(max(2, speed)) }
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    guard !closing, subtitlePickerGeneration == generation, let url = urls.first else { return }
    subtitlePickerGeneration = nil
    loadExternalSubtitle(url)
  }
  private func clearExternalSubtitle() {
    subtitleRevision += 1
    externalSubtitleURL = nil
    subtitles = NativeVideoSubtitles()
    caption.text = nil
  }
  private func loadExternalSubtitle(_ url: URL) {
    subtitleRevision += 1
    if kernel == "mpv" {
      externalSubtitleURL = url
      engine?.subtitle(url)
      return
    }
    let revision = subtitleRevision, mediaGeneration = generation
    Task { @MainActor [weak self] in
      let subtitles = await Task.detached(priority: .utility) { NativeVideoSubtitles.read(url) }.value
      guard let self, !self.closing, self.generation == mediaGeneration, self.subtitleRevision == revision else { return }
      guard let subtitles else { self.toast("无法读取字幕。系统播放器支持 SRT / VTT，ASS 可使用 MPV"); return }
      self.externalSubtitleURL = url
      self.subtitles = subtitles
      self.engine?.subtitle(url)
      self.renderState()
    }
  }
  private func loadDanmaku() {
    let identity = item.identity
    danmakuRevision += 1; let revision = danmakuRevision
    request?("danmaku", [:]) { [weak self] reply in
      guard let self, !self.closing, self.danmakuEnabled, self.item.identity == identity,
            self.danmakuRevision == revision else { return }
      self.danmaku = (reply?["items"] as? [[String: Any]] ?? []).compactMap { row in
        guard let text = row["text"] as? String, !text.isEmpty, let time = row["time"] as? Double, time.isFinite else { return nil }
        return (max(0, time), String(text.prefix(180)))
      }.sorted { $0.0 < $1.0 }
      self.danmakuPosition = nil
      if self.danmaku.isEmpty { self.toast("本集暂未提供弹幕") }
    }
  }
  private func updateDanmaku() {
    guard danmakuEnabled, pendingSeek == nil else { return }
    if state.playing == danmakuPaused {
      let layer = bullets.layer
      if state.playing {
        let paused = layer.timeOffset; layer.speed = 1; layer.timeOffset = 0; layer.beginTime = 0
        layer.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) - paused
      } else { let at = layer.convertTime(CACurrentMediaTime(), from: nil); layer.speed = 0; layer.timeOffset = at }
      danmakuPaused = !state.playing
    }
    let position = state.position
    if danmakuPosition.map({ position < $0 || position - $0 > 2 }) ?? true {
      bullets.subviews.forEach { $0.removeFromSuperview() }
      danmakuIndex = danmakuBoundary { $0 < position }
    }
    danmakuPosition = position
    guard state.playing else { return }
    guard danmakuIndex < danmaku.count, danmaku[danmakuIndex].0 <= position else { return }
    let end = danmakuBoundary { $0 <= position }
    let capacity = min(6, max(0, 40 - bullets.subviews.count))
    let start = max(danmakuIndex, end - capacity)
    danmakuIndex = end
    for index in start..<end {
      let text = danmaku[index].1
      let label = UILabel(); label.text = text; label.textColor = .white; label.font = .systemFont(ofSize: 19, weight: .medium)
      label.layer.shadowColor = UIColor.black.cgColor; label.layer.shadowOpacity = 1; label.layer.shadowRadius = 1
      label.sizeToFit(); label.frame.origin = CGPoint(x: bullets.bounds.width, y: CGFloat(danmakuRow % 6) * 28 + 56); danmakuRow += 1
      bullets.addSubview(label)
      UIView.animate(withDuration: 8, delay: 0, options: .curveLinear) { label.frame.origin.x = -label.bounds.width } completion: { _ in label.removeFromSuperview() }
    }
  }
  // The track is sorted. Skip a dense burst in logarithmic time on the UI thread.
  private func danmakuBoundary(while precedes: (Double) -> Bool) -> Int {
    var lower = 0, upper = danmaku.count
    while lower < upper {
      let mid = (lower + upper) / 2
      if precedes(danmaku[mid].0) { lower = mid + 1 } else { upper = mid }
    }
    return lower
  }
  private func toast(_ text: String) {
    toastTimer?.invalidate()
    toastMessage = text
    renderState()
    toastTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated { self?.toastMessage = nil; self?.renderState() }
    }
  }
  static func clock(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max) else { return "00:00" }
    let value = Int(seconds)
    return value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, (value / 60) % 60, value % 60) : String(format: "%02d:%02d", value / 60, value % 60)
  }
  func finish(dismiss: Bool = true, completion: @escaping () -> Void = {}) {
    guard !closing else { completion(); return }
    emit("progress"); closing = true; generation += 1; requestGeneration += 1; pendingEngine = nil
    timeout?.invalidate(); autoHide?.invalidate(); sleepTimer?.invalidate(); toastTimer?.invalidate(); resetPip()
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
    result["autoNext"] = autoNext
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

struct NativeVideoSubtitles: Sendable {
  private struct Cue: Sendable {
    let start: Double, end: Double, text: String
  }
  private var cues: [Cue] = []
  private var latestEnd: [Double] = []
  var isEmpty: Bool { cues.isEmpty }

  func caption(at position: Double) -> String? {
    var lower = 0, upper = cues.count
    while lower < upper {
      let mid = (lower + upper) / 2
      if cues[mid].start <= position { lower = mid + 1 } else { upper = mid }
    }
    var visible: [String] = []
    var index = lower
    while index > 0 && latestEnd[index - 1] > position {
      index -= 1
      if position < cues[index].end { visible.append(cues[index].text) }
    }
    return visible.isEmpty ? nil : visible.reversed().joined(separator: "\n")
  }

  static func read(_ url: URL) -> Self? {
    let limit = 8 * 1024 * 1024
    guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? file.close() }
    guard let data = try? file.read(upToCount: limit + 1), data.count <= limit else { return nil }
    let encoding: String.Encoding = data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff]) ? .utf16 : .utf8
    guard let text = String(data: data, encoding: encoding) else { return nil }

    func seconds(_ timestamp: Substring) -> Double? {
      var total = 0.0
      let value = timestamp.replacingOccurrences(of: ",", with: ".")
      guard value.range(of: #"^(?:[0-9]+:)?[0-5][0-9]:[0-5][0-9]\.[0-9]{3}$"#,
                        options: .regularExpression) != nil else { return nil }
      let fields = value.split(separator: ":")
      for field in fields {
        guard let number = Double(field), number.isFinite, number >= 0 else { return nil }
        total = total * 60 + number
      }
      return total.isFinite ? total : nil
    }

    func parseBlock(_ lines: [String]) -> Cue? {
      guard let first = lines.first?.trimmingCharacters(in: .whitespaces),
            first != "STYLE", first != "REGION",
            first != "NOTE", !first.hasPrefix("NOTE "), !first.hasPrefix("NOTE\t"),
            let index = lines.prefix(2).firstIndex(where: { $0.contains("-->") }) else { return nil }
      let fields = lines[index].components(separatedBy: "-->")
      guard fields.count == 2,
            let start = seconds(Substring(fields[0].trimmingCharacters(in: .whitespaces))),
            let timestamp = fields[1].split(whereSeparator: { $0.isWhitespace }).first,
            let end = seconds(timestamp), end > start else { return nil }
      let caption = lines.dropFirst(index + 1).joined(separator: "\n")
        .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        .replacingOccurrences(of: "&lt;", with: "<")
        .replacingOccurrences(of: "&gt;", with: ">")
        .replacingOccurrences(of: "&nbsp;", with: "\u{00a0}")
        .replacingOccurrences(of: "&lrm;", with: "\u{200e}")
        .replacingOccurrences(of: "&rlm;", with: "\u{200f}")
        .replacingOccurrences(of: "&amp;", with: "&")
      return caption.isEmpty ? nil : Cue(start: start, end: end, text: caption)
    }

    var subtitles = Self()
    var lines: [String] = []
    text.enumerateLines { line, _ in
      if line.trimmingCharacters(in: .whitespaces).isEmpty {
        if let cue = parseBlock(lines) { subtitles.cues.append(cue) }
        lines.removeAll(keepingCapacity: true)
      } else {
        lines.append(line)
      }
    }
    if let cue = parseBlock(lines) { subtitles.cues.append(cue) }
    guard !subtitles.cues.isEmpty else { return nil }
    subtitles.cues.sort { $0.start < $1.start }
    var end = 0.0
    for cue in subtitles.cues {
      end = max(end, cue.end)
      subtitles.latestEnd.append(end)
    }
    return subtitles
  }
}
