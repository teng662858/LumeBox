import 'package:lume_box/shared/widgets/lume_icon.dart';

import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/shell/shell_settings.dart';
import '../../core/theme/lume_theme.dart';

/// Dock 收起后的左下角悬浮球：三种样式共用同一套位置/手势，只换外观。
///
/// 背景统一走 [BackdropFilter] 毛玻璃：
/// - 灵动箭头：主题渐变 + 白色箭头；
/// - 精致网格：半透明白玻璃 + 主题紫九点；
/// - 极简线条：更透的白玻璃 + 主题紫三横线。
class DockHandleButton extends StatelessWidget {
  const DockHandleButton({
    super.key,
    required this.style,
    this.size = 52,
    this.opacity = 1,
    this.onPressed,
    this.tooltip = '展开导航',
  });

  final DockHandleStyle style;
  final double size;

  /// 空闲态整体透明度（用户口径：不用的时候可以半透明）。
  final double opacity;
  final VoidCallback? onPressed;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final accent = LumeTheme.accent;
    final glass = (dark ? LumeTheme.surface : Colors.white).withValues(
      alpha: dark ? .52 : .64,
    );
    final border = Border.all(
      color: dark
          ? Colors.white.withValues(alpha: .18)
          : Colors.white.withValues(alpha: .82),
    );
    final content = switch (style) {
      DockHandleStyle.arrow => LumeIcon(
        Icons.chevron_right_rounded,
        slot: 'dock_handle_button.1',
        size: size * .58,
        color: LumeTheme.onAccent,
      ),
      DockHandleStyle.grid => LumeIcon(
        Icons.grid_view,
        slot: 'dock.handle.grid',
        label: '收起后的导航把手 · 网格',
        group: '底部导航',
        color: accent,
        size: size * .58,
        fallback: _DotGrid(color: accent),
      ),
      DockHandleStyle.lines => LumeIcon(
        Icons.menu,
        slot: 'dock.handle.lines',
        label: '收起后的导航把手 · 横线',
        group: '底部导航',
        color: accent,
        size: size * .58,
        fallback: _RoundedLines(color: accent),
      ),
    };
    final fill = switch (style) {
      DockHandleStyle.arrow => BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            accent.withValues(alpha: .96),
            accent.withValues(alpha: .68),
          ],
        ),
      ),
      DockHandleStyle.grid => BoxDecoration(
        color: glass,
        shape: BoxShape.circle,
      ),
      DockHandleStyle.lines => BoxDecoration(
        color: glass.withValues(alpha: glass.a * .88),
        shape: BoxShape.circle,
      ),
    };

    return Opacity(
      opacity: opacity,
      child: Tooltip(
        message: tooltip,
        child: SizedBox(
          width: size,
          height: size,
          child: DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: border,
              boxShadow: LumeTheme.floatShadow,
            ),
            child: ClipOval(
              child: BackdropFilter(
                filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                child: DecoratedBox(
                  decoration: fill,
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: onPressed,
                      child: Center(child: content),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DotGrid extends StatelessWidget {
  const _DotGrid({required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      for (var row = 0; row < 3; row++)
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var column = 0; column < 3; column++)
              Padding(
                padding: const EdgeInsets.all(2.4),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                  ),
                  child: const SizedBox(width: 4.6, height: 4.6),
                ),
              ),
          ],
        ),
    ],
  );
}

class _RoundedLines extends StatelessWidget {
  const _RoundedLines({required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      for (var i = 0; i < 3; i++)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 2.2),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(2),
            ),
            child: const SizedBox(width: 20, height: 3.4),
          ),
        ),
    ],
  );
}
