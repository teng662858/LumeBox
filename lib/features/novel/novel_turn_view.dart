import 'package:flutter/material.dart';

import 'novel_page_painter.dart';

/// 翻页视图：拖拽 → 连续页码 → 变形绘制。三种分页模式共用同一套手势与动画。
///
/// 三种模式只在「谁在动」上不同，几何上一以贯之：
/// - 底板 = 较早那页（`floor(位置)`），到达的那张纸 = 较晚那页；
/// - 连续位置 `pos ∈ [-1, pageCount]`，`t = pos - floor(pos)`：
///   平移 = 两页同移，覆盖 = 只有新页移动，Curl = 新页从右缘铺进来并卷边；
/// - 停在整数位置时 `t = 0`，屏幕上只有底板一页，与静态渲染完全一致。
///
/// 手势与动画收在这里，页码语义留给外层（阅读器）：拖动结束才回调
/// [onIndexChanged]，因此进度落库、预加载窗口都不必跟着每一帧抖动。
class NovelTurnView extends StatefulWidget {
  const NovelTurnView({
    super.key,
    required this.mode,
    required this.pageCount,
    required this.index,
    required this.buildPage,
    required this.onIndexChanged,
    this.onBeyondStart,
    this.onBeyondEnd,
  });

  /// 翻页模式，必须是 [NovelTurnMode.isPaged] 的分页模式。
  final NovelTurnMode mode;

  final int pageCount;

  /// 当前页（整数）。
  final int index;

  /// 页画笔工厂。索引可能落在 `-1` 与 `pageCount`（越界一页）：
  /// 外层据此给出「已是第一页 / 最后一页」的提示页。
  final NovelPagePainter Function(int index) buildPage;

  /// 停在新的整数页时回调。
  final ValueChanged<int> onIndexChanged;

  /// 在第一页继续往后翻（通常是切到上一章）。
  final VoidCallback? onBeyondStart;

  /// 在最后一页继续往前翻（通常是切到下一章）。
  final VoidCallback? onBeyondEnd;

  @override
  State<NovelTurnView> createState() => NovelTurnViewState();
}

/// 公开 State：阅读器用它做程序化翻页（点按区域、工具栏按钮）。
class NovelTurnViewState extends State<NovelTurnView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 240),
  );
  Animation<double>? _tween;

  /// 连续页码。整数即静止，小数即正在翻。
  double _position = 0;

  @override
  void initState() {
    super.initState();
    _position = widget.index.toDouble();
    _animation.addListener(() {
      final tween = _tween;
      if (tween == null) return;
      setState(() => _position = tween.value);
    });
    _animation.addStatusListener((status) {
      if (status != AnimationStatus.completed) return;
      final settled = _position.roundToDouble();
      setState(() => _position = settled);
      widget.onIndexChanged(settled.round());
    });
  }

  @override
  void didUpdateWidget(NovelTurnView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 外部换页（切章、跳章、恢复进度）时把位置对齐过去。
    if (oldWidget.index != widget.index ||
        oldWidget.pageCount != widget.pageCount) {
      _animation.stop();
      _position = widget.index.toDouble();
    }
  }

  @override
  void dispose() {
    _animation.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------------ 对外

  /// 下一页（末页继续翻则切下一章）。
  void next() {
    if (_position.round() >= widget.pageCount - 1) {
      widget.onBeyondEnd?.call();
      return;
    }
    _animateTo(_position.roundToDouble() + 1);
  }

  /// 上一页（首页继续翻则切上一章）。
  void previous() {
    if (_position.round() <= 0) {
      widget.onBeyondStart?.call();
      return;
    }
    _animateTo(_position.roundToDouble() - 1);
  }

  /// 直接跳到某页（目录、进度恢复）。
  void jumpTo(int index) {
    final target = index.clamp(0, widget.pageCount - 1).toDouble();
    _animation.stop();
    setState(() => _position = target);
  }

  // ------------------------------------------------------------------ 手势

  void _onDragUpdate(DragUpdateDetails details, double width) {
    if (width <= 0) return;
    setState(() {
      _position = (_position - details.delta.dx / width)
          .clamp(-1.0, widget.pageCount.toDouble());
    });
  }

  void _onDragEnd(DragEndDetails details, double width) {
    final velocity = details.velocity.pixelsPerSecond.dx;
    var target = _position.roundToDouble();
    if (velocity.abs() > 380) {
      // 甩动：按方向至少翻一页。
      target = velocity < 0
          ? (_position + 1).floorToDouble()
          : (_position - 1).ceilToDouble();
    }
    if (target < 0) {
      widget.onBeyondStart?.call();
      target = 0;
    } else if (target > widget.pageCount - 1) {
      widget.onBeyondEnd?.call();
      target = (widget.pageCount - 1).toDouble();
    }
    _animateTo(target);
  }

  void _animateTo(double target) {
    if ((target - _position).abs() < 0.01) {
      setState(() => _position = target);
      widget.onIndexChanged(target.round());
      return;
    }
    final distance = (target - _position).abs();
    _animation.duration = Duration(
      milliseconds: (180 + 140 * distance).clamp(180, 420).round(),
    );
    _tween = Tween<double>(begin: _position, end: target).animate(
      CurvedAnimation(parent: _animation, curve: Curves.easeOutCubic),
    );
    _animation.forward(from: 0);
  }

  // ------------------------------------------------------------------ 构建

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: (_) => _animation.stop(),
          onHorizontalDragUpdate: (details) =>
              _onDragUpdate(details, size.width),
          onHorizontalDragEnd: (details) => _onDragEnd(details, size.width),
          onHorizontalDragCancel: () =>
              _animateTo(_position.roundToDouble()),
          child: _buildStage(size),
        );
      },
    );
  }

  Widget _buildStage(Size size) {
    final lower = _position.floor();
    final t = _position - lower;
    switch (widget.mode) {
      case NovelTurnMode.curl:
        return CustomPaint(
          size: size,
          painter: NovelCurlPainter(
            base: widget.buildPage(lower),
            moving: widget.buildPage(lower + 1),
            progress: t,
          ),
        );
      case NovelTurnMode.slide:
        return Stack(
          fit: StackFit.expand,
          children: <Widget>[
            if (t < 1)
              Transform.translate(
                offset: Offset(-t * size.width, 0),
                child: _page(lower),
              ),
            if (t > 0)
              Transform.translate(
                offset: Offset((1 - t) * size.width, 0),
                child: _page(lower + 1),
              ),
          ],
        );
      case NovelTurnMode.cover:
        return Stack(
          fit: StackFit.expand,
          children: <Widget>[
            _page(lower),
            if (t > 0)
              Transform.translate(
                offset: Offset((1 - t) * size.width, 0),
                child: Stack(
                  fit: StackFit.expand,
                  children: <Widget>[
                    _page(lower + 1),
                    // 新页压在旧页上：给个左缘阴影，纸的层次才出来。
                    const CustomPaint(
                      painter: NovelEdgeShadowPainter(width: 16, onLeft: true),
                    ),
                  ],
                ),
              ),
          ],
        );
      case NovelTurnMode.scroll:
        // 连续滚动模式不经过本视图。
        return _page(lower);
    }
  }

  Widget _page(int index) => CustomPaint(
        painter: widget.buildPage(index),
        size: Size.infinite,
      );
}
