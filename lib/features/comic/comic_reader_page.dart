import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../core/reading/reading.dart';
import '../../core/source/source.dart';
import '../../core/theme/lume_theme.dart';
import '../../core/util/lume_log.dart';
import '../../shared/widgets/glass_card.dart';
import '../../shared/widgets/state_view.dart';
import 'comic_settings.dart';

/// 漫画阅读器：条漫瀑布流 / 单页左右翻页 / 双页跨页三种模式，共用一套调节控件。
///
/// 资源纪律（宪法第 7 条）：
/// - 进入时创建**本页独占**的图片管线，退出时 [SectionImagePipeline.dispose]：
///   关闭 HTTP 客户端取消全部在飞图片请求、逐张 dispose 解码位图、清空内存缓存；
/// - 图片 tile 挂载时登记引用、卸载时释放，被展示的位图不会被 LRU 淘汰；
/// - 滑动窗口外的预加载图会被解除钉住并回收，窗口大小 = 预加载半径；
/// - 退出前把进度写回板块阅读库（进度与书架标记一起更新）。
class ComicReaderPage extends StatefulWidget {
  const ComicReaderPage({
    super.key,
    required this.library,
    required this.dataSource,
    required this.target,
    required this.chapters,
    required this.initialChapterIndex,
    this.initialPage = 0,
  });

  final ReadingLibrary library;

  /// 已打开并校验过板块归属的数据源。
  final DataSource dataSource;

  final ReadingTarget target;

  final List<SourceChapter> chapters;

  final int initialChapterIndex;

  /// 续读的页序号（瀑布流模式下作为纵向滚动位置的锚点）。
  final int initialPage;

  @override
  State<ComicReaderPage> createState() => _ComicReaderPageState();
}

class _ComicReaderPageState extends State<ComicReaderPage> {
  late final SectionImagePipeline _pipeline;

  /// 阅读设置可被面板改写（模式、侧边距、双击放大），因此不是 final。
  late ComicReaderSettings _settings;
  late List<SourceChapter> _chapters;
  late int _chapterIndex;

  List<String> _images = const <String>[];
  bool _loading = true;
  bool _failed = false;
  String? _failureDetail;

  /// 当前页序号（单页 / 双页模式为页，瀑布流模式为图序号）。
  int _page = 0;

  /// 瀑布流模式下的页内比例 0..1。
  double _fraction = 0;

  bool _toolbar = false;
  bool _saving = false;

  PageController? _pageController;
  ScrollController? _scrollController;

  /// 瀑布流：已解码图片的「高/宽」比，用于精确排布与定位。
  final Map<int, double> _ratios = <int, double>{};

  Timer? _saveTimer;

  /// 视口尺寸与按屏宽解码的目标宽度。在 [didChangeDependencies] 里缓存，
  /// 图片键、瀑布流占位高度与解码分辨率都以它为准（旋屏后自动更新）。
  Size _viewport = const Size(400, 800);
  int _decodeWidthPx = 800;
  bool _bootstrapped = false;

  /// 瀑布流占位比例：图片解码前先按这个比例占位，解码到位后自动纠正。
  static const double _placeholderRatio = 1.4;

