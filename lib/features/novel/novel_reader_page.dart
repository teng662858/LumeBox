import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/reading/reading.dart';
import '../../core/source/source.dart';
import '../../core/util/lume_log.dart';
import '../../shared/widgets/state_view.dart';
import 'novel_bookmarks.dart';
import 'novel_page_painter.dart';
import 'novel_pagination.dart';
import 'novel_turn_view.dart';
import 'novel_typesetting.dart';

/// 小说阅读器：自研分页引擎 + CustomPainter 渲染，**不用 WebView**。
///
/// 结构：
/// - 分页：`NovelPaginator` 逐段排一次、按行切页，结果按「章节 + 视口 + 排版」
///   缓存；换主题不重排，只有换排版参数或视口才重排。
/// - 渲染：`NovelPageCanvas` 只排当前页可见的几段，`NovelPagePainter` 画背景、
///   正文、页眉页脚；相邻页的 canvas 只多留一份。
/// - 翻页：`NovelTurnView` 提供仿真 Curl / 平移 / 覆盖三种分页翻页，
///   上下连续滚动走 `ListView`（页与页无缝拼接）。
/// - 主题：阅读主题独立于 App 全局主题（羊皮纸 / 夜间深灰 / 护眼绿 / 纯白 /
///   自定义背景色），整页背景、正文、页眉页脚、工具栏一起换。
///
/// 资源纪律：退出时清空排版缓存与页画布、取消在飞章节请求（数据源调用）、
/// 落库阅读进度。小说进度 = 章节索引 + 章节内字符偏移量。
class NovelReaderPage extends StatefulWidget {
  const NovelReaderPage({
    super.key,
    required this.library,
    required this.dataSource,
    required this.target,
    required this.chapters,
    required this.initialChapterIndex,
    this.initialCharOffset = 0,
    this.resumeAtChapterEnd = false,
  });

  final ReadingLibrary library;
  final DataSource dataSource;
  final ReadingTarget target;
  final List<SourceChapter> chapters;
  final int initialChapterIndex;

  /// 续读位置：章节内字符偏移量。
  final int initialCharOffset;

  /// 从上一章往回翻时，停在上一章的最后一页。
  final bool resumeAtChapterEnd;

  @override
  State<NovelReaderPage> createState() => _NovelReaderPageState();
}

class _NovelReaderPageState extends State<NovelReaderPage> {
  final GlobalKey<NovelTurnViewState> _turnKey =
      GlobalKey<NovelTurnViewState>();
  final NovelLayoutCache _cache = NovelLayoutCache();

  /// 页画布缓存（当前页 ± 1）。换排版 / 换主题 / 换章时重建并释放旧的。
  final Map<int, NovelPageCanvas> _canvases = <int, NovelPageCanvas>{};
  String _canvasKey = '';

  late NovelTypesetting _typesetting;
  late NovelReaderTheme _theme;
  late NovelTurnMode _turnMode;

  late List<SourceChapter> _chapters;
  late int _chapterIndex;
  NovelChapterText? _text;
  ChapterPagination? _pagination;

  int _pageIndex = 0;
  Size? _viewport;
  bool _loadingChapter = true;
  bool _paginating = false;
  String? _failure;
  bool _toolbar = false;
  _PanelTab _panel = _PanelTab.catalog;

  Timer? _saveTimer;
  ScrollController? _scrollController;

  /// 本书书签（进阅读器时读一次，增删后写回）。
  List<NovelBookmark> _bookmarks = const <NovelBookmark>[];

  /// 自动翻页：定时器 + 间隔（秒）。null 表示未开启。
  Timer? _autoPageTimer;
  int _autoPageSeconds = 15;

  /// 章节内查找：关键词与命中位置。
  String _searchKeyword = '';
  List<int> _searchHits = const <int>[];
  int _searchHitIndex = -1;

  /// 分页结果对应的排版签名，用于判断是否需要重排。
  String? _paginatedSignature;

  static const int _canvasCacheSize = 3;

  @override
  void initState() {
    super.initState();
    _typesetting = NovelTypesetting.decode(
      widget.library.setting(NovelTypesetting.settingKey),
    );
    _theme = NovelReaderTheme.load(widget.library);
    _turnMode = NovelTurnMode.fromId(
      widget.library.setting(NovelTurnMode.settingKey),
    );
    _bookmarks = NovelBookmarks.decode(
      widget.library.setting(NovelBookmarks.keyFor(widget.target.itemId)),
    );
    _autoPageSeconds = int.tryParse(
          widget.library.setting(NovelTypesetting.autoPageKey) ?? '',
        ) ??
        15;
    _chapters = widget.chapters;
    _chapterIndex = _chapters.isEmpty
        ? 0
        : widget.initialChapterIndex.clamp(0, _chapters.length - 1);
    // 进阅读器即入架：书架上要有这条记录，进度才有归属。
    widget.library.shelve(
      sourceId: widget.target.sourceId,
      itemId: widget.target.itemId,
      title: widget.target.title,
      cover: widget.target.cover,
      subtitle: widget.target.subtitle,
      chapterCount: _chapters.length,
    );
    _loadChapter(
      offset: widget.initialCharOffset,
      atEnd: widget.resumeAtChapterEnd,
    );
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _autoPageTimer?.cancel();
    _saveProgress();
    _scrollController?.dispose();
    _disposeCanvases();
    // 退出后不会再有绘制帧，待释放的页画布不必再等下一帧：立刻归还。
    _flushPendingDisposal();
    _cache.clear();
    super.dispose();
  }

