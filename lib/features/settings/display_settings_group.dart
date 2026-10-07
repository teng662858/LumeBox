import 'package:flutter/material.dart';

import '../../core/theme/appearance.dart';
import '../../core/theme/lume_theme.dart';
import '../../shared/widgets/glass_card.dart';

/// 设置页的「显示」分组：外观（亮暗模式）+ 主题色。
///
/// 为什么合成一个分组（用户要求）：这两项都是「App 长什么样」的偏好，原先散在
/// 通用列表里，改起来要找两处。分组标题「显示」，组内两行——外观与主题色。
///
/// 交互与视觉沿用页面既有的一套：卡片用同一份 [GlassCard]，选择弹窗是底部 Sheet
/// 一行一项（与图源切换 / 轨道选择同款），不新造交互。
class DisplaySettingsGroup extends StatelessWidget {
  const DisplaySettingsGroup({super.key, this.showTitle = true});

  /// 是否自带分组标题（嵌进设置页的更大分组时传 false）。
  final bool showTitle;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (showTitle)
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 0, 6, 8),
            child: Text(
            '显示',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: LumeTheme.textSecondary,
            ),
          ),
        ),
        GlassCard(
          radius: 14,
          padding: EdgeInsets.zero,
          child: Column(
            children: <Widget>[
              const _AppearanceRow(),
              Padding(
                padding: const EdgeInsets.only(left: 50),
                child: Divider(
                  height: 1,
                  thickness: 1,
                  color: LumeTheme.divider,
                ),
              ),
              const _AccentRow(),
            ],
          ),
        ),
      ],
    );
  }
}

/// 分组内的一行：图标 + 标题 + 当前值（可带色块）+ 右箭头。
class _DisplayRow extends StatelessWidget {
  const _DisplayRow({
    required this.icon,
    required this.title,
    required this.value,
    required this.onTap,
    this.swatch,
  });

  final IconData icon;
  final String title;

  /// 右侧当前值（如「跟随系统」「紫水晶」）。
  final String value;

  final VoidCallback onTap;

  /// 值左侧的色块（主题色那行用）。
  final Widget? swatch;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: <Widget>[
            Icon(icon, size: 22, color: LumeTheme.textSecondary),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                title,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: LumeTheme.textPrimary,
                ),
              ),
            ),
            if (swatch != null) ...<Widget>[swatch!, const SizedBox(width: 8)],
            Text(
              value,
              style: TextStyle(fontSize: 13, color: LumeTheme.textSecondary),
            ),
            const SizedBox(width: 4),
            Icon(Icons.chevron_right, size: 20, color: LumeTheme.muted),
          ],
        ),
      ),
    );
  }
}

/// 「外观」行：跟随系统 / 浅色 / 深色。
class _AppearanceRow extends StatelessWidget {
  const _AppearanceRow();

  /// 模式 → 展示名（弹窗与行内当前值共用一份）。
  static String labelOf(ThemeMode mode) => switch (mode) {
        ThemeMode.system => '跟随系统',
        ThemeMode.light => '浅色',
        ThemeMode.dark => '深色',
      };

  @override
  Widget build(BuildContext context) {
    final controller = AppearanceController.instance;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => _DisplayRow(
        icon: Icons.brightness_6_outlined,
        title: '外观',
        value: labelOf(controller.mode),
        onTap: () async {
          final picked = await showModalBottomSheet<ThemeMode>(
            context: context,
            backgroundColor: Colors.transparent,
            builder: (_) => OptionSheet<ThemeMode>(
              title: '外观',
              current: controller.mode,
              options: const <ThemeMode>[
                ThemeMode.system,
                ThemeMode.light,
                ThemeMode.dark,
              ],
              labelOf: labelOf,
            ),
          );
          if (picked == null) return;
          controller.apply(controller.settings.copyWith(mode: picked));
        },
      ),
    );
  }
}

/// 「主题色」行：11 种主色，点击弹出列表（当前项打勾 + 色块）。
class _AccentRow extends StatelessWidget {
  const _AccentRow();

  @override
  Widget build(BuildContext context) {
    final controller = AppearanceController.instance;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        // 色块按当前亮度取色（深色主题下主色会提亮，小圆点也要跟着）。
        final brightness = Theme.of(context).brightness;
        return _DisplayRow(
          icon: Icons.palette_outlined,
          title: '主题色',
          value: controller.accent.label,
          swatch: AccentDot(color: controller.accent.colorFor(brightness)),
          onTap: () async {
            final picked = await showModalBottomSheet<ThemeAccent>(
              context: context,
              backgroundColor: Colors.transparent,
              builder: (_) => OptionSheet<ThemeAccent>(
                title: '主题色',
                current: controller.accent,
                options: ThemeAccent.values,
                labelOf: (accent) => accent.label,
                swatchOf: (accent) => accent.colorFor(brightness),
              ),
            );
            if (picked == null) return;
            controller.apply(controller.settings.copyWith(accent: picked));
          },
        );
      },
    );
  }
}

/// 主题色小圆点。
class AccentDot extends StatelessWidget {
  const AccentDot({super.key, required this.color, this.size = 14});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: LumeTheme.hairline),
      ),
    );
  }
}

/// 通用选择弹窗：底部 Sheet + 一行一项 + 当前项打勾（主题色项多一个色块）。
///
/// 外观与主题色共用它；再往后的单选设置也可以直接复用，不必各写一个弹窗。
class OptionSheet<T> extends StatelessWidget {
  const OptionSheet({
    super.key,
    required this.title,
    required this.current,
    required this.options,
    required this.labelOf,
    this.swatchOf,
  });

  final String title;
  final T current;
  final List<T> options;
  final String Function(T option) labelOf;

  /// 可选的色块（主题色列表用它）。
  final Color Function(T option)? swatchOf;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      child: DecoratedBox(
        decoration: LumeTheme.background,
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    title,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: LumeTheme.textPrimary,
                    ),
                  ),
                ),
              ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: <Widget>[
                    for (final option in options)
                      ListTile(
                        dense: true,
                        leading: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            Icon(
                              option == current
                                  ? Icons.check_circle
                                  : Icons.circle_outlined,
                              size: 20,
                              color: option == current
                                  ? LumeTheme.accent
                                  : LumeTheme.muted,
                            ),
                            if (swatchOf != null) ...<Widget>[
                              const SizedBox(width: 12),
                              AccentDot(color: swatchOf!(option)),
                            ],
                          ],
                        ),
                        title: Text(
                          labelOf(option),
                          style: TextStyle(color: LumeTheme.textPrimary),
                        ),
                        onTap: () => Navigator.of(context).pop(option),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}
