import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/reading/reading.dart';
import '../../core/source/source.dart';
import '../../core/theme/lume_theme.dart';
import '../../core/util/lume_log.dart';
import '../../shared/widgets/glass_card.dart';
import '../../shared/widgets/state_view.dart';
import '../reading/poster_card.dart';
import '../reading/section_image.dart';
import 'comic_download.dart';
import 'comic_reader_page.dart';

/// 漫画详情页：大图模糊背景封面、作品元信息、章节列表（正序 / 倒序可切换）。
///
/// 章节序号在页面内部一律按「正序下标」表达，倒序只是展示顺序的翻转——
/// 阅读进度、阅读器的 chapterIndex 都用正序下标，两套顺序不会串。
class ComicDetailPage extends StatefulWidget {
  const ComicDetailPage({
    super.key,
    required this.library,
    required this.manager,
    required this.target,
    this.runtimeAvailable,
  });

  final ReadingLibrary library;

  /// 图源管理端口：详情页自己打开图源，因此从书架进来也能用。
  final SourceManager manager;

  final ReadingTarget target;

  /// 平台是否提供图源运行时；透传给阅读器（为空时它自己按板块判断）。
  /// 与 `ComicPage` 的平台门同一口径，测试也靠它显式声明运行环境。
  final bool? runtimeAvailable;

  @override
  State<ComicDetailPage> createState() => _ComicDetailPageState();
}

class _ComicDetailPageState extends State<ComicDetailPage> {
  late final SectionImagePipeline _pipeline = SectionImagePipeline(
    cacheDir: widget.library.imageCacheDir,
    memoryBudgetBytes: SectionImagePipeline.thumbnailBudgetBytes,
  );

  DataSource? _source;
  SourceDetail? _detail;
  List<SourceChapter> _chapters = const <SourceChapter>[];
  ReadingProgress? _progress;
  bool _loading = true;
  String? _failure;

  /// 章节列表是否倒序展示。
  bool _descending = false;

  bool _onShelf = false;

  /// 批量下载器：第一次点「批量下载」时创建，之后复用同一个实例
  /// （进度卡片、取消、结果汇总都读它）。
  ComicDownloader? _downloader;

