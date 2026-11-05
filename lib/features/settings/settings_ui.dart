import 'package:lume_box/shared/widgets/lume_icon.dart';
import 'package:flutter/material.dart';

import '../../core/theme/lume_theme.dart';
import '../../shared/widgets/glass_card.dart';

/// 设置模块统一的脚注颜色（用户指定 #8E8E93）。
///
/// 说明文字不该和设置项抢注意力：字号比正文小一档、颜色降到中性灰。
const Color settingsNoteColor = Color(0xFF8E8E93);

/// A subtle inset separator between independent options in the same card.
class SettingsDivider extends StatelessWidget {
  const SettingsDivider({super.key});

  @override
  Widget build(BuildContext context) => Divider(
    height: 1,
    thickness: 1,
    indent: 16,
    endIndent: 16,
    color: Theme.of(context).brightness == Brightness.dark
        ? Colors.white.withValues(alpha: .10)
        : Colors.black.withValues(alpha: .07),
  );
}

class SettingsGroupCard extends StatelessWidget {
  const SettingsGroupCard({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => GlassCard(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Column(
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) const SettingsDivider(),
          children[i],
        ],
      ],
    ),
  );
}

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

/// Applies the colorful icon treatment only to the global settings hierarchy.
class SettingsIconScope extends InheritedWidget {
  const SettingsIconScope({
    super.key,
    this.color,
    this.grouped = false,
    required super.child,
  });
  final Color? color;
  final bool grouped;
  static SettingsIconScope? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SettingsIconScope>();
  static bool enabled(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SettingsIconScope>() != null;
  @override
  bool updateShouldNotify(SettingsIconScope oldWidget) =>
      color != oldWidget.color || grouped != oldWidget.grouped;
}

// Each action gets its own recognizable glyph. The slot name remains unchanged
// so existing user-selected icons continue to apply.
(IconData, Color)? _settingsEntryIcon(String title) => switch (title) {
  '主题色' => (Icons.palette, Color(0xFF9B51A5)),
  '页面底色' => (Icons.format_color_fill, Color(0xFFB65B83)),
  'App 图标' => (Icons.apps, Color(0xFFAC5C9B)),
  '应用图标库' => (Icons.interests, Color(0xFF8651A6)),
  '原生系统导航' => (Icons.navigation, Color(0xFF347D81)),
  '内容分类显示' => (Icons.visibility, Color(0xFF278A92)),
  '小说设置' => (Icons.menu_book, Color(0xFF7154B8)),
  '漫画设置' => (Icons.auto_stories, Color(0xFF8956B1)),
  '漫画阅读器设置' => (Icons.chrome_reader_mode, Color(0xFF8956B1)),
  'AI 图片超分与上色' => (Icons.auto_fix_high, Color(0xFFAA5C9B)),
  '播放与选集' => (Icons.video_library, Color(0xFF6851C5)),
  '片头片尾' => (Icons.skip_next, Color(0xFF6B70BA)),
  '画面与显示' => (Icons.aspect_ratio, Color(0xFF5675B2)),
  '声音与字幕' => (Icons.closed_caption, Color(0xFF5269B3)),
  '弹幕与匹配' => (Icons.chat_bubble, Color(0xFF9758A7)),
  '手势与外观' => (Icons.touch_app, Color(0xFF8D66AA)),
  '内核与网络' => (Icons.memory, Color(0xFF5968A9)),
  '弹幕服务' => (Icons.forum, Color(0xFFAD6297)),
  '音频播放器' => (Icons.headphones, Color(0xFF7956BD)),
  '继续看／读／听' => (Icons.history, Color(0xFF8265AB)),
  '翻译语言包' => (Icons.language, Color(0xFF478F8B)),
  '全局翻译' => (Icons.translate, Color(0xFF367F92)),
  '源管理' => (Icons.source, Color(0xFF366AAE)),
  '一键导入全部订阅源' => (Icons.playlist_add_circle, Color(0xFF4779B4)),
  '添加与管理源' => (Icons.library_add, Color(0xFF3974B5)),
  '漫画订阅' => (Icons.collections_bookmark, Color(0xFF6A67B6)),
  '视频订阅' => (Icons.subscriptions, Color(0xFF467AB3)),
  '猫源订阅' => (Icons.pets, Color(0xFF9B719C)),
  '一键同步全部订阅' => (Icons.sync, Color(0xFF398C83)),
  '私有 GitHub 订阅' => (Icons.lock, Color(0xFF4D7897)),
  '总订阅导入导出' => (Icons.import_export, Color(0xFF527BA8)),
  'TVBox 聚合配置导入' => (Icons.live_tv, Color(0xFF5289A0)),
  '仓库维护' => (Icons.cloud_upload, Color(0xFF526DA2)),
  '搜索' => (Icons.search, Color(0xFF547EB6)),
  '网络设置' => (Icons.wifi, Color(0xFF9B622C)),
  'TMDB配置' => (Icons.movie, Color(0xFFAC7437)),
  'Bangumi 追番同步' => (Icons.tv, Color(0xFFAA6674)),
  '下载中心' => (Icons.download, Color(0xFF3C885F)),
  '存储与缓存' => (Icons.storage, Color(0xFF387A53)),
  '预载与清理' => (Icons.downloading, Color(0xFF498C76)),
  '缓存管理' => (Icons.cleaning_services, Color(0xFFB05252)),
  '隐私（应用锁）' => (Icons.privacy_tip, Color(0xFF4C8063)),
  '配置备份' => (Icons.backup, Color(0xFF478A88)),
  '问题排查' => (Icons.troubleshoot, Color(0xFF596D89)),
  '使用说明' => (Icons.help, Color(0xFF657C9A)),
  '高级设置' => (Icons.tune, Color(0xFF77708F)),
  '沙箱设置' => (Icons.hourglass_bottom, Color(0xFF8B7694)),
  '调试面板' => (Icons.bug_report, Color(0xFF9A6673)),
  '流畅度采集' => (Icons.speed, Color(0xFF627CA0)),
  '运行日志' => (Icons.receipt_long, Color(0xFF6B8291)),
  '错误报告' => (Icons.assignment, Color(0xFF9B6D71)),
  _ => null,
};

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
    final style = SettingsIconScope.enabled(context)
        ? _settingsEntryIcon(title)
        : null;
    final scope = SettingsIconScope.of(context);
    final tint = scope?.color ?? style?.$2 ?? iconColor ?? LumeTheme.accent;
    final content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: <Widget>[
          Container(
            width: scope == null ? 42 : 30,
            height: scope == null ? 42 : 30,
            decoration: style == null
                ? BoxDecoration(
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
                      color: (iconColor ?? LumeTheme.accent).withValues(
                        alpha: .09,
                      ),
                    ),
                  )
                : BoxDecoration(
                    color: tint.withValues(alpha: .12),
                    borderRadius: BorderRadius.circular(9),
                  ),
            child: Center(
              child: LumeIcon(
                style?.$1 ?? icon,
                slot: 'settings.entry.$title',
                label: title,
                group: '设置',
                size: scope == null ? 22 : 18,
                color: style == null ? (iconColor ?? LumeTheme.accent) : tint,
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
    );
    if (scope?.grouped ?? false) return InkWell(onTap: onTap, child: content);
    final card = GlassCard(
      radius: 24,
      padding: EdgeInsets.zero,
      onTap: onTap,
      child: content,
    );
    if (marginBottom <= 0) return card;
    return Padding(
      padding: EdgeInsets.only(bottom: marginBottom),
      child: card,
    );
  }
}

/// 页面底部的说明文字，随系统字号缩放并适配深色主题。
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
        style: TextStyle(
          fontSize: LumeTypography.descriptionSize,
          fontWeight: FontWeight.w400,
          height: 1.5,
          color: LumeTheme.descriptionColorOf(Theme.of(context).brightness),
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
            fontSize: LumeTypography.displaySmallSize,
            fontWeight: interfaceFontWeight(context, FontWeight.w700),
            height: 1.25,
            color: LumeTheme.textPrimary,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          description,
          style: Theme.of(context).textTheme.bodyMedium
              ?.copyWith(color: LumeTheme.textSecondary, height: 1.5),
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

Color settingsCategoryColor(String title) => switch (title) {
  '阅读与播放' || '漫画设置' => const Color(0xFF6851C5),
  '内容与订阅' => const Color(0xFF366AAE),
  '个性与界面' => const Color(0xFF9955A0),
  '导航与首页' => const Color(0xFF347D81),
  '存储与安全' => const Color(0xFF387A53),
  '网络与服务' => const Color(0xFF9B622C),
  '诊断与关于' => const Color(0xFF596D89),
  _ => LumeTheme.accent,
};
List<Widget> settingsGroupedChildren(List<Widget> children) {
  final result = <Widget>[];
  var entries = <Widget>[];
  void flush() {
    if (entries.isEmpty) return;
    result.add(
      Padding(
        padding: const EdgeInsets.only(bottom: 18),
        child: SettingsGroupCard(children: entries),
      ),
    );
    entries = <Widget>[];
  }

  for (final child in children) {
    if (child is SettingsEntryCard) {
      entries.add(child);
    } else {
      flush();
      result.add(child);
    }
  }
  flush();
  return result;
}

class SettingsCategoryPage extends StatelessWidget {
  const SettingsCategoryPage({super.key, required this.category});
  final SettingsCategory category;
  @override
  Widget build(BuildContext context) => SettingsIconScope(
    color: settingsCategoryColor(category.title),
    grouped: true,
    child: GlassScaffold(
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
          ...settingsGroupedChildren(category.children),
        ],
      ),
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
  String? expanded;
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
        const SettingsPageIntro(
          title: '让 LumeBox 更像你',
          description: '外观、内容与使用习惯，从这里调整。',
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
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                disabledBorder: InputBorder.none,
              ),
            ),
          ),
        ),
        for (final category in matches) ...[
          _SettingsCategoryCard(
            category: category,
            expanded: expanded == category.title,
            onTap: () => setState(() {
              expanded = expanded == category.title ? null : category.title;
            }),
          ),
          if (expanded == category.title)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SettingsIconScope(
                    color: settingsCategoryColor(category.title),
                    grouped: true,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: settingsGroupedChildren(category.children),
                    ),
                  ),
                ],
              ),
            ),
          if (search.isNotEmpty && expanded != category.title)
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
          if (search.isNotEmpty && expanded != category.title)
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
  const _SettingsCategoryCard({
    required this.category,
    required this.onTap,
    required this.expanded,
  });

  final SettingsCategory category;
  final VoidCallback onTap;
  final bool expanded;

  Color _categoryColor() => switch (category.title) {
    '阅读与播放' => const Color(0xFF6851C5),
    '内容与订阅' => const Color(0xFF366AAE),
    '个性与界面' => const Color(0xFF9955A0),
    '导航与首页' => const Color(0xFF347D81),
    '存储与安全' => const Color(0xFF387A53),
    '网络与服务' => const Color(0xFF9B622C),
    '诊断与关于' => const Color(0xFF596D89),
    _ => LumeTheme.accent,
  };

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final accent = _categoryColor();
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
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: accent,
                    boxShadow: [
                      BoxShadow(
                        color: accent.withValues(alpha: dark ? .22 : .18),
                        blurRadius: 10,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Center(
                    child: LumeIcon(
                      category.icon,
                      slot: 'settings.entry.${category.title}',
                      label: category.title,
                      group: '设置',
                      size: 23,
                      color: Colors.white,
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
                  expanded
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
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
