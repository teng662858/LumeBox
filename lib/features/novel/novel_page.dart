import 'package:flutter/material.dart';

import '../../core/reading/reading.dart';
import '../../core/session/section.dart';
import '../../core/source/source.dart';
import '../../core/util/lume_log.dart';
import '../../shared/widgets/glass_card.dart';
import '../../shared/widgets/notice_card.dart';
import '../../shared/widgets/state_view.dart';
import '../reading/reading_hub_page.dart';
import 'novel_explore_page.dart';
import 'novel_shelf_page.dart';

/// 小说板块（Phase2）：书架 / 探索两个页签。
///
/// 与漫画板块同一套骨架（[ReadingHubPage] + [ReadingLibrary]），但拿到的
/// Section 是小说，因此阅读库、缓存目录、图源全部落在 `sections/novel/` 之下，
/// 与漫画互不可见。小说不需要图片缓存（正文是文本），因此不挂缓存管理入口。
class NovelPage extends StatefulWidget {
  const NovelPage({super.key, this.library, this.manager});

  /// 阅读库；为空时按板块打开正式实现（测试可注入）。
  final ReadingLibrary? library;

  /// 图源管理端口；为空时用正式实现。
  final SourceManager? manager;

  @override
  State<NovelPage> createState() => _NovelPageState();
}

class _NovelPageState extends State<NovelPage> {
  ReadingLibrary? _library;
  SectionImagePipeline? _pipeline;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    // 平台边界：没有图源运行时的平台（Android / Windows）按宪法只保留骨架，
    // 连阅读库都不打开——不在这些平台上落业务数据。
    if (!LumeSources.runtimeAvailable) return;
    _boot();
  }

  @override
  void dispose() {
    _pipeline?.dispose();
    // 自己开的阅读库自己关（注入进来的库不代管）：释放 sqlite 句柄与内存，
    // 下次进板块会重新打开同一个库文件，书架与进度照旧。
    if (widget.library == null) ReadingLibrary.close(Section.novel);
    super.dispose();
  }

  Future<void> _boot() async {
    try {
      final library = widget.library ?? await ReadingLibrary.open(Section.novel);
      if (!mounted) return;
      setState(() {
        _library = library;
        _pipeline = SectionImagePipeline(
          cacheDir: library.imageCacheDir,
          memoryBudgetBytes: SectionImagePipeline.thumbnailBudgetBytes,
        );
      });
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
      if (!mounted) return;
      setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!LumeSources.runtimeAvailable) {
      return GlassScaffold(
        title: Section.novel.label,
        child: const SkeletonNotice(),
      );
    }
    final library = _library;
    final pipeline = _pipeline;
    if (_failed) {
      return GlassScaffold(
        title: Section.novel.label,
        child: const NoticeCard(
          title: '阅读存储不可用',
          subtitle: '小说板块的阅读库打不开，请重启应用后重试',
        ),
      );
    }
    if (library == null || pipeline == null) {
      return GlassScaffold(
        title: Section.novel.label,
        child: const SourceStateView(state: SourceStateKind.loading),
      );
    }
    final manager = widget.manager ?? LumeSources.manager(Section.novel);
    return ReadingHubPage(
      section: Section.novel,
      shelf: NovelShelfPage(
        library: library,
        pipeline: pipeline,
        manager: manager,
      ),
      explore: NovelExplorePage(
        library: library,
        pipeline: pipeline,
        manager: widget.manager,
      ),
    );
  }
}
