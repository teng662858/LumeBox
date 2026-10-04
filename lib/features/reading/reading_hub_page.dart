import 'package:flutter/material.dart';

import '../../core/session/section.dart';
import '../../shared/widgets/glass_card.dart';
import '../shell/board_tabs.dart';

/// 板块阅读外壳：书架 / 探索两个页签。
///
/// 只负责骨架，不碰数据：书架与探索两块内容由各板块页提供。两个板块共用它，
/// 是为了让「书架在哪、探索在哪」在所有板块里完全一致——阶段二的阅读体系
/// 对用户应当是同一套肌肉记忆。页签条与内容区的排布走 [BoardTabs]，与视频
/// 板块的「浏览 / 播放」同款。
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
    return GlassScaffold(
      title: section.label,
      actions: actions,
      child: BoardTabs(
        labels: const <String>['书架', '探索'],
        children: <Widget>[shelf, explore],
      ),
    );
  }
}
