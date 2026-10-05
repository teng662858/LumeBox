import AVFoundation
import Flutter
import MediaPlayer

/// 语音朗读的原生实现（iOS）：`AVSpeechSynthesizer`。
///
/// 契约见 Dart 侧 `MethodChannelSpeechBackend`：
/// - 方法通道 `lumebox/speech`：`isSupported` / `speak` / `stop` / `pause` / `resume`
///   / `setNowPlaying` / `clearNowPlaying`；
/// - 事件通道 `lumebox/speech/events`：
///   `started` / `finished` / `progress` / `paused` / `resumed` / `stopped` / `failed`。
///
/// 为什么用系统合成器而不是第三方：它离线可用、逐字回调（`willSpeakRangeOfSpeechString`）
/// 正好给出「朗读到第几个字」，是跟读翻页与进度保存需要的唯一信息。
///
/// 位置口径：`charOffset` 一律是**相对当前这段文本**的 UTF-16 偏移。Dart 侧的
/// 片段起点是 Dart 字符串下标（UTF-16 单位），两者口径一致，可以直接相加——
/// 这里不能改成「字符数」或字节偏移，否则中文文本会错位。
///
/// 后台播放：`Info.plist` 声明 `audio` 后台模式 + 音频会话类别 `.playback`
/// （配 `.spokenAudio` 模式），离开 App 后合成器继续朗读；锁屏 / 控制中心的
/// 播放控件经 `MPRemoteCommandCenter` 回到这里，再由合成器委托上报事件——
/// 状态仍只有一个来源（合成器），不在这里另造一套。
final class SpeechController: NSObject {
  private let methodChannelName = "lumebox/speech"
  private let eventChannelName = "lumebox/speech/events"

  private let synthesizer = AVSpeechSynthesizer()
  private var eventSink: FlutterEventSink?

  /// 当前这段的语速 / 音调 / 音量（speak 时下发）。
  private var rate: Float = 0.5
  private var pitch: Float = 1.0
  private var volume: Float = 1.0

  /// 是否允许后台播放（Dart 侧的听书设置）。关掉时退到后台会暂停朗读。
  private var backgroundPlayback = true

  /// 主动打断上一段（换段 / 跳段）时抑制 `stopped` 事件。
  ///
  /// `stopSpeaking` 会触发 `didCancel`，若照常上报，Dart 侧会先收到一次
  /// 「已停止」再收到「开始朗读」——状态闪一下，UI 也跟着闪。
  /// 这种打断是我们自己发起的，不该当作一次用户可见的停止。
  private var suppressCancelEvent = false

  /// 音频会话是否已激活（避免重复 setActive 的额外开销）。
  private var sessionActive = false

  /// 锁屏信息（书名 / 章节名）；Dart 侧在开始朗读时下发。
  private var nowPlayingTitle: String?
  private var nowPlayingSubtitle: String?

  func register(with messenger: FlutterBinaryMessenger) {
    let methods = FlutterMethodChannel(name: methodChannelName, binaryMessenger: messenger)
    methods.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }

    let events = FlutterEventChannel(name: eventChannelName, binaryMessenger: messenger)
    events.setStreamHandler(self)

    synthesizer.delegate = self
    configureAudioSession()
    configureRemoteCommands()
    observeInterruptions()
    observeBackgrounding()
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isSupported":
      // 系统合成器在所有 iOS 设备上都可用；真正的「不支持」是原生未接入，
      // 那种情况下 Dart 侧根本不会调到这个方法。
      result(true)
    case "speak":
      speak(call, result: result)
    case "stop":
      stop(result: result)
    case "pause":
      pause(result: result)
    case "resume":
      resume(result: result)
    case "setNowPlaying":
      setNowPlaying(call)
      result(nil)
    case "clearNowPlaying":
      clearNowPlaying()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // ------------------------------------------------------------ 音频会话 / 后台

