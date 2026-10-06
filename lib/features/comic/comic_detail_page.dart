import 'dart:ui';

import 'package:flutter/material.dart';

import '../../core/reading/reading.dart';
import '../../core/source/source.dart';
import '../../core/theme/lume_theme.dart';
import '../../core/util/lume_log.dart';
import '../../shared/widgets/glass_card.dart';
import '../../shared/widgets/state_view.dart';
import '../reading/poster_card.dart';
import '../reading/section_image.dart';
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
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
          padding: const EdgeInsets.fromLTRB(16, kToolbarHeight + 44, 16, 8),
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
                            color: Colors.white,
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
                                color: Colors.white,
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
  Widget _buildGlow() {
    final cover = _detail?.cover ?? widget.target.cover;
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        if (cover != null && cover.isNotEmpty)
          ImageFiltered(
            imageFilter: ImageFilter.blur(sigmaX: 32, sigmaY: 32),
            child: SectionImage(
              pipeline: _pipeline,
              url: cover,
              targetWidth: 200,
              fit: BoxFit.cover,
            ),
          ),
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: <Color>[
                Color(0xAA000000),
                Color(0x44000000),
                Color(0xFF0B0B12),
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
            color: Colors.white70,
          ),
        ),
      ),
    );
  }

  /// 章节区标题 + 正序 / 倒序切换。
  Widget _buildChapterHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 8, 6),
      child: Row(
        children: <Widget>[
          Text(
            '章节（${_chapters.length}）',
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: Colors.white,
            ),
          ),
          const Spacer(),
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
                  color: current ? Colors.white : LumeTheme.muted,
                  fontWeight: current ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
            if (current)
              const Padding(
                padding: EdgeInsets.only(left: 6),
                child: Text(
                  '在读',
                  style: TextStyle(fontSize: 11, color: Colors.white),
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
