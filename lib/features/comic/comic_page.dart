import 'package:flutter/material.dart';

import '../../core/reading/reading.dart';
import '../../core/session/section.dart';
import '../../core/source/source.dart';
import '../../core/util/lume_log.dart';
import '../../shared/widgets/glass_card.dart';
import '../../shared/widgets/notice_card.dart';
import '../../shared/widgets/state_view.dart';
import '../reading/reading_hub_page.dart';
import '../source/add_source_button.dart';
import '../source/source_section_page.dart';
import 'comic_explore_page.dart';
import 'comic_repo_page.dart';
import 'comic_shelf_page.dart';

/// 漫画板块（Phase2）：书架 / 探索两个页签。
///
/// 本页是板块的**资源宿主**：打开漫画板块的阅读库（`sections/comic/reading.db`
/// 与 `reading_cache/`），持有一份封面用的图片管线，退出本页时释放。
/// 书架、探索、详情、阅读器都只从宿主拿到「本板块的库与管线」。
///
/// 隔离：阅读库、缓存目录、图源都只属于漫画板块；小说板块走同一套代码，
/// 但拿到的 Section 不同，因此两边数据、缓存、图源完全不交叉。
class ComicPage extends StatefulWidget {
  const ComicPage({super.key, this.library, this.manager, this.runtimeAvailable});

  /// 阅读库；为空时按板块打开正式实现（测试可注入）。
  final ReadingLibrary? library;

  /// 图源管理端口；为空时用正式实现。
  final SourceManager? manager;

  /// 平台是否提供图源运行时；为空时取 [LumeSources.runtimeAvailable]。
  /// 测试注入 true 即可在非 iOS 平台驱动完整板块交互（与设置页同一口径）。
  final bool? runtimeAvailable;

  @override
  State<ComicPage> createState() => _ComicPageState();
}

class _ComicPageState extends State<ComicPage> {
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
    // 封面管线随页面释放：取消在飞请求、回收解码位图。
    _pipeline?.dispose();
    // 自己开的阅读库自己关（注入进来的库不代管）：释放 sqlite 句柄与内存，
    // 下次进板块会重新打开同一个库文件，书架与进度照旧。
    if (widget.library == null) ReadingLibrary.close(Section.comic);
    super.dispose();
  }

  Future<void> _boot() async {
    try {
      final library = widget.library ?? await ReadingLibrary.open(Section.comic);
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

  /// 扩展仓库：漫画板块独有的入口（其他板块没有这个能力）。
  void _manageRepos() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ComicRepoPage(manager: widget.manager),
      ),
    );
  }

  /// 图片缓存：显示占用并可一键清理（用户保存的图片不在清理范围）。
  Future<void> _manageCache() async {
    final library = _library;
    if (library == null) return;
    final bytes = library.cacheBytes();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('图片缓存'),
        content: Text(
          '漫画板块当前占用 ${_formatBytes(bytes)}。\n'
          '清理只删除缓存图片，书架、进度与保存的图片都不受影响。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('清理'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    library.clearCache();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已清理 ${_formatBytes(bytes)} 图片缓存')),
    );
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    if (!_runtimeAvailable) {
      return GlassScaffold(
        title: Section.comic.label,
        child: const SkeletonNotice(),
      );
    }
    final library = _library;
    final pipeline = _pipeline;
    if (_failed) {
      return GlassScaffold(
        title: Section.comic.label,
        child: const NoticeCard(
          title: '阅读存储不可用',
          subtitle: '漫画板块的阅读库打不开，请重启应用后重试',
        ),
      );
    }
    if (library == null || pipeline == null) {
      return GlassScaffold(
        title: Section.comic.label,
        child: const SourceStateView(state: SourceStateKind.loading),
      );
    }
    return ReadingHubPage(
      section: Section.comic,
      actions: <Widget>[
        // 右上角「图源管理」：本板块已导入图源的统一入口。
        IconButton(
          tooltip: '图源管理',
          icon: const Icon(Icons.source_outlined),
          onPressed: _manageSources,
        ),
        IconButton(
          tooltip: '扩展仓库',
          icon: const Icon(Icons.extension_outlined),
          onPressed: _manageRepos,
        ),
        IconButton(
          tooltip: '图片缓存',
          icon: const Icon(Icons.cleaning_services_outlined),
          onPressed: _manageCache,
        ),
        // 右上角统一的「+」添加图源：本地文件 / 订阅链接，只写漫画板块。
        AddSourceButton(
          section: Section.comic,
          manager: widget.manager,
          onImported: _onSourcesChanged,
        ),
      ],
      shelf: ComicShelfPage(
        key: ValueKey<int>(_revision),
        library: library,
        pipeline: pipeline,
        manager: widget.manager ?? LumeSources.manager(Section.comic),
      ),
      explore: ComicExplorePage(
        key: ValueKey<int>(_revision),
        library: library,
        pipeline: pipeline,
        manager: widget.manager,
      ),
    );
  }

  /// 图源导入后重挂书架与探索：两块内容各自重新解析本板块的图源与列表。
  void _onSourcesChanged() => setState(() => _revision++);

  /// 打开本板块的图源管理页；返回后重挂内容（重新解析当前图源）。
  Future<void> _manageSources() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SourceSectionPage(
          section: Section.comic,
          manager: widget.manager,
        ),
      ),
    );
    if (!mounted) return;
    _onSourcesChanged();
  }
}
