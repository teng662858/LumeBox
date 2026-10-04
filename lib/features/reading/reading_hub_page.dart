import 'package:flutter/material.dart';

import '../../core/session/section.dart';
import '../../core/theme/lume_theme.dart';
import '../../shared/widgets/glass_card.dart';

/// 板块阅读外壳：书架 / 探索两个页签。
///
/// 只负责骨架，不碰数据：书架与探索两块内容由各板块页提供。两个板块共用它，
/// 是为了让「书架在哪、探索在哪」在所有板块里完全一致——阶段二的阅读体系
/// 对用户应当是同一套肌肉记忆。
class ReadingHubPage extends StatelessWidget {
  const ReadingHubPage({
    super.key,
    required this.section,
    required this.shelf,
    required this.explore,
    this.actions,
  });

  final Section section;

  /// 书架页签内容。
  final Widget shelf;

  /// 探索页签内容。
  final Widget explore;

  final List<Widget>? actions;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: GlassScaffold(
        title: section.label,
        actions: actions,
        child: Column(
          children: <Widget>[
            const _HubTabs(),
            Expanded(
              child: TabBarView(children: <Widget>[shelf, explore]),
            ),
          ],
        ),
      ),
    );
  }
}

/// 页签条：深色玻璃主题下保持低存在感，选中态用白色短下划线表达。
class _HubTabs extends StatelessWidget {
  const _HubTabs();

  @override
  Widget build(BuildContext context) {
    return const TabBar(
      dividerColor: Colors.transparent,
      indicatorColor: Colors.white,
      indicatorSize: TabBarIndicatorSize.label,
      indicatorWeight: 2,
      labelColor: Colors.white,
      unselectedLabelColor: LumeTheme.muted,
      labelStyle: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      unselectedLabelStyle: TextStyle(fontSize: 15, fontWeight: FontWeight.w400),
      tabs: <Widget>[
        Tab(text: '书架', height: 42),
        Tab(text: '探索', height: 42),
      ],
    );
  }
}
