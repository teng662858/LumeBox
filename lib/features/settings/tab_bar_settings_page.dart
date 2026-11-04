import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/shell/shell_settings.dart';
import '../shell/shell_dock_bar.dart';
import 'liquid_glass_settings_page.dart';

class TabBarSettingsPage extends StatelessWidget {
  const TabBarSettingsPage({super.key, this.controller});
  final ShellSettingsController? controller;
  @override
  Widget build(BuildContext context) => const LiquidGlassSettingsPage();
}

class DockLiquidSettingsPage extends StatelessWidget {
  const DockLiquidSettingsPage({
    super.key,
    required this.controller,
    required this.entries,
  });
  final ShellSettingsController controller;
  final List<ShellDockEntry> entries;
  @override
  Widget build(BuildContext context) => const LiquidGlassSettingsPage();
}

class DockAppearancePreview extends StatefulWidget {
  const DockAppearancePreview({
    super.key,
    this.maxHeight,
    this.reference = false,
    this.solidIcons = false,
    required this.appearance,
    required this.entries,
  });

  final DockAppearance appearance;
  final double? maxHeight;
  final bool reference;
  final bool solidIcons;

  /// 当前可见的页签（顺序与真实 Dock 一致，至少 1 项）。
  final List<ShellDockEntry> entries;

  @override
  State<DockAppearancePreview> createState() => DockAppearancePreviewState();
}

class DockAppearancePreviewState extends State<DockAppearancePreview> {
  String _activeId = 'settings';

  /// 选中项被用户隐藏后，回落到第一个仍可见的页签。
  String get _resolvedActiveId {
    if (widget.entries.isEmpty) return _activeId;
    if (widget.entries.any((entry) => entry.id == _activeId)) return _activeId;
    return widget.entries.first.id;
  }

  @override
  Widget build(BuildContext context) {
    final appearance = widget.appearance;
    // 预览高度跟随「高度 + 正离底距离」增长：150pt 高、100pt 抬高时也能完整
    // 看到胶囊；位置计算与生产底栏共享，并限制在屏幕下沿。
    final previewHeight =
        200.0 +
        (appearance.height - 54).clamp(0, 96) +
        appearance.bottomFor(10);
    return LayoutBuilder(
      builder: (context, constraints) => SizedBox(
        height: math.min(previewHeight, widget.maxHeight ?? previewHeight),
        child: FittedBox(
          fit: BoxFit.contain,
          child: ClipRRect(
            key: const ValueKey('dock-appearance-preview'),
            borderRadius: BorderRadius.circular(16),
            child: SizedBox(
              width: constraints.maxWidth,
              height: previewHeight,
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  const _PreviewPosterWall(),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: ShellDockBar(
                      entries: widget.entries,
                      activeId: _resolvedActiveId,
                      onSelect: (id) {
                        if (id != ShellDockEntry.search.id) {
                          setState(() => _activeId = id);
                        }
                      },
                      appearance: appearance,
                      solidIcons: widget.solidIcons,
                      applyViewPadding: false,
                      bottomMargin: appearance.bottomFor(10),
                    ),
                  ),
                  Positioned(
                    left: 10,
                    top: 10,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: .34),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        child: Text(
                          widget.reference ? '默认参照 · 自绘底栏' : '当前底栏 · 可交互',
                          style: const TextStyle(
                            fontSize: 10,
                            height: 1.2,
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 预览背景：一张由海报拼成的彩色墙，底层再铺细斜纹。
///
/// 斜纹是给毛玻璃「对焦」用的：不模糊时是一根根细线，模糊后融成柔和的
/// 光带，滑块拖到 0 与 15 的差别一眼可见。
class _PreviewPosterWall extends StatelessWidget {
  const _PreviewPosterWall();

  static const List<(List<Color>, String, String)> _posters =
      <(List<Color>, String, String)>[
        (<Color>[Color(0xFF6C5CE7), Color(0xFFA29BFE)], '漫剧', '新番'),
        (<Color>[Color(0xFFFF7675), Color(0xFFFDA085)], '电影', '热映'),
        (<Color>[Color(0xFF00B894), Color(0xFF55EFC4)], '阅读', '连载'),
        (<Color>[Color(0xFF0984E3), Color(0xFF74B9FF)], '短剧', '推荐'),
      ];

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            for (final poster in _posters)
              Expanded(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: poster.$1,
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(10, 12, 10, 10),
                    child: Align(
                      alignment: Alignment.bottomLeft,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            poster.$2,
                            style: TextStyle(
                              fontSize: 22,
                              height: 1.1,
                              fontWeight: FontWeight.w800,
                              color: Colors.white.withValues(alpha: .92),
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            poster.$3,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: Colors.white.withValues(alpha: .64),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
        const Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          height: 104,
          child: CustomPaint(painter: _PreviewStripePainter()),
        ),
        Positioned.fill(
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: <Color>[
                    Colors.transparent,
                    Colors.black.withValues(alpha: .18),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _PreviewStripePainter extends CustomPainter {
  const _PreviewStripePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: .16)
      ..strokeWidth = 2;
    for (var x = -size.height; x < size.width; x += 14) {
      canvas.drawLine(
        Offset(x, size.height),
        Offset(x + size.height, 0),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _PreviewStripePainter oldDelegate) => false;
}
