import 'package:flutter/material.dart';

import '../../core/theme/lume_theme.dart';

/// 板块页签条：浅色主题下保持低存在感，选中态用品牌紫短下划线表达。
class BoardTabBar extends StatelessWidget {
  const BoardTabBar({super.key, required this.labels, this.controller});

  /// 页签文案，顺序即展示顺序。
  final List<String> labels;

  /// 外部控制器（需要代码切页签时传入）；为空时用 [DefaultTabController]。
  final TabController? controller;

  @override
  Widget build(BuildContext context) {
    return TabBar(
      controller: controller,
      dividerColor: Colors.transparent,
      indicatorColor: LumeTheme.accent,
      indicatorSize: TabBarIndicatorSize.label,
      indicatorWeight: 2,
      labelColor: LumeTheme.accent,
      unselectedLabelColor: LumeTheme.textSecondary,
      labelStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      unselectedLabelStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w400),
      tabs: <Widget>[
        for (final label in labels) Tab(text: label, height: 42),
      ],
    );
  }
}

/// 顶部栏里的页签条（板块页的「书架 / 探索」「浏览 / 播放」）。
///
/// 页签条放进顶部栏而不是压在内容区上方，是为了让顶部栏是一整条玻璃：
/// 标题 + 页签共用同一层磨砂，内容从它们下面滚过。
/// 用法：`GlassScaffold(bottom: BoardTabHeader(labels: ...), child: BoardTabs(...))`，
/// 两处传同一个 [controller]（或都不传，由 [DefaultTabController] 供给）。
class BoardTabHeader extends StatelessWidget implements PreferredSizeWidget {
  const BoardTabHeader({super.key, required this.labels, this.controller});

  final List<String> labels;
  final TabController? controller;

  /// 页签本体 42 + 下划线 2。
  ///
  /// 46 → 44：配合顶栏工具栏一起上移（用户要求整条顶部导航贴近状态栏），
  /// 去掉的只是多余余量，页签文字与下划线尺寸不变。
  static const double height = 44;

  @override
  Size get preferredSize => const Size.fromHeight(height);

  @override
  Widget build(BuildContext context) =>
      BoardTabBar(labels: labels, controller: controller);
}

/// 板块页签内容区（页签条在顶部栏里，见 [BoardTabHeader]）。
///
/// 内容铺满整屏、从玻璃条下穿过：页面自己的滚动视图按 `GlassScaffold` 注入的
/// MediaQuery 内边距让出首屏顶部即可（不写 padding 的滚动视图自动生效）。
class BoardTabs extends StatelessWidget {
  const BoardTabs({super.key, required this.children, this.controller});

  final List<Widget> children;
  final TabController? controller;

  @override
  Widget build(BuildContext context) {
    return TabBarView(controller: controller, children: children);
  }
}
