import 'package:flutter/material.dart';

import '../../core/player/abstract_player.dart';
import '../../core/player/brightness.dart';
import '../../core/player/pip.dart';
import '../../core/player/player_factory.dart';
import '../../core/player/player_settings.dart';
import '../../core/reading/reading.dart';
import '../../core/session/section.dart';
import '../../core/source/source.dart';
import '../../core/theme/lume_theme.dart';
import '../../core/util/lume_log.dart';
import '../../shared/widgets/glass_card.dart';
import '../reading/explore_view.dart';
import '../reading/history_sheet.dart';
import '../shell/board_tabs.dart';
import '../source/add_source_button.dart';
import '../source/source_home_page.dart';
import '../source/source_section_page.dart';
import 'continue_watching.dart';
import 'source_playback.dart';
import 'video_play_target.dart';
import 'video_player_page.dart';

/// 视频板块：**只保留【浏览】**（真机反馈：播放子页签移除）。
///
/// 页面职责只剩浏览与快速入口：
/// - 图源条（切换当前图源）+ 分类 / 搜索 / 列表（[SourceBrowsePane]）；
/// - 列表最底部少量「继续观看」记录（[ContinueWatchingSection]）；
/// - 右上角：⏱️ 历史（底部抽屉）+ 既有的图源管理与「+」添加图源。
///
/// **点条目不再切页签，而是唤起独立播放器页**（[VideoPlayerPage]）：播放是沉浸
/// 场景，独立页面能返回、能带自己的标题，也不再占板块的页签位。没有可用图源时
/// 首页给出导入引导。
///
/// 播放内核与播放设置的读写都搬到了播放器页：本页不再创建播放器，因此也不持有
/// 播放器设置库——只持有浏览列表封面用的图片管线与本板块阅读库。
class VideoPage extends StatefulWidget {
  const VideoPage({
    super.key,
    this.playerFactory,
    this.catalog,
    this.pipBackend,
    this.brightnessBackend,
    this.sourceManager,
    this.library,
  });

  /// 播放器创建端口（按内核）。为空时用 [PlayerFactory.create]。
  ///
  /// 本页自己不建播放器，这个端口只用于**透传**给唤起的播放器页（测试注入同一份
  /// 替身，就不必分别配置两处）。
  final AbstractPlayer? Function(PlayerKernel kernel)? playerFactory;

  /// 内核可用性目录。为空时用平台目录。同样只用于透传给播放器页。
  final PlayerKernelCatalog? catalog;

  /// 画中画后端（透传给播放器页）。
  final PipBackend? pipBackend;

  /// 屏幕亮度后端（透传给播放器页）。
  final BrightnessBackend? brightnessBackend;

  /// 图源管理端口（首页的浏览面用它取本板块图源）。为空时用正式实现。
  final SourceManager? sourceManager;

  /// 本板块阅读库（进度与继续观看）；为空时按板块打开正式实现。
  final ReadingLibrary? library;

  /// 页签文案：**只保留【浏览】**（播放已移到独立播放器页）。
  static const List<String> tabLabels = <String>['浏览'];

  @override
  State<VideoPage> createState() => _VideoPageState();
}

class _VideoPageState extends State<VideoPage> {
  /// 本板块的阅读库：视频进度（集数 + 时间点）与「继续观看」落在它里面。
  ReadingLibrary? _library;

  /// 浏览列表的封面图管线：**本板块自己**的（缓存落在 sections/video 之下）。
  SectionImagePipeline? _pipeline;

  /// 浏览面换代：从图源管理页返回后 +1，重挂浏览面（列表与当前图源重算）。
  int _browseRevision = 0;

  /// 「继续观看」列表换代：从播放器页 / 历史抽屉返回后 +1，重算那一块。
  int _continueWatchingRevision = 0;

  /// 阅读库打不开：浏览照常，但进度与继续观看不可用。
  bool _libraryFailed = false;

  /// 是否有播放器页正压在栈上（由 [_openPlayer] 维护）。
  ///
  /// 用来守住一个真实踩到的坑：退出时板块页与播放器页会在**同一帧**被销毁，
  /// 而 Flutter 不保证板块页晚于播放器页销毁。如果板块页先把共享的阅读库关了，
  /// 播放器页在 dispose 里写的最后一条进度就落进一个已关闭的库——store 对已关闭
  /// 库的写入是**静默降级**，结果是「退出 App 时最后几秒的进度丢失」（实测复现）。
  /// 因此只要播放器页还在栈上，板块页就不关它；等播放器页自己退栈后，下一次
  /// 板块页销毁（或 App 退出）再收尾。
  bool _playerRouteOpen = false;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  @override
  void dispose() {
    _pipeline?.dispose();
    // 自己开的阅读库自己关（注入进来的不代管）；播放器页还在栈上时先让给它用
    // （见 [_playerRouteOpen]）。
    if (widget.library == null && !_playerRouteOpen) {
      ReadingLibrary.close(Section.video);
    }
    super.dispose();
  }

