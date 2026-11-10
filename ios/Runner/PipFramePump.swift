import AVFoundation
import CoreMedia
import CoreVideo
import Flutter
import UIKit
import CoreImage

/// 画中画帧泵：把 Dart 侧送来的 BGRA 像素包成 `CMSampleBuffer` 交给
/// `AVSampleBufferDisplayLayer` 上屏。
///
/// 为什么要这一层：iOS 的画中画只认 `AVPlayerLayer`（AVPlayer 专用）或
/// `AVSampleBufferDisplayLayer`（通用）。MPV / MDK 不是 AVPlayer，只能走第二条——
/// 内核解码出帧 → Dart 帧源（节流）→ 方法通道 → 本类 → 系统画中画窗口。
///
/// 内存纪律（移动端最要紧的一条）：**复用同一个 CVPixelBufferPool**。
/// 每帧新建 pixel buffer 会在 30fps 下产生持续的分配压力，用池复用能把这块开销
/// 降到几乎为零。池按「首帧尺寸」建立；尺寸变化（旋转 / 换分辨率）时重建。
final class PipFramePump {
  /// 目标层：系统从这里取画面。
  private(set) var displayLayer: AVSampleBufferDisplayLayer?

  let danmaku = PipDanmakuRenderer()
  private let imageContext = CIContext(options: [.cacheIntermediates: false])
  private var pool: CVPixelBufferPool?
  private var poolWidth = 0
  private var poolHeight = 0
  private var timebase: CMTimebase?
  private var timelineReady = false
  private var playing = true
  private var playbackRate = 1.0
  func setPlaybackState(playing: Bool, rate: Double = 1) {
    self.playing = playing
    playbackRate = rate.isFinite && rate > 0 ? rate : 1
    if let timebase = timebase { CMTimebaseSetRate(timebase, rate: playing ? playbackRate : 0) }
  }
  private func presentationTime(_ milliseconds: Int) -> CMTime {
    let media = CMTime(value: CMTimeValue(milliseconds), timescale: 1000)
    guard let timebase = timebase else { return media }
    let current = CMTimebaseGetTime(timebase)
    if !timelineReady || abs(CMTimeGetSeconds(current - media)) > 2 {
      displayLayer?.flush()
      CMTimebaseSetTime(timebase, time: media)
      CMTimebaseSetRate(timebase, rate: playing ? playbackRate : 0)
      timelineReady = true
    }
    return CMTimebaseGetTime(timebase)
  }


  /// 帧计数（诊断）。
  private(set) var receivedFrames = 0
  private(set) var droppedFrames = 0

