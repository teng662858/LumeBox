import 'package:lume_box/shared/widgets/lume_icon.dart';
import 'package:flutter/material.dart';

import '../../core/reading/reading.dart';
import '../../core/reading/comic_image_tools.dart';
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
import 'novel_detail_page.dart';
import 'novel_explore_page.dart';
import 'novel_shelf_page.dart';

/// 小说板块（Phase2）：书架 / 探索两个页签。
///
/// 与漫画板块同一套骨架（[ReadingHubPage] + [ReadingLibrary]），但拿到的
/// Section 是小说，因此阅读库、缓存目录、图源全部落在 `sections/novel/` 之下，
/// 与漫画互不可见。小说不需要图片缓存（正文是文本），因此不挂缓存管理入口。
class NovelPage extends StatefulWidget {
  const NovelPage({
    super.key,
    this.library,
    this.manager,
    this.runtimeAvailable,
  });

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
    // 自己开的图源板块也自己关（与阅读库同一条纪律，注入进来的不代管）：
    // 收在板块页而不是探索页的理由见 ComicPage 的同名注释（探索页只是借用）。
    if (widget.manager == null) LumeSources.close(Section.novel);
    super.dispose();
  }

  Future<void> _boot() async {
    try {
      final library =
          widget.library ?? await ReadingLibrary.open(Section.novel);
      if (!mounted) return;
      setState(() {
        _library = library;
        _pipeline = SectionImagePipeline(
          cacheDir: library.imageCacheDir,
          memoryBudgetBytes: SectionImagePipeline.thumbnailBudgetBytes,
          // 封面网格按封面并发（4）跑：并发太大被图床限流，反而更多空白。
          maxConcurrent: SectionImagePipeline.coverConcurrency,
          decodeTransform: (bytes) =>
              automaticUpscale(bytes, UpscaleSurface.novelIllustration),
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
        effectModule: GlassModule.novel,
        title: Section.novel.label,
        child: const SkeletonNotice(),
      );
    }
    final library = _library;
    final pipeline = _pipeline;
    if (_failed) {
      return GlassScaffold(
        effectModule: GlassModule.novel,
        title: Section.novel.label,
        child: const NoticeCard(
          title: '阅读存储不可用',
          subtitle: '小说板块的阅读库打不开，请重启应用后重试',
        ),
      );
    }
    if (library == null || pipeline == null) {
      return GlassScaffold(
        effectModule: GlassModule.novel,
        title: Section.novel.label,
        child: const SourceStateView(state: SourceStateKind.loading),
      );
    }
    final manager = widget.manager ?? LumeSources.manager(Section.novel);
    return ReadingHubPage(
      section: Section.novel,
      manager: widget.manager,
      onSubscriptionsClosed: _onSourcesChanged,
      onFavorites: () => _openHistory(library, favorites: true),
      actions: <Widget>[
        // 右上角统一的入口（与视频 / 漫画同一套设计）：⏱️ 历史（底部抽屉）。
        IconButton(
          tooltip: '阅读历史',
          icon: const LumeIcon(Icons.history, slot: 'novel_page.1'),
          onPressed: () => _openHistory(library),
        ),
        // 右上角「图源管理」：本板块已导入图源的统一入口（启用 / 禁用 /
        // 重命名 / 导出 / 删除）。与全局设置的图源总管理不是一回事。
        IconButton(
          tooltip: '源管理',
          icon: const LumeIcon(Icons.source_outlined, slot: 'novel_page.2'),
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
      // 探索页走**原地刷新**（revision 传进去，不换 Key）：换 Key 会让新旧实例
      // 在同一帧里交接，而旧实例退出时会关掉板块共享的图源注册表——新实例随后
      // 的首次解析就撞上「数据库已关闭」（真机在导入订阅后复现）。
      explore: NovelExplorePage(
        library: library,
        pipeline: pipeline,
        manager: widget.manager,
        revision: _revision,
      ),
    );
  }

  /// 图源导入后重挂书架与探索：两块内容各自重新解析本板块的图源与列表。
  ///
  /// 书架用 Key 重挂（它的数据来自阅读库，与图源注册表无关）；探索页原地刷新
  /// （见上面的说明）。
  void _onSourcesChanged() => setState(() => _revision++);

  /// 阅读历史抽屉：底部 Sheet 里浏览最近的阅读记录与收藏（不新开全屏页面）。
  ///
  /// 两条路径共用同一个「打开详情」动作：记录里点条目 = 续读（[continueOnOpen]），
  /// 收藏里点一条还没读过的 = 直接进详情页（用户点名：历史图标里要有收藏记录）。
  Future<void> _openHistory(
    ReadingLibrary library, {
    bool favorites = false,
  }) async {
    final manager = widget.manager ?? LumeSources.manager(Section.novel);
    void openDetail(LibraryItem item, {bool continueOnOpen = false}) {
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
            continueOnOpen: continueOnOpen,
          ),
        ),
      );
    }

    await showReadingHistorySheet(
      context: context,
      section: Section.novel,
      library: library,
      initialTab: favorites
          ? HistoryDrawerTab.favorites
          : HistoryDrawerTab.records,
      onResume: (item, _) => openDetail(item, continueOnOpen: true),
      onOpenItem: openDetail,
    );
  }

  /// 打开本板块的图源管理页；返回后重挂内容（重新解析当前图源）。
  Future<void> _manageSources() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            SourceSectionPage(section: Section.novel, manager: widget.manager),
      ),
    );
    if (!mounted) return;
    _onSourcesChanged();
  }
}
