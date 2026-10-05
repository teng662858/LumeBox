import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'danmaku_models.dart';
import 'danmaku_settings.dart';

/// 弹幕叠加层：盖在播放器画面上，按播放时间滚动 / 固定显示弹幕。
///
/// 设计要点：
/// - **吃播放位置而不是自走时钟**：每帧从 [position] 取当前时间，因此拖动进度条、
///   切集、暂停都能立刻对齐（自走时钟会在 seek 后错位）；
/// - **分层轨道**：滚动弹幕按「已占用轨道」分配，避免同屏重叠；顶部 / 底部固定
///   弹幕各占独立轨道，按停留时长换位；
/// - **同屏上限**：超过 [DanmakuSettings.maxOnScreen] 就不再显示新弹幕——弹幕
///   刷屏时优先保证播放流畅；
/// - **暂停时静止**：暂停不推进动画，弹幕停在原处（与主流播放器一致）。
///
/// 这是一个纯渲染组件：不联网、不读库、不认识图源。数据由外层（播放页）喂进来。
class DanmakuOverlay extends StatefulWidget {
  const DanmakuOverlay({
    super.key,
    required this.position,
    required this.playing,
    required this.track,
    required this.settings,
    this.tickInterval = const Duration(milliseconds: 16),
  });

  /// 当前播放位置（每帧变化）。
  final Duration position;

  /// 是否正在播放（暂停时弹幕静止）。
  final bool playing;

  /// 本集弹幕。
  final DanmakuTrack track;

  final DanmakuSettings settings;

  /// 重绘节拍（测试可调大以减少 pump 次数）。
  final Duration tickInterval;

  @override
  State<DanmakuOverlay> createState() => _DanmakuOverlayState();
}

class _DanmakuOverlayState extends State<DanmakuOverlay> {
  /// 屏幕上的弹幕实例（含各自的出现时刻与轨道）。
  final List<_ActiveDanmaku> _active = <_ActiveDanmaku>[];

  /// 已投放到屏幕上的弹幕在 track 里的下标（单调推进，避免重复投放）。
  int _cursor = 0;

  /// 上一次的位置：用于检测「跳转」（seek / 切集）并重置状态。
  Duration _lastPosition = Duration.zero;

  /// 轨道占用情况：轨道序号 → 该轨道上最后一条弹幕的「离开时间」。
  final Map<int, Duration> _scrollLanes = <int, Duration>{};
  final Map<int, Duration> _topLanes = <int, Duration>{};
  final Map<int, Duration> _bottomLanes = <int, Duration>{};

  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(widget.tickInterval, (_) => _onTick());
  }

  @override
  void didUpdateWidget(covariant DanmakuOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 换集 / 换弹幕源：整层重置。
    if (!identical(oldWidget.track, widget.track)) _reset();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  /// 每帧推进：投放新弹幕 + 清理过期弹幕。
  void _onTick() {
    if (!mounted) return;
    final position = widget.position;

    // 跳转检测：位置倒退（seek 回去 / 换集）或大幅前跳 → 重置。
    final delta = position - _lastPosition;
    if (delta.isNegative || delta > const Duration(seconds: 2)) {
      _reset(keepCursorAt: position);
    }
    _lastPosition = position;

    if (!widget.settings.enabled || widget.track.isEmpty) {
      if (_active.isNotEmpty) setState(_active.clear);
      return;
    }

    _spawn(position);
    _expire(position);
    if (mounted) setState(() {});
  }

  /// 重置：清屏、清轨道、把游标对齐到当前时间。
  void _reset({Duration? keepCursorAt}) {
    _active.clear();
    _scrollLanes.clear();
    _topLanes.clear();
    _bottomLanes.clear();
    _cursor = 0;
    if (keepCursorAt != null) {
      // 游标指向「当前时间之后的第一条」：重置后只投放新位置的弹幕。
      final items = widget.track.items;
      var low = 0;
      var high = items.length;
      while (low < high) {
        final mid = (low + high) >> 1;
        if (items[mid].time < keepCursorAt) {
          low = mid + 1;
        } else {
          high = mid;
        }
      }
      _cursor = low;
    }
  }

  /// 投放：把时间窗口内还没上屏的弹幕加进来。
  void _spawn(Duration position) {
    final items = widget.track.items;
    // 只投放「已经到点」的弹幕（不提前显示）。
    while (_cursor < items.length && items[_cursor].time <= position) {
      final item = items[_cursor];
      _cursor++;
      // 太旧的弹幕不补投：seek 之后不该把几分钟前的弹幕一次性糊上来。
      if (position - item.time > const Duration(seconds: 1)) continue;
      if (_active.length >= widget.settings.maxOnScreen) continue;
      final lane = _allocateLane(item, position);
      if (lane == null) continue;
      _active.add(_ActiveDanmaku(item: item, lane: lane, bornAt: item.time));
    }
  }

  /// 清理已经离开屏幕的弹幕，并释放轨道。
  void _expire(Duration position) {
    _active.removeWhere((entry) => entry.isGone(position, widget.settings));
  }

  /// 分配轨道：同一条弹幕按位置类型进不同轨道池。
  int? _allocateLane(DanmakuItem item, Duration position) {
    final lanes = switch (item.mode) {
      DanmakuMode.scroll => _scrollLanes,
      DanmakuMode.top => _topLanes,
      DanmakuMode.bottom => _bottomLanes,
    };
    final needed = item.mode == DanmakuMode.scroll
        ? DanmakuLayout.scrollDuration.inMilliseconds ~/ widget.settings.speedScale
        : DanmakuLayout.fixedDuration.inMilliseconds;

    // 找第一条「上一批已经离开」的轨道。
    for (var lane = 0; lane < DanmakuLayout.maxLanes; lane++) {
      final busyUntil = lanes[lane];
      if (busyUntil == null || busyUntil <= position) {
        lanes[lane] = position + Duration(milliseconds: needed.round());
        return lane;
      }
    }
    return null; // 轨道满了：这条不显示（不硬挤，挤了就重叠）。
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.settings.enabled || _active.isEmpty) {
      return const SizedBox.shrink();
    }
    return IgnorePointer(
      child: CustomPaint(
        painter: _DanmakuPainter(
          entries: List<_ActiveDanmaku>.of(_active),
          position: widget.position,
          settings: widget.settings,
          playing: widget.playing,
        ),
        size: Size.infinite,
      ),
    );
  }
}