  /// 建立（或复用）显示层。返回是否为新建。
  @discardableResult
  func ensureDisplayLayer() -> Bool {
    if displayLayer != nil { return false }
    let layer = AVSampleBufferDisplayLayer()
    layer.videoGravity = .resizeAspect
    // 画中画窗口尺寸由系统决定，层本身的 frame 不重要，但要有合法值。
    layer.frame = CGRect(x: 0, y: 0, width: 16, height: 9)
    var clock: CMTimebase?
    if CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault,
      sourceClock: CMClockGetHostTimeClock(), timebaseOut: &clock) == noErr,
      let clock = clock {
      timebase = clock
      layer.controlTimebase = clock
      CMTimebaseSetRate(clock, rate: playing ? playbackRate : 0)
    }
    timelineReady = false
    displayLayer = layer
    return true
  }

  /// 释放显示层与缓冲池（退出画中画 / 页面销毁时调用）。
  func teardown() {
    displayLayer?.flushAndRemoveImage()
    displayLayer?.removeFromSuperlayer()
    displayLayer = nil
    timebase = nil; timelineReady = false
    pool = nil
    poolWidth = 0
    poolHeight = 0
    danmaku.update([:])
  }

  /// 接收一帧 BGRA 像素并上屏。
  ///
  /// - Parameters:
  ///   - pixels: BGRA8888 字节（每像素 4 字节，行紧密排列）。
  ///   - width/height: 像素尺寸。
  ///   - timestampMs: 该帧在视频时间轴上的位置（毫秒）。
  /// - Returns: 是否成功入队。
  @discardableResult
  func submit(
    pixels: Data,
    width: Int,
    height: Int,
    timestampMs: Int
  ) -> Bool {
    guard width > 0, height > 0 else { return false }
    let expected = width * height * 4
    guard pixels.count >= expected else {
      droppedFrames += 1
      return false
    }
    ensureDisplayLayer()
    guard let layer = displayLayer else { return false }
    guard let buffer = makePixelBuffer(width: width, height: height) else {
      droppedFrames += 1
      return false
    }

    // 拷像素进 CVPixelBuffer。
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let base = CVPixelBufferGetBaseAddress(buffer) else {
      droppedFrames += 1
      return false
    }
    let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
    pixels.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
      guard let source = raw.baseAddress else { return }
      // 逐行拷贝：CVPixelBuffer 的行距可能大于 width*4（对齐要求）。
      for row in 0..<height {
        let sourceRow = source.advanced(by: row * width * 4)
        let targetRow = base.advanced(by: row * bytesPerRow)
        memcpy(targetRow, sourceRow, width * 4)
      }
    }

    // mpv screenshot-raw may be BGR0: video is opaque, but CoreGraphics
    // requires valid alpha before blending text into the pixel buffer.
    let bytes = base.assumingMemoryBound(to: UInt8.self)
    for row in 0..<height {
      for column in 0..<width { bytes[row * bytesPerRow + column * 4 + 3] = 255 }
    }
    danmaku.draw(base: base, width: width, height: height, stride: bytesPerRow, timestampMs: timestampMs)
    guard let sample = makeSampleBuffer(from: buffer, timestampMs: timestampMs) else {
      droppedFrames += 1
      return false
    }
    if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true)
      as? [NSMutableDictionary], let attachment = attachments.first {
      attachment[kCMSampleAttachmentKey_DisplayImmediately as String] = true
    }

    // 层可能处于「需要重启」状态（切后台回来常见）：先 flush 再入队。
    if layer.status == .failed {
      layer.flush()
    }
    layer.enqueue(sample)
    receivedFrames += 1
    return true
  }

  /// AVPlayerItemVideoOutput shares the same composited PiP frame path.
  @discardableResult
  func submit(buffer source: CVPixelBuffer, timestampMs: Int, transform: CGAffineTransform = .identity) -> Bool {
    var image = CIImage(cvPixelBuffer: source).transformed(by: transform)
    let extent = image.extent
    guard extent.width > 0, extent.height > 0 else { return false }
    image = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
    let scale = min(1.0, min(960.0 / extent.width, 540.0 / extent.height))
    image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    let width = max(1, Int(image.extent.width)), height = max(1, Int(image.extent.height))
    guard let buffer = makePixelBuffer(width: width, height: height) else { return false }
    imageContext.render(image, to: buffer)
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    if let base = CVPixelBufferGetBaseAddress(buffer) {
      danmaku.draw(base: base, width: width, height: height, stride: CVPixelBufferGetBytesPerRow(buffer), timestampMs: timestampMs)
    }
    ensureDisplayLayer()
    guard let layer = displayLayer, let sample = makeSampleBuffer(from: buffer, timestampMs: timestampMs) else { return false }
    if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as? [NSMutableDictionary], let first = attachments.first {
      first[kCMSampleAttachmentKey_DisplayImmediately as String] = true
    }
    if layer.status == .failed { layer.flush() }
    layer.enqueue(sample)
    receivedFrames += 1
    return true
  }

  // ------------------------------------------------------------ 内部：缓冲

  /// 从池里取一个 pixel buffer（尺寸变化时重建池）。
  private func makePixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
    if pool == nil || poolWidth != width || poolHeight != height {
      pool = makePool(width: width, height: height)
      poolWidth = width
      poolHeight = height
    }
    guard let pool else { return nil }
    var buffer: CVPixelBuffer?
    let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
    return status == kCVReturnSuccess ? buffer : nil
  }

  /// 建池：BGRA 格式（与 Dart 侧送的字节一致，省一次转换）。
  private func makePool(width: Int, height: Int) -> CVPixelBufferPool? {
    let attributes: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferWidthKey as String: width,
      kCVPixelBufferHeightKey as String: height,
      // IOSurface 让系统能零拷贝把 buffer 交给显示层。
      kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
    ]
    var pool: CVPixelBufferPool?
    let status = CVPixelBufferPoolCreate(
      kCFAllocatorDefault,
      nil,
      attributes as CFDictionary,
      &pool
    )
    return status == kCVReturnSuccess ? pool : nil
  }

  /// CVPixelBuffer → CMSampleBuffer（带时间戳，供系统做窗口同步）。
  private func makeSampleBuffer(
    from buffer: CVPixelBuffer,
    timestampMs: Int
  ) -> CMSampleBuffer? {
    var formatDescription: CMVideoFormatDescription?
    let formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(
      allocator: kCFAllocatorDefault,
      imageBuffer: buffer,
      formatDescriptionOut: &formatDescription
    )
    guard formatStatus == noErr, let format = formatDescription else { return nil }

    var timing = CMSampleTimingInfo(
      duration: CMTime(value: 1, timescale: 30),
      presentationTimeStamp: presentationTime(timestampMs),
      decodeTimeStamp: .invalid
    )
    var sample: CMSampleBuffer?
    let status = CMSampleBufferCreateReadyWithImageBuffer(
      allocator: kCFAllocatorDefault,
      imageBuffer: buffer,
      formatDescription: format,
      sampleTiming: &timing,
      sampleBufferOut: &sample
    )
    return status == noErr ? sample : nil
  }
}

