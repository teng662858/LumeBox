import '../download/download_selection.dart';
import 'comic_download_center.dart';

import 'dart:async';

import '../../core/source/source_picker_groups.dart';
import '../../shared/widgets/native_glass_surfaces.dart';
import '../../shared/widgets/source_translation.dart';
import '../../shared/widgets/network_owned_state.dart';

import 'package:lume_box/shared/widgets/lume_icon.dart';

import '../../shared/widgets/drawer_geometry.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/reading/reading.dart';
import '../../core/reading/comic_image_tools.dart';
import '../../core/reading/chapter_display_order.dart';
import '../../core/session/section.dart';
import '../../core/source/source.dart';
import '../../core/net/network_settings.dart';
import '../../core/theme/lume_theme.dart';
import '../../core/util/lume_log.dart';
import '../../shared/widgets/chapter_tile.dart';
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
    this.imagePipeline,
    this.downloadCenter,
  });

  final ReadingLibrary library;

  /// 图源管理端口：详情页自己打开图源，因此从书架进来也能用。
  final SourceManager manager;

  final ReadingTarget target;

  /// 平台是否提供图源运行时；透传给阅读器（为空时它自己按板块判断）。
  /// 与 `ComicPage` 的平台门同一口径，测试也靠它显式声明运行环境。
  final bool? runtimeAvailable;
  final SectionImagePipeline? imagePipeline;
  final ComicDownloadCenter? downloadCenter;

  @override
  State<ComicDetailPage> createState() => _ComicDetailPageState();
}

