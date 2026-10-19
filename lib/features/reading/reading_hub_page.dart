import 'package:lume_box/shared/widgets/lume_icon.dart';

import '../../shared/widgets/subscription_status_icon.dart';

import 'package:flutter/material.dart';

import '../../core/session/section.dart';
import '../../core/source/source.dart';
import '../../shared/widgets/glass_card.dart';
import '../source/source_subscription_page.dart';
import '../source/source_section_page.dart';

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
    this.onFavorites,
    this.manager,
    this.onSubscriptionsClosed,
  });

  final Section section;

  /// 书架页签内容。
  final Widget shelf;

  /// 探索页签内容。
  final Widget explore;

  final List<Widget>? actions;
  final VoidCallback? onFavorites;
  final SourceManager? manager;
  final VoidCallback? onSubscriptionsClosed;

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
        effectModule: GlassModule.fromId(section.id),
        // **不随键盘收缩**：内容区（ExploreView）自己让出键盘高度；外层跟着收缩
        // 会把固定工具栏 / 搜索行挤出屏幕（真机反馈过两次「搜索框不见了」）。
        resizeToAvoidBottomInset: false,
        title: section.label,
        actions: [
          if (actions?.isNotEmpty == true) actions!.first,
          const SizedBox(width: 2),
          IconButton(
            tooltip: '收藏',
            icon: const LumeIcon(
              Icons.bookmark_outline,
              slot: 'reading_hub_page.1',
            ),
            onPressed:
                onFavorites ??
                () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => DefaultTabController(
                      length: 2,
                      child: GlassScaffold(
                        effectModule: GlassModule.fromId(section.id),
                        title: '${section.label}收藏',
                        child: shelf,
                      ),
                    ),
                  ),
                ),
          ),
          const SizedBox(width: 2),
          IconButton(
            tooltip: '源管理',
            icon: const LumeIcon(
              Icons.dns_outlined,
              slot: 'reading_hub_page.2',
            ),
            onPressed: () async {
              await Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) =>
                      SourceSectionPage(section: section, manager: manager),
                ),
              );
              if (context.mounted) onSubscriptionsClosed?.call();
            },
          ),
          const SizedBox(width: 2),
          Tooltip(
            message: '订阅',
            child: IconButton(
              icon: SubscriptionStatusIcon(section: section),
              onPressed: () async {
                await Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => SourceSubscriptionPage(
                      section: section,
                      manager: manager,
                      extraActions:
                          actions
                              ?.whereType<IconButton>()
                              .where((action) => action.tooltip == '扩展仓库')
                              .toList() ??
                          const [],
                    ),
                  ),
                );
                if (context.mounted) onSubscriptionsClosed?.call();
              },
            ),
          ),
        ],
        behindBar: true,
        floatingBar: true,
        mergeHomeHeader: true,
        // 顺序与 tabLabels 一一对应：探索在前。
        child: explore,
      ),
    );
  }
}
