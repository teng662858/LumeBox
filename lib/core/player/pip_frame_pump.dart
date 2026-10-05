import 'dart:async';

import 'mpv_engine.dart';
import '../util/lume_log.dart';
import 'pip_frame_source.dart';

/// 画中画帧转发泵：画中画激活期间按帧率节拍从内核取帧并转发。
///
/// 为什么要「泵」而不是回调：mpv 的取帧接口是**拉取式**的（`screenshot-raw`），
/// 不是推流式回调——没有「每解码一帧通知你」这种钩子。因此这里用定时器按目标
/// 帧率主动拉，拉不到就跳过（不阻塞、不重试）。
///
/// 三条纪律：
/// - **只在画中画激活时跑**：不激活就不拉帧（拉帧有真实开销：mpv 侧要拷贝整帧）；
/// - **拉不到就跳过**：某次取帧返回 null（未加载 / 正在 seek）不报错，下一拍再试；
/// - **失败不冒泡**：任何异常只记日志——画中画是增强功能，绝不能影响播放。
///
/// 帧率由 [PipFrameSource] 的节流统一管（泵按略高于目标帧率的节拍拉，
/// 实际送出的帧仍受节流约束），因此这里不需要重复实现帧率逻辑。
class PipFramePump {
  PipFramePump({
    required this.engine,
    required this.frameSource,
    this.targetFps = 30,
  });

  /// 取帧来源（MPV 引擎）。
  final MpvEngine engine;

  /// 帧出口（节流 + 送原生）。
  final PipFrameSource frameSource;

  /// 目标帧率。
  final int targetFps;

  Timer? _timer;
  bool _pumping = false;
  int _captureFailures = 0;

  /// 是否正在转发。
  bool get isPumping => _timer != null;

  /// 取帧失败次数（诊断）。
  int get captureFailures => _captureFailures;

  /// 开始转发。
  void start() {
    if (_timer != null) return;
    frameSource.resetStats();
    _captureFailures = 0;
    // 拉取节拍略快于目标帧率（1.2 倍）：让节流层决定实际送出多少帧，
    // 避免定时器抖动导致实际帧率低于目标。
    final intervalMs = (1000 / (targetFps * 1.2)).round();
    _timer = Timer.periodic(Duration(milliseconds: intervalMs), (_) {
      unawaited(_tick());
    });
    LumeLog.info('[pip] 帧转发开始（目标 $targetFps fps）');
  }

  /// 停止转发（退出画中画时调用）。
  void stop() {
    _timer?.cancel();
    _timer = null;
    LumeLog.info('[pip] 帧转发停止（${frameSource.describe()}）');
  }

  /// 一拍：取帧 → 转发。重入保护：上一拍还没完就跳过这一拍。
  Future<void> _tick() async {
    if (_pumping) return;
    _pumping = true;
    try {
      final frame = await engine.captureFrame();
      if (frame == null) {
        _captureFailures++;
        return;
      }
      await frameSource.submitFrame(
        // 去掉行距填充：原生侧期望紧密排列的 BGRA。
        pixels: frame.toTightBgra(),
        width: frame.width,
        height: frame.height,
        timestamp: Duration.zero,
      );
    } catch (error, stackTrace) {
      // 单拍失败不中断泵（下一拍继续）。
      LumeLog.warn('[pip] 帧转发单拍失败: $error');
      LumeLog.error(error, stackTrace);
    } finally {
      _pumping = false;
    }
  }

  /// 诊断摘要。
  String describe() =>
      '帧泵：${isPumping ? '运行中' : '已停止'} · ${frameSource.describe()}'
      '${_captureFailures > 0 ? ' · 取帧失败 $_captureFailures' : ''}';
}
