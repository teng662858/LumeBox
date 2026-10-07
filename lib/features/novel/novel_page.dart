import 'package:flutter/material.dart';

import '../../core/reading/reading.dart';
import '../../core/session/section.dart';
import '../../core/source/source.dart';
import '../../core/util/lume_log.dart';
import '../../shared/widgets/glass_card.dart';
import '../../shared/widgets/notice_card.dart';
import '../../shared/widgets/state_view.dart';
import '../reading/history_sheet.dart';
import '../reading/reading_hub_page.dart';
import '../source/add_source_button.dart';
import '../source/source_section_page.dart';
import '../video/watch_calendar.dart';
import '../video/watch_calendar_page.dart';
import 'novel_detail_page.dart';
import 'novel_explore_page.dart';
import 'novel_shelf_page.dart';

/// 小说板块（Phase2）：书架 / 探索两个页签。
///
/// 与漫画板块同一套骨架（[ReadingHubPage] + [ReadingLibrary]），但拿到的
/// Section 是小说，因此阅读库、缓存目录、图源全部落在 `sections/novel/` 之下，
/// 与漫画互不可见。小说不需要图片缓存（正文是文本），因此不挂缓存管理入口。
class NovelPage extends StatefulWidget {
  const NovelPage({super.key, this.library, this.manager, this.runtimeAvailable});

  /// 阅读库；为空时按板块打开正式实现（测试可注入）。
  final ReadingLibrary? library;

  /// 图源管理端口；为空时用正式实现。
  final SourceManager? manager;

  /// 平台是否提供图源运行时；为空时取 [LumeSources.runtimeAvailable]。
  /// 测试注入 true 即可在非 iOS 平台驱动完整板块交互（与设置页同一口径）。
  final bool? runtimeAvailable;

  @override
  State<NovelPage> createState() => _NovelPageState();
}

class _NovelPageState extends State<NovelPage> {
  ReadingLibrary? _library;
  SectionImagePipeline? _pipeline;
  bool _failed = false;

  /// 图源变更代数：导入新图源后 +1，用它做书架 / 探索的 Key 让两块内容重挂，
  /// 立刻按新的图源列表重新解析（不必等用户切页签）。
  int _revision = 0;

  bool get _runtimeAvailable =>
      widget.runtimeAvailable ?? LumeSources.runtimeAvailable;

  @override
  void initState() {
    super.initState();
    // 平台边界：没有图源运行时的平台（Android / Windows）按宪法只保留骨架，
    // 连阅读库都不打开——不在这些平台上落业务数据。
    if (!_runtimeAvailable) return;
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
    if (!_runtimeAvailable) {
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
      actions: <Widget>[
        // 右上角统一的两枚独立图标（与视频 / 漫画同一套设计）：
        // 📅 追更日历（哪章有更新 / 哪天读过）、⏱️ 历史（底部抽屉）。
        IconButton(
          tooltip: '追更日历',
          icon: const Icon(Icons.calendar_month_outlined),
          onPressed: () => _openCalendar(library, manager),
        ),
        IconButton(
          tooltip: '阅读历史',
          icon: const Icon(Icons.history),
          onPressed: () => _openHistory(library),
        ),
        // 右上角「图源管理」：本板块已导入图源的统一入口（启用 / 禁用 /
        // 重命名 / 导出 / 删除）。与全局设置的图源总管理不是一回事。
        IconButton(
          tooltip: '源管理',
          icon: const Icon(Icons.source_outlined),
          onPressed: _manageSources,
        ),
        // 右上角统一的「+」添加图源：本地文件 / 订阅链接，只写小说板块。
        AddSourceButton(
          section: Section.novel,
          manager: widget.manager,
          onImported: _onSourcesChanged,
        ),
      ],
      shelf: NovelShelfPage(
        key: ValueKey<int>(_revision),
        library: library,
        pipeline: pipeline,
        manager: manager,
      ),
      explore: NovelExplorePage(
        key: ValueKey<int>(_revision),
        library: library,
        pipeline: pipeline,
        manager: widget.manager,
      ),
    );
  }

  /// 图源导入后重挂书架与探索：两块内容各自重新解析本板块的图源与列表。
  void _onSourcesChanged() => setState(() => _revision++);

  /// 追更日历：哪章有更新、哪天读过（与视频 / 漫画同一套页面）。
  Future<void> _openCalendar(ReadingLibrary library, SourceManager manager) async {
    final updates = await collectCalendarUpdates(
      library: library,
      manager: manager,
      isCancelled: () => !mounted,
    );
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => WatchCalendarPage(
          library: library,
          updates: updates,
          title: '${Section.novel.label} · 追更日历',
          // 点日历上的条目 → 打开详情页（那里有「继续阅读」，能直接续上进度）。
          onOpen: (entry) => _openFromCalendar(library, manager, entry),
        ),
      ),
    );
  }

  /// 从日历点条目：打开作品详情页（详情页自己带「继续阅读」入口）。
  void _openFromCalendar(
    ReadingLibrary library,
    SourceManager manager,
    CalendarEntry entry,
  ) {
    final item = library.item(entry.itemId);
    if (item == null) {
      // 记录被删了（书架移除）时如实提示，不静默失败。
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('「${entry.title}」已不在书架里')),
      );
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => NovelDetailPage(
          library: library,
          manager: manager,
          target: ReadingTarget(
            sourceId: item.sourceId,
            itemId: item.itemId,
            title: item.title,
            cover: item.cover,
            subtitle: item.subtitle,
          ),
          // 日历点进来的意图就是「接着读」。
          continueOnOpen: true,
        ),
      ),
    );
  }

  /// 阅读历史抽屉：底部 Sheet 里浏览最近的阅读记录（不新开全屏页面）。
  Future<void> _openHistory(ReadingLibrary library) async {
    final manager = widget.manager ?? LumeSources.manager(Section.novel);
    await showReadingHistorySheet(
      context: context,
      section: Section.novel,
      library: library,
      onResume: (item, _) {
        Navigator.of(context).pop();
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => NovelDetailPage(
              library: library,
              manager: manager,
              target: ReadingTarget(
                sourceId: item.sourceId,
                itemId: item.itemId,
                title: item.title,
                cover: item.cover,
                subtitle: item.subtitle,
              ),
              continueOnOpen: true,
            ),
          ),
        );
      },
    );
  }

  /// 打开本板块的图源管理页；返回后重挂内容（重新解析当前图源）。
  Future<void> _manageSources() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SourceSectionPage(
          section: Section.novel,
          manager: widget.manager,
        ),
      ),
    );
    if (!mounted) return;
    _onSourcesChanged();
  }
}
