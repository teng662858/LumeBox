import 'package:flutter/material.dart';

import '../../core/session/section.dart';
import '../../shared/widgets/glass_card.dart';
import '../shell/board_tabs.dart';

/// 板块阅读外壳：探索 / 书架两个页签（顺序见 [tabLabels]）。
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

  /// 页签文案（用户要求：**探索在前、书架在后**）。
  ///
  /// 只调换显示先后位置，两个页签的内容、按钮与逻辑都不变；
  /// 视频板块不走这里（它只有【浏览】一个页签，顺序自然不受影响）。
  /// `DefaultTabController` 的初始页签随之落在「探索」上——这正是用户要的
  /// 「打开板块先看探索」。
  static const List<String> tabLabels = <String>['探索', '书架'];

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
        // 顺序与 tabLabels 一一对应：探索在前。
        child: BoardTabs(children: <Widget>[explore, shelf]),
      ),
    );
  }
}