  @override
  void initState() {
    super.initState();
    _pipeline = SectionImagePipeline(cacheDir: widget.library.imageCacheDir);
    _settings = ComicReaderSettings.load(widget.library);
    _chapters = widget.chapters;
    _chapterIndex = widget.chapters.isEmpty
        ? 0
        : widget.initialChapterIndex.clamp(0, widget.chapters.length - 1);
    // 进阅读器即入架：书架要有这一条，未读角标才有章节总数口径。
    widget.library.shelve(
      sourceId: widget.target.sourceId,
      itemId: widget.target.itemId,
      title: widget.target.title,
      cover: widget.target.cover,
      subtitle: widget.target.subtitle,
      chapterCount: _chapters.length,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _viewport = MediaQuery.sizeOf(context);
    final ratio = MediaQuery.devicePixelRatioOf(context);
    _decodeWidthPx = math.max(1, (_viewport.width * ratio).round());
    if (_bootstrapped) return;
    _bootstrapped = true;
    _loadChapter(resume: true);
  }

  @override
  void dispose() {
    // 先落进度，再释放图片资源；顺序反了进度就丢了。
    _saveTimer?.cancel();
    _saveProgress();
    _pageController?.dispose();
    _scrollController?.dispose();
    _pipeline.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------------ 加载

  Future<void> _loadChapter({bool resume = false}) async {
    if (_chapters.isEmpty) {
      setState(() {
        _loading = false;
        _images = const <String>[];
      });
      return;
    }
    setState(() {
      _loading = true;
      _failed = false;
      _failureDetail = null;
      _images = const <String>[];
      _ratios.clear();
    });
    final chapter = _chapters[_chapterIndex];
    try {
      final content = await widget.dataSource.content(
        itemId: widget.target.itemId,
        chapterId: chapter.id,
      );
      if (!mounted) return;
      switch (content) {
        case null:
          setState(() {
            _loading = false;
            _images = const <String>[];
          });
        case ImageContent(:final images):
          final start = resume ? widget.initialPage : 0;
          setState(() {
            _images = images;
            _page = images.isEmpty ? 0 : start.clamp(0, images.length - 1);
            _fraction = 0;
            _loading = false;
          });
          _rebuildControllers();
          _primeWindow();
          // 进章即记一次进度：书架的「未读角标」与「继续阅读」都靠这条记录，
          // 不能等到翻页或退出才写。
          _saveProgress();
        case TextContent():
          setState(() {
            _loading = false;
            _failed = true;
            _failureDetail = '该章节不是图片内容：图源返回了文本';
          });
        case VideoContent():
          setState(() {
            _loading = false;
            _failed = true;
            _failureDetail = '该章节不是图片内容：图源返回了视频地址';
          });
      }
    } on SourceException catch (error) {
      LumeLog.warn('[${widget.target.itemId}] 章节内容获取失败: $error');
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = true;
        _failureDetail = error.message;
      });
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = true;
        _failureDetail = '$error';
      });
    }
  }

  /// 按当前模式（重新）建立滚动控制器，并把位置恢复到 [_page]。
  ///
  /// 旧控制器推迟到下一帧销毁：同一帧里仍然挂着的滚动视图还持有它，
  /// 立刻 dispose 会在 debug 下报「controller 已释放」。
  void _rebuildControllers() {
    final oldPage = _pageController;
    final oldScroll = _scrollController;
    _pageController = null;
    _scrollController = null;
    switch (_settings.mode) {
      case ComicReadingMode.waterfall:
        _scrollController = ScrollController(
          initialScrollOffset: _waterfallOffsetFor(_page),
        );
      case ComicReadingMode.single:
        _pageController = PageController(initialPage: _page);
      case ComicReadingMode.doublePage:
        _pageController = PageController(initialPage: _page ~/ 2);
    }
    if (oldPage != null || oldScroll != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        oldPage?.dispose();
        oldScroll?.dispose();
      });
    }
  }

  // ------------------------------------------------------------------ 进度

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 600), _saveProgress);
  }

  void _saveProgress() {
    if (_chapters.isEmpty) return;
    final chapter = _chapters[_chapterIndex];
    widget.library.saveProgress(
      ComicProgress(
        section: widget.library.section,
        itemId: widget.target.itemId,
        chapterIndex: _chapterIndex,
        chapterId: chapter.id,
        chapterTitle: chapter.title,
        updatedAt: DateTime.now(),
        page: _page,
        pageFraction: _fraction,
      ),
    );
  }

  // ------------------------------------------------------------------ 预加载

  /// 计算当前可见范围，钉住窗口内的图并预加载窗口外一圈。
  void _primeWindow() {
    if (_images.isEmpty) return;
    final radius = _settings.preloadRadius;
    final window = <int>[
      for (int i = _page - radius; i <= _page + radius; i++)
        if (i >= 0 && i < _images.length) i,
    ];
    final urls = <String>[for (final index in window) _images[index]];
    _pipeline.retain(urls, targetWidth: _decodeWidth);
    final ahead = <String>[
      for (int i = _page + radius + 1;
          i <= _page + radius * 2 && i < _images.length;
          i++)
        _images[i],
      for (int i = _page - radius - 1;
          i >= _page - radius * 2 && i >= 0;
          i--)
        _images[i],
    ];
    _pipeline.preload(ahead, targetWidth: _decodeWidth);
  }

  /// 解码宽度：按屏宽（物理像素）解码，长条图不按屏宽解码会占几十 MB。
  int get _decodeWidth => _decodeWidthPx;

  // ------------------------------------------------------------------ 瀑布流定位

  double get _innerWidth =>
      math.max(1, _viewport.width - _settings.marginOf(_viewport.width) * 2);

  double _itemHeight(int index) =>
      _innerWidth * (_ratios[index] ?? _placeholderRatio);

  double _waterfallOffsetFor(int index) {
    var offset = 0.0;
    for (var i = 0; i < index && i < _images.length; i++) {
      offset += _itemHeight(i);
    }
    return offset;
  }

  int _waterfallIndexFor(double offset) {
    var sum = 0.0;
    for (var i = 0; i < _images.length; i++) {
      final height = _itemHeight(i);
      if (offset < sum + height) return i;
      sum += height;
    }
    return _images.isEmpty ? 0 : _images.length - 1;
  }

  void _onRatio(int index, double ratio) {
    if (!mounted) return;
    if ((_ratios[index] ?? 0).toStringAsFixed(3) == ratio.toStringAsFixed(3)) {
      return;
    }
    setState(() => _ratios[index] = ratio);
  }

  /// 瀑布流滚动：结束时才更新页序号与进度，滚动过程中不做重计算。
  bool _onScroll(ScrollNotification notification) {
    if (notification is ScrollEndNotification) {
      final controller = _scrollController;
      if (controller != null && controller.hasClients) {
        final index = _waterfallIndexFor(controller.offset);
        final height = _itemHeight(index);
        final start = _waterfallOffsetFor(index);
        final fraction =
            height <= 0 ? 0.0 : ((controller.offset - start) / height).clamp(0.0, 1.0);
        if (index != _page || (fraction - _fraction).abs() > 0.01) {
          setState(() {
            _page = index;
            _fraction = fraction;
          });
          _scheduleSave();
          _primeWindow();
        }
      }
    }
    return false;
  }

  // ------------------------------------------------------------------ 交互

  void _toggleToolbar() => setState(() => _toolbar = !_toolbar);

  void _onPageChanged(int page) {
    final next = _settings.mode == ComicReadingMode.doublePage ? page * 2 : page;
    if (next == _page) return;
    setState(() {
      _page = next;
      _fraction = 0;
    });
    _scheduleSave();
    _primeWindow();
  }

  void _switchMode(ComicReadingMode mode) {
    if (mode == _settings.mode) return;
    setState(() {
      _settings = _settings.copyWith(mode: mode);
      // 双页模式按跨页折算，保证切换后仍停在同一个作品位置。
      _page = mode == ComicReadingMode.doublePage ? (_page ~/ 2) * 2 : _page;
    });
    _settings.save(widget.library);
    _rebuildControllers();
    _primeWindow();
  }

  void _updateSettings(ComicReaderSettings next) {
    setState(() => _settings = next);
    _settings.save(widget.library);
  }

  Future<void> _openChapter(int index) async {
    if (index < 0 || index >= _chapters.length || index == _chapterIndex) return;
    _saveTimer?.cancel();
    _saveProgress();
    setState(() {
      _chapterIndex = index;
      _page = 0;
      _fraction = 0;
      _toolbar = false;
    });
    await _loadChapter(resume: false);
  }

  Future<void> _showChapterSheet() async {
    final selected = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _ChapterSheet(
        chapters: _chapters,
        currentIndex: _chapterIndex,
      ),
    );
    if (selected == null || !mounted) return;
    await _openChapter(selected);
  }

  /// 长按保存当前图片：取原始字节写入本板块的导出目录（不经相册权限）。
  Future<void> _saveImage(int index) async {
    if (_saving) return;
    if (index < 0 || index >= _images.length) return;
    _saving = true;
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      const SnackBar(
        duration: Duration(seconds: 1),
        content: Text('正在保存图片…'),
      ),
    );
    try {
      final url = _images[index];
      final bytes = await _pipeline.bytes(url);
      if (!mounted) return;
      if (bytes == null) {
        messenger.showSnackBar(
          const SnackBar(content: Text('保存失败：图片未能取到')),
        );
        return;
      }
      final file = widget.library.saveImage(_fileNameFor(url, index), bytes);
      messenger.showSnackBar(
        SnackBar(content: Text('已保存到 ${file.path}')),
      );
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
      messenger.showSnackBar(const SnackBar(content: Text('保存失败')));
    } finally {
      _saving = false;
    }
  }

  String _fileNameFor(String url, int index) {
    final base = p.basename(Uri.tryParse(url)?.path ?? '');
    if (base.isNotEmpty && base.contains('.')) return base;
    return '${widget.library.section.id}_${_chapterIndex + 1}_${index + 1}.jpg';
  }

  // ------------------------------------------------------------------ 构建

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      body: Stack(
        children: <Widget>[
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _toggleToolbar,
              child: _buildContent(),
            ),
          ),
          if (_toolbar) ...<Widget>[
            _buildTopBar(),
            _buildBottomPanel(),
          ],
        ],
      ),
    );
  }

  Widget _buildContent() {
    if (_loading) {
      return const SourceStateView(state: SourceStateKind.loading);
    }
    if (_failed) {
      return SourceStateView(
        state: SourceStateKind.scriptError,
        detail: _failureDetail,
        onRetry: () => _loadChapter(resume: false),
      );
    }
    if (_images.isEmpty) {
      return const SourceStateView(
        state: SourceStateKind.empty,
        detail: '本章暂无图片内容',
      );
    }
    return switch (_settings.mode) {
      ComicReadingMode.waterfall => _buildWaterfall(),
      ComicReadingMode.single => _buildPaged(doublePage: false),
      ComicReadingMode.doublePage => _buildPaged(doublePage: true),
    };
  }

  /// 条漫瀑布流：纵向连续，无分页、无间隙，按各图真实比例排布。
  Widget _buildWaterfall() {
    final margin = _settings
        .marginOf(MediaQuery.maybeSizeOf(context)?.width ?? 400);
    return NotificationListener<ScrollNotification>(
      onNotification: _onScroll,
      child: ListView.builder(
        controller: _scrollController,
        padding: EdgeInsets.zero,
        itemCount: _images.length,
        itemExtentBuilder: (index, _) => _itemHeight(index),
        itemBuilder: (context, index) => Padding(
          padding: EdgeInsets.symmetric(horizontal: margin),
          child: _ComicImageTile(
            pipeline: _pipeline,
            url: _images[index],
            index: index,
            decodeWidth: _decodeWidth,
            fit: BoxFit.cover,
            doubleTapZoom: _settings.doubleTapZoom,
            onLongPress: () => _saveImage(index),
            onRatio: (ratio) => _onRatio(index, ratio),
          ),
        ),
      ),
    );
  }

  /// 单页 / 双页模式：横向翻页，[doublePage] 时一屏并排两页。
  Widget _buildPaged({required bool doublePage}) {
    final width = MediaQuery.maybeSizeOf(context)?.width ?? 400;
    final margin = _settings.marginOf(width);
    final pageCount =
        doublePage ? (_images.length + 1) ~/ 2 : _images.length;
    return PageView.builder(
      controller: _pageController,
      itemCount: pageCount,
      onPageChanged: _onPageChanged,
      itemBuilder: (context, page) {
        final first = doublePage ? page * 2 : page;
        return Padding(
          padding: EdgeInsets.symmetric(horizontal: margin, vertical: 4),
          child: doublePage
              ? Row(
                  children: <Widget>[
                    Expanded(
                      child: _ComicImageTile(
                        pipeline: _pipeline,
                        url: _images[first],
                        index: first,
                        decodeWidth: _decodeWidth,
                        doubleTapZoom: _settings.doubleTapZoom,
                        onLongPress: () => _saveImage(first),
                      ),
                    ),
                    if (first + 1 < _images.length)
                      Expanded(
                        child: _ComicImageTile(
                          pipeline: _pipeline,
                          url: _images[first + 1],
                          index: first + 1,
                          decodeWidth: _decodeWidth,
                          doubleTapZoom: _settings.doubleTapZoom,
                          onLongPress: () => _saveImage(first + 1),
                        ),
                      )
                    else
                      const Spacer(),
                  ],
                )
              : _ComicImageTile(
                  pipeline: _pipeline,
                  url: _images[first],
                  index: first,
                  decodeWidth: _decodeWidth,
                  doubleTapZoom: _settings.doubleTapZoom,
                  onLongPress: () => _saveImage(first),
                ),
        );
      },
    );
  }

  Widget _buildTopBar() {
    final chapter = _chapters.isEmpty ? null : _chapters[_chapterIndex];
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: <Color>[Color(0xCC000000), Colors.transparent],
          ),
        ),
        child: SafeArea(
          bottom: false,
          child: Row(
            children: <Widget>[
              IconButton(
                icon: const Icon(Icons.arrow_back, color: Colors.white),
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
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
                    Text(
                      chapter?.title ??
                          '第 ${_chapterIndex + 1}/${_chapters.length} 章',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        color: LumeTheme.muted,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: '目录',
                icon: const Icon(Icons.list, color: Colors.white),
                onPressed: _showChapterSheet,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBottomPanel() {
    final pageLabel = _images.isEmpty ? '—' : _pageLabel;
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: <Color>[Color(0xE6000000), Colors.transparent],
          ),
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
            child: GlassCard(
              radius: 18,
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  SegmentedButton<ComicReadingMode>(
                    segments: <ButtonSegment<ComicReadingMode>>[
                      for (final mode in ComicReadingMode.values)
                        ButtonSegment<ComicReadingMode>(
                          value: mode,
                          label: Text(
                            mode.label,
                            style: const TextStyle(fontSize: 11),
                          ),
                        ),
                    ],
                    selected: <ComicReadingMode>{_settings.mode},
                    showSelectedIcon: false,
                    style: const ButtonStyle(
                      visualDensity: VisualDensity.compact,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    onSelectionChanged: (selection) =>
                        _switchMode(selection.first),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: <Widget>[
                      const SizedBox(
                        width: 46,
                        child: Text(
                          '侧边距',
                          style: TextStyle(fontSize: 12, color: Colors.white70),
                        ),
                      ),
                      Expanded(
                        child: Slider(
                          value: _settings.marginRatio,
                          max: ComicReaderSettings.maxMarginRatio,
                          divisions: 10,
                          label:
                              '${(_settings.marginRatio * 100).round()}%',
                          onChanged: (value) => _updateSettings(
                            _settings.copyWith(marginRatio: value),
                          ),
                        ),
                      ),
                      SizedBox(
                        width: 40,
                        child: Text(
                          '${(_settings.marginRatio * 100).round()}%',
                          textAlign: TextAlign.end,
                          style: const TextStyle(
                            fontSize: 12,
                            color: Colors.white70,
                          ),
                        ),
                      ),
                    ],
                  ),
                  Row(
                    children: <Widget>[
                      const Text(
                        '双击放大',
                        style: TextStyle(fontSize: 12, color: Colors.white70),
                      ),
                      Switch(
                        value: _settings.doubleTapZoom,
                        onChanged: (value) => _updateSettings(
                          _settings.copyWith(doubleTapZoom: value),
                        ),
                      ),
                      const Spacer(),
                      TextButton.icon(
                        onPressed: _images.isEmpty ? null : () => _saveImage(_page),
                        icon: const Icon(Icons.download, size: 18),
                        label: const Text('保存本页'),
                      ),
                    ],
                  ),
                  const Divider(height: 1, color: Colors.white12),
                  Row(
                    children: <Widget>[
                      IconButton(
                        tooltip: '上一章',
                        icon: const Icon(Icons.skip_previous),
                        onPressed: _chapterIndex > 0
                            ? () => _openChapter(_chapterIndex - 1)
                            : null,
                      ),
                      Expanded(
                        child: Text(
                          '第 ${_chapterIndex + 1}/${_chapters.length} 章 · '
                          '第 $pageLabel 页',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 12,
                            color: Colors.white,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: '下一章',
                        icon: const Icon(Icons.skip_next),
                        onPressed: _chapterIndex < _chapters.length - 1
                            ? () => _openChapter(_chapterIndex + 1)
                            : null,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 当前页号文案：瀑布流按图序号，单页 / 双页按页序号。
  String get _pageLabel {
    if (_settings.mode == ComicReadingMode.waterfall) {
      return '${_page + 1}/${_images.length}';
    }
    if (_settings.mode == ComicReadingMode.single) {
      return '${_page + 1}/${_images.length}';
    }
    final pageCount = (_images.length + 1) ~/ 2;
    return '${_page ~/ 2 + 1}/$pageCount';
  }
}

/// 阅读区内的一张图：负责加载、引用计数、双击放大、长按保存与自然比例回报。
///
/// 引用计数是本组件与管线之间的约定：挂载登记、卸载释放，被展示的位图不会被
/// 内存缓存的 LRU 回收——不会出现「画到已释放图片」的崩溃。
class _ComicImageTile extends StatefulWidget {
  const _ComicImageTile({
    required this.pipeline,
    required this.url,
    required this.index,
    required this.decodeWidth,
    required this.doubleTapZoom,
    required this.onLongPress,
    this.onRatio,
    this.fit = BoxFit.contain,
  });

  final SectionImagePipeline pipeline;
  final String url;
  final int index;
  final int decodeWidth;
  final bool doubleTapZoom;
  final VoidCallback onLongPress;

  /// 解码完成后回报「高/宽」比（瀑布流据此精确定位）。
  final ValueChanged<double>? onRatio;

  final BoxFit fit;

  @override
  State<_ComicImageTile> createState() => _ComicImageTileState();
}

class _ComicImageTileState extends State<_ComicImageTile>
    with SingleTickerProviderStateMixin {
  final TransformationController _transform = TransformationController();
  late final AnimationController _zoomAnimation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
  );
  Animation<Matrix4>? _zoomTween;

  ui.Image? _image;
  bool _failed = false;
  bool _acquired = false;
  Offset _zoomPoint = Offset.zero;

  @override
  void initState() {
    super.initState();
    _zoomAnimation.addListener(() {
      final tween = _zoomTween;
      if (tween != null) _transform.value = tween.value;
    });
    _resolve();
  }

  @override
  void didUpdateWidget(_ComicImageTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url ||
        oldWidget.decodeWidth != widget.decodeWidth) {
      _release();
      _resolve();
    }
  }

  @override
  void dispose() {
    _release();
    _zoomAnimation.dispose();
    _transform.dispose();
    super.dispose();
  }

  /// 当前持有引用的那张图（URL 与解码宽度）。换图/卸载时按它归还：
  /// `didUpdateWidget` 之后 `widget` 已经是新图，照 widget 释放会漏掉旧引用。
  String? _heldUrl;
  int? _heldWidth;

  void _release() {
    if (!_acquired) return;
    widget.pipeline.release(_heldUrl ?? widget.url, targetWidth: _heldWidth);
    _acquired = false;
    _image = null;
    _heldUrl = null;
    _heldWidth = null;
  }

  Future<void> _resolve() async {
    if (mounted) setState(() => _failed = false);
    final url = widget.url;
    final width = widget.decodeWidth;
    // image() 返回的图自带一次引用（见管线的引用契约），由 _release 归还。
    final image = await widget.pipeline.image(url, targetWidth: width);
    if (!mounted) {
      // 页面已退出：立刻归还这次引用，别把它钉在管线上。
      if (image != null) widget.pipeline.release(url, targetWidth: width);
      return;
    }
    if (image == null) {
      setState(() => _failed = true);
      return;
    }
    _acquired = true;
    _heldUrl = url;
    _heldWidth = width;
    setState(() => _image = image);
    if (image.width > 0) {
      widget.onRatio?.call(image.height / image.width);
    }
  }

  void _toggleZoom() {
    final scale = _transform.value.getMaxScaleOnAxis();
    final zoomed = scale > 1.01;
    final target = zoomed
        ? Matrix4.identity()
        : (Matrix4.identity()
          ..translateByDouble(
            _zoomPoint.dx * (1 - 2.0),
            _zoomPoint.dy * (1 - 2.0),
            0,
            1,
          )
          ..scaleByDouble(2.0, 2.0, 1, 1));
    _zoomTween = Matrix4Tween(begin: _transform.value, end: target)
        .animate(CurvedAnimation(parent: _zoomAnimation, curve: Curves.easeOut));
    _zoomAnimation.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    if (image == null) {
      return _failed ? _buildFailure() : _buildPlaceholder();
    }
    final content = RawImage(
      image: image,
      fit: widget.fit,
      filterQuality: FilterQuality.medium,
    );
    if (!widget.doubleTapZoom) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onLongPress: widget.onLongPress,
        child: Center(child: content),
      );
    }
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPress: widget.onLongPress,
      onDoubleTapDown: (details) => _zoomPoint = details.localPosition,
      onDoubleTap: _toggleZoom,
      child: InteractiveViewer(
        transformationController: _transform,
        minScale: 1,
        maxScale: 4,
        // 未放大时不抢纵向拖动，列表照常滚动；放大后拖动用于看图。
        panEnabled: _transform.value.getMaxScaleOnAxis() > 1.01,
        onInteractionEnd: (_) => setState(() {}),
        child: Center(child: content),
      ),
    );
  }

  Widget _buildPlaceholder() => ColoredBox(
        color: Colors.white.withValues(alpha: 0.04),
        child: const Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );

  Widget _buildFailure() => Center(
        child: TextButton.icon(
          onPressed: _resolve,
          icon: const Icon(Icons.refresh, size: 18),
          label: const Text('加载失败，点击重试'),
        ),
      );
}

/// 章节目录面板：阅读器内直接跳章，不必退回详情页。
class _ChapterSheet extends StatelessWidget {
  const _ChapterSheet({required this.chapters, required this.currentIndex});

  final List<SourceChapter> chapters;
  final int currentIndex;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      // Material 承载面板背景：ListTile 的背景与墨水效果需要它。
      child: Material(
        color: const Color(0xFF12121E),
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 14),
                child: Text(
                  '目录',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
              ),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: chapters.length,
                  itemBuilder: (context, index) {
                    final chapter = chapters[index];
                    final current = index == currentIndex;
                    return ListTile(
                      dense: true,
                      title: Text(
                        chapter.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          color: current ? Colors.white : LumeTheme.muted,
                          fontWeight:
                              current ? FontWeight.w600 : FontWeight.w400,
                        ),
                      ),
                      trailing: current
                          ? const Icon(Icons.play_arrow, size: 18)
                          : null,
                      onTap: () => Navigator.of(context).pop(index),
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