  /// 音频会话：类别 `.playback` 才能后台出声，模式 `.spokenAudio` 让系统
  /// 按「有声书」处理（蓝牙 / CarPlay 上的暂停键语义更贴切）。
  private func configureAudioSession() {
    do {
      try AVAudioSession.sharedInstance().setCategory(
        .playback,
        mode: .spokenAudio,
        options: []
      )
    } catch {
      // 会话配置失败不阻断朗读：前台朗读仍然可用，只是退到后台会停。
      emit(kind: "failed", message: "音频会话配置失败：\(error.localizedDescription)")
    }
  }

  /// 激活 / 停用音频会话。
  ///
  /// 停用时用 `.notifyOthersOnDeactivation` 把音频交还给别的 App
  /// （否则用户会发现「明明停了朗读，音乐 App 却不出声」）。
  private func setSessionActive(_ active: Bool) {
    guard active != sessionActive else { return }
    do {
      try AVAudioSession.sharedInstance().setActive(
        active,
        options: active ? [] : .notifyOthersOnDeactivation
      )
      sessionActive = active
    } catch {
      // 激活失败：前台仍能读，只是后台会停——如实记一条，不抛给页面。
      emit(kind: "failed", message: "音频会话激活失败：\(error.localizedDescription)")
    }
  }