/// 弹幕布局常量（渲染层与计时共用的唯一出处）。
class DanmakuLayout {
  DanmakuLayout._();

  /// 滚动弹幕穿越屏幕的基准时长（1x 速度）。
  static const Duration scrollDuration = Duration(seconds: 8);

  /// 固定弹幕（顶 / 底）停留时长。
  static const Duration fixedDuration = Duration(seconds: 4);

  /// 轨道高度（与字号挂钩）。
  static const double laneHeight = 22;

  /// 轨道数上限（防病态配置）。
  static const int maxLanes = 64;
}

/// 屏幕上的一条弹幕。
class _ActiveDanmaku {
  _ActiveDanmaku({required this.item, required this.lane, required this.bornAt});

  final DanmakuItem item;
  final int lane;

  /// 上屏时刻（视频时间轴）。
  final Duration bornAt;

  /// 滚动进度 0..1（0 = 刚进右边缘，1 = 完全离开左边缘）。
  double progress(Duration position, DanmakuSettings settings) {
    final span = DanmakuLayout.scrollDuration.inMilliseconds / settings.speedScale;
    if (span <= 0) return 1;
    final elapsed = (position - bornAt).inMilliseconds.toDouble();
    return (elapsed / span).clamp(0.0, 1.0);
  }

  /// 固定弹幕的剩余停留比例 1..0。
  double fixedRemaining(Duration position) {
    final elapsed = (position - bornAt).inMilliseconds;
    final total = DanmakuLayout.fixedDuration.inMilliseconds;
    return (1 - elapsed / total).clamp(0.0, 1.0);
  }

  bool isGone(Duration position, DanmakuSettings settings) {
    if (item.mode == DanmakuMode.scroll) {
      return progress(position, settings) >= 1.0;
    }
    return fixedRemaining(position) <= 0;
  }
}

/// 弹幕绘制：滚动 / 顶部 / 底部三类，统一描边保证可读。
class _DanmakuPainter extends CustomPainter {
  _DanmakuPainter({
    required this.entries,
    required this.position,
    required this.settings,
    required this.playing,
  });

  final List<_ActiveDanmaku> entries;
  final Duration position;
  final DanmakuSettings settings;
  final bool playing;

  @override
  void paint(Canvas canvas, Size size) {
    final maxHeight = size.height * settings.displayArea;
    final laneCount = (maxHeight / DanmakuLayout.laneHeight).floor().clamp(1, 64);

    for (final entry in entries) {
      final style = DanmakuStyle.of(entry.item, settings);
      final painter = _textPainter(entry.item.text, style);

      double? dx;
      double? dy;
      switch (entry.item.mode) {
        case DanmakuMode.scroll:
          // 从右边缘外进入，滚到左边缘外。
          final progress = entry.progress(position, settings);
          dx = size.width - (size.width + painter.width) * progress;
          dy = entry.lane * DanmakuLayout.laneHeight;
        case DanmakuMode.top:
          dx = (size.width - painter.width) / 2;
          dy = entry.lane * DanmakuLayout.laneHeight;
        case DanmakuMode.bottom:
          dx = (size.width - painter.width) / 2;
          dy = size.height -
              (entry.lane + 1) * DanmakuLayout.laneHeight;
      }

      // 越界（固定弹幕轨道超区）就不画。
      if (dy < 0 || dy + painter.height > size.height) continue;
      // 固定弹幕淡出：最后 25% 时间渐隐。
      final opacity = entry.item.mode == DanmakuMode.scroll
          ? 1.0
          : (entry.fixedRemaining(position) / 0.25).clamp(0.0, 1.0);

      canvas.save();
      if (opacity < 1) {
        canvas.saveLayer(
          Offset.zero & size,
          Paint()..color = Colors.white.withValues(alpha: opacity),
        );
      }
      painter.paint(canvas, Offset(dx, dy));
      if (opacity < 1) canvas.restore();
      canvas.restore();
    }
    // laneCount 只用于诊断：轨道超出可视区时不再分配（在 _allocateLane 里靠 64 上限兜底）。
    assert(laneCount >= 1);
  }

  /// 文本绘制：先描边再填充（浅色画面下也看得清）。
  static TextPainter _textPainter(String text, DanmakuStyle style) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: style.fontSize,
          color: style.color,
          fontWeight: FontWeight.w600,
          shadows: style.strokeWidth > 0
              ? <Shadow>[
                  Shadow(
                    color: Colors.black.withValues(
                      alpha: style.color.a * 0.9,
                    ),
                    blurRadius: style.strokeWidth,
                  ),
                ]
              : null,
        ),
      ),
      textDirection: ui.TextDirection.ltr,
      maxLines: 1,
    )..layout();
    return painter;
  }

  @override
  bool shouldRepaint(covariant _DanmakuPainter oldDelegate) =>
      oldDelegate.position != position ||
      oldDelegate.entries.length != entries.length ||
      oldDelegate.settings != settings;
}