/// Bakes text into the video buffer, so system PiP includes it outside Flutter.
final class PipDanmakuRenderer {
  private var settings: [String: Any] = [:]
  private var items: [[String: Any]] = []
  private struct Label {
    let fill: NSAttributedString
    let outline: NSAttributedString?
    func size() -> CGSize { fill.size() }
    func draw(at point: CGPoint) {
      outline?.draw(at: point)
      fill.draw(at: point)
    }
  }
  private var labels: [String: Label] = [:]
  var playing = true
  private var lastPosition = -1
  private var anchor: CFTimeInterval = 0
  private var clockPosition: Double = 0
  private var clockFrame: CFTimeInterval = 0
  private struct Entry {
    let label: Label
    let width: Double, start: Double, duration: Double, y: Double
    let scrolling: Bool
  }
  private var active: [Entry] = []
  private var nextIndex = -1
  private var layoutKey = ""
  private var lastDraw = -Double.infinity
  private var laneEnds: [Double] = [], laneStarts: [Double] = [], laneWidths: [Double] = []
  private var laneModes: [String] = []
  private var recent: [String: Double] = [:]
  private var second = -1, admitted = 0
  var enabled: Bool { bool("enabled", true) && bool("pipEnabled", true) && !items.isEmpty }
  func update(_ args: [String: Any]) {
    settings = args["settings"] as? [String: Any] ?? [:]
    items = (args["items"] as? [[String: Any]] ?? []).sorted { number($0["time"]) < number($1["time"]) }
    labels.removeAll()
    lastPosition = -1
    clockFrame = 0
    nextIndex = -1; active.removeAll(); layoutKey = ""
  }
  private func bool(_ key: String, _ fallback: Bool) -> Bool { settings[key] as? Bool ?? fallback }
  private func value(_ key: String, _ fallback: Double) -> Double { (settings[key] as? NSNumber)?.doubleValue ?? fallback }
  private func number(_ value: Any?) -> Double { (value as? NSNumber)?.doubleValue ?? 0 }
  func draw(base: UnsafeMutableRawPointer, width: Int, height: Int, stride: Int, timestampMs: Int) {
    guard enabled else { return }
    let now = CACurrentMediaTime()
    if timestampMs != lastPosition { lastPosition = timestampMs; anchor = now }
    let playbackSpeed = max(0.1, value("playbackRate", 1))
    let target = Double(timestampMs) + (playing ? min(1000, (now - anchor) * 1000) * playbackSpeed : 0)
    let delta = min(100, max(0, (now - clockFrame) * 1000))
    if clockFrame == 0 || !playing || abs(target - clockPosition) > 2000 {
      clockPosition = target
    } else {
      let predicted = clockPosition + delta * playbackSpeed
      let correction = min(delta * playbackSpeed * 0.1, max(-delta * playbackSpeed * 0.1, (target - predicted) * 0.12))
      clockPosition = min(Double(timestampMs) + 1000 * playbackSpeed, predicted + correction)
    }
    clockFrame = now
    let position = clockPosition - value("delayMs", 0)
    let scale = Double(width) / 640
    // The system shrinks the composited frame to the PiP window.
    let fontSize = 24 * value("fontScale", 1) * scale
    let stroke = value("strokeWidth", 1.2)
    let outline = min(max(0, stroke) * scale, fontSize * 0.04)
    let rowPadding = outline + 2 * scale
    let rowHeight = ceil(fontSize * max(1.35, value("lineSpacing", 1.35)) + rowPadding)
    let topInset = ceil(6 * scale)
    let available = Double(height) * (bool("avoidSubtitles", true) ? 0.82 : 1)
    let rows = Int(value("rows", 3))
    let region = rows > 0 ? available : min(available, Double(height) * value("displayArea", 0.5))
    let count = min(rows > 0 ? rows : 64, Int(max(0, region - topInset) / rowHeight))
    guard count > 0, let context = CGContext(data: base, width: width, height: height, bitsPerComponent: 8, bytesPerRow: stride, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
    context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: 1, y: -1)
    context.clip(to: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
    UIGraphicsPushContext(context)
    defer { UIGraphicsPopContext() }
    let span = 8000 / max(0.5, value("speedScale", 1))
    let key = "\(width)|\(height)|\(count)|\(fontSize)|\(span)"
    // Keep an admitted comment in its lane until it leaves. Rebuilding the
    // last eight seconds every frame changed lanes as the window advanced.
    if nextIndex < 0 || key != layoutKey || position < lastDraw - 150 || position - lastDraw > 2000 {
      active.removeAll(); recent.removeAll(); second = -1; admitted = 0
      laneEnds = Array(repeating: -Double.infinity, count: count)
      laneStarts = laneEnds; laneWidths = Array(repeating: 0, count: count)
      laneModes = Array(repeating: "", count: count)
      var low = 0, high = items.count
      while low < high { let mid = (low + high) / 2; if number(items[mid]["time"]) < position - max(5000, span) { low = mid + 1 } else { high = mid } }
      nextIndex = low; layoutKey = key
    }
    lastDraw = position
    active.removeAll { position - $0.start >= $0.duration }
    recent = recent.filter { position - $0.value < 5000 }
    let blocked = (settings["blockedWords"] as? [String] ?? []).map { $0.lowercased() }
    while nextIndex < items.count {
      let item = items[nextIndex], time = number(item["time"])
      if time > position { break }
      nextIndex += 1
      guard let text = item["text"] as? String, !text.isEmpty else { continue }
      let mode = item["mode"] as? String ?? "scroll"
      if mode == "scroll" && !bool("showScroll", true) || mode == "top" && !bool("showTop", true) || mode == "bottom" && !bool("showBottom", true) { continue }
      if blocked.contains(where: { text.lowercased().contains($0) }) { continue }
      let sec = Int(time / 1000)
      if sec != second { second = sec; admitted = 0 }
      if admitted >= Int(value("maxPerSecond", 8)) { continue }
      if bool("mergeDuplicates", true), let previous = recent[text], time - previous < 5000 { continue }
      let sourceScale = number(item["fontSize"])
      let size = min(
        fontSize * min(3, max(0.5, sourceScale == 0 ? 1 : sourceScale)),
        (rowHeight - rowPadding) / 1.35
      )
      let rawColor = bool("allowColored", true) ? Int(number(item["color"])) : 0xFFFFFF
      // Missing colors used to become zero (black); keep PiP text readable.
      let rgb = (rawColor & 0xFFFFFF) == 0 ? 0xFFFFFF : rawColor
      let key = "\(text)|\(rgb)|\(size)"
      var label = labels[key]
      if label == nil {
        let color = UIColor(red: CGFloat((rgb >> 16) & 255)/255, green: CGFloat((rgb >> 8) & 255)/255, blue: CGFloat(rgb & 255)/255, alpha: CGFloat(value("opacity", 0.9)))
        let font = UIFont.systemFont(ofSize: CGFloat(size), weight: bool("bold", true) ? .semibold : .regular)
        let fill = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .strokeWidth: 0])
        let border = outline > 0 ? NSAttributedString(string: text, attributes: [
          .font: font, .strokeColor: UIColor.black.withAlphaComponent(CGFloat(value("opacity", 0.9) * 0.85)),
          .strokeWidth: min(6, outline / size * 100)
        ]) : nil
        // Fill last: a combined fill/stroke pass can cover thin CJK stems with
        // the black outline when the system downsizes the composited PiP frame.
        label = Label(fill: fill, outline: border)
        if labels.count >= 1000 { labels.removeAll() }
        labels[key] = label
      }
      guard let label = label else { continue }
      let measured = label.size()
      let order = mode == "bottom" ? Array((0..<count).reversed()) : Array(0..<count)
      guard let lane = order.first(where: { lane in
        if laneEnds[lane] <= time { return true }
        if mode != "scroll" || laneModes[lane] != "scroll" { return false }
        let oldSpeed = (Double(width) + laneWidths[lane]) / span
        let newSpeed = (Double(width) + Double(measured.width)) / span
        let elapsed = time - laneStarts[lane]
        let gap = oldSpeed * elapsed - laneWidths[lane]
        if gap < 12 * scale { return false }
        return newSpeed <= oldSpeed || gap / (newSpeed - oldSpeed) >= span - elapsed
      }) else { continue }
      let duration = mode == "scroll" ? span : 4000
      laneEnds[lane] = time + duration
      laneStarts[lane] = time; laneWidths[lane] = Double(measured.width); laneModes[lane] = mode
      admitted += 1; recent[text] = time
      let age = position - time
      if age < 0 || age >= duration { continue }
      if active.count >= Int(value("maxOnScreen", 60)) { continue }
      let rowY = mode == "bottom"
        ? available - Double(count - lane) * rowHeight
        : topInset + Double(lane) * rowHeight
      let y = rowY + max(0, (rowHeight - Double(measured.height)) / 2)
      active.append(Entry(label: label, width: Double(measured.width), start: time,
                          duration: duration, y: y, scrolling: mode == "scroll"))
    }
    for entry in active {
      let age = position - entry.start
      guard age >= 0 && age < entry.duration else { continue }
      let x = entry.scrolling ? Double(width) - (Double(width) + entry.width) * age / entry.duration : (Double(width) - entry.width) / 2
      entry.label.draw(at: CGPoint(x: x, y: entry.y))
    }
  }
}