  /// 用户手动关掉进度 / 结果卡片；下一次开始下载时重新出现。
  bool _downloadCardHidden = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    // 先停下载再释放管线：管线关闭会让在飞请求返回空，下载器据此
    // 判定「这一批不下了」，而不是把剩下的图逐张记成失败。
    _downloader?.dispose();
    _pipeline.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failure = null;
    });
    try {
      final source = await widget.manager.open(widget.target.sourceId);
      if (!mounted) return;
      if (source == null) {
        setState(() {
          _loading = false;
          _failure = '源不可用（已停用或脚本载入失败），去探索页的源管理里检查';
        });
        return;
      }
      final detail = await source.detail(widget.target.itemId);
      final chapters = await source.chapters(widget.target.itemId);
      if (!mounted) return;
      setState(() {
        _source = source;
        _detail = detail;
        _chapters = chapters;
        _loading = false;
        _onShelf = widget.library.onShelf(widget.target.itemId);
        _progress = widget.library.progress(widget.target.itemId);
      });
      // 已在书架：同步章节总数，未读角标才有准确口径。
      if (_onShelf) {
        widget.library.syncChapters(widget.target.itemId, chapters.length);
      }
    } on SourceException catch (error) {
      LumeLog.warn('[${widget.target.itemId}] 详情获取失败: $error');
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failure = error.message;
      });
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failure = '$error';
      });
    }
  }

  /// 加入书架：书本信息来自详情（拿不到就用列表页带进来的快照）。
  void _shelve({bool silent = false}) {
    widget.library.shelve(
      sourceId: widget.target.sourceId,
      itemId: widget.target.itemId,
      title: _detail?.title ?? widget.target.title,
      cover: _detail?.cover ?? widget.target.cover,
      subtitle: _detail?.subtitle ?? widget.target.subtitle,
      chapterCount: _chapters.length,
    );
    setState(() {
      _onShelf = true;
      _progress = widget.library.progress(widget.target.itemId);
    });
    if (!silent) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          duration: Duration(seconds: 1),
          content: Text('已加入书架'),
        ),
      );
    }
  }

  Future<void> _unshelve() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('移出书架'),
        content: const Text('移出后这条阅读记录与进度都会清除，确定吗？'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('移出'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    widget.library.unshelve(widget.target.itemId);
    setState(() {
      _onShelf = false;
      _progress = null;
    });
  }

  /// 进阅读器。[index] 为正序章节下标。
  Future<void> _openReader(int index, {int page = 0}) async {
    final source = _source;
    if (source == null || _chapters.isEmpty) return;
    if (!_onShelf) _shelve(silent: true);
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ComicReaderPage(
          library: widget.library,
          dataSource: source,
          target: widget.target,
          chapters: _chapters,
          initialChapterIndex: index,
          initialPage: page,
          runtimeAvailable: widget.runtimeAvailable,
        ),
      ),
    );
    if (!mounted) return;
    // 返回后刷新进度：书架的未读角标与「继续阅读」都依赖它。
    setState(() {
      _onShelf = widget.library.onShelf(widget.target.itemId);
      _progress = widget.library.progress(widget.target.itemId);
    });
  }

  /// 继续阅读：有进度就从进度进入，没有就从第一章开始。
  Future<void> _continueReading() async {
    final progress = _progress;
    if (progress == null) {
      await _openReader(0);
      return;
    }
    final index = progress.chapterIndex.clamp(0, _chapters.length - 1);
    final page = progress is ComicProgress ? progress.page : 0;
    await _openReader(index, page: page);
  }

  // ------------------------------------------------------------------ 批量下载

  /// 惰性创建下载器：字节来源接详情页自己的图片管线，但**不落图片缓存**
  /// （下载的字节直接写导出目录，落缓存会让同一张图存两份）。
  ComicDownloader? _ensureDownloader() {
    final source = _source;
    if (source == null || _chapters.isEmpty) return null;
    return _downloader ??= ComicDownloader(
      dataSource: source,
      itemId: widget.target.itemId,
      works: _detail?.title ?? widget.target.title,
      library: widget.library,
      fetch: _pipeline.fetch,
    );
  }

  /// 「批量下载」：先选范围（全部 / 未读 / 仅当前章），选完立即开始。
  Future<void> _startBatchDownload() async {
    final downloader = _ensureDownloader();
    if (downloader == null) return;
    if (downloader.progress.running) {
      setState(() => _downloadCardHidden = false);
      return;
    }
    final readChapterIndex = _progress?.chapterIndex;
    final scope = await showModalBottomSheet<ComicDownloadScope>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => _DownloadScopeSheet(
        chapterCount: _chapters.length,
        readChapterIndex: readChapterIndex,
      ),
    );
    if (scope == null || !mounted) return;
    setState(() => _downloadCardHidden = false);
    await downloader.start(
      chapters: _chapters,
      indices: scope.indices(
        chapterCount: _chapters.length,
        readChapterIndex: readChapterIndex,
        currentIndex: readChapterIndex,
      ),
    );
  }

  /// 复制下载目录路径（结果卡片上的动作：保存到相册之前，路径是唯一出口）。
  Future<void> _copyDownloadPath(String path) async {
    await Clipboard.setData(ClipboardData(text: path));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        duration: Duration(seconds: 1),
        content: Text('已复制下载目录'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: GlassAppBar(
        title: Text(
          _detail?.title ?? widget.target.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: DecoratedBox(
        decoration: LumeTheme.background,
        child: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) return const SourceStateView(state: SourceStateKind.loading);
    final failure = _failure;
    if (failure != null && _chapters.isEmpty) {
      return SourceStateView(
        state: SourceStateKind.scriptError,
        detail: failure,
        onRetry: _load,
      );
    }
    return CustomScrollView(
      slivers: <Widget>[
        SliverToBoxAdapter(child: _buildHeader()),
        SliverToBoxAdapter(child: _buildDescription()),
        SliverToBoxAdapter(child: _buildChapterHeader()),
        SliverToBoxAdapter(child: _buildDownloadCard()),
        if (_chapters.isEmpty)
          const SliverToBoxAdapter(
            child: SizedBox(
              height: 160,
              child: SourceStateView(
                state: SourceStateKind.empty,
                detail: '该源没有提供章节',
              ),
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            sliver: SliverList.builder(
              itemCount: _chapters.length,
              itemBuilder: (context, position) {
                final index = _descending ? _chapters.length - 1 - position : position;
                return _ChapterTile(
                  chapter: _chapters[index],
                  read: _isRead(index),
                  current: _progress?.chapterIndex == index,
                  onTap: () => _openReader(index),
                );
              },
            ),
          ),
      ],
    );
  }

  /// 当前章之后的章节都算未读，因此「已读」= 章节下标 <= 进度章节。
  bool _isRead(int index) {
    final progress = _progress;
    return progress != null && index <= progress.chapterIndex;
  }

  /// 头部：模糊封面背景 + 封面缩略图 + 元信息 + 主操作。
  Widget _buildHeader() {
    final detail = _detail;
    final progress = _progress;
    return Stack(
      children: <Widget>[
        Positioned.fill(child: _buildGlow()),
        Padding(
          // 让出玻璃顶部栏（状态栏 + 工具栏）：顶栏是半透明的，内容不能压到它下面。
          padding: EdgeInsets.fromLTRB(
            16,
            MediaQuery.paddingOf(context).top + kToolbarHeight + 12,
            16,
            8,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  SizedBox(
                    width: 110,
                    height: 148,
                    child: PosterCover(
                      pipeline: _pipeline,
                      url: detail?.cover ?? widget.target.cover,
                      width: 320,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          detail?.title ?? widget.target.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            color: LumeTheme.textPrimary,
                          ),
                        ),
                        if ((detail?.subtitle ?? widget.target.subtitle) != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(
                              detail?.subtitle ?? widget.target.subtitle!,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 12,
                                color: LumeTheme.muted,
                              ),
                            ),
                          ),
                        const SizedBox(height: 8),
                        Text(
                          '共 ${_chapters.length} 章',
                          style: const TextStyle(
                            fontSize: 12,
                            color: LumeTheme.muted,
                          ),
                        ),
                        if (progress != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              '读至 ${progress.describe()}',
                              style: const TextStyle(
                                fontSize: 12,
                                color: LumeTheme.textPrimary,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Row(
                children: <Widget>[
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _chapters.isEmpty ? null : _continueReading,
                      icon: const Icon(Icons.menu_book, size: 18),
                      label: Text(progress == null ? '开始阅读' : '继续阅读'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  OutlinedButton(
                    onPressed: _onShelf ? _unshelve : _shelve,
                    child: Text(_onShelf ? '移出书架' : '加入书架'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 模糊背景：封面放大模糊 + 向页面底色渐隐，做出「大图模糊背景」层次。
  ///
  /// 浅色主题下这里是**浅色晕染**而不是深色压图：封面以低透明度铺一层，
  /// 再压一层白到页面底色的渐变——顶部透出作品色调，往下融进页面底色。
  /// 标题与元信息因此可以用深色文字，不必靠深色遮罩保可读性。
  Widget _buildGlow() {
    final cover = _detail?.cover ?? widget.target.cover;
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        if (cover != null && cover.isNotEmpty)
          Opacity(
            opacity: 0.34,
            child: ImageFiltered(
              imageFilter: ImageFilter.blur(sigmaX: 32, sigmaY: 32),
              child: SectionImage(
                pipeline: _pipeline,
                url: cover,
                targetWidth: 200,
                fit: BoxFit.cover,
              ),
            ),
          ),
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: <Color>[
                Color(0x99FFFFFF),
                Color(0x59FFFFFF),
                Color(0x00FFFFFF),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDescription() {
    final description = _detail?.description;
    if (description == null) return const SizedBox(height: 4);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      child: GlassCard(
        radius: 14,
        padding: const EdgeInsets.all(14),
        child: Text(
          description,
          style: const TextStyle(
            fontSize: 13,
            height: 1.6,
            color: LumeTheme.textSecondary,
          ),
        ),
      ),
    );
  }

  /// 章节区标题 + 批量下载入口 + 正序 / 倒序切换。
  Widget _buildChapterHeader() {
    final running = _downloader?.progress.running ?? false;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 8, 6),
      child: Row(
        children: <Widget>[
          Text(
            '章节（${_chapters.length}）',
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: LumeTheme.textPrimary,
            ),
          ),
          const Spacer(),
          IconButton(
            tooltip: running ? '下载中' : '批量下载',
            visualDensity: VisualDensity.compact,
            onPressed: _chapters.isEmpty ? null : _startBatchDownload,
            icon: running
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.download_for_offline_outlined, size: 20),
          ),
          TextButton.icon(
            onPressed: () => setState(() => _descending = !_descending),
            icon: Icon(
              _descending ? Icons.arrow_downward : Icons.arrow_upward,
              size: 16,
            ),
            label: Text(_descending ? '倒序' : '正序'),
          ),
        ],
      ),
    );
  }

  /// 下载进度 / 结果卡片：下载进行中与刚结束（未手动关闭）时出现。
  ///
  /// 做成列表内的一张卡而不是模态面板：下载要能边下边看——用户可以继续翻章节、
  /// 进阅读器，回来时这张卡还在原处。
  Widget _buildDownloadCard() {
    final downloader = _downloader;
    if (downloader == null || _downloadCardHidden) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: downloader,
      builder: (context, _) {
        final progress = downloader.progress;
        if (progress.status == ComicDownloadStatus.idle) {
          return const SizedBox.shrink();
        }
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
          child: _DownloadCard(
            progress: progress,
            onCancel: downloader.cancel,
            onCopy: () => _copyDownloadPath(progress.destination),
            onDismiss: () => setState(() => _downloadCardHidden = true),
          ),
        );
      },
    );
  }
}

/// 下载范围选择面板：全部 / 未读 / 仅当前章，各自带「会下多少章」的实数。
class _DownloadScopeSheet extends StatelessWidget {
  const _DownloadScopeSheet({
    required this.chapterCount,
    required this.readChapterIndex,
  });

  final int chapterCount;

  /// 阅读进度所在章节（正序下标）；没有进度时为 null。
  final int? readChapterIndex;

  @override
  Widget build(BuildContext context) {
    final scopes = <(ComicDownloadScope, int)>[
      for (final scope in ComicDownloadScope.values)
        (
          scope,
          scope
              .indices(
                chapterCount: chapterCount,
                readChapterIndex: readChapterIndex,
                currentIndex: readChapterIndex,
              )
              .length,
        ),
    ];
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      child: Material(
        color: LumeTheme.surface,
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Text(
                  '批量下载',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: LumeTheme.textPrimary,
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  '图片存到应用内的导出目录（按作品 / 章节分目录），'
                  '已下过的图会自动跳过，可随时取消。',
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.5,
                    color: LumeTheme.muted,
                  ),
                ),
                const SizedBox(height: 6),
                for (final (scope, count) in scopes)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    enabled: count > 0,
                    onTap: count > 0
                        ? () => Navigator.of(context).pop(scope)
                        : null,
                    title: Text(
                      scope.label,
                      style: const TextStyle(
                        fontSize: 14,
                        color: LumeTheme.textPrimary,
                      ),
                    ),
                    subtitle: Text(
                      switch (scope) {
                        ComicDownloadScope.all => '整部作品，共 $count 章',
                        ComicDownloadScope.unread =>
                          count == 0 ? '没有未读章节' : '进度之后，共 $count 章',
                        ComicDownloadScope.current => count == 0
                            ? '暂无可下载章节'
                            : '只下第 ${(readChapterIndex ?? 0) + 1} 章',
                      },
                      style: const TextStyle(
                        fontSize: 12,
                        color: LumeTheme.muted,
                      ),
                    ),
                    trailing: count > 0
                        ? const Icon(Icons.chevron_right, color: LumeTheme.muted)
                        : null,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 下载进度 / 结果卡片。
class _DownloadCard extends StatelessWidget {
  const _DownloadCard({
    required this.progress,
    required this.onCancel,
    required this.onCopy,
    required this.onDismiss,
  });

  final ComicDownloadProgress progress;
  final VoidCallback onCancel;
  final VoidCallback onCopy;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final running = progress.running;
    return GlassCard(
      radius: 14,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(
                running
                    ? Icons.downloading
                    : (progress.status == ComicDownloadStatus.done
                        ? Icons.check_circle_outline
                        : Icons.cancel_outlined),
                size: 18,
                color: LumeTheme.muted,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  _title(),
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: LumeTheme.textPrimary,
                  ),
                ),
              ),
              if (running)
                TextButton(onPressed: onCancel, child: const Text('取消'))
              else
                TextButton(onPressed: onDismiss, child: const Text('关闭')),
            ],
          ),
          if (running) ...<Widget>[
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: progress.fraction,
                minHeight: 4,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              _runningDetail(),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: LumeTheme.muted),
            ),
          ] else ...<Widget>[
            const SizedBox(height: 4),
            Text(
              _summary(),
              style: const TextStyle(fontSize: 12, color: LumeTheme.muted),
            ),
            for (final failure in progress.failures.take(3))
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Text(
                  failure,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    color: LumeTheme.danger,
                  ),
                ),
              ),
            if (progress.failures.length > 3)
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Text(
                  '…另有 ${progress.failures.length - 3} 章失败',
                  style: const TextStyle(fontSize: 12, color: LumeTheme.muted),
                ),
              ),
            const SizedBox(height: 2),
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    progress.destination,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11, color: LumeTheme.muted),
                  ),
                ),
                TextButton.icon(
                  onPressed: onCopy,
                  icon: const Icon(Icons.copy, size: 15),
                  label: const Text('复制路径', style: TextStyle(fontSize: 12)),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  String _title() {
    if (progress.running) {
      return '批量下载中 · 已下完 ${progress.chapterDone}/${progress.chapterTotal} 章';
    }
    if (progress.status == ComicDownloadStatus.cancelled) return '已取消下载';
    return progress.chapterFailed > 0 ? '下载结束（有失败）' : '下载完成';
  }

  String _runningDetail() {
    final title = progress.currentChapterTitle;
    if (progress.currentImageTotal == 0) {
      return title.isEmpty ? '正在获取章节内容…' : '「$title」· 正在获取章节内容…';
    }
    return '「$title」· 第 ${progress.currentImageDone}'
        '/${progress.currentImageTotal} 张 · 已写入 ${progress.imageSaved} 张'
        '（跳过 ${progress.imageSkipped} 张）';
  }

  String _summary() {
    final parts = <String>[
      '成功 ${progress.chapterDone} 章',
      if (progress.chapterFailed > 0) '失败 ${progress.chapterFailed} 章',
      '写入 ${progress.imageSaved} 张',
      if (progress.imageSkipped > 0) '跳过 ${progress.imageSkipped} 张',
    ];
    return parts.join(' · ');
  }
}

/// 章节行：已读打勾，当前章加亮。
class _ChapterTile extends StatelessWidget {
  const _ChapterTile({
    required this.chapter,
    required this.read,
    required this.current,
    required this.onTap,
  });

  final SourceChapter chapter;
  final bool read;
  final bool current;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: GlassCard(
        radius: 12,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
        onTap: onTap,
        child: Row(
          children: <Widget>[
            Expanded(
              child: Text(
                chapter.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 14,
                  color: current ? LumeTheme.textPrimary : LumeTheme.muted,
                  fontWeight: current ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
            if (current)
              const Padding(
                padding: EdgeInsets.only(left: 6),
                child: Text(
                  '在读',
                  style: TextStyle(fontSize: 11, color: LumeTheme.textPrimary),
                ),
              )
            else if (read)
              const Padding(
                padding: EdgeInsets.only(left: 6),
                child: Icon(Icons.done, size: 14, color: LumeTheme.muted),
              ),
          ],
        ),
      ),
    );
  }
}
