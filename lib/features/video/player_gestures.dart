import 'package:flutter/foundation.dart';

/// 播放器手势的纯逻辑：把「一次拖拽」翻译成亮度 / 音量 / 进度的变化。
///
/// 为什么要抽出来：手势的业务规则（左侧调亮度、右侧调音量、水平拖进度、
/// 长按倍速）全是可以单独验证的算术，混在 widget 里就只能靠模拟手势去测，
/// 既慢又脆。这里保持**纯函数 + 不可变状态**，widget 只负责把触摸事件喂进来。
///
/// 三条规则（与主流播放器一致）：
/// - **左侧上下滑 = 亮度**，右侧上下滑 = 音量：分区按首次按下的 x 坐标决定，
///   拖到另一侧也不会「改主意」（中途换功能最让人恼火）；
/// - **水平拖 = 调进度**：位移阈值大于垂直位移时才判定为调进度；
/// - **长按 = 倍速**：按下不动超过阈值时间即临时加速，松手恢复。
class PlayerGesturePolicy {
  const PlayerGesturePolicy._();

  /// 长按触发临时倍速的时间阈值。
  static const Duration longPressDelay = Duration(milliseconds: 400);

  /// 判定「水平拖」的最小位移（避免手抖被当成调进度）。
  static const double minHorizontalDrag = 24;

  /// 判定「垂直拖」的最小位移。
  static const double minVerticalDrag = 12;

  /// 一次拖拽的意图。
  static PlayerGestureIntent intentFor({
    required double dx,
    required double dy,
    required double startFraction,
  }) {
    // 横向位移占优 → 调进度。
    if (dx.abs() > dy.abs() && dx.abs() >= minHorizontalDrag) {
      return PlayerGestureIntent.seek;
    }
    if (dy.abs() >= minVerticalDrag) {
      // 起始点在屏幕左半边 → 亮度；右半边 → 音量。
      return startFraction < 0.5
          ? PlayerGestureIntent.brightness
          : PlayerGestureIntent.volume;
    }
    return PlayerGestureIntent.none;
  }

  /// 垂直滑动 → 数值增量。
  ///
  /// 口径：**向上滑增大**（与系统音量面板一致），整屏高度对应 100% 变化，
  /// 因此「滑过半个屏幕」约改变 50%——既不过于灵敏，也不用滑好几次。
  static double applyVerticalDelta({
    required double startValue,
    required double dy,
    required double height,
  }) {
    if (height <= 0) return startValue;
    return (startValue - dy / height).clamp(0.0, 1.0);
  }

  /// 水平滑动 → 目标位置。
  ///
  /// 口径：整屏宽度对应「可视进度窗口」，默认 90 秒——比按总时长比例更符合直觉
  /// （长视频里按比例滑一下会跳几十分钟）。
  static Duration applyHorizontalDelta({
    required Duration startPosition,
    required Duration duration,
    required double dx,
    required double width,
    Duration window = const Duration(seconds: 90),
  }) {
    if (width <= 0 || duration <= Duration.zero) return startPosition;
    final deltaMs = (dx / width * window.inMilliseconds).round();
    final target = startPosition + Duration(milliseconds: deltaMs);
    if (target.isNegative) return Duration.zero;
    return target > duration ? duration : target;
  }

  /// 长按倍速的取值：在用户设置倍速的基础上临时提升。
  static double boostSpeed(double baseSpeed) {
    // 已经是快放就不再叠（3x 上再叠会失真到没法听）。
    if (baseSpeed >= 2.5) return baseSpeed;
    return (baseSpeed * 2).clamp(1.0, 3.0);
  }

  /// 手势提示文案（松手前显示在屏幕上）。
  static String describe(
    PlayerGestureIntent intent, {
    double? value,
    Duration? position,
    double? speed,
  }) {
    switch (intent) {
      case PlayerGestureIntent.brightness:
        return '亮度 ${((value ?? 0) * 100).round()}%';
      case PlayerGestureIntent.volume:
        return '音量 ${((value ?? 0) * 100).round()}%';
      case PlayerGestureIntent.seek:
        return _clock(position ?? Duration.zero);
      case PlayerGestureIntent.boost:
        return '${(speed ?? 1).toStringAsFixed(1)}x 快进';
      case PlayerGestureIntent.none:
        return '';
    }
  }

  static String _clock(Duration value) {
    final total = value.inSeconds;
    final hours = total ~/ 3600;
    final minutes = (total % 3600) ~/ 60;
    final seconds = total % 60;
    final mm = minutes.toString().padLeft(hours > 0 ? 2 : 1, '0');
    final ss = seconds.toString().padLeft(2, '0');
    return hours > 0 ? '$hours:$mm:$ss' : '$mm:$ss';
  }
}

/// 手势意图。
enum PlayerGestureIntent {
  /// 还没判定出来（位移太小）。
  none('none', '无'),

  /// 左侧上下滑：亮度。
  brightness('brightness', '亮度'),

  /// 右侧上下滑：音量。
  volume('volume', '音量'),

  /// 水平拖：调进度。
  seek('seek', '进度'),

  /// 长按：临时倍速。
  boost('boost', '快进');

  const PlayerGestureIntent(this.id, this.label);

  final String id;
  final String label;
}

/// 一次手势的进行态（不可变；widget 每帧替换）。
@immutable
class PlayerGestureState {
  const PlayerGestureState({
    this.intent = PlayerGestureIntent.none,
    this.brightness = 1.0,
    this.volume = 1.0,
    this.seekTarget,
    this.boosting = false,
    this.active = false,
  });

  final PlayerGestureIntent intent;

  /// 当前亮度（0..1）。真实亮度受平台能力限制（见播放页说明）。
  final double brightness;

  /// 当前音量（0..1）。
  final double volume;

  /// 调进度时的目标位置；非进度手势为 null。
  final Duration? seekTarget;

  /// 是否处于长按快进中。
  final bool boosting;

  /// 是否正在手势中（用于显示提示浮层）。
  final bool active;

  static const PlayerGestureState idle = PlayerGestureState();

  PlayerGestureState copyWith({
    PlayerGestureIntent? intent,
    double? brightness,
    double? volume,
    Duration? seekTarget,
    bool? boosting,
    bool? active,
    bool clearSeekTarget = false,
  }) {
    return PlayerGestureState(
      intent: intent ?? this.intent,
      brightness: brightness ?? this.brightness,
      volume: volume ?? this.volume,
      seekTarget: clearSeekTarget ? null : (seekTarget ?? this.seekTarget),
      boosting: boosting ?? this.boosting,
      active: active ?? this.active,
    );
  }

  /// 提示文案（无手势时为空）。
  String get hint {
    if (!active) return '';
    return PlayerGesturePolicy.describe(
      intent,
      value: intent == PlayerGestureIntent.brightness ? brightness : volume,
      position: seekTarget,
      speed: null,
    );
  }
}
