import 'dart:async';
import 'dart:typed_data';

import '../util/lume_log.dart';

/// 画中画帧源：解码器把「一帧」交给它，它负责送到原生侧的
/// `AVSampleBufferDisplayLayer`。
///
/// 为什么要有这一层：iOS 的画中画窗口只认两种内容源——`AVPlayerLayer`（AVPlayer
/// 专用）与 `AVSampleBufferDisplayLayer`（通用，喂 CMSampleBuffer）。MPV / MDK
/// 不是 AVPlayer，所以必须走第二条：内核每解码出一帧，转成 BGRA 字节交到这里，
/// 原生侧再包成 CVPixelBuffer / CMSampleBuffer 上屏。
///
/// 数据流：
/// ```
/// MPV 解码帧（原生） → Dart 取帧（MpvEngine.captureFrame） → 帧泵（本类 + PipFramePump）
///   → 方法通道 lumebox/pip/frames → Swift 帧泵 → AVSampleBufferDisplayLayer
/// ```
///
/// 取帧是**拉取式**的（mpv 的 `screenshot-raw`），不是解码回调：因此画中画激活
/// 期间由 [PipFramePump] 按帧率节拍主动拉，而不是内核主动推。拉不到帧（未加载 /
/// 正在 seek）时如实跳过，[isReady] 与计数反映真实情况。
///
/// 节流：画中画窗口不需要 60fps 全帧率（系统会做插值），默认限制到 30fps 上限，
/// 减少通道序列化与内存拷贝开销——移动端这两项都很贵。
class PipFrameSource {
  PipFrameSource({
    this.maxFramesPerSecond = 30,
    this.maxFrameBytes = 8 * 1024 * 1024,
  });

  /// 送帧上限（超过即丢帧：画中画窗口不是主屏，不追求满帧）。
  final int maxFramesPerSecond;

  /// 单帧字节上限（超大的帧直接丢弃并记日志，避免通道里塞几十 MB）。
  final int maxFrameBytes;

  /// 帧提交端口（由原生通道实现注入；为空表示原生未接入）。
  Future<void> Function(Map<String, Object?> frame)? onFrame;

  DateTime _lastFrameAt = DateTime.fromMillisecondsSinceEpoch(0);
  int _droppedForRate = 0;
  int _droppedForSize = 0;
  int _submitted = 0;

  /// 是否已接上帧端口。
  bool get isReady => onFrame != null;

  /// 已提交帧数（诊断）。
  int get submittedFrames => _submitted;

  /// 因帧率限制丢掉的帧数。
  int get droppedForRate => _droppedForRate;

  /// 因体积超限丢掉的帧数。
  int get droppedForSize => _droppedForSize;

  /// 绑定帧端口。
  void attach(Future<void> Function(Map<String, Object?> frame) sink) {
    onFrame = sink;
  }

  void detach() => onFrame = null;

  /// 提交一帧 BGRA 像素。
  ///
  /// 返回是否真的送出（被节流或超限时返回 false，并计入诊断计数）。
  Future<bool> submitFrame({
    required Uint8List pixels,
    required int width,
    required int height,
    required Duration timestamp,
  }) async {
    final sink = onFrame;
    if (sink == null) return false;

    if (pixels.length > maxFrameBytes) {
      _droppedForSize++;
      LumeLog.warn(
        '[pip] 帧过大已丢弃（${pixels.length} > $maxFrameBytes 字节）',
      );
      return false;
    }

    final now = DateTime.now();
    final minGap = Duration(
      microseconds: (1000000 / maxFramesPerSecond).round(),
    );
    if (now.difference(_lastFrameAt) < minGap) {
      _droppedForRate++;
      return false;
    }
    _lastFrameAt = now;

    await sink(<String, Object?>{
      'width': width,
      'height': height,
      'timestampMs': timestamp.inMilliseconds,
      // 传 Uint8List 而不是 List<int>：方法通道对它走高效二进制编码，
      // 不必逐元素序列化成 JSON 数字数组。
      'pixels': pixels,
    });
    _submitted++;
    return true;
  }

  /// 复位诊断计数（开始新一次画中画时调用）。
  void resetStats() {
    _submitted = 0;
    _droppedForRate = 0;
    _droppedForSize = 0;
    _lastFrameAt = DateTime.fromMillisecondsSinceEpoch(0);
  }

  /// 诊断摘要。
  String describe() =>
      '帧源：${isReady ? '已就绪' : '未接入'} · 已送 $_submitted 帧'
      '${_droppedForRate > 0 ? ' · 限流丢 $_droppedForRate' : ''}'
      '${_droppedForSize > 0 ? ' · 超限丢 $_droppedForSize' : ''}';
}
