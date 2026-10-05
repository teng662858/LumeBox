import AVFoundation
import Flutter

/// 语音朗读的原生实现（iOS）：`AVSpeechSynthesizer`。
///
/// 契约见 Dart 侧 `MethodChannelSpeechBackend`：
/// - 方法通道 `lumebox/speech`：`isSupported` / `speak` / `stop` / `pause` / `resume`；
/// - 事件通道 `lumebox/speech/events`：
///   `started` / `finished` / `progress` / `paused` / `resumed` / `stopped` / `failed`。
///
/// 为什么用系统合成器而不是第三方：它离线可用、逐字回调（`willSpeakRangeOfSpeechString`）
/// 正好给出「朗读到第几个字」，是跟读翻页与进度保存需要的唯一信息。
///
/// 位置口径：`charOffset` 一律是**相对当前这段文本**的 UTF-16 偏移。Dart 侧的
/// 片段起点是 Dart 字符串下标（UTF-16 单位），两者口径一致，可以直接相加——
/// 这里不能改成「字符数」或字节偏移，否则中文文本会错位。
final class SpeechController: NSObject {
  private let methodChannelName = "lumebox/speech"
  private let eventChannelName = "lumebox/speech/events"

  private let synthesizer = AVSpeechSynthesizer()
  private var eventSink: FlutterEventSink?

  /// 当前这段的语速 / 音调 / 音量（speak 时下发）。
  private var rate: Float = 0.5
  private var pitch: Float = 1.0
  private var volume: Float = 1.0

  /// 主动打断上一段（换段 / 跳段）时抑制 `stopped` 事件。
  ///
  /// `stopSpeaking` 会触发 `didCancel`，若照常上报，Dart 侧会先收到一次
  /// 「已停止」再收到「开始朗读」——状态闪一下，UI 也跟着闪。
  /// 这种打断是我们自己发起的，不该当作一次用户可见的停止。
  private var suppressCancelEvent = false

  func register(with messenger: FlutterBinaryMessenger) {
    let methods = FlutterMethodChannel(name: methodChannelName, binaryMessenger: messenger)
    methods.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }

    let events = FlutterEventChannel(name: eventChannelName, binaryMessenger: messenger)
    events.setStreamHandler(self)

    synthesizer.delegate = self
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
    default:
      result(FlutterMethodNotImplemented)
    }
  }

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

  private func stop(result: @escaping FlutterResult) {
    if synthesizer.isSpeaking || synthesizer.isPaused {
      // 用户主动停止：正常上报 stopped，不抑制。
      suppressCancelEvent = false
      synthesizer.stopSpeaking(at: .immediate)
    } else {
      // 引擎本来就没在说：didCancel 不会触发，直接补一个 stopped 让 Dart 侧
      // 有确定的收敛信号（否则「停止」在无声音时状态不会变）。
      emit(kind: "stopped")
    }
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
    emit(kind: "started")
  }

  func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer,
    didFinish utterance: AVSpeechUtterance
  ) {
    emit(kind: "finished")
  }

  func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer,
    didPause utterance: AVSpeechUtterance
  ) {
    emit(kind: "paused")
  }

  func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer,
    didContinue utterance: AVSpeechUtterance
  ) {
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
