import 'package:lume_box/shared/widgets/lume_icon.dart';
import 'package:flutter/material.dart';

import '../../core/theme/lume_theme.dart';
import '../../shared/widgets/glass_card.dart';

/// 设置模块统一的脚注颜色（用户指定 #8E8E93）。
///
/// 说明文字不该和设置项抢注意力：字号比正文小一档、颜色降到中性灰。
const Color settingsNoteColor = Color(0xFF8E8E93);

/// 设置页的分组标题（个性与界面 / 阅读与播放 / …）。
class SettingsGroupTitle extends StatelessWidget {
  const SettingsGroupTitle(
    this.text, {
    super.key,
    this.topPadding = 10,
    this.bottomPadding = 8,
  });

  final String text;
  final double topPadding;
  final double bottomPadding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(6, topPadding, 6, bottomPadding),
      child: Text(
        text,
        style: TextStyle(
          fontSize: LumeTypography.sectionTitleSize,
          fontWeight: interfaceFontWeight(context, FontWeight.w600),
          height: 1.5,
          color: LumeTheme.textPrimary,
        ),
      ),
    );
  }
}

/// 统一设置项卡片。
///
/// 排版口径（用户要求，所有设置页共用）：
/// - 图标 22，图标与文字之间固定 12px；
/// - 卡片内边距固定 16 / 14，不随标题、副标题有没有而变高变矮；
/// - 右侧当前值靠右，末尾统一箭头。
class SettingsEntryCard extends StatelessWidget {
  const SettingsEntryCard({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    required this.onTap,
    this.trailingValue,
    this.trailing,
    this.showChevron = true,
    this.marginBottom = 10,
    this.iconColor,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback? onTap;

  /// 行尾的当前值（可空）。
  final String? trailingValue;

  /// 自定义行尾控件（开关 / 进度圈等）。给了它就不再画「值 + 箭头」。
  final Widget? trailing;

  final bool showChevron;
  final double marginBottom;

  /// 图标颜色；默认中性灰（线条风格）。
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    final card = GlassCard(
      radius: 14,
      padding: EdgeInsets.zero,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: <Widget>[
            LumeIcon(
              icon,
              slot: 'settings.entry.$title',
              label: title,
              group: '设置',
              size: 22,
              color: iconColor ?? LumeTheme.textSecondary,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: LumeTypography.titleSize,
                      fontWeight: interfaceFontWeight(context, FontWeight.w600),
                      color: LumeTheme.textPrimary,
                    ),
                  ),
                  if (subtitle != null) ...<Widget>[
                    const SizedBox(height: 4),
                    Text(
                      subtitle!,
                      style: TextStyle(
                        fontWeight: FontWeight.w400,
                        fontSize: LumeTypography.descriptionSize,
                        height: 1.5,
                        color: LumeTheme.descriptionColor,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (trailing != null)
              trailing!
            else ...<Widget>[
              if (trailingValue != null)
                Text(
                  trailingValue!,
                  textAlign: TextAlign.end,
                  style: TextStyle(
                    fontWeight: FontWeight.w400,
                    fontSize: LumeTypography.bodySize,
                    height: 1.5,
                    color: LumeTheme.textSecondary,
                  ),
                ),
              if (showChevron) ...<Widget>[
                const SizedBox(width: 4),
                LumeIcon(
                  Icons.chevron_right,
                  slot: 'settings_ui.2',
                  size: 20,
                  color: LumeTheme.muted,
                ),
              ],
            ],
          ],
        ),
      ),
    );
    if (marginBottom <= 0) return card;
    return Padding(
      padding: EdgeInsets.only(bottom: marginBottom),
      child: card,
    );
  }
}

/// 页面底部的说明文字：11px、#8E8E93，不抢设置项的注意力。
class SettingsFooterNote extends StatelessWidget {
  const SettingsFooterNote(
    this.text, {
    super.key,
    this.padding = const EdgeInsets.fromLTRB(4, 4, 4, 8),
    this.textAlign = TextAlign.start,
  });

  final String text;
  final EdgeInsetsGeometry padding;
  final TextAlign textAlign;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Text(
        text,
        textAlign: textAlign,
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w400,
          height: 1.5,
          color: settingsNoteColor,
        ),
      ),
    );
  }
}

/// 带玻璃底板的说明卡（内容复杂、需要和背景隔开时用）。
class SettingsNoteCard extends StatelessWidget {
  const SettingsNoteCard(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      radius: 14,
      padding: const EdgeInsets.all(14),
      child: SettingsFooterNote(text, padding: EdgeInsets.zero),
    );
  }
}
