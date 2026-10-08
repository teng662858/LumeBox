import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:path/path.dart' as p;

import '../../core/reading/reading.dart';
import '../../core/session/section.dart';
import '../../core/source/source.dart';
import '../../core/theme/lume_theme.dart';
import '../../core/util/lume_log.dart';
import '../../shared/widgets/glass_card.dart';
import '../../shared/widgets/notice_card.dart';
import '../../shared/widgets/state_view.dart';
import 'comic_bookmarks.dart';
import '../../core/session/section_module_settings.dart';
import 'comic_reader_settings_page.dart';
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
    this.runtimeAvailable,
  });

  final ReadingLibrary library;

  /// 已打开并校验过板块归属的数据源。
  final DataSource dataSource;

  final ReadingTarget target;

  final List<SourceChapter> chapters;

  final int initialChapterIndex;

  /// 续读的页序号（瀑布流模式下作为纵向滚动位置的锚点）。
  final int initialPage;

  /// 平台是否提供图源运行时；为空时取 [LumeSources.runtimeAvailableFor]。
  ///
  /// 这是**双保险**：正常路径下阅读器由板块入口进入，入口已经拦过一道
  /// （非 iOS 直接渲染骨架）；这里再拦一次，是为了让「阅读器被别的路径打开」
  /// （深链、测试、将来的路由重构）也不会在无运行时平台上白跑一遍网络与解码。
  /// 与 `ComicPage` 的平台门同一口径（宪法第 1 条）。
  ///
  /// 注意默认值必须按**漫画板块**取（`runtimeAvailableFor(Section.comic)`）：
  /// 用全局的 `LumeSources.runtimeAvailable` 会漏掉「猫源在 Android 上有引擎」
  /// 这类板块差异，也会让测试在无运行时的开发机上被误拦。
  final bool? runtimeAvailable;

  @override
  State<ComicReaderPage> createState() => _ComicReaderPageState();
}

class _ComicReaderPageState extends State<ComicReaderPage> {
  late final SectionImagePipeline _pipeline;

  /// 阅读设置可被面板改写（模式、侧边距、双击放大），因此不是 final。
  late ComicReaderSettings _settings;
  late List<SourceChapter> _chapters;
  late int _chapterIndex;

  /// 本平台是否提供图源运行时。为假时只渲染骨架，不碰网络与解码。
  bool get _runtimeAvailable =>
      widget.runtimeAvailable ??
      LumeSources.runtimeAvailableFor(widget.library.section);

  List<String> _images = const <String>[];
  bool _loading = true;
  bool _failed = false;
  String? _failureDetail;

  /// 当前页序号（单页 / 双页模式为页，瀑布流模式为图序号）。
  int _page = 0;

  /// 瀑布流模式下的页内比例 0..1。
  double _fraction = 0;

  /// 本作品的书签（按作品存进板块阅读库）。
  List<ComicBookmark> _bookmarks = const <ComicBookmark>[];

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
    _pipeline = SectionImagePipeline(
      cacheDir: widget.library.imageCacheDir,
      // 漫画板块的图片缓存已按用户要求关闭（不读盘也不落盘）：翻页 / 预取照旧，
      // 只是这一话跨会话再看会重新下载（内存缓存与管线复用仍在）。
      diskCache: SectionImagePipeline.diskCacheFor(Section.comic),
    );
    _settings = ComicReaderSettings.load(widget.library);
    // 模块设置（手势阈值 / 控件尺寸 / 间距）：与全局「漫画设置」同一份数据。
    _module = SectionModuleSettings.load(widget.library);
    _bookmarks = ComicBookmarks.decode(
      widget.library.setting(ComicBookmarks.keyFor(widget.target.itemId)),
    );
    _chapters = widget.chapters;
    _chapterIndex = widget.chapters.isEmpty
        ? 0
        : widget.initialChapterIndex.clamp(0, widget.chapters.length - 1);
    // 平台守卫：无运行时平台不落任何副作用（入架 / 进度都属于「真的读过」）。
    // `didChangeDependencies` 与 `build` 各拦了一道，这里也要拦——否则骨架
    // 渲染出来了，书架却已经多了一条记录。
    if (!_runtimeAvailable) return;
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
    final previous = _viewport;
    _viewport = MediaQuery.sizeOf(context);
    final ratio = MediaQuery.devicePixelRatioOf(context);
    _decodeWidthPx = math.max(1, (_viewport.width * ratio).round());
    if (!_bootstrapped) {
      _bootstrapped = true;
      // 平台守卫：无运行时平台只渲染骨架，不取章节、不解码、不落进度。
      if (_runtimeAvailable) _loadChapter(resume: true);
      return;
    }
    // 旋屏 / 分屏导致视口变化：滚动与翻页控制器是按旧尺寸建立的，偏移按像素
    // 保留会偏掉（瀑布流尤其明显，可能偏出半屏）。这里按当前页重建控制器，
    // 把位置锚回同一页——与换模式走同一条 `_rebuildControllers` 路径。
    //
    // `setState` 不能省：控制器是在 `build` 里交给 ListView / PageView 的，
    // 只换实例不触发重建的话，视图仍拿着旧控制器（实测：新控制器的 offset
    // 已经算对，界面却纹丝不动）。
    //
    // 只比尺寸不比 DPR：DPR 变化（外接屏）不影响几何换算，重建是白费。
    if (previous != _viewport) {
      _rebuildControllers();
      setState(() {});
    }
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

