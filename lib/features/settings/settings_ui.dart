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
    this.searchTargets = const {},
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
  final Map<String, VoidCallback> searchTargets;
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
      radius: 24,
      padding: EdgeInsets.zero,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: <Widget>[
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    (iconColor ?? LumeTheme.accent).withValues(alpha: .16),
                    (iconColor ?? LumeTheme.accent).withValues(alpha: .06),
                  ],
                ),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: (iconColor ?? LumeTheme.accent).withValues(alpha: .09),
                ),
              ),
              child: Center(
                child: LumeIcon(
                  icon,
                  slot: 'settings.entry.$title',
                  label: title,
                  group: '设置',
                  size: 22,
                  color: iconColor ?? LumeTheme.accent,
                ),
              ),
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
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: (MediaQuery.sizeOf(context).width * .22).clamp(
                      48,
                      110,
                    ),
                  ),
                  child: Text(
                    trailingValue!,
                    textAlign: TextAlign.end,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight: FontWeight.w400,
                      fontSize: LumeTypography.bodySize,
                      height: 1.5,
                      color: LumeTheme.textSecondary,
                    ),
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

class SettingsPageIntro extends StatelessWidget {
  const SettingsPageIntro({
    super.key,
    required this.title,
    required this.description,
  });
  final String title, description;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 6, 4, 22),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
            fontSize: 26,
            fontWeight: FontWeight.w700,
            letterSpacing: -.6,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          description,
          style: Theme.of(context).textTheme.bodyMedium
              ?.copyWith(color: LumeTheme.textSecondary, height: 1.6),
        ),
      ],
    ),
  );
}

class SettingsCategory {
  const SettingsCategory(
    this.title,
    this.description,
    this.icon,
    this.children, {
    this.keywords = '',
  });
  final String title, description, keywords;
  final IconData icon;
  final List<Widget> children;
}

class SettingsCategoryPage extends StatelessWidget {
  const SettingsCategoryPage({super.key, required this.category});
  final SettingsCategory category;
  @override
  Widget build(BuildContext context) => GlassScaffold(
    title: category.title,
    effectModule: GlassModule.settings,
    behindBar: true,
    child: ListView(
      padding: GlassScaffold.barInset(context)
          .add(const EdgeInsets.fromLTRB(20, 20, 20, 36)),
      children: [
        SettingsPageIntro(
          title: category.title,
          description: category.description,
        ),
        ...category.children,
      ],
    ),
  );
}

class SettingsHome extends StatefulWidget {
  const SettingsHome({super.key, required this.categories});
  final List<SettingsCategory> categories;
  @override
  State<SettingsHome> createState() => _SettingsHomeState();
}

class _SettingsHomeState extends State<SettingsHome> {
  String query = '';
  void open(SettingsCategory category) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => SettingsCategoryPage(category: category),
    ),
  );
  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final accent = LumeTheme.accent;
    final search = query.trim().toLowerCase();
    final matches = widget.categories
        .where(
          (c) =>
              ('${c.title} ${c.description} ${c.keywords} ${c.children.whereType<SettingsEntryCard>().map((e) => '${e.title} ${e.subtitle} ${e.searchTargets.keys.join(' ')}').join(' ')}')
                  .toLowerCase()
                  .contains(search),
        )
        .toList();
    return ListView(
      padding: GlassScaffold.barInset(context)
          .add(const EdgeInsets.fromLTRB(20, 20, 20, 36)),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(2, 4, 2, 22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '让 LumeBox 更像你',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontSize: 26,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -.6,
                  color: LumeTheme.textPrimary,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '外观、内容与使用习惯，从这里调整。',
                style: TextStyle(
                  fontSize: LumeTypography.bodySize,
                  height: 1.5,
                  color: LumeTheme.textSecondary,
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 20),
          child: Container(
            decoration: BoxDecoration(
              color: dark
                  ? Colors.white.withValues(alpha: .06)
                  : Colors.white.withValues(alpha: .78),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: dark
                    ? Colors.white.withValues(alpha: .08)
                    : Colors.white.withValues(alpha: .9),
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: dark ? .12 : .035),
                  blurRadius: 18,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: TextField(
              key: const ValueKey('settings-search'),
              onChanged: (value) => setState(() => query = value),
              decoration: InputDecoration(
                hintText: '搜索设置',
                prefixIcon: Icon(
                  Icons.search_rounded,
                  color: accent.withValues(alpha: .8),
                ),
                filled: false,
                border: const OutlineInputBorder(
                  borderRadius: BorderRadius.all(Radius.circular(20)),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
        ),
        for (final category in matches) ...[
          _SettingsCategoryCard(
            category: category,
            onTap: () => open(category),
          ),
          if (search.isNotEmpty)
            for (final entry
                in category.children.whereType<SettingsEntryCard>())
              for (final target in entry.searchTargets.entries)
                if (target.key.toLowerCase().contains(search))
                  SettingsEntryCard(
                    icon: entry.icon,
                    title: target.key,
                    subtitle: entry.title,
                    onTap: target.value,
                  ),
          if (search.isNotEmpty)
            for (final entry
                in category.children.whereType<SettingsEntryCard>())
              if (('${entry.title} ${entry.subtitle}').toLowerCase().contains(
                search,
              ))
                entry,
        ],
        if (matches.isEmpty)
          const SettingsNoteCard('没有找到相关设置，试试“主题”“播放”或“缓存”。'),
      ],
    );
  }
}

/// 首页入口使用柔和高光和阴影，保持各分类入口的触控面积与搜索行为。
class _SettingsCategoryCard extends StatelessWidget {
  const _SettingsCategoryCard({required this.category, required this.onTap});

  final SettingsCategory category;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final accent = LumeTheme.accent;
    final radius = BorderRadius.circular(24);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: radius,
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: dark
                ? [
                    Colors.white.withValues(alpha: .11),
                    Colors.white.withValues(alpha: .045),
                  ]
                : [
                    Colors.white.withValues(alpha: .96),
                    Colors.white.withValues(alpha: .72),
                  ],
          ),
          border: Border.all(
            color: Colors.white.withValues(alpha: dark ? .10 : .92),
          ),
        ),
        child: GlassCard(
          radius: 24,
          padding: EdgeInsets.zero,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
            child: Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        accent.withValues(alpha: dark ? .30 : .19),
                        accent.withValues(alpha: dark ? .12 : .07),
                      ],
                    ),
                    border: Border.all(color: accent.withValues(alpha: .12)),
                  ),
                  child: Center(
                    child: LumeIcon(
                      category.icon,
                      slot: 'settings.entry.${category.title}',
                      label: category.title,
                      group: '设置',
                      size: 23,
                      color: accent,
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        category.title,
                        style: TextStyle(
                          fontSize: LumeTypography.titleSize,
                          fontWeight: interfaceFontWeight(
                            context,
                            FontWeight.w600,
                          ),
                          color: LumeTheme.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        category.description,
                        style: TextStyle(
                          fontSize: LumeTypography.descriptionSize,
                          height: 1.4,
                          color: LumeTheme.descriptionColor,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  Icons.chevron_right_rounded,
                  size: 21,
                  color: LumeTheme.muted,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
