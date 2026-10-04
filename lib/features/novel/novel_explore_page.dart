import 'package:flutter/material.dart';

import '../../core/reading/reading.dart';
import '../../core/session/section.dart';
import '../../core/source/source.dart';
import '../reading/explore_view.dart';
import 'novel_detail_page.dart';

/// 小说探索页：图源下拉 + 右侧筛选抽屉 + 条目列表。
///
/// 与漫画探索页共用 [ExploreView]，只有布局（列表）与详情页不同。
class NovelExplorePage extends StatelessWidget {
  const NovelExplorePage({
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
    final sourceManager = manager ?? LumeSources.manager(Section.novel);
    return ExploreView(
      section: Section.novel,
      pipeline: pipeline,
      manager: manager,
      layout: ExploreLayout.list,
      onOpenItem: (selection) => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => NovelDetailPage(
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