  Future<void> _loadChapter({bool resume = false, int? targetPage}) async {
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
    // 本章已经进来了：它的「预取」记录作废（下次接近时应该能重新预取）。
    _prefetchedChapters.remove(chapter.id);
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
          // 目标页优先（书签跳转要落在指定页上），其次才是续读位置。
          final start = targetPage ?? (resume ? widget.initialPage : 0);
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
            _failureDetail = '该章节不是图片内容：源返回了文本';
          });
        case VideoContent():
          setState(() {
            _loading = false;
            _failed = true;
            _failureDetail = '该章节不是图片内容：源返回了视频地址';
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
  ///
  /// **为什么还要在挂载后 jumpTo 一次**（实测踩过两次坑）：
  /// 1. `ScrollController.keepScrollOffset` 默认 true，会把旧像素偏移存进
  ///    `PageStorage` 并在新位置恢复；
  /// 2. 但把 `keepScrollOffset` 设成 false **并不能**解决——恢复走的是
  ///    `ScrollPosition.restoreScrollOffset()`，它按**树的存储位置**取旧值，
  ///    与控制器实例无关（`ListView` 还在原位，所以旧偏移照样被恢复回来）。
  ///
  /// 因此正确做法是：建好控制器后，等它 attach 到新的 Scrollable 上，
  /// 再把偏移**显式设到**按当前几何算出的位置。旋屏时旧偏移在新几何下对应的是
  /// 另一页，不设这一次，用户看到的就是「转屏后跳到别处」。
  void _rebuildControllers() {
    final oldPage = _pageController;
    final oldScroll = _scrollController;
    _pageController = null;
    _scrollController = null;
    switch (_settings.mode) {
      case ComicReadingMode.waterfall:
        final target = _waterfallOffsetFor(_page);
        _scrollController = ScrollController(initialScrollOffset: target);
        // 挂载后校正：见方法注释（PageStorage 会把旧偏移恢复回来）。
        _restoreScrollAfterAttach(target);
      case ComicReadingMode.single:
        _pageController = PageController(initialPage: _page);
      case ComicReadingMode.doublePage:
        // 跨页模式下 PageView 的下标是「屏」，要按配对规则换算。
        _pageController = PageController(
          initialPage: _settings.spreadIndexOf(_page),
        );
    }
    if (oldPage != null || oldScroll != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        oldPage?.dispose();
        oldScroll?.dispose();
      });
    }
  }

  /// 等控制器挂上 Scrollable 之后，把偏移设到 [target]。
  ///
  /// 用 `jumpTo` 而不是 `animateTo`：旋屏是瞬时几何变化，不该有滚动动画。
  void _restoreScrollAfterAttach(double target) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final controller = _scrollController;
      if (controller == null || !controller.hasClients) return;
      if ((controller.offset - target).abs() < 0.5) return;
      controller.jumpTo(target.clamp(
        controller.position.minScrollExtent,
        controller.position.maxScrollExtent,
      ));
    });
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
    // 临近章尾时提前拉下一章的头几张：不这么做的话，翻到章尾再等网络，
    // 用户看到的是「卡一下才出图」。
    _prefetchNextChapterHead();
  }

  /// 距章尾还剩多少张时开始预取下一章。
  static const int _nextChapterPrefetchWindow = 3;

  /// 下一章预取的图数量（够填满首屏即可，多了浪费流量）。
  static const int _nextChapterPrefetchCount = 3;

  /// 已经发起过预取的章节 id：同一章只预取一次。
  ///
  /// 进章时会把这个 id 移出集合（见 [_loadChapter]）：预取只为「马上要进这一章」
  /// 服务，进完就作废——否则回头再读上一章时，明明图早被内存预算淘汰了，
  /// 却因为「预取过」而不再预取，用户照样要等。
  final Set<String> _prefetchedChapters = <String>{};

  /// 预取下一章开头的几张图（只在接近章尾时做）。
  void _prefetchNextChapterHead() {
    if (_images.isEmpty) return;
    if (_page < _images.length - _nextChapterPrefetchWindow) return;
    final next = _chapterIndex + 1;
    if (next >= _chapters.length) return;
    final chapter = _chapters[next];
    if (!_prefetchedChapters.add(chapter.id)) return;
    unawaited(_prefetchChapterHead(chapter.id));
  }

  Future<void> _prefetchChapterHead(String chapterId) async {
    try {
      final content = await widget.dataSource.content(
        itemId: widget.target.itemId,
        chapterId: chapterId,
      );
      if (!mounted || content is! ImageContent) return;
      final head = content.images.take(_nextChapterPrefetchCount);
      _pipeline.preload(head, targetWidth: _decodeWidth);
    } catch (error) {
      // 预取失败只记日志：它只是提前准备，进章时会正常重试。
      LumeLog.warn('下一章预取失败: $chapterId ($error)');
    }
  }

  /// 解码宽度：按屏宽（物理像素）解码，长条图不按屏宽解码会占几十 MB。
  int get _decodeWidth => _decodeWidthPx;

  // ------------------------------------------------------------------ 瀑布流定位

  double get _innerWidth =>
      math.max(1, _viewport.width - _settings.marginOf(_viewport.width) * 2);

  /// 单张图的高度（不含页间距）。
  double _itemHeight(int index) =>
      _innerWidth * (_ratios[index] ?? _placeholderRatio);

  /// 单张图占据的滚动高度（含页间距）。
  ///
  /// 间距必须算进来：`itemExtentBuilder` 与这里用的是同一个值，否则
  /// 「滚动偏移 ↔ 图下标」的换算会随间距累积偏移（滑到后面就错位）。
  double _itemSlotHeight(int index) => _itemHeight(index) + _settings.pageGap;

  double _waterfallOffsetFor(int index) {
    var offset = 0.0;
    for (var i = 0; i < index && i < _images.length; i++) {
      offset += _itemSlotHeight(i);
    }
    return offset;
  }

  int _waterfallIndexFor(double offset) {
    var sum = 0.0;
    for (var i = 0; i < _images.length; i++) {
      final height = _itemSlotHeight(i);
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

  /// 打开「阅读设置」二级页（顶部工具栏入口）。
  ///
  /// 页面与阅读器共用同一份 `ComicReaderSettings`：那里改完立刻写回，
  /// 返回阅读页即生效（不需要额外的「保存」按钮）。
  Future<void> _openReaderSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ComicReaderSettingsPage(
          settings: _settings,
          onChanged: _updateSettings,
          canSavePage: _images.isNotEmpty && !_saving,
          onSavePage: () => _saveImage(_page),
          // 顶栏撤掉了「书签列表」按钮，但这个功能不能变成看得见摸不着——
          // 挪到这个二级页（这也是「不常用项」的正确去处）。
          bookmarkCount: _bookmarks.length,
          onOpenBookmarks: _showBookmarkSheet,
        ),
      ),
    );
  }

  /// 点按分区：默认呼出 / 收起工具栏；设置成「点击翻页」后，左 1/3 上一页、
  /// 右 1/3 下一页、中间仍是工具栏。分区方向随阅读方向：从右往左（日漫）时
  /// 下一页在左边——与滑动方向（`reverse`）一致，用户不必记哪边是前。
  ///
  /// **呼出工具栏（连带底部面板）要过一个「双击窗口」的延时**（用户口径：面板
  /// 太容易误触，稍微点重一点就弹出来）：
  /// - 期间若发生**双击放大**，这次呼出直接作废（放大是用户的本意，不是要面板）；
  /// - 翻页那两区**不等**：翻页要跟手，延时会让它发木。
  void _onTapUp(TapUpDetails details, Size size) {
    final zones = _settings.tapAction == ComicTapAction.pageTurn &&
        _settings.mode != ComicReadingMode.waterfall;
    if (!zones) {
      _scheduleToolbarToggle();
      return;
    }
    final x = details.localPosition.dx;
    final rtl = _settings.isRightToLeft;
    if (x < size.width / 3) {
      _turnPage(rtl ? 1 : -1);
      return;
    }
    if (x > size.width * 2 / 3) {
      _turnPage(rtl ? -1 : 1);
      return;
    }
    _scheduleToolbarToggle();
  }

  /// 延后一拍再呼出 / 收起工具栏（见 [_onTapUp] 的说明）。
  void _scheduleToolbarToggle() {
    _toolbarTimer?.cancel();
    // 延后时长 = 模块设置里的「呼出工具栏延时」，且**不小于双击判定窗口**：
    // 否则「双击判定窗口调大、呼出延时很小」时，双击还没判定完面板就弹出来了
    //（用户口径：双击放大时不该弹面板）。
    final delay = _module.toolbarToggleDelay >= _module.doubleTapWindow
        ? _module.toolbarToggleDelay
        : _module.doubleTapWindow;
    _toolbarTimer = Timer(delay, () {
      _toolbarTimer = null;
      if (!mounted) return;
      _toggleToolbar();
    });
  }

  /// 双击放大即将生效：撤掉待呼出的工具栏（用户要的是放大，不是面板）。
  void _cancelToolbarToggle() {
    _toolbarTimer?.cancel();
    _toolbarTimer = null;
  }

  Timer? _toolbarTimer;

  /// 本板块的模块设置（手势阈值 / 控件尺寸 / 间距 / 动画）。
  ///
  /// 与「设置 → 各模块独立设置 → 漫画设置」是**同一份数据**：那边改完回到阅读页
  /// 立即生效（本页每次进页面读一次；页内不重复读，避免与就地调整打架）。
  SectionModuleSettings _module = const SectionModuleSettings();

  /// 分区点击翻页：按逻辑页序前进 / 后退一页。
  ///
  /// 越界不动：章尾继续往前的手势交给滑动越界（[_onPagedScroll]）处理，
  /// 点一下就直接跳章会让「点到最后一页停住」变成意外换章。
  void _turnPage(int delta) {
    final controller = _pageController;
    if (controller == null || !controller.hasClients) return;
    final fallback = _settings.mode == ComicReadingMode.doublePage
        ? _settings.spreadIndexOf(_page)
        : _page;
    final current = (controller.page ?? fallback.toDouble()).round();
    final pageCount = _settings.mode == ComicReadingMode.doublePage
        ? _settings.spreadCount(_images.length)
        : _images.length;
    final target = current + delta;
    if (target < 0 || target >= pageCount) return;
    controller.animateToPage(
      target,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }

  /// 跳到本章指定页（书签跳转用）。
  void _goToPage(int page) {
    if (_images.isEmpty) return;
    final target = page.clamp(0, _images.length - 1);
    if (target == _page) return;
    setState(() {
      _page = target;
      _fraction = 0;
    });
    _rebuildControllers();
    _scheduleSave();
    _primeWindow();
  }

  void _onPageChanged(int page) {
    // 双页模式下 PageView 的下标是「屏」，换算成图序号；首页单独配对时
    // 第 1 屏就是第 1 张图，因此用配对规则反查而不是简单乘 2。
    final next = _settings.mode == ComicReadingMode.doublePage
        ? _settings.imagesOfSpread(page, _images.length).$1
        : page;
    if (next < 0) return;
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
      _page = mode == ComicReadingMode.doublePage
          ? _settings.imagesOfSpread(
              _settings.spreadIndexOf(_page),
              _images.length,
            ).$1
          : _page;
    });
    _settings.save(widget.library);
    _rebuildControllers();
    _primeWindow();
  }

  void _updateSettings(ComicReaderSettings next) {
    setState(() => _settings = next);
    _settings.save(widget.library);
  }

  // ------------------------------------------------------------------ 书签

  /// 当前页是否已加书签。
  bool get _bookmarkedHere =>
      ComicBookmarks.at(
        _bookmarks,
        chapterIndex: _chapterIndex,
        page: _page,
      ) !=
      null;

  /// 加 / 移除当前页的书签（按作品落库）。
  void _toggleBookmark() {
    if (_chapters.isEmpty || _images.isEmpty) return;
    final chapter = _chapters[_chapterIndex];
    final existing = ComicBookmarks.at(
      _bookmarks,
      chapterIndex: _chapterIndex,
      page: _page,
    );
    final next = existing != null
        ? ComicBookmarks.remove(_bookmarks, existing)
        : ComicBookmarks.add(
            _bookmarks,
            ComicBookmark(
              chapterIndex: _chapterIndex,
              chapterId: chapter.id,
              chapterTitle: chapter.title,
              page: _page,
              createdAt: DateTime.now(),
            ),
          );
    _writeBookmarks(next);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(milliseconds: 900),
        content: Text(existing != null ? '已移除书签' : '已加书签'),
      ),
    );
  }

  /// 删除一条书签（列表面板里删的）。
  void _removeBookmark(ComicBookmark bookmark) {
    _writeBookmarks(ComicBookmarks.remove(_bookmarks, bookmark));
  }

  void _writeBookmarks(List<ComicBookmark> next) {
    setState(() => _bookmarks = next);
    widget.library.setSetting(
      ComicBookmarks.keyFor(widget.target.itemId),
      ComicBookmarks.encode(next),
    );
  }

  /// 书签列表：点一条跳到对应章节的对应页，右侧可删。
  Future<void> _showBookmarkSheet() async {
    final selected = await showModalBottomSheet<ComicBookmark>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _BookmarkSheet(
        bookmarks: _bookmarks,
        onRemove: _removeBookmark,
      ),
    );
    if (selected == null || !mounted) return;
    if (selected.chapterIndex == _chapterIndex) {
      _goToPage(selected.page);
      return;
    }
    await _openChapter(selected.chapterIndex, targetPage: selected.page);
  }

  Future<void> _openChapter(int index, {int? targetPage}) async {
    if (index < 0 || index >= _chapters.length || index == _chapterIndex) return;
    // 加载中不再受理换章：越界手势会连续触发，而 `_chapterIndex` 在加载**开始**时
    // 就已经改掉了，第二次通知会拿新章的边界再判一次，可能一路连跳好几章。
    if (_loading) return;
    _saveTimer?.cancel();
    _saveProgress();
    setState(() {
      _chapterIndex = index;
      _page = 0;
      _fraction = 0;
      _toolbar = false;
    });
    await _loadChapter(resume: false, targetPage: targetPage);
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

  /// 长按图片：选择「保存图片」或「复制图片地址」。
  ///
  /// 用底部选择面板而不是直接保存：长按的意图有两种（存下来 / 分享给别处），
  /// 直接存会替用户做决定。分享走「复制地址」——不引入分享插件依赖，
  /// 用户粘到任意 App 都能用。
  Future<void> _onImageLongPress(int index) async {
    if (index < 0 || index >= _images.length) return;
    final action = await showModalBottomSheet<_ImageAction>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => const _ImageActionSheet(),
    );
    if (action == null || !mounted) return;
    switch (action) {
      case _ImageAction.save:
        await _saveImage(index);
      case _ImageAction.copyLink:
        await Clipboard.setData(ClipboardData(text: _images[index]));
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            duration: Duration(seconds: 1),
            content: Text('已复制图片地址'),
          ),
        );
    }
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
    // 平台骨架：无图源运行时的平台上阅读器不可达（板块入口已拦），
    // 这里再拦一次做双保险，避免别的入口把它拉起来白跑一遍。
    if (!_runtimeAvailable) {
      return const Scaffold(body: SafeArea(child: SkeletonNotice()));
    }
    return Scaffold(
      backgroundColor: _settings.background.color,
      extendBodyBehindAppBar: true,
      body: Stack(
        children: <Widget>[
          Positioned.fill(
            child: LayoutBuilder(
              builder: (context, constraints) => GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapUp: (details) => _onTapUp(details, constraints.biggest),
                child: _buildContent(),
              ),
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

  /// 翻页模式下的越界处理：滑到章尾再往前拉 = 进下一章。
  ///
  /// 用「越界拖动」而不是在最后一页加一个「下一章」按钮：前者是漫画阅读器的
  /// 通用手势，用户不需要学新东西；按钮则会在每一章末尾多出一屏。
  ///
  /// 方向必须按阅读方向算：`reverse: true`（从右往左）会把滚动轴整个翻过来，
  /// 于是「最后一页」落在 minScrollExtent 而不是 maxScrollExtent，越界的正负号
  /// 也跟着反。直接用像素正负判方向在日漫模式下会完全反过来。
  bool _onPagedScroll(ScrollNotification notification) {
    if (notification is! OverscrollNotification) return false;
    final metrics = notification.metrics;
    final rtl = _settings.isRightToLeft;
    // 阅读方向的「章尾 / 章首」在滚动轴上的位置。
    final atForwardEnd = rtl
        ? metrics.pixels <= metrics.minScrollExtent + 0.5
        : metrics.pixels >= metrics.maxScrollExtent - 0.5;
    final atBackwardEnd = rtl
        ? metrics.pixels >= metrics.maxScrollExtent - 0.5
        : metrics.pixels <= metrics.minScrollExtent + 0.5;
    // 越界的正负号同样随方向翻转。
    final overscrollingForward = rtl
        ? notification.overscroll < 0
        : notification.overscroll > 0;
    if (atForwardEnd && overscrollingForward) {
      _openChapter(_chapterIndex + 1);
    } else if (atBackwardEnd && !overscrollingForward) {
      _openChapter(_chapterIndex - 1);
    }
    return false;
  }

  /// 条漫瀑布流：纵向连续，按各图真实比例排布。
  ///
  /// 页间距在这里是「图与图之间的空隙」：设为 0 时图与图严丝合缝（条漫常见），
  /// 设大一点则像翻纸质分镜。空隙不占 itemExtent 之外的高度——它算在每项的
  /// 高度里，否则滚动定位会整体偏移。
  Widget _buildWaterfall() {
    final margin = _settings
        .marginOf(MediaQuery.maybeSizeOf(context)?.width ?? 400);
    final gap = _settings.pageGap;
    return NotificationListener<ScrollNotification>(
      onNotification: _onScroll,
      child: ListView.builder(
        controller: _scrollController,
        padding: EdgeInsets.zero,
        itemCount: _images.length,
        itemExtentBuilder: (index, _) => _itemHeight(index) + gap,
        itemBuilder: (context, index) => Padding(
          padding: EdgeInsets.fromLTRB(margin, 0, margin, gap),
          child: _ComicImageTile(
            pipeline: _pipeline,
            url: _images[index],
            index: index,
            decodeWidth: _decodeWidth,
            fit: BoxFit.cover,
            doubleTapZoom: _settings.doubleTapZoom,
            // 双击放大 = 用户要的是放大，不是面板：把待呼出的那次撤掉。
            onDoubleTapZoom: _cancelToolbarToggle,
            onLongPress: () => _onImageLongPress(index),
            onRatio: (ratio) => _onRatio(index, ratio),
          ),
        ),
      ),
    );
  }

  /// 单页 / 双页模式：横向翻页，[doublePage] 时一屏并排两页。
  ///
  /// 三个设置在这里落地：
  /// - **翻页方向**：`reverse` 让从右往左的日漫也能「向右滑看下一页」；
  /// - **跨页配对**：首页是否单独一屏（见 [ComicSpreadMode]），配对由
  ///   [ComicReaderSettings.imagesOfSpread] 统一算，不再在这里写死 `page * 2`；
  /// - **页间距**：翻页模式里作为两页之间的水平间隙，瀑布流里作为图之间的空隙。
  Widget _buildPaged({required bool doublePage}) {
    final width = MediaQuery.maybeSizeOf(context)?.width ?? 400;
    final margin = _settings.marginOf(width);
    final gap = _settings.pageGap;
    final pageCount = doublePage
        ? _settings.spreadCount(_images.length)
        : _images.length;
    return NotificationListener<ScrollNotification>(
      onNotification: _onPagedScroll,
      child: PageView.builder(
        controller: _pageController,
        itemCount: pageCount,
        // 从右往左：PageView 反向，于是「右滑 = 下一页」符合日漫直觉。
        reverse: _settings.isRightToLeft,
        onPageChanged: _onPageChanged,
        itemBuilder: (context, page) {
          return Padding(
            padding: EdgeInsets.symmetric(
              horizontal: margin,
              vertical: 4 + gap / 2,
            ),
            child: doublePage
                ? _buildSpread(page, gap)
                : _ComicImageTile(
                    pipeline: _pipeline,
                    url: _images[page],
                    index: page,
                    decodeWidth: _decodeWidth,
                    doubleTapZoom: _settings.doubleTapZoom,
            // 双击放大 = 用户要的是放大，不是面板：把待呼出的那次撤掉。
            onDoubleTapZoom: _cancelToolbarToggle,
                    onLongPress: () => _onImageLongPress(page),
                  ),
          );
        },
      ),
    );
  }

  /// 一屏两张：按配对规则取图，落单时给另一半留空位。
  ///
  /// 留空的一侧**不画占位**：纸质漫画里落单的那一页就是单独居中偏一侧，
  /// 加个灰块反而像加载失败。
  Widget _buildSpread(int spread, double gap) {
    final (first, second) = _settings.imagesOfSpread(spread, _images.length);
    if (first < 0) return const SizedBox.shrink();
    final tiles = <Widget>[
      Expanded(child: _tileFor(first)),
      SizedBox(width: gap),
      if (second > first)
        Expanded(child: _tileFor(second))
      else
        const Spacer(),
    ];
    // 从右往左时整屏镜像：两张图的左右顺序也跟着换，否则跨页内容是反的。
    return Row(
      children: _settings.isRightToLeft
          ? tiles.reversed.toList(growable: false)
          : tiles,
    );
  }

  Widget _tileFor(int index) => _ComicImageTile(
        pipeline: _pipeline,
        url: _images[index],
        index: index,
        decodeWidth: _decodeWidth,
        doubleTapZoom: _settings.doubleTapZoom,
        onLongPress: () => _onImageLongPress(index),
      );

  Widget _buildTopBar() {
    final chapter = _chapters.isEmpty ? null : _chapters[_chapterIndex];
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: GlassPanel(
        // 阅读器顶栏是压在画面上的浮层：用玻璃（半透明白 + 模糊）而不是实色块，
        // 图片会从栏下隐约透出来；底色与全局顶栏同一套。
        color: LumeTheme.glassStrong,
        border: Border(
          bottom: BorderSide(color: LumeTheme.hairline),
        ),
        child: SafeArea(
          bottom: false,
          child: Row(
            children: <Widget>[
              IconButton(
                icon: Icon(Icons.arrow_back, color: LumeTheme.textPrimary),
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
                        color: LumeTheme.textPrimary,
                      ),
                    ),
                    Text(
                      chapter?.title ??
                          '第 ${_chapterIndex + 1}/${_chapters.length} 章',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: LumeTheme.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: _bookmarkedHere ? '移除书签' : '加书签',
                icon: Icon(
                  _bookmarkedHere
                      ? Icons.bookmark
                      : Icons.bookmark_add_outlined,
                  color: LumeTheme.textPrimary,
                ),
                onPressed: _images.isEmpty ? null : _toggleBookmark,
              ),
              // 「书签列表」按用户口径移除（使用频次很低；书签仍可在书籍页的历史/收藏
              // 抽屉里看）。「加书签 / 移除书签」保留，那是高频动作。
              IconButton(
                tooltip: '阅读设置',
                icon: Icon(Icons.tune, color: LumeTheme.textPrimary),
                onPressed: _openReaderSettings,
              ),
              IconButton(
                tooltip: '目录',
                icon: Icon(Icons.list, color: LumeTheme.textPrimary),
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
        // 面板本身是浅色玻璃卡，底下这层只做「轻轻压暗画面」，不再是深色罩。
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: <Color>[
              LumeTheme.base.withValues(alpha: 0.55),
              Colors.transparent,
            ],
          ),
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
            child: GlassCard(
              radius: 18,
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
              child: ConstrainedBox(
                // 小屏 / 横屏兜底：面板行数多，超了就在面板内部滚动，不溢出。
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(context).height * 0.62,
                ),
                child: SingleChildScrollView(
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
                          SizedBox(
                            width: 46,
                            child: Text(
                              '侧边距',
                              style: TextStyle(fontSize: 12, color: LumeTheme.textSecondary),
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
                              style: TextStyle(
                                fontSize: 12,
                                color: LumeTheme.textSecondary,
                              ),
                            ),
                          ),
                        ],
                      ),
                      // 「双击放大」「保存本页」已搬到顶栏的【阅读设置】二级页
                      //（用户口径：不常用的别占底部面板的空间）。
                      Row(
                        children: <Widget>[
                          SizedBox(
                            width: 46,
                            child: Text(
                              '页间距',
                              style: TextStyle(fontSize: 12, color: LumeTheme.textSecondary),
                            ),
                          ),
                          Expanded(
                            child: Slider(
                              value: _settings.pageGap,
                              max: ComicReaderSettings.maxPageGap,
                              divisions: 12,
                              label: '${_settings.pageGap.round()}',
                              onChanged: (value) => _updateSettings(
                                _settings.copyWith(pageGap: value),
                              ),
                            ),
                          ),
                          SizedBox(
                            width: 40,
                            child: Text(
                              '${_settings.pageGap.round()}',
                              textAlign: TextAlign.end,
                              style: TextStyle(
                                fontSize: 12,
                                color: LumeTheme.textSecondary,
                              ),
                            ),
                          ),
                        ],
                      ),
                      // 「背景」「点击行为」「翻页方向」「跨页配对」也已搬到【阅读设置】
                      //（用户口径：底部面板只留阅读时随手会改的三项——阅读模式、
                      // 侧边距、页间距；其余是「设定一次就不动」的）。
                      Divider(height: 1, color: LumeTheme.divider),
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
                              style: TextStyle(
                                fontSize: 12,
                                color: LumeTheme.textPrimary,
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
    this.onDoubleTapZoom,
    this.onRatio,
    this.fit = BoxFit.contain,
  });

  final SectionImagePipeline pipeline;
  final String url;
  final int index;
  final int decodeWidth;
  final bool doubleTapZoom;

  /// 双击放大真正生效前回调（阅读器用它取消「待呼出工具栏」）。
  final VoidCallback? onDoubleTapZoom;
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
      onDoubleTap: () {
        widget.onDoubleTapZoom?.call();
        _toggleZoom();
      },
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
        color: LumeTheme.fill,
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
///
/// 出口（用户口径：删掉右上角的关闭叉号，改成手势返回）：
/// - **左右侧滑**：面板跟着手指平移，任一方向过阈值（或甩得够快）就关掉面板、
///   回到阅读页——两个方向都认，不必记「该往哪边划」；
/// - **下滑**：`showModalBottomSheet` 自带的面板拖拽；
/// - **点面板外的空白**：模态遮罩的默认行为。
///
/// 面板本身是「一个会横向平移的整块」：拖动量用 [AnimatedContainer] 的 transform
/// 表达，松手没到阈值就弹回原位（拖动中不加动画，否则跟手感变成拖影）。
class _ChapterSheet extends StatefulWidget {
  const _ChapterSheet({required this.chapters, required this.currentIndex});

  final List<SourceChapter> chapters;
  final int currentIndex;

  @override
  State<_ChapterSheet> createState() => _ChapterSheetState();
}

class _ChapterSheetState extends State<_ChapterSheet> {
  /// 当前横向偏移（跟手）。
  double _dx = 0;

  /// 是否正在拖动：决定 transform 用不用补间（见类文档）。
  bool _dragging = false;

  /// 关闭阈值：屏宽的 22%（约 86pt）——太敏感会误关，太钝像没响应。
  static const double _dismissFraction = 0.22;

  /// 甩动关闭的速度阈值（逻辑像素 / 秒）。
  static const double _dismissVelocity = 700;

  void _onDragUpdate(DragUpdateDetails details) {
    setState(() {
      _dragging = true;
      _dx += details.delta.dx;
    });
  }

  void _onDragEnd(DragEndDetails details) {
    final width = MediaQuery.sizeOf(context).width;
    final flung = details.velocity.pixelsPerSecond.dx.abs() >= _dismissVelocity;
    if (_dx.abs() >= width * _dismissFraction || flung) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _dragging = false;
      _dx = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: _dragging ? Duration.zero : const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      transform: Matrix4.translationValues(_dx, 0, 0),
      child: GestureDetector(
        // 横向拖动整块都认（竖直方向留给面板拖拽与列表滚动）。
        onHorizontalDragUpdate: _onDragUpdate,
        onHorizontalDragEnd: _onDragEnd,
        child: ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          // Material 承载面板背景：ListTile 的背景与墨水效果需要它。
          child: Material(
            color: LumeTheme.surface,
            child: SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  // 抬头仍然固定在列表之上（不随滚动走）：滚到哪儿都看得见「这是目录」。
                  // 不再放关闭按钮——出口改成左右侧滑（见类文档）。
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
                    child: Text(
                      '目录',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: LumeTheme.textPrimary,
                      ),
                    ),
                  ),
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: widget.chapters.length,
                      itemBuilder: (context, index) {
                        final chapter = widget.chapters[index];
                        final current = index == widget.currentIndex;
                        return ListTile(
                          dense: true,
                          title: Text(
                            chapter.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 14,
                              color: current
                                  ? LumeTheme.textPrimary
                                  : LumeTheme.textSecondary,
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
        ),
      ),
    );
  }
}

/// 长按图片的两种意图。
enum _ImageAction { save, copyLink }

/// 图片操作选择面板。
class _ImageActionSheet extends StatelessWidget {
  const _ImageActionSheet();

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      child: DecoratedBox(
        decoration: LumeTheme.background,
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              ListTile(
                leading: Icon(
                  Icons.download,
                  color: LumeTheme.textSecondary,
                ),
                title: Text(
                  '保存图片',
                  style: TextStyle(color: LumeTheme.textPrimary),
                ),
                subtitle: Text(
                  '存到本板块的导出目录（不写入系统相册）',
                  style: TextStyle(fontSize: 12, color: LumeTheme.muted),
                ),
                onTap: () => Navigator.of(context).pop(_ImageAction.save),
              ),
              ListTile(
                leading: Icon(
                  Icons.link,
                  color: LumeTheme.textSecondary,
                ),
                title: Text(
                  '复制图片地址',
                  style: TextStyle(color: LumeTheme.textPrimary),
                ),
                subtitle: Text(
                  '粘到任意 App 都能用',
                  style: TextStyle(fontSize: 12, color: LumeTheme.muted),
                ),
                onTap: () => Navigator.of(context).pop(_ImageAction.copyLink),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}

/// 书签列表面板：点一条跳到对应章节的对应页，右侧可删。
///
/// 删除在面板内**就地**生效（面板维护自己的展示副本），宿主回调负责落库——
/// 删一条就关面板、要再开一次才能删第二条，不是阅读器该有的手感。
class _BookmarkSheet extends StatefulWidget {
  const _BookmarkSheet({required this.bookmarks, required this.onRemove});

  final List<ComicBookmark> bookmarks;

  /// 删除一条：宿主负责落库。
  final ValueChanged<ComicBookmark> onRemove;

  @override
  State<_BookmarkSheet> createState() => _BookmarkSheetState();
}

class _BookmarkSheetState extends State<_BookmarkSheet> {
  late List<ComicBookmark> _items = List<ComicBookmark>.of(widget.bookmarks);

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      // Material 承载面板背景：ListTile 的背景与墨水效果需要它。
      child: Material(
        color: LumeTheme.surface,
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Padding(
                padding: EdgeInsets.symmetric(vertical: 14),
                child: Text(
                  '书签',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: LumeTheme.textPrimary,
                  ),
                ),
              ),
              if (_items.isEmpty)
                Padding(
                  padding: EdgeInsets.symmetric(vertical: 24, horizontal: 24),
                  child: Text(
                    '还没有书签\n阅读时点顶栏的书签按钮即可添加',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 13, color: LumeTheme.muted),
                  ),
                )
              else
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: _items.length,
                    itemBuilder: (context, index) {
                      final bookmark = _items[index];
                      return ListTile(
                        dense: true,
                        title: Text(
                          bookmark.describe(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14,
                            color: LumeTheme.textPrimary,
                          ),
                        ),
                        trailing: IconButton(
                          tooltip: '删除书签',
                          icon: Icon(
                            Icons.delete_outline,
                            size: 18,
                            color: LumeTheme.muted,
                          ),
                          onPressed: () {
                            setState(() {
                              _items = <ComicBookmark>[
                                for (final item in _items)
                                  if (item.key != bookmark.key) item,
                              ];
                            });
                            widget.onRemove(bookmark);
                          },
                        ),
                        onTap: () => Navigator.of(context).pop(bookmark),
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
