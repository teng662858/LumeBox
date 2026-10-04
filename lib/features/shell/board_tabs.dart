import 'package:flutter/material.dart';

import '../../core/theme/lume_theme.dart';

/// 板块页签条：深色玻璃主题下保持低存在感，选中态用白色短下划线表达。
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
      indicatorColor: Colors.white,
      indicatorSize: TabBarIndicatorSize.label,
      indicatorWeight: 2,
      labelColor: Colors.white,
      unselectedLabelColor: LumeTheme.muted,
      labelStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      unselectedLabelStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w400),
      tabs: <Widget>[
        for (final label in labels) Tab(text: label, height: 42),
      ],
    );
  }
}

/// 板块页签外壳：页签条 + 内容区。
///
/// 小说 / 漫画（书架 / 探索）与视频（浏览 / 播放）共用同一套排布，四个板块的
/// 页签手感一致。需要代码切页签时（视频板块点条目起播后跳到「播放」）传入
/// 自己的 [controller]，其余场景留空即可。
class BoardTabs extends StatelessWidget {
  const BoardTabs({
    super.key,
    required this.labels,
    required this.children,
    this.controller,
  });

  final List<String> labels;
  final List<Widget> children;
  final TabController? controller;

  @override
  Widget build(BuildContext context) {
    final tabs = Column(
      children: <Widget>[
        BoardTabBar(labels: labels, controller: controller),
        Expanded(child: TabBarView(controller: controller, children: children)),
      ],
    );
    if (controller != null) return tabs;
    return DefaultTabController(length: children.length, child: tabs);
  }
}
