import 'dart:ui';

import 'package:flutter/material.dart';

import '../../core/reading/reading.dart';
import '../../core/source/source.dart';
import '../../core/theme/lume_theme.dart';
import '../../core/util/lume_log.dart';
import '../../shared/widgets/chapter_tile.dart';
import '../../shared/widgets/glass_card.dart';
import '../../shared/widgets/state_view.dart';
import '../reading/poster_card.dart';
import '../reading/section_image.dart';
import 'novel_catalog_page.dart';
import 'novel_reader_page.dart';

/// 小说详情页：模糊封面背景、作品元信息、章节概览与「继续阅读」。
///
/// 详情页自己打开图源（从书架进来也能用），并把打开好的数据源交给目录页与阅读器，
/// 避免每个页面各开一次。章节全量列表在目录页，这里只预览前若干章。
class NovelDetailPage extends StatefulWidget {
  const NovelDetailPage({
    super.key,
    required this.library,
    required this.manager,
    required this.target,
    this.continueOnOpen = false,
  });

  final ReadingLibrary library;
  final SourceManager manager;
  final ReadingTarget target;

  /// 从书架的「续读」进来：加载完成后直接进阅读器续读。
  final bool continueOnOpen;

  @override
  State<NovelDetailPage> createState() => _NovelDetailPageState();
}

class _NovelDetailPageState extends State<NovelDetailPage> {
  /// 详情页封面只用于头部模糊背景与缩略图，用缩略图预算即可。
  late final SectionImagePipeline _pipeline = SectionImagePipeline(
    cacheDir: widget.library.imageCacheDir,
    memoryBudgetBytes: SectionImagePipeline.thumbnailBudgetBytes,
  );

  /// 详情页的章节列表**不再截断预览**（用户口径：章节列表要完整展示，不得压缩
  /// 成预览条）。列表在 `SliverList.builder` 里按需构建，几千章也只是滚动条长，
  /// 不会一次性建出全部行。
  DataSource? _source;
  SourceDetail? _detail;
  List<SourceChapter> _chapters = const <SourceChapter>[];
  ReadingProgress? _progress;
  bool _loading = true;
  String? _failure;
  bool _onShelf = false;
  bool _autoOpened = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
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
        _progress = widget.library.novelProgress(widget.target.itemId);
      });
      if (_onShelf) {
        widget.library.syncChapters(widget.target.itemId, chapters.length);
      }
      if (widget.continueOnOpen && !_autoOpened && chapters.isNotEmpty) {
        _autoOpened = true;
        await _continueReading();
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
      _progress = widget.library.novelProgress(widget.target.itemId);
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
  Future<void> _openReader(int index, {int charOffset = 0, bool atEnd = false}) async {
    final source = _source;
    if (source == null || _chapters.isEmpty) return;
    if (!_onShelf) _shelve(silent: true);
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => NovelReaderPage(
          library: widget.library,
          dataSource: source,
          target: widget.target,
          chapters: _chapters,
          initialChapterIndex: index,
          initialCharOffset: charOffset,
          resumeAtChapterEnd: atEnd,
        ),
      ),
    );
    if (!mounted) return;
    setState(() {
      _onShelf = widget.library.onShelf(widget.target.itemId);
      _progress = widget.library.novelProgress(widget.target.itemId);
    });
  }

  Future<void> _continueReading() async {
    final progress = _progress;
    if (progress == null || _chapters.isEmpty) {
      await _openReader(0);
      return;
    }
    final index = progress.chapterIndex.clamp(0, _chapters.length - 1);
    await _openReader(
      index,
      charOffset: progress is NovelProgress ? progress.charOffset : 0,
    );
  }

  Future<void> _openCatalog() async {
    final source = _source;
    if (source == null || _chapters.isEmpty) return;
    if (!_onShelf) _shelve(silent: true);
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => NovelCatalogPage(
          library: widget.library,
          dataSource: source,
          target: widget.target,
          chapters: _chapters,
          initialChapterIndex: _progress?.chapterIndex ?? 0,
        ),
      ),
    );
    if (!mounted) return;
    setState(() {
      _onShelf = widget.library.onShelf(widget.target.itemId);
      _progress = widget.library.novelProgress(widget.target.itemId);
    });
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
    if (failure != null) {
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
        if (_chapters.isEmpty)
          const SliverToBoxAdapter(
            child: SizedBox(
              height: 150,
              child: SourceStateView(
                state: SourceStateKind.empty,
                detail: kNoChaptersHint,
              ),
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            sliver: SliverList.builder(
              itemCount: _chapters.length,
              itemBuilder: (context, index) => ChapterTile(
                title: _chapters[index].title,
                current: _progress?.chapterIndex == index,
                onTap: () => _openReader(index),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildHeader() {
    final detail = _detail;
    return Stack(
      children: <Widget>[
        Positioned.fill(child: _buildGlow()),
        Padding(
          // 让出玻璃顶部栏（状态栏 + 工具栏）。
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
                    width: 104,
                    height: 142,
                    child: PosterCover(
                      pipeline: _pipeline,
                      url: detail?.cover ?? widget.target.cover,
                      width: 300,
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
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            color: LumeTheme.textPrimary,
                          ),
                        ),
                        if ((detail?.subtitle ?? widget.target.subtitle) !=
                            null)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(
                              detail?.subtitle ?? widget.target.subtitle!,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                color: LumeTheme.muted,
                              ),
                            ),
                          ),
                        const SizedBox(height: 8),
                        NovelChapterSummary(
                          chapterCount: _chapters.length,
                          progress: _progress,
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
                      label: Text(_progress == null ? '开始阅读' : '继续阅读'),
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

  /// 与漫画详情页同一套视觉：封面模糊 + 向页面底色渐隐（浅色晕染，见漫画详情页）。
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
          style: TextStyle(
            fontSize: 13,
            height: 1.6,
            color: LumeTheme.textSecondary,
          ),
        ),
      ),
    );
  }

  Widget _buildChapterHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 8, 6),
      child: Row(
        children: <Widget>[
          Text(
            '章节（${_chapters.length}）',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: LumeTheme.textPrimary,
            ),
          ),
          const Spacer(),
          if (_chapters.isNotEmpty)
            TextButton.icon(
              onPressed: _openCatalog,
              icon: const Icon(Icons.list, size: 16),
              label: const Text('完整目录'),
            ),
        ],
      ),
    );
  }
}