  // ------------------------------------------------------------------ 章节

  Future<void> _loadChapter({int offset = 0, bool atEnd = false}) async {
    if (_chapters.isEmpty) {
      setState(() {
        _loadingChapter = false;
        _failure = null;
      });
      return;
    }
    final chapter = _chapters[_chapterIndex];
    setState(() {
      _loadingChapter = true;
      _failure = null;
      _paginating = false;
      _paginatedSignature = null;
      _disposeCanvases();
    });

    // 文本缓存优先：切章来回不重复拉取与规范化。
    var text = _cache.text(chapter.id);
    if (text == null) {
      try {
        final content = await widget.dataSource.content(
          itemId: widget.target.itemId,
          chapterId: chapter.id,
        );
        if (!mounted) return;
        if (content is! TextContent) {
          setState(() {
            _loadingChapter = false;
            _text = null;
            _pagination = null;
            _failure = content == null
                ? '本章暂无内容'
                : '该章节不是文本内容（图源返回了其他类型）';
          });
          return;
        }
        text = NovelChapterText.parse(content.text);
        _cache.putText(chapter.id, text);
      } on SourceException catch (error) {
        LumeLog.warn('[${widget.target.itemId}] 章节文本获取失败: $error');
        if (!mounted) return;
        setState(() {
          _loadingChapter = false;
          _failure = error.message;
        });
        return;
      } catch (error, stackTrace) {
        LumeLog.error(error, stackTrace);
        if (!mounted) return;
        setState(() {
          _loadingChapter = false;
          _failure = '$error';
        });
        return;
      }
    }
    if (!mounted) return;
    setState(() {
      _text = text;
      _pagination = null;
      _pageIndex = 0;
      _loadingChapter = false;
      _failure = null;
      // 记住恢复目标：分页完成后按字符偏移落到具体页。
      _pendingRestoreChar = atEnd ? (text!.length) : offset;
      _prefetchNeighbours();
    });
    final size = _viewport;
    if (size != null) _schedulePagination(size);
  }

  /// 恢复目标（字符偏移）。分页完成后消费一次即清空。
  int? _pendingRestoreChar;

  /// 预取相邻章节文本，让「下一章」不必等网络。
  void _prefetchNeighbours() {
    for (final index in <int>[_chapterIndex + 1, _chapterIndex - 1]) {
      if (index < 0 || index >= _chapters.length) continue;
      final chapter = _chapters[index];
      if (_cache.text(chapter.id) != null) continue;
      unawaited(_prefetchChapter(chapter.id));
    }
  }

  Future<void> _prefetchChapter(String chapterId) async {
    try {
      final content = await widget.dataSource.content(
        itemId: widget.target.itemId,
        chapterId: chapterId,
      );
      if (!mounted) return;
      if (content is TextContent) {
        _cache.putText(chapterId, NovelChapterText.parse(content.text));
      }
    } catch (error) {
      // 预取失败只记日志：它只是提前准备。
      LumeLog.warn('章节预取失败: $chapterId ($error)');
    }
  }

  // ------------------------------------------------------------------ 分页

  /// 是否需要用当前视口重新分页。
  bool _needsPagination(Size size) =>
      _pagination == null ||
      _viewport != size ||
      _paginatedSignature != _signatureFor(size);

  String _signatureFor(Size size) => ChapterPagination.cacheKey(
        chapterId: _chapters.isEmpty ? '' : _chapters[_chapterIndex].id,
        viewport: size,
        typesetting: _typesetting,
        reserveChrome: _turnMode != NovelTurnMode.scroll,
        leadingParagraphSpacing: _turnMode == NovelTurnMode.scroll,
      );

