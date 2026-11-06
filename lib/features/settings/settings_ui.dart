import 'package:lume_box/shared/widgets/lume_icon.dart';
import 'package:flutter/material.dart';

import '../../core/theme/lume_theme.dart';
import '../../core/session/app_preferences.dart';
import '../../shared/widgets/glass_card.dart';
import '../../shared/widgets/frosted_glass_widget.dart';

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
    this.status,
    this.onTap,
  });
  final VoidCallback? onTap;
  final String title, description, keywords;
  final String Function()? status;
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
          SettingsFooterNote(
            category.description,
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 16),
          ),
          ...settingsGroupedChildren(category.children),
        ],
      ),
    ),
  );
}

class SettingsShortcut {
  const SettingsShortcut(this.id, this.title, this.icon, this.onTap);
  final String id, title;
  final IconData icon;
  final VoidCallback onTap;
}

/// Home is a directory only; settings are mounted on their own routes.
class SettingsHome extends StatefulWidget {
  const SettingsHome({
    super.key,
    required this.categories,
    this.shortcuts = const [],
    this.footer,
  });
  final List<SettingsCategory> categories;
  final List<SettingsShortcut> shortcuts;
  final Widget? footer;
  @override
  State<SettingsHome> createState() => _SettingsHomeState();
}

class _SettingsHomeState extends State<SettingsHome> {
  String query = '';

  List<SettingsShortcut> get selectedShortcuts {
    final ids = AppPreferences.instance.settingsShortcuts;
    final selected = <SettingsShortcut>[
      for (final id in ids)
        for (final item in widget.shortcuts)
          if (item.id == id) item,
    ];
    return selected.isEmpty
        ? widget.shortcuts.take(AppPreferences.maxSettingsShortcuts).toList()
        : selected.take(AppPreferences.maxSettingsShortcuts).toList();
  }

