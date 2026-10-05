import AVFoundation
import CoreMedia
import CoreVideo
import Flutter
import UIKit

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

  private var pool: CVPixelBufferPool?
  private var poolWidth = 0
  private var poolHeight = 0

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
    displayLayer = layer
    return true
  }

  /// 释放显示层与缓冲池（退出画中画 / 页面销毁时调用）。
  func teardown() {
    displayLayer?.flushAndRemoveImage()
    displayLayer = nil
    pool = nil
    poolWidth = 0
    poolHeight = 0
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
    guard ensureDisplayLayer(), let layer = displayLayer else { return false }
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

    guard let sample = makeSampleBuffer(from: buffer, timestampMs: timestampMs) else {
      droppedFrames += 1
      return false
    }

    // 层可能处于「需要重启」状态（切后台回来常见）：先 flush 再入队。
    if layer.status == .failed {
      layer.flush()
    }
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
      presentationTimeStamp: CMTime(value: CMTimeValue(timestampMs), timescale: 1000),
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
