import 'package:flutter/material.dart';

import '../../core/reading/reading.dart';
import '../../core/session/section.dart';
import '../../core/source/source.dart';
import '../reading/explore_view.dart';
import '../reading/source_filter_page.dart';
import 'comic_detail_page.dart';

/// 漫画探索页：图源下拉 + 右侧筛选抽屉 + 海报网格。
///
/// 内容获取、图源切换与筛选逻辑全在共享的 [ExploreView] 里，本页只提供漫画的
/// 呈现口径（海报网格）与「点条目进哪一页」。小说板块用的是同一个视图，
/// 区别只在布局与详情页。
class ComicExplorePage extends StatelessWidget {
  const ComicExplorePage({
    super.key,
    required this.library,
    required this.pipeline,
    this.manager,
  });

  final ReadingLibrary library;
  final SectionImagePipeline pipeline;
  final SourceManager? manager;

  @override
  Widget build(BuildContext context) {
    final sourceManager = manager ?? LumeSources.manager(Section.comic);
    return ExploreView(
      // 用户要求：小说 / 漫画两块去掉工具栏里的「排序」（视频板块保留）。
      showSort: false,
      // 顶栏已经有「源管理」：工具条的源下拉里不再重复放一个
      //（换到「探索」为默认页签后，两个同名入口会同屏出现）。
      showSourceManage: false,
      section: Section.comic,
      pipeline: pipeline,
      manager: manager,
      layout: ExploreLayout.grid,
      // 分页跳转筛选（用户口径任务 1，三板块共用）：点「筛选」直接进独立筛选页。
      onOpenFacetFilter: (context, source, currentCategoryId) =>
          openSourceFacetFilter(
        context: context,
        source: source,
        currentCategoryId: currentCategoryId,
      ),
      onOpenItem: (selection) => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ComicDetailPage(
            library: library,
            manager: sourceManager,
            target: ReadingTarget(
              sourceId: selection.sourceId,
              itemId: selection.item.id,
              title: selection.item.title,
              cover: selection.item.cover,
              subtitle: selection.item.subtitle,
            ),
          ),
        ),
      ),
    );
  }
}