  Future<void> _openCategory(SettingsCategory category) async {
    FocusManager.instance.primaryFocus?.unfocus();
    if (category.onTap != null) {
      category.onTap!();
      return;
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => SettingsCategoryPage(category: category),
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _editShortcuts() async {
    final ids = selectedShortcuts.map((s) => s.id).toList();
    final saved = await showModalBottomSheet<List<String>>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => SizedBox(
          height: MediaQuery.sizeOf(context).height * .7,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 8, 0),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        '编辑常用入口',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '关闭',
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('选择 1–4 项，按选择顺序排列（${ids.length}/4）'),
                ),
              ),
              Expanded(
                child: ListView(
                  children: [
                    for (final item in widget.shortcuts)
                      CheckboxListTile(
                        title: Text(item.title),
                        secondary: Icon(item.icon),
                        value: ids.contains(item.id),
                        onChanged:
                            !ids.contains(item.id) &&
                                ids.length >=
                                    AppPreferences.maxSettingsShortcuts
                            ? null
                            : (value) => update(() {
                                if (value == true) {
                                  ids.add(item.id);
                                } else {
                                  ids.remove(item.id);
                                }
                              }),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: ids.isEmpty
                        ? null
                        : () => Navigator.pop(context, ids),
                    child: const Text('保存'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (saved == null || !mounted) return;
    AppPreferences.instance.settingsShortcuts = List.of(saved);
    AppPreferences.instance.save();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final search = query.trim().toLowerCase();
    final matches = widget.categories
        .where(
          (category) =>
              ('${category.title} ${category.description} ${category.keywords} '
                      '${category.children.whereType<SettingsEntryCard>().map((e) => '${e.title} ${e.subtitle ?? ''} ${e.searchTargets.keys.join(' ')}').join(' ')}')
                  .toLowerCase()
                  .contains(search),
        )
        .toList();
    final shortcuts = selectedShortcuts;
    return ListView(
      key: const PageStorageKey('settings-directory'),
      padding: GlassScaffold.barInset(context)
          .add(const EdgeInsets.fromLTRB(20, 16, 20, 36)),
      children: [
        TextField(
          key: const ValueKey('settings-search'),
          onChanged: (value) => setState(() => query = value),
          decoration: InputDecoration(
            hintText: '搜索设置',
            prefixIcon: const Icon(Icons.search_rounded),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: BorderSide.none,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: BorderSide.none,
            ),
            filled: true,
          ),
        ),
        const SizedBox(height: 16),
        if (search.isEmpty) ...[
          if (shortcuts.isNotEmpty) ...[
            Row(
              children: [
                const Expanded(child: SettingsGroupTitle('常用')),
                TextButton(
                  key: const ValueKey('edit-settings-shortcuts'),
                  onPressed: _editShortcuts,
                  child: const Text('编辑'),
                ),
              ],
            ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < shortcuts.length; i++) ...[
                  if (i > 0) const SizedBox(width: 10),
                  Expanded(
                    child: _SettingsShortcutTile(shortcut: shortcuts[i]),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 18),
          ],
          const SettingsGroupTitle('全部设置'),
        ] else
          const SettingsGroupTitle('搜索结果'),
        for (var start = 0; start < matches.length; start += 4)
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: SettingsGroupCard(
              children: [
                for (final category in matches.skip(start).take(4))
                  _SettingsDirectoryRow(
                    category: category,
                    onTap: () => _openCategory(category),
                  ),
              ],
            ),
          ),
        if (search.isNotEmpty)
          for (final category in matches)
            for (final entry
                in category.children.whereType<SettingsEntryCard>()) ...[
              if ('${entry.title} ${entry.subtitle ?? ''}'
                  .toLowerCase()
                  .contains(search))
                SettingsEntryCard(
                  icon: entry.icon,
                  title: entry.title,
                  subtitle: category.title,
                  onTap: entry.onTap,
                ),
              for (final target in entry.searchTargets.entries)
                if (target.key.toLowerCase().contains(search) &&
                    target.key != entry.title)
                  SettingsEntryCard(
                    icon: entry.icon,
                    title: target.key,
                    subtitle: '${category.title} · ${entry.title}',
                    onTap: target.value,
                  ),
            ],
        if (matches.isEmpty)
          const SettingsNoteCard('没有找到相关设置，试试“主题”“播放”或“缓存”。'),
        if (search.isEmpty && widget.footer != null) widget.footer!,
      ],
    );
  }
}

class _SettingsShortcutTile extends StatelessWidget {
  const _SettingsShortcutTile({required this.shortcut});
  final SettingsShortcut shortcut;
  @override
  Widget build(BuildContext context) => FrostedGlassWidget(
    key: ValueKey('settings-shortcut-glass-${shortcut.id}'),
    nativeGlass: true,
    translucentOverlay: true,
    neutralTint: true,
    interactive: true,
    radius: 18,
    opacity: .16,
    child: InkWell(
      key: ValueKey('settings-shortcut-${shortcut.id}'),
      borderRadius: BorderRadius.circular(18),
      onTap: shortcut.onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 14),
        child: Column(
          children: [
            Icon(shortcut.icon, color: LumeTheme.accent, size: 25),
            const SizedBox(height: 8),
            Text(
              shortcut.title,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14),
            ),
          ],
        ),
      ),
    ),
  );
}

class _SettingsDirectoryRow extends StatelessWidget {
  const _SettingsDirectoryRow({required this.category, required this.onTap});
  final SettingsCategory category;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => InkWell(
    key: ValueKey('settings-category-${category.title}'),
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      child: LayoutBuilder(
        builder: (context, size) {
          final compact =
              size.maxWidth < 320 ||
              MediaQuery.textScalerOf(context).scale(14) > 18;
          final value =
              category.status?.call() ??
              switch (category.title) {
                '阅读与播放' => '阅读器与播放器',
                '内容与订阅' => '源与订阅',
                '导航与首页' => '首页与导航',
                '网络与服务' => '网络与第三方',
                '诊断与关于' => '帮助与版本',
                _ => category.description,
              };
          return Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: settingsCategoryColor(category.title),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Center(
                  child: LumeIcon(
                    category.icon,
                    size: 19,
                    color: Colors.white,
                    slot: 'settings.entry.${category.title}',
                    label: category.title,
                    group: '设置',
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      category.title,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: interfaceFontWeight(
                          context,
                          FontWeight.w600,
                        ),
                      ),
                    ),
                    if (compact)
                      Text(
                        value,
                        style: TextStyle(
                          fontSize: 12,
                          color: LumeTheme.textSecondary,
                        ),
                      ),
                  ],
                ),
              ),
              if (!compact) ...[
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    value,
                    textAlign: TextAlign.end,
                    style: TextStyle(
                      fontSize: 12,
                      color: LumeTheme.textSecondary,
                    ),
                  ),
                ),
              ],
              const SizedBox(width: 6),
              Icon(Icons.chevron_right, size: 18, color: LumeTheme.muted),
            ],
          );
        },
      ),
    ),
  );
}

/// Changes sections in place, keeping settings navigation at three levels.
class SettingsTabBar extends StatefulWidget {
  const SettingsTabBar({
    super.key,
    required this.tabs,
    required this.selected,
    required this.onSelected,
  });
  final List<(String, String)> tabs;
  final String selected;
  final ValueChanged<String> onSelected;
  @override
  State<SettingsTabBar> createState() => _SettingsTabBarState();
}

class _SettingsTabBarState extends State<SettingsTabBar> {
  final keys = <String, GlobalKey>{};
  @override
  void initState() {
    super.initState();
    revealSelection();
  }

  @override
  void didUpdateWidget(SettingsTabBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selected != oldWidget.selected) revealSelection();
  }

  void revealSelection() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final target = keys[widget.selected]?.currentContext;
      if (target != null) Scrollable.ensureVisible(target, alignment: .5);
    });
  }

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    child: Row(
      children: [
        for (final tab in widget.tabs)
          Padding(
            key: keys.putIfAbsent(tab.$1, GlobalKey.new),
            padding: const EdgeInsets.only(right: 8),
            child: ChoiceChip(
              key: ValueKey('settings-tab-${tab.$1}'),
              label: Text(tab.$2),
              selected: widget.selected == tab.$1,
              onSelected: (_) {
                FocusManager.instance.primaryFocus?.unfocus();
                widget.onSelected(tab.$1);
              },
            ),
          ),
      ],
    ),
  );
}

Future<void> showSettingsDetail(BuildContext context, Widget page) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => SizedBox(
        height: MediaQuery.sizeOf(context).height * .94,
        child: page,
      ),
    );