  /// 来电 / 闹钟等系统打断：被中断即暂停，中断结束时不自动抢回（由用户决定）。
  ///
  /// 不自动恢复是刻意的：系统打断结束后用户往往还在通话，抢回音频很讨厌。
  private func observeInterruptions() {
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleInterruption(_:)),
      name: AVAudioSession.interruptionNotification,
      object: AVAudioSession.sharedInstance()
    )
  }

  @objc private func handleInterruption(_ notification: Notification) {
    guard let info = notification.userInfo,
          let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
          let type = AVAudioSession.InterruptionType(rawValue: raw)
    else { return }
    switch type {
    case .began:
      if synthesizer.isSpeaking {
        synthesizer.pauseSpeaking(at: .word)
      }
    case .ended:
      // 会话被系统停用后需要重新激活，否则下一次 speak 后台不出声。
      sessionActive = false
      configureAudioSession()
    @unknown default:
      break
    }
  }

  /// 退到后台：按设置决定继续读还是暂停。
  ///
  /// 关掉后台播放时主动暂停，而不是停用音频会话——会话停用会让系统立刻
  /// 掐掉声音（像被强杀），暂停则干净地停在词边界，回前台还能接着读。
  private func observeBackgrounding() {
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleDidEnterBackground),
      name: UIApplication.didEnterBackgroundNotification,
      object: nil
    )
  }

  @objc private func handleDidEnterBackground() {
    guard !backgroundPlayback else { return }
    if synthesizer.isSpeaking {
      synthesizer.pauseSpeaking(at: .word)
    }
  }

  // -------------------------------------------------------------- 锁屏控制

  /// 锁屏 / 控制中心 / 耳机按键：只转发成合成器操作，事件仍由委托统一上报。
  private func configureRemoteCommands() {
    let center = MPRemoteCommandCenter.shared()

    center.playCommand.isEnabled = true
    center.playCommand.addTarget { [weak self] _ -> MPRemoteCommandHandlerStatus in
      guard let self else { return .commandFailed }
      guard self.synthesizer.isPaused else { return .commandFailed }
      self.synthesizer.continueSpeaking()
      return .success
    }

    center.pauseCommand.isEnabled = true
    center.pauseCommand.addTarget { [weak self] _ -> MPRemoteCommandHandlerStatus in
      guard let self else { return .commandFailed }
      guard self.synthesizer.isSpeaking else { return .commandFailed }
      self.synthesizer.pauseSpeaking(at: .word)
      return .success
    }

    // 锁屏上的「停止」= 结束本次朗读（清队列），与 App 内的停止同口径。
    center.stopCommand.isEnabled = true
    center.stopCommand.addTarget { [weak self] _ -> MPRemoteCommandHandlerStatus in
      guard let self else { return .commandFailed }
      self.stopSpeakingInternal()
      return .success
    }

    // 耳机线控 / 锁屏播放键：说的时候暂停，停的时候继续。
    center.togglePlayPauseCommand.isEnabled = true
    center.togglePlayPauseCommand.addTarget { [weak self] _ -> MPRemoteCommandHandlerStatus in
      guard let self else { return .commandFailed }
      if self.synthesizer.isSpeaking {
        self.synthesizer.pauseSpeaking(at: .word)
        return .success
      }
      if self.synthesizer.isPaused {
        self.synthesizer.continueSpeaking()
        return .success
      }
      return .commandFailed
    }
  }

  /// 锁屏信息：书名（title）+ 章节名（subtitle）。
  ///
  /// 不带播放进度：朗读进度是「片段序号 / 片段总数」，Dart 侧才知道，
  /// 而锁屏进度条需要秒数——硬凑一个假秒数不如不给（进度条自然隐藏）。
  private func setNowPlaying(_ call: FlutterMethodCall) {
    guard let args = call.arguments as? [String: Any] else { return }
    nowPlayingTitle = args["title"] as? String
    nowPlayingSubtitle = args["subtitle"] as? String
    updateNowPlayingInfo()
  }

  private func updateNowPlayingInfo() {
    var info: [String: Any] = [:]
    if let nowPlayingTitle { info[MPMediaItemPropertyTitle] = nowPlayingTitle }
    if let nowPlayingSubtitle { info[MPMediaItemPropertyArtist] = nowPlayingSubtitle }
    info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
    // 语速影响锁屏的「快进 / 快退」提示，如实带上。
    info[MPNowPlayingInfoPropertyPlaybackRate] = synthesizer.isSpeaking ? 1.0 : 0.0
    MPNowPlayingInfoCenter.default().nowPlayingInfo = info.isEmpty ? nil : info
  }

  private func clearNowPlaying() {
    nowPlayingTitle = nil
    nowPlayingSubtitle = nil
    MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
  }

  // -------------------------------------------------------------- 朗读控制

  private func speak(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
          let text = args["text"] as? String,
          !text.isEmpty
    else {
      result(FlutterError(code: "badArgs", message: "朗读文本为空", details: nil))
      return
    }
    rate = (args["rate"] as? NSNumber)?.floatValue ?? 0.5
    pitch = (args["pitch"] as? NSNumber)?.floatValue ?? 1.0
    volume = (args["volume"] as? NSNumber)?.floatValue ?? 1.0
    backgroundPlayback = (args["background"] as? NSNumber)?.boolValue ?? true

    // 后台出声的前提：音频会话已激活。
    setSessionActive(true)

    // 打断上一段：Dart 侧一次只送一段，引擎队列里不该有残留。
    // 这次打断是我们自己发起的，抑制随之而来的 didCancel（否则 UI 会先闪一下
    // 「已停止」再进入「朗读中」）。
    if synthesizer.isSpeaking {
      suppressCancelEvent = true
      synthesizer.stopSpeaking(at: .immediate)
    }

    let utterance = AVSpeechUtterance(string: text)
    utterance.voice = AVSpeechSynthesisVoice(language: voiceLanguage(for: text))
    // AVSpeechUtterance 的语速区间是 [AVSpeechUtteranceMinimumSpeechRate,
    // MaximumSpeechRate]，Dart 侧给的是 0.2~1.0 的「相对语速」，这里换算。
    utterance.rate = clampRate(rate)
    utterance.pitchMultiplier = min(max(pitch, 0.5), 2.0)
    utterance.volume = min(max(volume, 0.0), 1.0)

    synthesizer.speak(utterance)
    updateNowPlayingInfo()
    result(nil)
  }

  /// 语速换算：夹到系统允许区间。
  ///
  /// 系统区间本身就是 0.0~1.0（默认 0.5），与 Dart 侧的 0.2~1.0 同口径——
  /// Dart 侧 0.5 即系统默认语速，不需要额外映射，只需防越界。
  private func clampRate(_ value: Float) -> Float {
    let minRate = AVSpeechUtteranceMinimumSpeechRate
    let maxRate = AVSpeechUtteranceMaximumSpeechRate
    return min(max(value, minRate), maxRate)
  }

  /// 选语音：中文文本用中文语音，其余用系统默认。
  ///
  /// 不做语言检测库：判「有没有中日韩字符」这一条就够覆盖本项目的中文小说场景，
  /// 而且行为可预测（用户知道为什么读的是中文音）。
  private func voiceLanguage(for text: String) -> String {
    for scalar in text.unicodeScalars {
      let value = scalar.value
      let isCJK = (value >= 0x4E00 && value <= 0x9FFF)   // 基本汉字
        || (value >= 0x3400 && value <= 0x4DBF)          // 扩展 A
        || (value >= 0x3040 && value <= 0x30FF)          // 日文假名
        || (value >= 0xAC00 && value <= 0xD7AF)          // 韩文
      if isCJK { return "zh-CN" }
    }
    return AVSpeechSynthesisVoice.currentLanguageCode()
  }

  /// 停止朗读（内部共用：方法通道与锁屏停止键都走这里）。
  private func stopSpeakingInternal() {
    if synthesizer.isSpeaking || synthesizer.isPaused {
      // 用户主动停止：正常上报 stopped，不抑制。
      suppressCancelEvent = false
      synthesizer.stopSpeaking(at: .immediate)
    } else {
      // 引擎本来就没在说：didCancel 不会触发，直接补一个 stopped 让 Dart 侧
      // 有确定的收敛信号（否则「停止」在无声音时状态不会变）。
      emit(kind: "stopped")
    }
    setSessionActive(false)
    clearNowPlaying()
  }

  private func stop(result: @escaping FlutterResult) {
    stopSpeakingInternal()
    result(nil)
  }

  private func pause(result: @escaping FlutterResult) {
    guard synthesizer.isSpeaking else {
      result(nil)
      return
    }
    // pauseSpeaking 返回是否受理；不受理（例如已经读完）时如实回报，
    // 但 Dart 侧会自行收敛状态，这里不抛错。
    synthesizer.pauseSpeaking(at: .word)
    result(nil)
  }

  private func resume(result: @escaping FlutterResult) {
    guard synthesizer.isPaused else {
      result(nil)
      return
    }
    // 从锁屏恢复也要重新激活会话（可能已被系统停用）。
    setSessionActive(true)
    synthesizer.continueSpeaking()
    result(nil)
  }

  private func emit(kind: String, charOffset: Int? = nil, message: String? = nil) {
    var payload: [String: Any] = ["kind": kind]
    if let charOffset { payload["charOffset"] = charOffset }
    if let message { payload["message"] = message }
    eventSink?(payload)
  }
}