  /// 排版在下一帧执行：分页是 CPU 活（逐段 TextPainter），
  /// 不放在 build / layout 里，先让「正在排版」这一帧画出来。
  void _schedulePagination(Size size) {
    if (_paginating) return;
    _paginating = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _paginate(size);
    });
  }

  void _paginate(Size size) {
    final text = _text;
    if (text == null || _chapters.isEmpty) {
      setState(() {
        _paginating = false;
        _viewport = size;
      });
      return;
    }
    final chapterId = _chapters[_chapterIndex].id;
    final scroll = _turnMode == NovelTurnMode.scroll;
    final key = ChapterPagination.cacheKey(
      chapterId: chapterId,
      viewport: size,
      typesetting: _typesetting,
      reserveChrome: !scroll,
      leadingParagraphSpacing: scroll,
    );
    var pagination = _cache.pagination(key);
    if (pagination == null) {
      pagination = const NovelPaginator().paginate(
        chapterId: chapterId,
        text: text,
        viewport: size,
        typesetting: _typesetting,
        reserveChrome: !scroll,
        leadingParagraphSpacing: scroll,
      );
      _cache.putPagination(pagination);
    }
    final restore = _pendingRestoreChar;
    final targetPage = restore == null
        ? _pageIndex.clamp(0, pagination.pageCount - 1)
        : pagination.pageIndexForChar(restore);
    setState(() {
      _pagination = pagination;
      _paginating = false;
      _viewport = size;
      _paginatedSignature = key;
      _pendingRestoreChar = null;
      _pageIndex = targetPage;
      _disposeCanvases();
    });
    _rebuildScrollController(size);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _turnKey.currentState?.jumpTo(targetPage);
      _saveProgress();
    });
  }

  void _rebuildScrollController(Size size) {
    final previous = _scrollController;
    _scrollController = _turnMode == NovelTurnMode.scroll
        ? ScrollController(initialScrollOffset: _pageIndex * size.height)
        : null;
    if (previous != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => previous.dispose());
    }
  }

  // ------------------------------------------------------------------ 画布

  /// 取一页的画布。[index] 越界时返回 null（由提示页接管）。
  NovelPageCanvas? _canvasFor(int index) {
    final pagination = _pagination;
    if (pagination == null) return null;
    if (index < 0 || index >= pagination.pageCount) return null;
    final key = _canvasKeyFor(pagination);
    if (key != _canvasKey) {
      _disposeCanvases();
      _canvasKey = key;
    }
    final cached = _canvases.remove(index);
    if (cached != null) {
      _canvases[index] = cached; // 命中即最近使用
      return cached;
    }
    final size = _viewport;
    if (size == null) return null;
    final canvas = NovelPageCanvas.build(
      page: pagination.pageAt(index),
      text: pagination.text,
      typesetting: _typesetting,
      theme: _theme,
      contentWidth: _typesetting.contentSize(
        size,
        reserveChrome: _turnMode != NovelTurnMode.scroll,
      ).width,
    );
    _canvases[index] = canvas;
    while (_canvases.length > _canvasCacheSize) {
      final oldest = _canvases.keys.first;
      final removed = _canvases.remove(oldest);
      _deferDispose(removed);
    }
    return canvas;
  }

  String _canvasKeyFor(ChapterPagination pagination) =>
      '${pagination.key}#${_theme.id}#${_theme.background.toARGB32()}'
      '#${_turnMode.id}';

  /// 画布销毁推迟到下一帧：本帧里旧画笔可能还握着它。
  final List<NovelPageCanvas> _pendingDisposal = <NovelPageCanvas>[];

  /// 延迟释放：下一帧统一排空。[dispose] 时改为立即排空（退出后没有绘制帧了）。
  void _deferDispose(NovelPageCanvas? canvas) {
    if (canvas == null) return;
    _pendingDisposal.add(canvas);
    if (_pendingDisposal.length > 1) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => _flushPendingDisposal());
  }

  /// 立即释放待销毁的页画布（TextPainter 逐段归还原生该页资源）。
  void _flushPendingDisposal() {
    if (_pendingDisposal.isEmpty) return;
    final pending = List<NovelPageCanvas>.of(_pendingDisposal);
    _pendingDisposal.clear();
    for (final canvas in pending) {
      canvas.dispose();
    }
  }

  void _disposeCanvases() {
    for (final canvas in _canvases.values) {
      _deferDispose(canvas);
    }
    _canvases.clear();
    _canvasKey = '';
  }

  /// 页画笔工厂：翻页视图只认这个回调，画布缓存留在阅读器里。
  NovelPagePainter _painterFor(int index) {
    final pagination = _pagination;
    final size = _viewport ?? const Size(360, 640);
    final contentWidth = _typesetting
        .contentSize(size, reserveChrome: _turnMode != NovelTurnMode.scroll)
        .width;
    if (pagination == null) {
      return NovelPagePainter(
        theme: _theme,
        typesetting: _typesetting,
        title: _chapterTitle,
        pageIndex: 0,
        pageCount: 1,
        chapterRatio: 0,
        contentWidth: contentWidth,
        hint: '正在排版…',
      );
    }
    if (index < 0) {
      return NovelPagePainter(
        theme: _theme,
        typesetting: _typesetting,
        title: _chapterTitle,
        pageIndex: 0,
        pageCount: pagination.pageCount,
        chapterRatio: 0,
        contentWidth: contentWidth,
        hint: _chapterIndex > 0 ? '已是第一页，继续翻到上一章' : '已是本书第一页',
      );
    }
    if (index >= pagination.pageCount) {
      return NovelPagePainter(
        theme: _theme,
        typesetting: _typesetting,
        title: _chapterTitle,
        pageIndex: pagination.pageCount - 1,
        pageCount: pagination.pageCount,
        chapterRatio: 1,
        contentWidth: contentWidth,
        hint: _chapterIndex < _chapters.length - 1
            ? '本章完，继续翻进入下一章'
            : '本章完，已是最后一章',
      );
    }
    return NovelPagePainter(
      theme: _theme,
      typesetting: _typesetting,
      title: _chapterTitle,
      pageIndex: index,
      pageCount: pagination.pageCount,
      chapterRatio: pagination.charRatio(index),
      contentWidth: contentWidth,
      content: _canvasFor(index),
    );
  }

  String get _chapterTitle =>
      _chapters.isEmpty ? '' : _chapters[_chapterIndex].title;

  // ------------------------------------------------------------------ 书签

  /// 当前位置（章节 + 字符偏移）——书签与查找都用它做锚点。
  int get _currentCharOffset {
    final pagination = _pagination;
    if (pagination == null || _pageIndex >= pagination.pageCount) return 0;
    return pagination.pageAt(_pageIndex).charStart;
  }

  /// 当前位置附近的摘录（书签列表展示用）。
  String _excerptAt(int charOffset) {
    final text = _text;
    if (text == null) return '';
    final raw = text.text;
    if (raw.isEmpty) return '';
    final start = charOffset.clamp(0, raw.length);
    final end = (start + 24).clamp(0, raw.length);
    final slice = raw.substring(start, end).replaceAll(RegExp(r'\s+'), ' ').trim();
    return slice;
  }

  /// 当前位置的书签（没有则为 null）。
  NovelBookmark? get _bookmarkHere => NovelBookmarks.at(
        _bookmarks,
        chapterIndex: _chapterIndex,
        charOffset: _currentCharOffset,
      );

  /// 加/删当前位置的书签。
  void _toggleBookmark() {
    if (_chapters.isEmpty || _text == null) return;
    final chapter = _chapters[_chapterIndex];
    final offset = _currentCharOffset;
    final existing = _bookmarkHere;
    final next = existing != null
        ? NovelBookmarks.remove(_bookmarks, existing)
        : NovelBookmarks.add(
            _bookmarks,
            NovelBookmark(
              chapterIndex: _chapterIndex,
              chapterId: chapter.id,
              chapterTitle: chapter.title,
              charOffset: offset,
              createdAt: DateTime.now(),
              excerpt: _excerptAt(offset),
            ),
          );
    setState(() => _bookmarks = next);
    widget.library.setSetting(
      NovelBookmarks.keyFor(widget.target.itemId),
      NovelBookmarks.encode(next),
    );
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 1),
        content: Text(existing != null ? '已移除书签' : '已添加书签'),
      ),
    );
  }

  /// 跳到某条书签。
  Future<void> _openBookmark(NovelBookmark bookmark) async {
    setState(() => _toolbar = false);
    if (bookmark.chapterIndex == _chapterIndex) {
      _jumpToCharOffset(bookmark.charOffset);
      return;
    }
    await _openChapter(bookmark.chapterIndex);
    if (!mounted) return;
    _jumpToCharOffset(bookmark.charOffset);
  }

  /// 跳到章节内某个字符偏移对应的页。
  void _jumpToCharOffset(int charOffset) {
    final pagination = _pagination;
    if (pagination == null || pagination.pageCount == 0) return;
    final page = pagination.pageIndexForChar(charOffset);
    _goToPage(page);
  }

  /// 跳到指定页（分页模式与滚动模式各自处理）。
  void _goToPage(int page) {
    final pagination = _pagination;
    if (pagination == null) return;
    final target = page.clamp(0, pagination.pageCount - 1);
    if (_turnMode.isPaged) {
      _turnKey.currentState?.jumpTo(target);
      setState(() => _pageIndex = target);
      _scheduleSave();
      return;
    }
    final height = _viewport?.height ?? 0;
    if (height <= 0) return;
    _scrollController?.animateTo(
      target * height,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  // -------------------------------------------------------------- 章节内查找

  /// 在当前章节里查找关键词，记录全部命中位置。
  void _search(String keyword) {
    final text = _text;
    final trimmed = keyword.trim();
    if (text == null || trimmed.isEmpty) {
      setState(() {
        _searchKeyword = '';
        _searchHits = const <int>[];
        _searchHitIndex = -1;
      });
      return;
    }
    final hits = <int>[];
    final lower = text.text.toLowerCase();
    final needle = trimmed.toLowerCase();
    var index = lower.indexOf(needle);
    while (index >= 0) {
      hits.add(index);
      index = lower.indexOf(needle, index + needle.length);
    }
    setState(() {
      _searchKeyword = trimmed;
      _searchHits = hits;
      _searchHitIndex = hits.isEmpty ? -1 : 0;
    });
    if (hits.isNotEmpty) _jumpToCharOffset(hits.first);
  }

  /// 跳到下一个 / 上一个命中。
  void _nextSearchHit(int step) {
    if (_searchHits.isEmpty) return;
    final next = (_searchHitIndex + step) % _searchHits.length;
    final wrapped = next < 0 ? _searchHits.length - 1 : next;
    setState(() => _searchHitIndex = wrapped);
    _jumpToCharOffset(_searchHits[wrapped]);
  }

  // ------------------------------------------------------------------ 自动翻页

  /// 开关自动翻页（按 [NovelTypesetting.autoPageKey] 记住间隔）。
  void _toggleAutoPage() {
    if (_autoPageTimer != null) {
      _autoPageTimer?.cancel();
      setState(() => _autoPageTimer = null);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(duration: Duration(seconds: 1), content: Text('已停止自动翻页')),
      );
      return;
    }
    _startAutoPage(_autoPageSeconds);
  }

  void _startAutoPage(int seconds) {
    _autoPageTimer?.cancel();
    _autoPageSeconds = seconds;
    widget.library.setSetting(
      NovelTypesetting.autoPageKey,
      seconds.toString(),
    );
    setState(() {
      _autoPageTimer = Timer.periodic(Duration(seconds: seconds), (_) {
        if (!mounted) return;
        // 到章尾自动进下一章；最后一章停下并关掉定时器（不空转）。
        final pagination = _pagination;
        if (pagination == null) return;
        if (_pageIndex >= pagination.pageCount - 1) {
          if (_chapterIndex >= _chapters.length - 1) {
            _autoPageTimer?.cancel();
            setState(() => _autoPageTimer = null);
            return;
          }
          _openChapter(_chapterIndex + 1);
          return;
        }
        _nextPage();
      });
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 1),
        content: Text('自动翻页：每 $seconds 秒'),
      ),
    );
  }

  // ------------------------------------------------------------------ 进度

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 700), _saveProgress);
  }

  void _saveProgress() {
    final pagination = _pagination;
    final text = _text;
    if (pagination == null || text == null || _chapters.isEmpty) return;
    final chapter = _chapters[_chapterIndex];
    widget.library.saveProgress(
      NovelProgress(
        section: widget.library.section,
        itemId: widget.target.itemId,
        chapterIndex: _chapterIndex,
        chapterId: chapter.id,
        chapterTitle: chapter.title,
        updatedAt: DateTime.now(),
        charOffset: pagination.pageAt(_pageIndex).charStart,
        chapterLength: text.length,
      ),
    );
  }

  void _onPageChanged(int index) {
    if (index == _pageIndex) return;
    setState(() => _pageIndex = index);
    _scheduleSave();
  }

  // ------------------------------------------------------------------ 翻页

  void _nextPage() {
    final pagination = _pagination;
    if (pagination == null) return;
    if (_turnMode.isPaged) {
      _turnKey.currentState?.next();
      return;
    }
    final height = _viewport?.height ?? 0;
    if (height <= 0) return;
    final target = _pageIndex + 1;
    if (target >= pagination.pageCount) {
      _openChapter(_chapterIndex + 1);
      return;
    }
    _scrollController?.animateTo(
      target * height,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  void _previousPage() {
    if (_turnMode.isPaged) {
      _turnKey.currentState?.previous();
      return;
    }
    final height = _viewport?.height ?? 0;
    if (height <= 0) return;
    final target = _pageIndex - 1;
    if (target < 0) {
      _openChapter(_chapterIndex - 1, atEnd: true);
      return;
    }
    _scrollController?.animateTo(
      target * height,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  Future<void> _openChapter(int index, {bool atEnd = false}) async {
    if (index < 0 || index >= _chapters.length) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 1),
          content: Text(index < 0 ? '已经是第一章' : '已经是最后一章'),
        ),
      );
      return;
    }
    _saveTimer?.cancel();
    _saveProgress();
    setState(() {
      _chapterIndex = index;
      _pageIndex = 0;
      _toolbar = false;
    });
    await _loadChapter(atEnd: atEnd);
  }

  /// 点按分区：左 1/3 上一页，右 1/3 下一页，中间呼出/收起工具栏。
  void _onTapUp(TapUpDetails details, Size size) {
    final x = details.localPosition.dx;
    if (x < size.width / 3) {
      _previousPage();
      return;
    }
    if (x > size.width * 2 / 3) {
      _nextPage();
      return;
    }
    setState(() => _toolbar = !_toolbar);
  }

  // ------------------------------------------------------------------ 设置

  void _updateTypesetting(NovelTypesetting next) {
    setState(() {
      _typesetting = next;
      _paginatedSignature = null;
      _disposeCanvases();
    });
    widget.library.setSetting(NovelTypesetting.settingKey, next.encode());
    final size = _viewport;
    if (size != null) _schedulePagination(size);
  }

  void _updateTheme(NovelReaderTheme next) {
    setState(() {
      _theme = next;
      // 主题只影响颜色：画布要重画（文字颜色在里面），但不需要重新分页。
      _disposeCanvases();
    });
    next.save(widget.library);
  }

  void _updateTurnMode(NovelTurnMode next) {
    setState(() {
      _turnMode = next;
      _paginatedSignature = null;
      _disposeCanvases();
    });
    widget.library.setSetting(NovelTurnMode.settingKey, next.id);
    final size = _viewport;
    if (size != null) _schedulePagination(size);
  }

  Future<void> _pickCustomColor() async {
    final picked = await showDialog<Color>(
      context: context,
      builder: (_) => _ColorPickerDialog(initial: _theme.background),
    );
    if (picked == null || !mounted) return;
    _updateTheme(NovelReaderTheme.custom(picked));
  }

  // ------------------------------------------------------------------ 构建

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _theme.background,
      body: Stack(
        children: <Widget>[
          Positioned.fill(child: _buildContent()),
          if (_toolbar) ...<Widget>[
            _buildTopBar(),
            _buildBottomPanel(),
          ],
        ],
      ),
    );
  }

  Widget _buildContent() {
    if (_loadingChapter) {
      return _centeredSpinner();
    }
    final failure = _failure;
    if (failure != null) {
      return SourceStateView(
        state: SourceStateKind.scriptError,
        detail: failure,
        onRetry: () => _loadChapter(),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        if (_needsPagination(size)) {
          _schedulePagination(size);
          return _paginating ? _centeredSpinner() : const SizedBox.shrink();
        }
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (details) => _onTapUp(details, size),
          child: _turnMode == NovelTurnMode.scroll
              ? _buildScroll(size)
              : NovelTurnView(
                  key: _turnKey,
                  mode: _turnMode,
                  pageCount: _pagination?.pageCount ?? 1,
                  index: _pageIndex,
                  buildPage: _painterFor,
                  onIndexChanged: _onPageChanged,
                  onBeyondStart: () => _openChapter(_chapterIndex - 1, atEnd: true),
                  onBeyondEnd: () => _openChapter(_chapterIndex + 1),
                ),
        );
      },
    );
  }

  Widget _centeredSpinner() => Center(
        child: SizedBox(
          width: 26,
          height: 26,
          child: CircularProgressIndicator(
            strokeWidth: 2.4,
            color: _theme.secondary,
          ),
        ),
      );

  /// 上下连续滚动：页与页无缝拼接，滚动位置直接换算页码。
  Widget _buildScroll(Size size) {
    final pagination = _pagination;
    if (pagination == null) return const SizedBox.shrink();
    final pageHeight = size.height;
    return NotificationListener<ScrollEndNotification>(
      onNotification: (notification) {
        final controller = _scrollController;
        if (controller == null || !controller.hasClients) return false;
        final index =
            (controller.offset / pageHeight).round().clamp(0, pagination.pageCount - 1);
        if (index != _pageIndex) {
          setState(() => _pageIndex = index);
          _scheduleSave();
        }
        return false;
      },
      child: ListView.builder(
        controller: _scrollController,
        itemExtent: pageHeight,
        itemCount: pagination.pageCount,
        itemBuilder: (context, index) => CustomPaint(
          painter: _painterFor(index),
          size: Size.infinite,
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      // 用 Material 而不是 DecoratedBox：面板里有 ListTile，
      // 它的背景与墨水效果需要最近的 Material 祖先承载。
      child: Material(
        color: _theme.chromeSurface,
        child: SafeArea(
          bottom: false,
          child: Row(
            children: <Widget>[
              IconButton(
                icon: Icon(Icons.arrow_back, color: _theme.chromeText),
                onPressed: () => Navigator.of(context).maybePop(),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      widget.target.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: _theme.chromeText,
                      ),
                    ),
                    Text(
                      _chapterTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: _theme.secondary),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: _bookmarkHere != null ? '移除书签' : '添加书签',
                icon: Icon(
                  _bookmarkHere != null
                      ? Icons.bookmark
                      : Icons.bookmark_border,
                  color: _theme.chromeText,
                ),
                onPressed: _toggleBookmark,
              ),
              IconButton(
                tooltip: '上一章',
                icon: Icon(Icons.skip_previous, color: _theme.chromeText),
                onPressed: () => _openChapter(_chapterIndex - 1),
              ),
              IconButton(
                tooltip: '下一章',
                icon: Icon(Icons.skip_next, color: _theme.chromeText),
                onPressed: () => _openChapter(_chapterIndex + 1),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBottomPanel() {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Material(
        color: _theme.chromeSurface,
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: <Widget>[
                  for (final tab in _PanelTab.values)
                    TextButton(
                      onPressed: () => setState(() => _panel = tab),
                      child: Text(
                        tab.label,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: _panel == tab
                              ? FontWeight.w700
                              : FontWeight.w400,
                          color: _panel == tab
                              ? _theme.chromeText
                              : _theme.secondary,
                        ),
                      ),
                    ),
                ],
              ),
              SizedBox(
                height: 260,
                child: switch (_panel) {
                  _PanelTab.catalog => _buildCatalog(),
                  _PanelTab.bookmarks => _buildBookmarks(),
                  _PanelTab.typesetting => _buildTypesetting(),
                  _PanelTab.theme => _buildThemePanel(),
                  _PanelTab.turn => _buildTurnPanel(),
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCatalog() {
    final pagination = _pagination;
    final ratio = pagination == null
        ? 0.0
        : pagination.charRatio(_pageIndex);
    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Row(
            children: <Widget>[
              Text(
                '共 ${_chapters.length} 章',
                style: TextStyle(fontSize: 12, color: _theme.secondary),
              ),
              const Spacer(),
              Text(
                '本章 ${(ratio * 100).round()}% · 第 ${_pageIndex + 1}/'
                '${pagination?.pageCount ?? 1} 页',
                style: TextStyle(fontSize: 12, color: _theme.secondary),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: _chapters.length,
            itemBuilder: (context, index) {
              final current = index == _chapterIndex;
              return ListTile(
                dense: true,
                title: Text(
                  _chapters[index].title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: current ? FontWeight.w700 : FontWeight.w400,
                    color: current ? _theme.chromeText : _theme.secondary,
                  ),
                ),
                trailing: current
                    ? Icon(Icons.bookmark, size: 16, color: _theme.chromeText)
                    : null,
                onTap: () => _openChapter(index),
              );
            },
          ),
        ),
      ],
    );
  }

  /// 书签面板：书签列表 + 章节内查找 + 自动翻页开关。
  Widget _buildBookmarks() {
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      children: <Widget>[
        // 章节内查找
        TextField(
          style: TextStyle(color: _theme.chromeText, fontSize: 14),
          decoration: InputDecoration(
            hintText: '在本章内查找',
            hintStyle: TextStyle(color: _theme.secondary, fontSize: 14),
            prefixIcon: Icon(Icons.search, color: _theme.secondary, size: 20),
            suffixIcon: _searchKeyword.isEmpty
                ? null
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        _searchHits.isEmpty
                            ? '无结果'
                            : '${_searchHitIndex + 1}/${_searchHits.length}',
                        style: TextStyle(fontSize: 12, color: _theme.secondary),
                      ),
                      IconButton(
                        tooltip: '上一个',
                        icon: Icon(
                          Icons.keyboard_arrow_up,
                          color: _theme.chromeText,
                          size: 20,
                        ),
                        onPressed: () => _nextSearchHit(-1),
                      ),
                      IconButton(
                        tooltip: '下一个',
                        icon: Icon(
                          Icons.keyboard_arrow_down,
                          color: _theme.chromeText,
                          size: 20,
                        ),
                        onPressed: () => _nextSearchHit(1),
                      ),
                    ],
                  ),
          ),
          onSubmitted: _search,
        ),
        const SizedBox(height: 12),
        // 自动翻页
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                '自动翻页',
                style: TextStyle(fontSize: 14, color: _theme.chromeText),
              ),
            ),
            Switch(
              value: _autoPageTimer != null,
              onChanged: (_) => _toggleAutoPage(),
            ),
            const SizedBox(width: 8),
            DropdownButton<int>(
              value: _autoPageSeconds,
              dropdownColor: _theme.chromeSurface,
              style: TextStyle(fontSize: 13, color: _theme.chromeText),
              items: <DropdownMenuItem<int>>[
                for (final seconds in <int>[5, 10, 15, 20, 30, 60])
                  DropdownMenuItem<int>(
                    value: seconds,
                    child: Text('$seconds 秒'),
                  ),
              ],
              onChanged: (value) {
                if (value == null) return;
                if (_autoPageTimer != null) {
                  _startAutoPage(value);
                } else {
                  setState(() => _autoPageSeconds = value);
                }
              },
            ),
          ],
        ),
        const Divider(height: 24),
        if (_bookmarks.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Text(
              '还没有书签。点顶部书签图标可把当前位置记下来。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: _theme.secondary),
            ),
          )
        else
          for (final bookmark in _bookmarks)
            ListTile(
              dense: true,
              leading: Icon(Icons.bookmark, size: 18, color: _theme.secondary),
              title: Text(
                bookmark.describe(),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, color: _theme.chromeText),
              ),
              trailing: IconButton(
                tooltip: '移除',
                icon: Icon(Icons.close, size: 18, color: _theme.secondary),
                onPressed: () {
                  final next = NovelBookmarks.remove(_bookmarks, bookmark);
                  setState(() => _bookmarks = next);
                  widget.library.setSetting(
                    NovelBookmarks.keyFor(widget.target.itemId),
                    NovelBookmarks.encode(next),
                  );
                },
              ),
              onTap: () => _openBookmark(bookmark),
            ),
      ],
    );
  }

  Widget _buildTypesetting() {
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      children: <Widget>[
        _slider(
          label: '字号',
          value: _typesetting.fontSize,
          min: NovelTypesetting.minFontSize,
          max: NovelTypesetting.maxFontSize,
          display: '${_typesetting.fontSize.round()}',
          onChanged: (value) =>
              _updateTypesetting(_typesetting.copyWith(fontSize: value)),
        ),
        _slider(
          label: '行间距',
          value: _typesetting.lineHeight,
          min: NovelTypesetting.minLineHeight,
          max: NovelTypesetting.maxLineHeight,
          display: _typesetting.lineHeight.toStringAsFixed(1),
          onChanged: (value) =>
              _updateTypesetting(_typesetting.copyWith(lineHeight: value)),
        ),
        _slider(
          label: '段间距',
          value: _typesetting.paragraphSpacing,
          min: NovelTypesetting.minParagraphSpacing,
          max: NovelTypesetting.maxParagraphSpacing,
          display: '${_typesetting.paragraphSpacing.round()}',
          onChanged: (value) =>
              _updateTypesetting(_typesetting.copyWith(paragraphSpacing: value)),
        ),
        _slider(
          label: '页边距',
          value: _typesetting.margin,
          min: NovelTypesetting.minMargin,
          max: NovelTypesetting.maxMargin,
          display: '${_typesetting.margin.round()}',
          onChanged: (value) =>
              _updateTypesetting(_typesetting.copyWith(margin: value)),
        ),
      ],
    );
  }

  Widget _slider({
    required String label,
    required double value,
    required double min,
    required double max,
    required String display,
    required ValueChanged<double> onChanged,
  }) {
    return Row(
      children: <Widget>[
        SizedBox(
          width: 52,
          child: Text(
            label,
            style: TextStyle(fontSize: 12, color: _theme.secondary),
          ),
        ),
        Expanded(
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 34,
          child: Text(
            display,
            textAlign: TextAlign.end,
            style: TextStyle(fontSize: 12, color: _theme.secondary),
          ),
        ),
      ],
    );
  }

  Widget _buildThemePanel() {
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      children: <Widget>[
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: <Widget>[
            for (final preset in NovelReaderTheme.presets)
              _themeChip(preset),
            _customThemeChip(),
          ],
        ),
        const SizedBox(height: 14),
        Text(
          '阅读主题独立于 App 全局主题：这里换的只是阅读页的背景与文字色。',
          style: TextStyle(fontSize: 12, height: 1.5, color: _theme.secondary),
        ),
      ],
    );
  }

  Widget _themeChip(NovelReaderTheme preset) {
    final selected = preset.id == _theme.id;
    return GestureDetector(
      onTap: () => _updateTheme(preset),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(
            width: 54,
            height: 54,
            decoration: BoxDecoration(
              color: preset.background,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: selected ? _theme.chromeText : _theme.divider,
                width: selected ? 2 : 1,
              ),
            ),
            child: Center(
              child: Text(
                '文',
                style: TextStyle(fontSize: 18, color: preset.textColor),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            preset.label,
            style: TextStyle(
              fontSize: 11,
              color: selected ? _theme.chromeText : _theme.secondary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _customThemeChip() {
    final selected = _theme.isCustom;
    return GestureDetector(
      onTap: _pickCustomColor,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(
            width: 54,
            height: 54,
            decoration: BoxDecoration(
              color: selected ? _theme.background : null,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: selected ? _theme.chromeText : _theme.divider,
                width: selected ? 2 : 1,
              ),
            ),
            child: Icon(
              Icons.palette_outlined,
              size: 20,
              color: selected ? _theme.textColor : _theme.secondary,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '自定义',
            style: TextStyle(
              fontSize: 11,
              color: selected ? _theme.chromeText : _theme.secondary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTurnPanel() {
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      children: <Widget>[
        for (final mode in NovelTurnMode.values)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(
              mode.label,
              style: TextStyle(
                fontSize: 14,
                color: _turnMode == mode ? _theme.chromeText : _theme.secondary,
                fontWeight: _turnMode == mode ? FontWeight.w700 : FontWeight.w400,
              ),
            ),
            trailing: _turnMode == mode
                ? Icon(Icons.check, size: 18, color: _theme.chromeText)
                : null,
            onTap: () => _updateTurnMode(mode),
          ),
      ],
    );
  }
}

enum _PanelTab {
  catalog('目录'),
  bookmarks('书签'),
  typesetting('排版'),
  theme('主题'),
  turn('翻页');

  const _PanelTab(this.label);

  final String label;
}

/// 自定义背景色选择：色相 + 明度两根滑杆。
///
/// 不引入外部取色器依赖：两根滑杆足够覆盖「换个护眼底色」这类需求，
/// 文字色由 [NovelReaderTheme.custom] 按亮度自动选定，不会出现浅底浅字。
class _ColorPickerDialog extends StatefulWidget {
  const _ColorPickerDialog({required this.initial});

  final Color initial;

  @override
  State<_ColorPickerDialog> createState() => _ColorPickerDialogState();
}

class _ColorPickerDialogState extends State<_ColorPickerDialog> {
  late double _hue;
  late double _lightness;

  @override
  void initState() {
    super.initState();
    final hsv = HSVColor.fromColor(widget.initial);
    _hue = hsv.hue;
    _lightness = hsv.value;
  }

  Color get _color => HSVColor.fromAHSV(1, _hue, 0.35, _lightness).toColor();

  @override
  Widget build(BuildContext context) {
    final theme = NovelReaderTheme.custom(_color);
    return AlertDialog(
      title: const Text('自定义背景色'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            height: 72,
            decoration: BoxDecoration(
              color: _color,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Center(
              child: Text(
                '正文预览',
                style: TextStyle(fontSize: 15, color: theme.textColor),
              ),
            ),
          ),
          const SizedBox(height: 12),
          const Text('色相', style: TextStyle(fontSize: 12)),
          Slider(
            value: _hue,
            min: 0,
            max: 360,
            onChanged: (value) => setState(() => _hue = value),
          ),
          const Text('明度', style: TextStyle(fontSize: 12)),
          Slider(
            value: _lightness,
            min: 0.12,
            max: 1,
            onChanged: (value) => setState(() => _lightness = value),
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_color),
          child: const Text('应用'),
        ),
      ],
    );
  }
}
