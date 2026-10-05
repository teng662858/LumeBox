import 'dart:async';

import 'mpv_engine.dart';
import '../util/lume_log.dart';
import 'pip_frame_source.dart';

/// 画中画帧转发泵：画中画激活期间按节拍从内核取帧并转发。
///
/// 为什么要「泵」而不是回调：mpv 的取帧接口是**拉取式**的（`screenshot-raw`），
/// 不是推流式回调——没有「每解码一帧通知你」这种钩子。因此这里用节拍主动拉，
/// 拉不到就跳过（不阻塞、不重试）。
///
/// 节拍有两个来源，优先用前者：
/// 1. **引擎的帧节拍**（[FrameTickCapable.frameTicks]，由 `time-pos` 驱动）：
///    取帧时刻跟着画面走——暂停即停、播放时与真实帧对齐；
/// 2. **定时器**（兜底）：引擎没有帧节拍能力时按目标帧率定时拉，
///    行为与旧实现一致（暂停时仍会空转，但没有更好的信号可用）。
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

  /// 目标帧率（仅在引擎没有帧节拍能力时用于定时器）。
  final int targetFps;

  Timer? _timer;
  StreamSubscription<void>? _ticks;
  bool _pumping = false;
  int _captureFailures = 0;

  /// 是否处于转发中。
  ///
  /// 与 [isPumping] 的区别：后者看「节拍源在不在」，这个看「这一轮转发是否还有效」。
  /// 一拍跨越多个 await，[stop] 可能落在中间——用这个标志让在飞的那一拍及时收手。
  bool _running = false;

  /// 是否正在转发。
  bool get isPumping => _timer != null || _ticks != null;

  /// 是否用引擎的帧节拍（false 表示退回定时器）。
  bool get isEventDriven => _ticks != null;

  /// 取帧失败次数（诊断）。
  int get captureFailures => _captureFailures;

  /// 开始转发。
  void start() {
    if (isPumping) return;
    frameSource.resetStats();
    _captureFailures = 0;
    _running = true;
    final engine = this.engine;
    if (engine is FrameTickCapable) {
      // 引擎能给帧节拍：跟着画面走（暂停时自然不再取帧）。
      _ticks = (engine as FrameTickCapable).frameTicks.listen(
        (_) => unawaited(_tick()),
        onError: (Object error, StackTrace stackTrace) {
          // 节拍流出错不该让泵停摆：退回定时器。
          LumeLog.warn('[pip] 帧节拍流异常，退回定时器节拍: $error');
          LumeLog.error(error, stackTrace);
          _ticks?.cancel();
          _ticks = null;
          _startTimer();
        },
      );
      LumeLog.info('[pip] 帧转发开始（引擎帧节拍）');
      return;
    }
    _startTimer();
  }

  void _startTimer() {
    if (_timer != null) return;
    // 拉取节拍略快于目标帧率（1.2 倍）：让节流层决定实际送出多少帧，
    // 避免定时器抖动导致实际帧率低于目标。
    final intervalMs = (1000 / (targetFps * 1.2)).round();
    _timer = Timer.periodic(Duration(milliseconds: intervalMs), (_) {
      unawaited(_tick());
    });
    LumeLog.info('[pip] 帧转发开始（定时器节拍，目标 $targetFps fps）');
  }

  /// 停止转发（退出画中画时调用）。
  void stop() {
    _running = false;
    _timer?.cancel();
    _timer = null;
    final ticks = _ticks;
    _ticks = null;
    unawaited(ticks?.cancel());
    LumeLog.info('[pip] 帧转发停止（${frameSource.describe()}）');
  }

  /// 一拍：取帧 → 转发。重入保护：上一拍还没完就跳过这一拍。
  ///
  /// 取帧与转发都是异步的，因此一拍可能在 [stop] 之后才走完。这里在每一步之后
  /// 复查 [_running]：停止后不再往原生送帧（否则退出画中画时还会闪最后一帧，
  /// 甚至往已经拆掉的显示层写数据）。
  Future<void> _tick() async {
    if (_pumping) return;
    _pumping = true;
    try {
      final frame = await engine.captureFrame();
      if (!_running) return;
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
      '帧泵：${isPumping ? '运行中' : '已停止'}'
      '（${isEventDriven ? '帧节拍' : '定时器'}）· ${frameSource.describe()}'
      '${_captureFailures > 0 ? ' · 取帧失败 $_captureFailures' : ''}';
}
