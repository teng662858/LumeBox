import 'package:flutter/material.dart';

import '../../core/session/section.dart';
import '../../shared/widgets/glass_card.dart';
import '../shell/board_tabs.dart';

/// 板块阅读外壳：书架 / 探索两个页签。
///
/// 只负责骨架，不碰数据：书架与探索两块内容由各板块页提供。两个板块共用它，
/// 是为了让「书架在哪、探索在哪」在所有板块里完全一致——阶段二的阅读体系
/// 对用户应当是同一套肌肉记忆。页签条与内容区的排布走 [BoardTabHeader] +
/// [BoardTabs]，与视频板块的「浏览 / 播放」同款。
///
/// 内容从玻璃顶部栏（标题 + 页签条）下穿过：滚动时列表会滑到磨砂条底下。
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

  /// 页签文案。
  static const List<String> tabLabels = <String>['书架', '探索'];

  @override
  Widget build(BuildContext context) {
    // DefaultTabController 提到最外层：页签条在顶部栏里，内容区在 body 里，
    // 两边要共用同一个控制器；书架空态的「去探索」也从这里取它切页签。
    return DefaultTabController(
      length: tabLabels.length,
      child: GlassScaffold(
        title: section.label,
        actions: actions,
        bottom: const BoardTabHeader(labels: tabLabels),
        behindBar: true,
        child: BoardTabs(children: <Widget>[shelf, explore]),
      ),
    );
  }
}