// MARK: - FlutterStreamHandler

extension SpeechController: FlutterStreamHandler {
  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }
}

// MARK: - AVSpeechSynthesizerDelegate

extension SpeechController: AVSpeechSynthesizerDelegate {
  func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer,
    didStart utterance: AVSpeechUtterance
  ) {
    // 新的一段已经开始：抑制标记到此必须失效。
    //
    // 为什么在这里兜底清：`suppressCancelEvent` 只在 didCancel 里被消费，而
    // `stopSpeaking` **不保证**一定触发 didCancel（合成器可能在 `isSpeaking`
    // 检查与调用之间正好读完）。那种情况下标记会一直挂着 true，把用户**下一次
    // 真正的停止**吞掉——点了停止却毫无反应。
    suppressCancelEvent = false
    updateNowPlayingInfo()
    emit(kind: "started")
  }

  func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer,
    didFinish utterance: AVSpeechUtterance
  ) {
    updateNowPlayingInfo()
    emit(kind: "finished")
  }

  func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer,
    didPause utterance: AVSpeechUtterance
  ) {
    updateNowPlayingInfo()
    emit(kind: "paused")
  }

  func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer,
    didContinue utterance: AVSpeechUtterance
  ) {
    updateNowPlayingInfo()
    emit(kind: "resumed")
  }

  func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer,
    didCancel utterance: AVSpeechUtterance
  ) {
    // 自己发起的打断（换段）不上报：Dart 侧不需要知道这次内部停止。
    if suppressCancelEvent {
      suppressCancelEvent = false
      return
    }
    emit(kind: "stopped")
  }

  /// 逐字推进：把 UTF-16 range 的起点作为「已读到第几个字」回报。
  func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer,
    willSpeakRangeOfSpeechString characterRange: NSRange,
    utterance: AVSpeechUtterance
  ) {
    emit(kind: "progress", charOffset: characterRange.location)
  }
}