class _ComicDetailPageState extends State<ComicDetailPage>
    with NetworkOwnedState<ComicDetailPage> {
  NetworkProfile _sourceNetwork = NetworkProfile.none;
  late final SectionImagePipeline _pipeline =
      widget.imagePipeline ??
      SectionImagePipeline(
        cacheDir: widget.library.imageCacheDir,
        network: _sourceNetwork,
        memoryBudgetBytes: SectionImagePipeline.thumbnailBudgetBytes,
        // 封面网格按封面并发（4）跑：并发太大被图床限流，反而更多空白。
        maxConcurrent: SectionImagePipeline.coverConcurrency,
        // 漫画板块的图片缓存已按用户要求关闭（不读盘也不落盘）。
        diskCache: SectionImagePipeline.diskCacheFor(Section.comic),
        decodeTransform: (bytes) =>
            automaticUpscale(bytes, UpscaleSurface.cover),
      );

  DataSource? _source;
  SourceDetail? _detail;
  List<SourceChapter> _chapters = const <SourceChapter>[];
  ReadingProgress? _progress;
  bool _loading = true;
  bool _chaptersLoading = false;
  int _loadRevision = 0;
  String? _failure;

  /// 章节列表是否倒序展示。
  bool _descending = false;

  bool _onShelf = false;
  static const _layoutKey = 'comic.detail.compactLayout';
  bool _compact = true, _descriptionExpanded = false, _isGallery = false;
  static const _originalColumnsKey = 'comic.detail.originalColumns';
  int? _originalColumns;
  bool _originalSearchVisible = false;
  String _chapterQuery = '';
  int? _locatedIndex;
  final _chapterSearch = TextEditingController();
  final _compactScroll = ScrollController();
  final _compactChapterAnchor = GlobalKey();
  ImageContent? _galleryPreview;
  bool _galleryLoading = false;
  String? _galleryFailure;

  /// 批量下载器：第一次点「批量下载」时创建，之后复用同一个实例
  /// （进度卡片、取消、结果汇总都读它）。
  ComicDownloader? _downloader;

  /// 用户手动关掉进度 / 结果卡片；下一次开始下载时重新出现。
  bool _downloadCardHidden = false;

  @override
  void initState() {
    super.initState();
    _compact = widget.library.setting(_layoutKey) != 'false';
    _originalColumns = int.tryParse(
      widget.library.setting(_originalColumnsKey) ?? '',
    );
    _descending = ChapterDisplayOrder(
      widget.library,
      widget.target.sourceId,
    ).descending;
    _load();
  }

  @override
  void dispose() {
    // 先停下载再释放管线：管线关闭会让在飞请求返回空，下载器据此
    // 判定「这一批不下了」，而不是把剩下的图逐张记成失败。
    // Downloads are owned by the global task center.
    _chapterSearch.dispose();
    _compactScroll.dispose();
    if (widget.imagePipeline == null) _pipeline.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final revision = ++_loadRevision;
    networkRequests.cancelAll();
    setState(() {
      _loading = true;
      _chaptersLoading = false;
      _failure = null;
      _galleryPreview = null;
      _galleryLoading = false;
      _galleryFailure = null;
      _locatedIndex = null;
    });
    try {
      final (descriptors, source) = await (
        widget.manager.list(),
        widget.manager.open(widget.target.sourceId),
      ).wait;
      if (!mounted || revision != _loadRevision) return;
      _sourceNetwork =
          descriptors
              .where((source) => source.id == widget.target.sourceId)
              .firstOrNull
              ?.network ??
          NetworkProfile.none;
      final descriptor = descriptors
          .where((entry) => entry.id == widget.target.sourceId)
          .firstOrNull;
      _isGallery =
          descriptor != null &&
          SourcePickerGroups.groupFor(widget.library.section, descriptor) ==
              'photo';
      _pipeline.bindSource(source);
      // 详情页封面也在源站自己的域名上：把源站会话挂到管线上，脚本带什么它就带什么
      // （源站上了 Cloudflare 校验而图片请求不带 cf_clearance 时，封面就是一片空白）。
      if (source != null) _pipeline.bindSession(source.section, source.id);
      if (!mounted || revision != _loadRevision) return;
      if (source == null) {
        setState(() {
          _loading = false;
          _chaptersLoading = false;
          _failure = '源不可用（已停用或脚本载入失败），去探索页的源管理里检查';
        });
        return;
      }
      final detail = await networkRequests.run(
        'detail',
        () => source.detail(widget.target.itemId),
      );
      if (!mounted || revision != _loadRevision) return;
      if (detail?.cover != null) {
        _pipeline.configureImageHeaders({detail!.cover!: detail.coverHeaders});
      }
      setState(() {
        _source = source;
        _detail = detail;
        _loading = false;
        _chaptersLoading = true;
        _onShelf = widget.library.onShelf(
          widget.target.itemId,
          sourceId: widget.target.sourceId,
        );
        _progress = widget.library.progress(
          widget.target.itemId,
          sourceId: widget.target.sourceId,
        );
      });
      final chapters = await networkRequests.run(
        'chapters',
        () => source.chapters(widget.target.itemId),
      );
      if (!mounted || revision != _loadRevision) return;
      // 详情页封面也在源站自己的域名上：把源站会话挂到管线上，脚本带什么它就带什么。
      _pipeline.bindSession(source.section, source.id);
      if (detail?.cover != null) {
        _pipeline.configureImageHeaders({detail!.cover!: detail.coverHeaders});
      }
      setState(() {
        _source = source;
        _detail = detail;
        _chapters = chapters;
        _loading = false;
        _chaptersLoading = false;
        _onShelf = widget.library.onShelf(
          widget.target.itemId,
          sourceId: widget.target.sourceId,
        );
        _progress = widget.library.progress(
          widget.target.itemId,
          sourceId: widget.target.sourceId,
        );
      });
      if (_compact && _isGallery) unawaited(_loadGalleryPreview());
      // 「查看详情」本身也是历史：只写 favorite = 0 的历史行；收藏必须等
      // 用户明确点「加入书架」。
      widget.library.recordHistoryItem(
        sourceId: widget.target.sourceId,
        itemId: widget.target.itemId,
        title: detail?.title ?? widget.target.title,
        cover: detail?.cover ?? widget.target.cover,
        subtitle: detail?.subtitle ?? widget.target.subtitle,
        chapterCount: chapters.length,
      );
      // Recording ownership can adopt an older checkpoint without source metadata.
      setState(
        () => _progress = widget.library.progress(
          widget.target.itemId,
          sourceId: widget.target.sourceId,
        ),
      );
      // 已在书架：同步章节总数，未读角标才有准确口径。
      if (_onShelf) {
        widget.library.syncChapters(
          widget.target.itemId,
          chapters.length,
          sourceId: widget.target.sourceId,
        );
      }
    } on SourceException catch (error) {
      LumeLog.warn('[${widget.target.itemId}] 详情获取失败: $error');
      if (!mounted || revision != _loadRevision) return;
      setState(() {
        _loading = false;
        _chaptersLoading = false;
        _failure = error.message;
      });
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
      if (!mounted || revision != _loadRevision) return;
      setState(() {
        _loading = false;
        _chaptersLoading = false;
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
      _progress = widget.library.progress(
        widget.target.itemId,
        sourceId: widget.target.sourceId,
      );
    });
    if (!silent) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(duration: Duration(seconds: 1), content: Text('已加入书架')),
      );
    }
  }

  Future<void> _unshelve() async {
    final confirmed = await showGlassDialog<bool>(
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
    widget.library.unshelve(
      widget.target.itemId,
      sourceId: widget.target.sourceId,
    );
    setState(() {
      _onShelf = false;
      _progress = null;
    });
  }

  /// 进阅读器。[index] 为正序章节下标。
  Future<void> _openReader(int index, {int page = 0}) async {
    final source = _source;
    if (source == null || _chapters.isEmpty) return;
    // 不再在这里 `_shelve(silent: true)`：进阅读器只产生历史记录，
    // 收藏必须由用户点按钮。阅读器自己会写 favorite = 0 的历史行。
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
          network: _sourceNetwork,
        ),
      ),
    );
    if (!mounted) return;
    // 返回后主动通知历史抽屉 / 书架重新取数；不能只靠切换 Tab 刷新。
    widget.library.refresh();
    setState(() {
      _onShelf = widget.library.onShelf(
        widget.target.itemId,
        sourceId: widget.target.sourceId,
      );
      _progress = widget.library.progress(
        widget.target.itemId,
        sourceId: widget.target.sourceId,
      );
    });
  }

  /// 继续阅读：有进度就从进度进入，没有就从第一章开始。
  Future<void> _continueReading() async {
    final progress = _progress;
    if (progress == null) {
      await _openReader(0);
      return;
    }
    final matched = _chapters.indexWhere(
      (chapter) => chapter.id == progress.chapterId,
    );
    final index = matched >= 0
        ? matched
        : progress.chapterIndex.clamp(0, _chapters.length - 1);
    final page = progress is ComicProgress ? progress.page : 0;
    await _openReader(index, page: page);
  }

  // ------------------------------------------------------------------ 批量下载

  /// 惰性创建下载器：字节来源接详情页自己的图片管线，但**不落图片缓存**
  /// （下载的字节直接写导出目录，落缓存会让同一张图存两份）。
  ComicDownloader? _ensureDownloader() {
    final source = _source;
    if (source == null || _chapters.isEmpty) return null;
    return _downloader ??=
        (widget.downloadCenter ?? ComicDownloadCenter.instance).attach(
          source: source,
          itemId: widget.target.itemId,
          title: _detail?.title ?? widget.target.title,
          library: widget.library,
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
    final scope = await showLumeBottomSheet<ComicDownloadScope>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => _DownloadScopeSheet(
        chapterCount: _chapters.length,
        readChapterIndex: readChapterIndex,
      ),
    );
    if (scope == null || !mounted) return;
    final indices = scope == ComicDownloadScope.selected
        ? await selectDownloadChapters(
            context,
            _chapters,
            initial: readChapterIndex ?? 0,
          )
        : scope.indices(
            chapterCount: _chapters.length,
            readChapterIndex: readChapterIndex,
            currentIndex: readChapterIndex,
          );
    if (indices == null || !mounted) return;
    setState(() => _downloadCardHidden = false);
    await (widget.downloadCenter ?? ComicDownloadCenter.instance).enqueue(
      downloader,
      _chapters,
      indices,
    );
  }

  /// 复制下载目录路径（结果卡片上的动作：保存到相册之前，路径是唯一出口）。
  Future<void> _copyDownloadPath(String path) async {
    await Clipboard.setData(ClipboardData(text: path));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(duration: Duration(seconds: 1), content: Text('已复制下载目录')),
    );
  }

  Widget _layoutMenu() => PopupMenuButton<bool>(
    key: const Key('comic-detail-layout'),
    tooltip: '详情页样式',
    icon: const Icon(Icons.view_compact_outlined),
    onSelected: (value) {
      widget.library.setSetting(_layoutKey, '$value');
      setState(() => _compact = value);
      if (value && _isGallery && _galleryPreview == null && !_galleryLoading) {
        unawaited(_loadGalleryPreview());
      }
    },
    itemBuilder: (_) => [
      CheckedPopupMenuItem(
        value: true,
        checked: _compact,
        child: const Text('紧凑版（新版）'),
      ),
      CheckedPopupMenuItem(
        value: false,
        checked: !_compact,
        child: const Text('原版详情页'),
      ),
    ],
  );

  Future<void> _loadGalleryPreview() async {
    final source = _source;
    if (!_isGallery || source == null || _chapters.isEmpty || _galleryLoading) {
      return;
    }
    final revision = _loadRevision;
    setState(() {
      _galleryLoading = true;
      _galleryFailure = null;
    });
    try {
      final content = await networkRequests.run(
        'gallery-preview',
        () => source.content(
          itemId: widget.target.itemId,
          chapterId: _chapters.first.id,
        ),
      );
      if (!mounted || revision != _loadRevision) return;
      if (content is! ImageContent) throw StateError('源没有返回图片列表');
      _pipeline.configureImageHeaders(content.imageHeaders);
      setState(() => _galleryPreview = content);
    } catch (_) {
      if (mounted && revision == _loadRevision) {
        setState(() => _galleryFailure = '预览暂未加载，可直接浏览图集');
      }
    } finally {
      if (mounted && revision == _loadRevision) {
        setState(() => _galleryLoading = false);
      }
    }
  }

  List<int> get _visibleChapterIndexes {
    final order = ChapterDisplayOrder(widget.library, widget.target.sourceId);
    final indexes = order.automatic
        ? ChapterDisplayOrder.correctedIndexes(_chapters)
        : List.generate(_chapters.length, (i) => i);
    final sorted = _descending ? indexes.reversed : indexes;
    return sorted
        .where(
          (i) => _locatedIndex != null
              ? i == _locatedIndex
              : _chapters[i].title.toLowerCase().contains(
                  _chapterQuery.toLowerCase(),
                ),
        )
        .toList();
  }

  bool get _useChapterGrid => !_isGallery && _chapters.isNotEmpty;

  void _locateReading() {
    final progress = _progress;
    if (progress == null || _chapters.isEmpty) return;
    final matched = _chapters.indexWhere(
      (chapter) => chapter.id == progress.chapterId,
    );
    final index = matched >= 0
        ? matched
        : progress.chapterIndex.clamp(0, _chapters.length - 1);
    _chapterSearch.clear();
    setState(() {
      _locatedIndex = index;
      _chapterQuery = '';
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final anchor = _compactChapterAnchor.currentContext;
      if (anchor != null) {
        Scrollable.ensureVisible(
          anchor,
          duration: const Duration(milliseconds: 250),
          alignment: .05,
        );
      }
    });
  }

  String get _compactProgressLabel {
    final progress = _progress;
    if (progress == null) return '';
    final title =
        _chapters
            .where((chapter) => chapter.id == progress.chapterId)
            .firstOrNull
            ?.title ??
        progress.chapterTitle;
    return progress is ComicProgress && title.isNotEmpty
        ? '$title · 第 ${progress.page + 1} 页'
        : progress.describe();
  }

  Widget _compactHeader() {
    final colors = Theme.of(context).colorScheme;
    final detail = _detail;
    final cover = detail?.cover ?? widget.target.cover;
    final info = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SourceText(
          detail?.title ?? widget.target.title,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 24,
            height: 1.25,
            fontWeight: FontWeight.w700,
            color: colors.onSurface,
          ),
        ),
        if (detail?.author?.isNotEmpty == true)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              '作者 · ${detail!.author}',
              style: TextStyle(fontSize: 13, color: colors.onSurfaceVariant),
            ),
          ),
        if ((detail?.subtitle ?? widget.target.subtitle)?.isNotEmpty == true)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              detail?.subtitle ?? widget.target.subtitle!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
            ),
          ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final text in [
              if (detail?.status?.isNotEmpty == true) detail!.status!,
              ...?detail?.tags.take(4),
            ])
              DecoratedBox(
                decoration: BoxDecoration(
                  color: colors.primary.withValues(alpha: .07),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 3,
                  ),
                  child: Text(
                    text,
                    style: TextStyle(fontSize: 11, color: colors.primary),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          _chaptersLoading
              ? '正在加载目录…'
              : _isGallery
              ? '共 ${_chapters.length} 组'
              : '共 ${_chapters.length} 话',
          style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
        ),
        if (_source != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              '来源 · ${_source!.name}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: colors.onSurfaceVariant),
            ),
          ),
      ],
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LayoutBuilder(
            builder: (context, bounds) {
              final narrow =
                  bounds.maxWidth < 310 ||
                  MediaQuery.textScalerOf(context).scale(1) > 1.5;
              final poster = SizedBox(
                width: narrow ? 90 : 110,
                height: narrow ? 123 : 150,
                child: PosterCover(
                  pipeline: _pipeline,
                  url: cover,
                  title: detail?.title ?? widget.target.title,
                  width: 330,
                  borderRadius: BorderRadius.circular(12),
                ),
              );
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  poster,
                  const SizedBox(width: 16),
                  Expanded(child: info),
                ],
              );
            },
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  key: const Key('comic-detail-read'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(44),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onPressed: _chapters.isEmpty ? null : _continueReading,
                  icon: Icon(
                    _isGallery
                        ? Icons.photo_library_outlined
                        : Icons.menu_book_outlined,
                    size: 19,
                  ),
                  label: Text(
                    _isGallery
                        ? '浏览图集'
                        : _progress == null
                        ? '开始阅读'
                        : '继续阅读',
                  ),
                ),
              ),
              const SizedBox(width: 10),
              IconButton.outlined(
                key: const Key('comic-detail-favorite'),
                tooltip: _onShelf ? '移出书架' : '加入书架',
                onPressed: _source == null
                    ? null
                    : _onShelf
                    ? _unshelve
                    : _shelve,
                style: IconButton.styleFrom(
                  minimumSize: const Size(44, 44),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                icon: Icon(_onShelf ? Icons.bookmark : Icons.bookmark_border),
              ),
              const SizedBox(width: 4),
              SourceTranslationAction(
                texts: [
                  detail?.title ?? widget.target.title,
                  if (detail?.description != null) detail!.description!,
                ],
              ),
            ],
          ),
          if (_progress != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '读至 $_compactProgressLabel',
                style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
              ),
            ),
          if (detail?.updatedAt != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '更新于 ${detail!.updatedAt!.year}-${detail.updatedAt!.month.toString().padLeft(2, '0')}-${detail.updatedAt!.day.toString().padLeft(2, '0')}',
                style: TextStyle(fontSize: 11, color: colors.onSurfaceVariant),
              ),
            ),
        ],
      ),
    );
  }

  Widget _compactDescription() {
    final description = _detail?.description?.trim() ?? '';
    if (description.isEmpty) return const SizedBox(height: 12);
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '简介',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: colors.onSurface,
                  ),
                ),
              ),
            ],
          ),
          InkWell(
            key: const Key('comic-detail-description'),
            onTap: () =>
                setState(() => _descriptionExpanded = !_descriptionExpanded),
            child: SourceText(
              description,
              maxLines: _descriptionExpanded ? null : 2,
              overflow: _descriptionExpanded ? null : TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                height: 1.6,
                color: colors.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _compactGalleryImages() {
    if (!_isGallery) return const SizedBox.shrink();
    final images = _galleryPreview?.images ?? [];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            images.isEmpty
                ? '图片预览'
                : '${_chapters.length > 1 ? '首组' : '共'} ${images.length} 张图片',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 10),
          if (_galleryLoading)
            const LinearProgressIndicator()
          else if (_galleryFailure != null)
            Row(
              children: [
                Expanded(
                  child: Text(
                    _galleryFailure!,
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
                IconButton(
                  tooltip: '重试图片预览',
                  onPressed: _loadGalleryPreview,
                  icon: const Icon(Icons.refresh),
                ),
              ],
            )
          else if (images.isNotEmpty)
            GridView.builder(
              key: const Key('comic-detail-gallery-preview'),
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              padding: EdgeInsets.zero,
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                crossAxisSpacing: 8,
                mainAxisSpacing: 8,
                childAspectRatio: .8,
              ),
              itemCount: images.length.clamp(0, 6),
              itemBuilder: (_, i) => InkWell(
                onTap: () => _openReader(0, page: i),
                child: SectionImage(
                  pipeline: _pipeline,
                  url: images[i],
                  targetWidth: 360,
                  headers: _galleryPreview!.imageHeaders[images[i]] ?? const {},
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _compactChapterTools() => Padding(
    key: _compactChapterAnchor,
    padding: const EdgeInsets.fromLTRB(16, 20, 16, 10),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                _chaptersLoading
                    ? '章节加载中…'
                    : '${_isGallery ? '图集分组' : '章节'}（${_chapters.length}）',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            IconButton(
              tooltip: '定位上次阅读',
              onPressed: _progress == null ? null : _locateReading,
              icon: const Icon(Icons.my_location_outlined, size: 20),
            ),
            TextButton(
              onPressed: () => setState(() {
                _descending = !_descending;
                ChapterDisplayOrder(
                  widget.library,
                  widget.target.sourceId,
                ).descending = _descending;
              }),
              child: Text(_descending ? '倒序' : '正序'),
            ),
            IconButton(
              tooltip: '批量下载',
              onPressed: _chapters.isEmpty ? null : _startBatchDownload,
              icon: const Icon(Icons.download_outlined, size: 20),
            ),
          ],
        ),
        TextField(
          key: const Key('comic-detail-chapter-search'),
          controller: _chapterSearch,
          decoration: InputDecoration(
            hintText: _isGallery ? '搜索图集分组' : '搜索章节名称或序号',
            prefixIcon: const Icon(Icons.search),
            isDense: true,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            suffixIcon: _chapterQuery.isNotEmpty || _locatedIndex != null
                ? IconButton(
                    tooltip: '显示全部章节',
                    onPressed: () {
                      _chapterSearch.clear();
                      setState(() {
                        _chapterQuery = '';
                        _locatedIndex = null;
                      });
                    },
                    icon: const Icon(Icons.close),
                  )
                : null,
          ),
          onChanged: (value) => setState(() {
            _chapterQuery = value;
            _locatedIndex = null;
          }),
        ),
        if (_locatedIndex != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              '上次阅读 · ${_chapters[_locatedIndex!].title}',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
          ),
      ],
    ),
  );

  Widget _compactChapter(int index, {bool grid = false}) {
    final colors = Theme.of(context).colorScheme;
    final active = _progress?.chapterId == _chapters[index].id;
    return Material(
      color: active ? colors.primaryContainer : colors.surfaceContainerLow,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        key: ValueKey('comic-detail-chapter-$index'),
        borderRadius: BorderRadius.circular(12),
        onTap: () => _openReader(index),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: 12,
            vertical: grid ? 4 : 14,
          ),
          child: Row(
            children: [
              if (!grid) ...[
                Icon(
                  active
                      ? Icons.bookmark
                      : _isRead(index)
                      ? Icons.check
                      : Icons.menu_book_outlined,
                  size: 18,
                  color: active ? colors.primary : colors.onSurfaceVariant,
                ),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: Text(
                  _chapters[index].title,
                  maxLines: grid ? 2 : 3,
                  overflow: TextOverflow.ellipsis,
                  textAlign: grid ? TextAlign.center : TextAlign.left,
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.3,
                    fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                    color: active
                        ? colors.onPrimaryContainer
                        : _isRead(index)
                        ? colors.onSurfaceVariant.withValues(alpha: .65)
                        : colors.onSurface,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _compactRelated() {
    final items = _detail?.related ?? [];
    if (items.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            '同源推荐',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 170,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: items.length.clamp(0, 12),
              separatorBuilder: (_, _) => const SizedBox(width: 10),
              itemBuilder: (_, i) {
                final item = items[i];
                return SizedBox(
                  width: 100,
                  child: InkWell(
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => ComicDetailPage(
                          library: widget.library,
                          manager: widget.manager,
                          target: ReadingTarget(
                            sourceId: widget.target.sourceId,
                            itemId: item.id,
                            title: item.title,
                            cover: item.cover,
                            subtitle: item.subtitle,
                          ),
                          runtimeAvailable: widget.runtimeAvailable,
                        ),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(
                          height: 136,
                          child: PosterCover(
                            pipeline: _pipeline,
                            url: item.cover,
                            title: item.title,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          item.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _compactBody() {
    if (_loading) return const SourceStateView(state: SourceStateKind.loading);
    if (_failure != null && _detail == null && _chapters.isEmpty) {
      return SourceStateView(
        state: SourceStateKind.scriptError,
        detail: _failure,
        onRetry: _load,
      );
    }
    final indexes = _visibleChapterIndexes;
    final scale = MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 2.5);
    final columns = ((MediaQuery.sizeOf(context).width - 32) / (84 * scale))
        .floor()
        .clamp(2, 5);
    return CustomScrollView(
      key: const Key('comic-detail-compact'),
      controller: _compactScroll,
      slivers: [
        SliverToBoxAdapter(child: _compactHeader()),
        SliverToBoxAdapter(child: _compactDescription()),
        if (_isGallery) SliverToBoxAdapter(child: _compactGalleryImages()),
        SliverToBoxAdapter(child: _compactChapterTools()),
        SliverToBoxAdapter(child: _buildDownloadCard()),
        if (_chaptersLoading)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.all(20),
              child: LinearProgressIndicator(),
            ),
          )
        else if (_failure != null)
          SliverToBoxAdapter(
            child: SourceStateView(
              state: SourceStateKind.networkError,
              detail: _failure,
              onRetry: _load,
            ),
          )
        else if (indexes.isEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(_chapters.isEmpty ? kNoChaptersHint : '没有匹配的章节'),
            ),
          )
        else if (_useChapterGrid)
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            sliver: SliverGrid.builder(
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: columns,
                crossAxisSpacing: 8,
                mainAxisSpacing: 8,
                mainAxisExtent: 44 * scale,
              ),
              itemCount: indexes.length,
              itemBuilder: (_, i) => _compactChapter(indexes[i], grid: true),
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            sliver: SliverList.separated(
              itemCount: indexes.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (_, i) => _compactChapter(indexes[i]),
            ),
          ),
        SliverToBoxAdapter(child: _compactRelated()),
        const SliverToBoxAdapter(child: SizedBox(height: 24)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_compact) {
      return Scaffold(
        backgroundColor: Theme.of(context).colorScheme.surface,
        appBar: AppBar(
          title: Text(_isGallery ? '图集详情' : '漫画详情'),
          actions: [_layoutMenu()],
        ),
        body: SafeArea(top: false, child: _compactBody()),
      );
    }
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: GlassAppBar(
        actions: [_layoutMenu()],
        title: Text(
          _detail?.title ?? widget.target.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: Material(color: LumeTheme.base, child: _buildBody()),
    );
  }

  Widget _buildBody() {
    final indexes = _visibleChapterIndexes;
    if (_loading) return const SourceStateView(state: SourceStateKind.loading);
    final failure = _failure;
    if (failure != null && _detail == null && _chapters.isEmpty) {
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
        if (_chaptersLoading)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.all(20),
              child: LinearProgressIndicator(),
            ),
          )
        else if (_failure != null)
          SliverToBoxAdapter(
            child: SourceStateView(
              state: SourceStateKind.networkError,
              detail: _failure,
              onRetry: _load,
            ),
          )
        else if (_chapters.isEmpty)
          const SliverToBoxAdapter(
            child: SizedBox(
              height: 160,
              child: SourceStateView(
                state: SourceStateKind.empty,
                detail: kNoChaptersHint,
              ),
            ),
          )
        else if (indexes.isEmpty)
          const SliverToBoxAdapter(
            child: Padding(padding: EdgeInsets.all(24), child: Text('没有匹配的章节')),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            sliver: SliverLayoutBuilder(
              builder: (context, constraints) {
                final scale = MediaQuery.textScalerOf(context).scale(16) / 16;
                final columns = constraints.crossAxisExtent < 300 || scale > 1.8
                    ? 1
                    : _effectiveOriginalColumns;
                if (columns == 1) {
                  return SliverList.separated(
                    itemCount: indexes.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 10),
                    itemBuilder: (_, position) =>
                        _originalChapter(indexes[position]),
                  );
                }
                return SliverGrid.builder(
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    crossAxisSpacing: 10,
                    mainAxisSpacing: 10,
                    mainAxisExtent: 52 * scale.clamp(1.0, 1.8),
                  ),
                  itemCount: indexes.length,
                  itemBuilder: (_, position) =>
                      _originalChapter(indexes[position]),
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
                      title: detail?.title ?? widget.target.title,
                      width: 320,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        SourceText(
                          detail?.title ?? widget.target.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: LumeTypography.pageTitleSize,
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
                                fontWeight: FontWeight.w600,
                                fontSize: LumeTypography.descriptionSize,
                                color: LumeTheme.descriptionColor,
                              ),
                            ),
                          ),
                        const SizedBox(height: 8),
                        Text(
                          _chaptersLoading
                              ? '正在加载目录…'
                              : '共 ${_chapters.length} 章',
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: LumeTypography.descriptionSize,
                            color: LumeTheme.descriptionColor,
                          ),
                        ),
                        if (progress != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              '读至 ${progress.describe()}',
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: LumeTypography.descriptionSize,
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
              TextButton(
                onPressed: () => showImageProcessingInfo(
                  context,
                  pipeline: _pipeline,
                  url: detail?.cover ?? widget.target.cover,
                ),
                child: const Text('图片信息 / 超分状态'),
              ),
              Row(
                children: <Widget>[
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _chapters.isEmpty ? null : _continueReading,
                      icon: const LumeIcon(
                        Icons.menu_book,
                        slot: 'comic_detail_page.1',
                        size: 18,
                      ),
                      label: Text(progress == null ? '开始阅读' : '继续阅读'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  OutlinedButton(
                    onPressed: _onShelf ? _unshelve : _shelve,
                    child: Text(_onShelf ? '移出书架' : '加入书架'),
                  ),
                  const SizedBox(width: 4),
                  SourceTranslationAction(
                    texts: [
                      detail?.title ?? widget.target.title,
                      if (detail?.description != null) detail!.description!,
                    ],
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
    if (description == null || description.trim().isEmpty) {
      return const SizedBox(height: 4);
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      child: GlassCard(
        radius: 14,
        padding: const EdgeInsets.all(14),
        onTap: () =>
            setState(() => _descriptionExpanded = !_descriptionExpanded),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('简介', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            SourceText(
              description,
              maxLines: _descriptionExpanded ? null : 2,
              overflow: _descriptionExpanded
                  ? TextOverflow.visible
                  : TextOverflow.ellipsis,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: LumeTypography.bodySize,
                height: 1.6,
                color: LumeTheme.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  int get _effectiveOriginalColumns =>
      _originalColumns == 1 || _originalColumns == 2
      ? _originalColumns!
      : _chapters.any((chapter) => chapter.title.length > 18)
      ? 1
      : 2;

  Widget _originalChapter(int index) {
    final current = _progress?.chapterId == _chapters[index].id;
    return GlassCard(
      key: ValueKey('comic-detail-original-chapter-$index'),
      radius: 12,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      color: current ? LumeTheme.accent.withValues(alpha: .10) : null,
      onTap: () => _openReader(index),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 42),
        child: Row(
          children: [
            Expanded(
              child: Text(
                _chapters[index].title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 16,
                  height: 1.3,
                  fontWeight: FontWeight.w600,
                  color: current
                      ? LumeTheme.accent
                      : _isRead(index)
                      ? LumeTheme.textSecondary
                      : LumeTheme.textPrimary,
                ),
              ),
            ),
            if (current || _isRead(index)) ...[
              const SizedBox(width: 4),
              Icon(
                current ? Icons.bookmark : Icons.done,
                size: 14,
                color: current ? LumeTheme.accent : LumeTheme.textSecondary,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildChapterHeader() {
    final running = _downloader?.progress.running ?? false;
    final controls = Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        IconButton(
          tooltip: '搜索章节',
          onPressed: () => setState(() {
            _originalSearchVisible = !_originalSearchVisible;
          }),
          icon: const Icon(Icons.search, size: 20),
        ),
        IconButton(
          tooltip: '定位在读',
          onPressed: _progress == null ? null : _locateReading,
          icon: const Icon(Icons.my_location, size: 20),
        ),
        PopupMenuButton<int>(
          tooltip: '章节列数',
          icon: const Icon(Icons.view_column_outlined, size: 20),
          onSelected: (value) {
            widget.library.setSetting(_originalColumnsKey, '$value');
            setState(() => _originalColumns = value);
          },
          itemBuilder: (_) => [
            for (final value in [1, 2])
              CheckedPopupMenuItem(
                value: value,
                checked: _effectiveOriginalColumns == value,
                child: Text(value == 1 ? '一列' : '两列'),
              ),
          ],
        ),
        TextButton(
          onPressed: () {
            setState(() => _descending = !_descending);
            ChapterDisplayOrder(
              widget.library,
              widget.target.sourceId,
            ).descending = _descending;
          },
          child: Text(_descending ? '倒序' : '正序'),
        ),
        PopupMenuButton<String>(
          tooltip: '更多章节操作',
          onSelected: (_) => _startBatchDownload(),
          itemBuilder: (_) => [
            PopupMenuItem(
              value: 'download',
              enabled: _chapters.isNotEmpty && !running,
              child: Text(running ? '下载中' : '批量下载'),
            ),
          ],
        ),
      ],
    );
    final heading = Text(
      _chaptersLoading ? '章节加载中…' : '章节（${_chapters.length}）',
      style: TextStyle(
        fontSize: LumeTypography.titleSize,
        fontWeight: FontWeight.w600,
        color: LumeTheme.textPrimary,
      ),
    );
    return Padding(
      key: _compactChapterAnchor,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LayoutBuilder(
            builder: (_, constraints) =>
                constraints.maxWidth < 390 ||
                    MediaQuery.textScalerOf(context).scale(16) > 20
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [heading, controls],
                  )
                : Row(
                    children: [
                      Expanded(child: heading),
                      controls,
                    ],
                  ),
          ),
          if (_originalSearchVisible ||
              _chapterQuery.isNotEmpty ||
              _locatedIndex != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: TextField(
                controller: _chapterSearch,
                onChanged: (value) => setState(() {
                  _chapterQuery = value.trim();
                  _locatedIndex = null;
                }),
                decoration: InputDecoration(
                  hintText: '搜索章节名称',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: IconButton(
                    tooltip: '显示全部章节',
                    onPressed: () {
                      _chapterSearch.clear();
                      setState(() {
                        _chapterQuery = '';
                        _locatedIndex = null;
                      });
                    },
                    icon: const Icon(Icons.close),
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),
          if (_locatedIndex != null)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text('已定位在读章节 · 清除后显示全部'),
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
    if (downloader == null || _downloadCardHidden) {
      return const SizedBox.shrink();
    }
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
          scope == ComicDownloadScope.selected
              ? chapterCount
              : scope
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
                Text(
                  '批量下载',
                  style: TextStyle(
                    fontSize: LumeTypography.sectionTitleSize,
                    fontWeight: FontWeight.w600,
                    color: LumeTheme.textPrimary,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '图片存到应用内的导出目录（按作品 / 章节分目录），'
                  '已下过的图会自动跳过，可随时取消。',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: LumeTypography.descriptionSize,
                    height: 1.5,
                    color: LumeTheme.descriptionColor,
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
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: LumeTypography.titleSize,
                        color: LumeTheme.textPrimary,
                      ),
                    ),
                    subtitle: Text(
                      switch (scope) {
                        ComicDownloadScope.selected => '勾选需要保存的章节',
                        ComicDownloadScope.all => '整部作品，共 $count 章',
                        ComicDownloadScope.unread =>
                          count == 0 ? '没有未读章节' : '进度之后，共 $count 章',
                        ComicDownloadScope.current =>
                          count == 0
                              ? '暂无可下载章节'
                              : '只下第 ${(readChapterIndex ?? 0) + 1} 章',
                      },
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: LumeTypography.descriptionSize,
                        color: LumeTheme.descriptionColor,
                      ),
                    ),
                    trailing: count > 0
                        ? LumeIcon(
                            Icons.chevron_right,
                            slot: 'comic_detail_page.4',
                            color: LumeTheme.muted,
                          )
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
              LumeIcon(
                running
                    ? Icons.downloading
                    : (progress.status == ComicDownloadStatus.done
                          ? Icons.check_circle_outline
                          : Icons.cancel_outlined),
                slot: 'comic_detail_page.5',
                variant: true,
                size: 18,
                color: LumeTheme.muted,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  _title(),
                  style: TextStyle(
                    fontSize: LumeTypography.titleSize,
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
              style: TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: LumeTypography.descriptionSize,
                color: LumeTheme.descriptionColor,
              ),
            ),
          ] else ...<Widget>[
            const SizedBox(height: 4),
            Text(
              _summary(),
              style: TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: LumeTypography.descriptionSize,
                color: LumeTheme.descriptionColor,
              ),
            ),
            for (final failure in progress.failures.take(3))
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Text(
                  failure,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: LumeTypography.descriptionSize,
                    color: LumeTheme.danger,
                  ),
                ),
              ),
            if (progress.failures.length > 3)
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Text(
                  '…另有 ${progress.failures.length - 3} 章失败',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: LumeTypography.descriptionSize,
                    color: LumeTheme.descriptionColor,
                  ),
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
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: LumeTypography.captionSize,
                      color: LumeTheme.muted,
                    ),
                  ),
                ),
                TextButton.icon(
                  onPressed: onCopy,
                  icon: const LumeIcon(
                    Icons.copy,
                    slot: 'comic_detail_page.6',
                    size: 15,
                  ),
                  label: const Text(
                    '复制路径',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: LumeTypography.descriptionSize,
                    ),
                  ),
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