  Future<void> _boot() async {
    try {
      final library = widget.library ?? await ReadingLibrary.open(Section.video);
      if (!mounted) return;
      setState(() {
        _library = library;
        // 封面缩略图管线：与阅读板块同一套纪律（引用计数 + LRU + 磁盘缓存）。
        _pipeline = SectionImagePipeline(
          cacheDir: library.imageCacheDir,
          memoryBudgetBytes: SectionImagePipeline.thumbnailBudgetBytes,
        );
      });
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
      if (!mounted) return;
      setState(() => _libraryFailed = true);
    }
  }

  /// 图源变更后重挂浏览面：列表与当前图源重新解析。
  void _onSourcesChanged() => setState(() => _browseRevision++);

  /// 打开本板块的图源管理页（启用 / 禁用 / 重命名 / 导出 / 删除都在那里）。
  Future<void> _manageSources() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SourceSectionPage(
          section: Section.video,
          manager: widget.sourceManager,
        ),
      ),
    );
    if (!mounted) return;
    _onSourcesChanged();
  }

  // ------------------------------------------------------ 图源条目 → 独立播放器

  /// 图源列表里点一个条目：**能直接播就直接播**，否则走剧集链路。
  ///
  /// 直接播的判据是条目自带可播放地址（列表里的 `url` 会落到条目 id 上）——
  /// 视频类图源最常见的形状就是 `{title, url}`。条目只有 id 时按
  /// 「作品 → 剧集 → 内容」取地址。取到地址后**唤起独立播放器页**。
  Future<void> _playFromSource(DataSource source, SourceItem item) async {
    final direct = SourcePlayback.directAddress(item.id);
    if (direct != null) {
      await _openPlayer(
        PlayerMedia(uri: direct, title: item.title),
        target: VideoPlayTarget(
          sourceId: source.id,
          itemId: item.id,
          title: item.title,
          cover: item.cover,
          chapterIndex: 0,
          chapterId: item.id,
          chapterTitle: item.title,
        ),
      );
      return;
    }

    final List<SourceChapter> chapters;
    try {
      chapters = await source.chapters(item.id);
    } on SourceException catch (error) {
      _toast('${error.message}；条目自带播放地址（url）时可直接起播');
      return;
    }
    if (!mounted) return;
    if (chapters.isEmpty) {
      _toast('「${item.title}」没有可播放的剧集');
      return;
    }

    // 只有一集就不必让用户再选一次。
    final chapter = chapters.length == 1
        ? chapters.first
        : await _pickChapter(item, chapters);
    if (chapter == null || !mounted) return;

    try {
      final content = await source.content(
        itemId: item.id,
        chapterId: chapter.id,
      );
      final address = SourcePlayback.contentAddress(content);
      if (address == null) {
        _toast('「${chapter.title}」不是视频内容');
        return;
      }
      final chapterIndex = chapters.indexWhere(
        (candidate) => candidate.id == chapter.id,
      );
      await _openPlayer(
        PlayerMedia(
          uri: address,
          title: '${item.title} · ${chapter.title}',
          // 图源给的防盗链头必须原样交给内核（丢 = CDN 403 + 退避重试）。
          headers: SourcePlayback.contentHeaders(content),
        ),
        target: VideoPlayTarget(
          sourceId: source.id,
          itemId: item.id,
          title: item.title,
          cover: item.cover,
          chapterIndex: chapterIndex < 0 ? 0 : chapterIndex,
          chapterId: chapter.id,
          chapterTitle: chapter.title,
        ),
        // 图源给了多条清晰度线路就一起带进播放器（单条 / 空表时按钮弹提示）。
        qualities: SourcePlayback.contentQualities(content),
      );
    } on SourceException catch (error) {
      _toast(error.message);
    }
  }

  /// 探索列表里点一个条目：先按 id 打开它所属的图源，再走既有的起播链路。
  Future<void> _playFromSelection(ExploreSelection selection) async {
    final manager = widget.sourceManager ?? LumeSources.manager(Section.video);
    final source = await manager.open(selection.sourceId);
    if (!mounted) return;
    if (source == null) {
      _toast('「${selection.item.title}」的源不可用（未启用或脚本载入失败）');
      return;
    }
    await _playFromSource(source, selection.item);
  }

  /// 唤起独立播放器页；返回后刷新「继续观看」（进度是在那边落的盘）。
  Future<void> _openPlayer(
    PlayerMedia media, {
    VideoPlayTarget? target,
    List<VideoQuality> qualities = const <VideoQuality>[],
  }) async {
    if (!mounted) return;
    _playerRouteOpen = true;
    try {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => VideoPlayerPage(
            media: media,
            title: target?.title,
            target: target,
            sourceId: target?.sourceId,
            playerFactory: widget.playerFactory,
            catalog: widget.catalog,
            pipBackend: widget.pipBackend,
            brightnessBackend: widget.brightnessBackend,
            sourceManager: widget.sourceManager,
            library: _library,
            qualities: qualities,
          ),
        ),
      );
    } finally {
      _playerRouteOpen = false;
    }
    if (!mounted) return;
    setState(() => _continueWatchingRevision++);
  }

  /// 剧集选择面板：一集一个条目，取消返回 null。
  Future<SourceChapter?> _pickChapter(
    SourceItem item,
    List<SourceChapter> chapters,
  ) {
    return showModalBottomSheet<SourceChapter>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => _ChapterSheet(title: item.title, chapters: chapters),
    );
  }

  /// 继续观看：按记录里的剧集与时间点续播。
  ///
  /// 记的是剧集 id 而不是序号，因此图源章节改名或重排也能找回同一集；只有剧集
  /// 取不到（图源改了）才回退到按序号定位。
  Future<void> _resumeFromProgress(
    LibraryItem item,
    VideoProgress progress,
  ) async {
    final manager = widget.sourceManager ?? LumeSources.manager(Section.video);
    final source = await manager.open(item.sourceId);
    if (!mounted) return;
    if (source == null) {
      _toast('「${item.title}」的源不可用（未启用或脚本载入失败）');
      return;
    }

    final List<SourceChapter> chapters;
    try {
      chapters = await source.chapters(item.itemId);
    } on SourceException catch (error) {
      _toast(error.message);
      return;
    }
    if (!mounted) return;
    if (chapters.isEmpty) {
      _toast('「${item.title}」没有可播放的剧集');
      return;
    }

    // 优先按剧集 id 找；找不到再按序号；都没有就用第一集。
    var index = chapters.indexWhere((chapter) => chapter.id == progress.chapterId);
    if (index < 0 && progress.chapterIndex < chapters.length) {
      index = progress.chapterIndex;
    }
    if (index < 0) index = 0;
    final chapter = chapters[index];

    try {
      final content = await source.content(
        itemId: item.itemId,
        chapterId: chapter.id,
      );
      final address = SourcePlayback.contentAddress(content);
      if (address == null) {
        _toast('「${chapter.title}」不是视频内容');
        return;
      }
      await _openPlayer(
        PlayerMedia(
          uri: address,
          title: '${item.title} · ${chapter.title}',
          headers: SourcePlayback.contentHeaders(content),
        ),
        target: VideoPlayTarget(
          sourceId: item.sourceId,
          itemId: item.itemId,
          title: item.title,
          cover: item.cover,
          chapterIndex: index,
          chapterId: chapter.id,
          chapterTitle: chapter.title,
        ),
        qualities: SourcePlayback.contentQualities(content),
      );
    } on SourceException catch (error) {
      _toast(error.message);
    }
  }

  /// 移除一条播放记录（书架条目一并撤下）。
  void _removeProgress(LibraryItem item) {
    final library = _library;
    if (library == null) return;
    library.unshelve(item.itemId);
    setState(() => _continueWatchingRevision++);
  }

  // ------------------------------------------------------------ 日历 / 历史

  /// 打开历史抽屉（底部 Sheet）：在抽屉里直接浏览播放记录。
  ///
  /// 真机反馈：时钟图标点进来是「随手看一眼就回去」，因此**不新开全屏页面**。
  /// 完整列表（含清空）仍在抽屉里：视频的记录就是它的「书架」，清掉不丢别的。
  Future<void> _openHistory() async {
    final library = _library;
    if (library == null) return;
    await showReadingHistorySheet(
      context: context,
      section: Section.video,
      library: library,
      onResume: (item, progress) {
        if (progress is! VideoProgress) return;
        Navigator.of(context).pop();
        _resumeFromProgress(item, progress);
      },
    );
    if (!mounted) return;
    setState(() => _continueWatchingRevision++);
  }

  /// 可读提示（不冒泡异常）。
  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  // ------------------------------------------------------------------ 构建

  /// 右上角动作（三个板块统一口径）：
  /// ⏱️ 历史抽屉，外加**图源管理**与「+」添加图源。
  ///
  /// 播放器设置不在这里——它属于播放器本身，在播放器页的控制栏齿轮上。
  List<Widget> _buildActions() => <Widget>[
        IconButton(
          tooltip: '播放历史',
          icon: const Icon(Icons.history),
          onPressed: _openHistory,
        ),
        IconButton(
          tooltip: '源管理',
          icon: const Icon(Icons.source_outlined),
          onPressed: _manageSources,
        ),
        // 右上角统一的「+」添加图源：导入完成即刷新首页（与小说 / 漫画同口径）。
        AddSourceButton(
          section: Section.video,
          manager: widget.sourceManager,
          onImported: _onSourcesChanged,
        ),
      ];

  @override
  Widget build(BuildContext context) {
    // 页签控制器提到最外层（与小说 / 漫画的阅读外壳同款）：页签条在顶部栏里、
    // 内容区在 body 里，两边共用同一个控制器。**只剩【浏览】一个页签**：播放已
    // 搬到独立播放器页，页签位不再被播放占用。
    return DefaultTabController(
      length: VideoPage.tabLabels.length,
      child: GlassScaffold(
        title: Section.video.label,
        actions: _buildActions(),
        // 页签条做成顶栏的一部分（整条玻璃），内容从它下面滚过。
        bottom: const BoardTabHeader(labels: VideoPage.tabLabels),
        behindBar: true,
        child: BoardTabs(children: <Widget>[_buildBrowseTab()]),
      ),
    );
  }

  /// 浏览页签内容：图源列表 + 底部「继续观看」。
  Widget _buildBrowseTab() {
    if (_libraryFailed) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: GlassCard(
            padding: EdgeInsets.all(20),
            child: Text(
              '视频板块的阅读库打不开，播放记录与「继续观看」暂不可用；'
              '浏览与播放不受影响。',
              style: TextStyle(fontSize: 13, height: 1.5),
            ),
          ),
        ),
      );
    }
    return Column(
      children: <Widget>[
        // **内容在前，历史在后**（真机反馈：历史条目一多就把搜索栏、分类与首页
        // 内容全部挤到屏幕下方）。顺序固定为：搜索 → 分类 → 内容列表 → 继续观看。
        Expanded(
          // 与小说 / 漫画**同一个浏览组件**：同款工具栏（源下拉 → 排序 → 布局 →
          // 搜索 → 筛选）、同款搜索（聚合 / 当前源）与分页 / 预热。视频板块因此
          // 不再有一套自己的浏览实现——三块的肌肉记忆真正一致。
          child: ExploreView(
            section: Section.video,
            // 管线可能还在准备：为空时封面先出占位（不挂转圈等它，见 ExploreView）。
            pipeline: _pipeline,
            manager: widget.sourceManager,
            layout: ExploreLayout.list,
            // 顶栏已经有「源管理」，图源条里不再重复放一个。
            showSourceManage: false,
            // 导入 / 删除图源后原地重解析（不重挂：重挂会与旧实例的 dispose
            // 抢同一份板块注册表，真机上会报「图源存储不可用」）。
            revision: _browseRevision,
            onOpenItem: _playFromSelection,
          ),
        ),
        if (_library != null)
          // 放在整页最底端；只展示最近 3 条：条目数与高度都可预期，不会把上面的
          // 内容列表压没。完整历史走右上角那个时钟图标（抽屉）。
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: ContinueWatchingSection(
              key: ValueKey<int>(_continueWatchingRevision),
              library: _library!,
              onResume: _resumeFromProgress,
              onRemove: _removeProgress,
              onShowAll: _openHistory,
              maxItems: 3,
            ),
          ),
      ],
    );
  }
}

/// 剧集选择面板：图源条目有多集时先选一集再起播。
///
/// 与图源切换面板同一套玻璃外观（顶部圆角 + 深色背景），一行一集。
class _ChapterSheet extends StatelessWidget {
  const _ChapterSheet({required this.title, required this.chapters});

  /// 作品标题（面板抬头用）。
  final String title;

  final List<SourceChapter> chapters;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      child: DecoratedBox(
        decoration: LumeTheme.background,
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      '选择剧集',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: LumeTheme.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: LumeTheme.muted),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: chapters.length,
                  itemBuilder: (context, index) {
                    final chapter = chapters[index];
                    return ListTile(
                      dense: true,
                      title: Text(
                        chapter.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: LumeTheme.textPrimary),
                      ),
                      onTap: () => Navigator.of(context).pop(chapter),
                    );
                  },
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}
