import AVFoundation
import Flutter
import Security

/// Incremental PCM sink shared by cloud and offline synthesis. All mutations
/// happen on the main queue. Stale producer tokens cannot restart stopped audio.
final class SpeechStream: NSObject, AVSpeechSynthesizerDelegate {
  var emit: ((String, Int?, String?) -> Void)?
  private let engine = AVAudioEngine()
  private let player = AVAudioPlayerNode()
  private let timePitch = AVAudioUnitTimePitch()
  private let synth = AVSpeechSynthesizer()
  private var format: AVAudioFormat?
  private var token = ""
  private var queued = 0
  private var offset = 0
  private var generation = 0
  private var heartbeat: Timer?
  private var pending: [FlutterResult] = []
  private var utteranceResult: FlutterResult?
  private var utteranceOffset = 0
  private var attached = false
  private(set) var active = false
  private(set) var paused = false
  var playing: Bool { active && !paused }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String:Any] ?? [:]
    if call.method == "speechGetKey" || call.method == "speechSetKey" {
      secret(call.method, args, result); return
    }
    if call.method == "speechVoices" {
      result(AVSpeechSynthesisVoice.speechVoices().map {
        ["id":$0.identifier,"name":$0.name,"language":$0.language]
      }); return
    }
    if call.method == "streamBegin" {
      stop(notify:false)
      token = args["token"] as? String ?? ""
      guard !token.isEmpty else { result(FlutterError(code:"token",message:"缺少播放标识",details:nil)); return }
      let sampleRate = (args["sampleRate"] as? NSNumber)?.doubleValue ?? 24000
      guard sampleRate == 24000 || sampleRate == 8000 else { result(FlutterError(code:"format",message:"不支持采样率",details:nil)); return }
      if !attached { engine.attach(player); engine.attach(timePitch); attached = true }
      engine.disconnectNodeOutput(player); engine.disconnectNodeOutput(timePitch)
      format = AVAudioFormat(standardFormatWithSampleRate:sampleRate,channels:1)
      engine.connect(player,to:timePitch,format:format)
      engine.connect(timePitch,to:engine.mainMixerNode,format:format)
      let pitch = min(max((args["pitch"] as? NSNumber)?.floatValue ?? 1,0.5),2)
      timePitch.pitch = 1200 * log2(pitch)
      player.volume = min(max((args["volume"] as? NSNumber)?.floatValue ?? 1,0),1)
      do {
        try AVAudioSession.sharedInstance().setCategory(.playback, mode:.spokenAudio)
        try AVAudioSession.sharedInstance().setActive(true)
        try engine.start(); player.play()
      } catch { result(FlutterError(code:"audio",message:"无法启动音频引擎",details:nil)); return }
      synth.delegate = self
      active = true; paused = false
      heartbeat = Timer.scheduledTimer(withTimeInterval:1,repeats:true) { [weak self] _ in
        guard let self, self.playing else { return }
        // Buffering never advances the saved text position.
        self.emit?("progress",self.offset,nil)
      }
      emit?("started",0,nil); result(nil); return
    }
    guard active, args["token"] as? String == token else { result(FlutterError(code:"cancelled",message:"播放已取消",details:nil)); return }
    switch call.method {
    case "streamPCM":
      guard let data = args["bytes"] as? FlutterStandardTypedData,
            data.data.count <= 192000, data.data.count % 2 == 0,
            let format else { result(FlutterError(code:"pcm",message:"无效 PCM 数据",details:nil)); return }
      let frames = data.data.count / 2
      if frames == 0 { result(nil); return }
      guard let buffer = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:AVAudioFrameCount(frames)),
            let samples = buffer.floatChannelData?[0] else { result(FlutterError(code:"pcm",message:"无法分配音频缓冲",details:nil)); return }
      buffer.frameLength = AVAudioFrameCount(frames)
      data.data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
        for i in 0..<frames {
          let raw = UInt16(bytes[2*i]) | UInt16(bytes[2*i+1]) << 8
          samples[i] = Float(Int16(bitPattern:raw)) / 32768
        }
      }
      queued += frames
      let version = generation
      let highWatermark = Int(format.sampleRate * 2)
      let shouldWait = queued > highWatermark
      if shouldWait { pending.append(result) }
      player.scheduleBuffer(buffer,completionCallbackType:.dataPlayedBack) { [weak self] _ in
        DispatchQueue.main.async {
          guard let self, self.generation == version else { return }
          self.queued = max(0,self.queued - frames)
          // Unblock the producer while audio is still queued. Waiting for
          // the newly appended buffer itself drains the whole queue.
          if self.queued <= highWatermark && !self.pending.isEmpty {
            let waiting = self.pending
            self.pending.removeAll()
            waiting.forEach { $0(nil) }
          }
        }
      }
      if !shouldWait { result(nil) }
    case "streamMark", "streamFinish":
      let version = generation
      let finished = call.method == "streamFinish"
      let nextOffset = args["offset"] as? Int ?? offset
      guard let format, let marker = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:1) else { result(nil); return }
      marker.frameLength = 1; marker.floatChannelData?[0][0] = 0
      player.scheduleBuffer(marker,completionCallbackType:.dataPlayedBack) { [weak self] _ in
        DispatchQueue.main.async {
          guard let self, self.generation == version, self.active else { return }
          self.offset = max(self.offset,nextOffset)
          if finished {
            self.stop(notify:false); self.emit?("finished",nil,nil)
          } else { self.emit?("progress",self.offset,nil) }
        }
      }
      result(nil)
    case "streamSystem":
      let text = args["text"] as? String ?? ""
      let utterance = AVSpeechUtterance(string:text)
      let voiceID = args["voice"] as? String ?? ""
      let role = args["role"] as? String ?? "narrator"
      let gender: AVSpeechSynthesisVoiceGender = role == "female" ? .female : .male
      utterance.voice = AVSpeechSynthesisVoice(identifier:voiceID)
        ?? (role == "narrator" ? nil : AVSpeechSynthesisVoice.speechVoices().first { $0.language.hasPrefix("zh") && $0.gender == gender })
        ?? AVSpeechSynthesisVoice(language:"zh-CN")
      utterance.rate = min(max((args["rate"] as? NSNumber)?.floatValue ?? 0.5,AVSpeechUtteranceMinimumSpeechRate),AVSpeechUtteranceMaximumSpeechRate)
      utterance.pitchMultiplier = min(max((args["pitch"] as? NSNumber)?.floatValue ?? 1,0.5),2)
      utterance.volume = min(max((args["volume"] as? NSNumber)?.floatValue ?? 1,0),1)
      utteranceOffset = args["offset"] as? Int ?? 0
      utteranceResult = result; synth.speak(utterance)
    case "streamFail":
      stop(notify:false); emit?("failed",nil,args["message"] as? String); result(nil)
    default: result(FlutterMethodNotImplemented)
    }
  }

  func pause() {
    guard active, !paused else { return }
    paused = true; player.pause()
    if synth.isSpeaking { synth.pauseSpeaking(at:.word) }
    emit?("paused",offset,nil)
  }
  func resume() {
    guard active, paused else { return }
    do {
      try AVAudioSession.sharedInstance().setActive(true)
      if !engine.isRunning { try engine.start() }
      player.play(); if synth.isPaused { synth.continueSpeaking() }
      paused = false; emit?("resumed",offset,nil)
    } catch { stop(notify:false); emit?("failed",nil,"无法恢复音频会话") }
  }
  func stop(notify: Bool = true) {
    generation += 1; active = false; paused = false
    heartbeat?.invalidate(); heartbeat = nil
    if attached { player.stop(); engine.stop() }
    synth.stopSpeaking(at:.immediate)
    let waiting = pending; pending.removeAll(); waiting.forEach { $0(nil) }
    let completion = utteranceResult; utteranceResult = nil; completion?(nil)
    queued = 0; offset = 0
    if notify { emit?("stopped",nil,nil) }
  }
  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    guard active else { return }
    offset = utteranceOffset + utterance.speechString.utf16.count
    emit?("progress",offset,nil)
    let completion = utteranceResult; utteranceResult = nil; completion?(nil)
  }
  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString range: NSRange, utterance: AVSpeechUtterance) {
    guard active else { return }
    offset = utteranceOffset + range.location
    emit?("progress",offset,nil)
  }
  private func secret(_ method:String, _ args:[String:Any], _ result:FlutterResult) {
    guard let kind = args["kind"] as? String,
      ["tts","llm","azure","volc","mimo","bangumi"].contains(kind) else {
      result(FlutterError(code:"key",message:"未知密钥类型",details:nil)); return
    }
    let query:[String:Any] = [kSecClass as String:kSecClassGenericPassword,
      kSecAttrService as String:"lumebox.speech",kSecAttrAccount as String:kind]
    if method == "speechGetKey" {
      var read = query; read[kSecReturnData as String] = true
      var value:CFTypeRef?
      let status = SecItemCopyMatching(read as CFDictionary,&value)
      guard status == errSecSuccess || status == errSecItemNotFound else {
        result(FlutterError(code:"keychain",message:"无法读取密钥",details:nil)); return
      }
      result((value as? Data).flatMap { String(data:$0,encoding:.utf8) } ?? "")
    } else {
      let key = args["key"] as? String ?? ""
      var status:OSStatus
      if key.isEmpty { status = SecItemDelete(query as CFDictionary) }
      else {
        let data = Data(key.utf8)
        status = SecItemUpdate(query as CFDictionary,[kSecValueData as String:data] as CFDictionary)
        if status == errSecItemNotFound {
          var insert = query; insert[kSecValueData as String] = data
          insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
          status = SecItemAdd(insert as CFDictionary,nil)
        }
      }
      guard status == errSecSuccess || (key.isEmpty && status == errSecItemNotFound) else {
        result(FlutterError(code:"keychain",message:"无法保存密钥",details:nil)); return
      }
      result(nil)
    }
  }
}
