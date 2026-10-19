import 'package:lume_box/shared/widgets/lume_icon.dart';

import '../../shared/widgets/drawer_geometry.dart';
import '../../core/source/source_picker_groups.dart';
import '../source/waf_webview_page.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/services.dart'
    show
        Clipboard,
        ClipboardData,
        SystemChrome,
        SystemUiMode,
        DeviceOrientation,
        MethodChannel;
import 'package:path/path.dart' as p;

import '../../core/reading/reading.dart';
import '../../core/reading/chapter_display_order.dart';
import '../../core/speech/speech_channel.dart';
import '../../core/speech/speech_segments.dart';
import '../../core/speech/speech_session.dart';
import '../../core/speech/speech_settings.dart';
import '../../core/speech/speech_voice_labels.dart';
import '../novel/novel_speech_modes.dart';
import '../../shared/widgets/chapter_order_controls.dart';
import '../../core/session/section.dart';
import '../../core/source/source.dart';
import '../../core/net/network_settings.dart';
import '../../core/theme/lume_theme.dart';
import '../../core/util/lume_log.dart';
import '../../shared/widgets/glass_card.dart';
import '../../shared/widgets/notice_card.dart';
import '../../shared/widgets/state_view.dart';
import 'comic_bookmarks.dart';
import '../../core/session/section_module_settings.dart';
import 'comic_reader_settings_page.dart';
import 'comic_settings.dart';
import 'comic_reader_preferences.dart';
import 'comic_page_filters.dart';
import 'comic_speech_text.dart';
import 'comic_reader_status.dart';
import 'comic_reader_glyphs.dart';
import 'comic_page_composition.dart';
import 'comic_shader_artwork.dart';
import 'comic_glass_backdrop.dart';
import '../settings/log_report.dart';
import '../settings/log_report_page.dart';

import '../../core/reading/comic_image_tools.dart';
import 'comic_image_tools_page.dart';

part 'comic_reader_chrome.dart';
part 'comic_reader_menu.dart';
part 'comic_reader_surface.dart';

/// 全屏漫画阅读器：连续滚动、方向翻页与双页阅读，共用章节和进度底座。
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
    this.network = NetworkProfile.none,
    this.speechBackend,
    this.imageTools,
    this.pageBytes,
    this.imageExporter,
  });

  final ReadingLibrary library;

  /// Optional host export destination; defaults to the existing system share/save.
  final Future<bool> Function(Uint8List bytes, String name)? imageExporter;

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
  final NetworkProfile network;

  /// 测试注入：语音后端与 OCR 工具。为空时使用平台默认实现。
  final SpeechBackend? speechBackend;
  final ComicImageTools? imageTools;

  /// 测试注入：按图片地址取原始字节；为空时走阅读器自己的图片管线。
  final Future<Uint8List?> Function(String url)? pageBytes;

  @override
  State<ComicReaderPage> createState() => _ComicReaderPageState();
}

class _ComicReaderPageState extends State<ComicReaderPage>
    with WidgetsBindingObserver {
  late final SectionImagePipeline _pipeline;
  late final ComicImageTools _imageTools;
  late final Future<void> _imageModelReady;

  Future<void> _chooseSourceImageModel() async {
    var descriptor = SourceDescriptor(
      id: widget.dataSource.id,
      name: widget.dataSource.name,
      version: '',
      enabled: true,
    );
    try {
      final sources = await LumeSources.manager(widget.dataSource.section)
          .list();
      descriptor =
          sources
              .where((source) => source.id == widget.dataSource.id)
              .firstOrNull ??
          descriptor;
    } catch (_) {
      /* Saved picker grouping still applies without a runtime. */
    }
    _imageTools.imageStyle =
        SourcePickerGroups.groupFor(Section.comic, descriptor) == 'photo'
        ? 'photo'
        : 'anime';
  }

  /// 阅读设置可被面板改写（模式、侧边距、双击放大），因此不是 final。
  late ComicReaderSettings _settings;
  late List<SourceChapter> _chapters;
  late int _chapterIndex;

  /// 本平台是否提供图源运行时。为假时只渲染骨架，不碰网络与解码。
  bool get _runtimeAvailable =>
      widget.runtimeAvailable ??
      LumeSources.runtimeAvailableFor(widget.library.section);

  List<String> _images = const <String>[];

  /// 手动超分 / 上色后「应用到当前页」的临时结果（仅本次阅读，不写回源文件）。
  final Map<String, Uint8List> _pageOverrides = <String, Uint8List>{};

  /// 漫画朗读：复用听书的同一套 TTS，单说话人（不区分旁白 / 男女声）。
  SpeechSession? _speech;
  SpeechSettings _speechSettings = const SpeechSettings();
  final ValueNotifier<SpeechState> _speechState = ValueNotifier<SpeechState>(
    SpeechState.unavailable,
  );
  final ValueNotifier<String> _speechStatus = ValueNotifier<String>('');
  bool _speechContinuous = false;
  int _speechPage = 0;
  bool _speechWorking = false;
  int _speechGeneration = 0;
  bool _speechPanelOpened = false;
  ComicSpeechText? _speechText;
  String? _speechUrl;
  final ValueNotifier<ComicSpeechCursor?> _speechCursor = ValueNotifier(null);

  bool _loading = true;
  bool _failed = false;
  String? _failureDetail;

  /// 当前页序号（单页 / 双页模式为页，瀑布流模式为图序号）。
  int _page = 0;

  /// 瀑布流模式下的页内比例 0..1。
  double _fraction = 0;

  /// 本作品的书签（按作品存进板块阅读库）。
  List<ComicBookmark> _bookmarks = const <ComicBookmark>[];

  bool _toolbar = true;
  late ComicReaderPreferences _preferences;
  Timer? _autoTimer;
  Timer? _sleepTimer;
  Timer? _zoneHintTimer;
  bool _zoneHintShown = false;
  bool _startupZoneHint = false;
  DateTime? _sleepDeadline;
  bool _autoScrolling = false;
  bool _speechMini = false;
  bool _sharing = false;
  Future<List<(String, String)>>? _comicVoices;
  final _comicVoiceAnchor = GlobalKey(debugLabel: 'comic.speech.voice');
  bool _translationBusy = false;
  String _translationScope = 'off';
  int _wideHalf = 0;
  int _translationGeneration = 0;
  final Map<String, List<ComicTextRegion>> _translations = {};
  void _refresh(VoidCallback change) {
    if (mounted) setState(change);
  }

  void _saveExperience() => _preferences.save(widget.library);

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
    if (_runtimeAvailable) {
      WidgetsBinding.instance.addObserver(this);
      unawaited(
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky),
      );
    }
    _imageTools = widget.imageTools ?? ComicImageTools();
    _imageModelReady = _chooseSourceImageModel();
    _pipeline = SectionImagePipeline(
      decodeTransform: (bytes) async {
        await _imageModelReady;
        return _imageTools.automatic(bytes);
      },
      cacheDir: widget.library.imageCacheDir,
      network: widget.network,
      // 漫画板块的图片缓存已按用户要求关闭（不读盘也不落盘）：翻页 / 预取照旧，
      // 只是这一话跨会话再看会重新下载（内存缓存与管线复用仍在）。
      diskCache: SectionImagePipeline.diskCacheFor(Section.comic),
    )..bindSession(widget.dataSource.section, widget.dataSource.id);
    _settings = ComicReaderSettings.load(widget.library);
    _preferences = ComicReaderPreferences.load(widget.library);
    _translationScope = _annotations()['translation.scope'] == 'series'
        ? 'series'
        : 'off';
    if (widget.library.setting(ComicReaderPreferences.key) == null) {
      _preferences.flow = _settings.mode == ComicReadingMode.waterfall
          ? 'webtoon'
          : _settings.mode == ComicReadingMode.doublePage
          ? 'spread'
          : _settings.isRightToLeft
          ? 'rtl'
          : 'ltr';
      _preferences.tapZones = _settings.tapAction == ComicTapAction.pageTurn
          ? 'horizontal'
          : 'disabled';
    }
    if (_runtimeAvailable) unawaited(_applyOrientation());
    _pipeline.bindSource(widget.dataSource);
    // 正文图也可能落在源站自己的域名上（有的站连阅读页都在 Cloudflare 校验后面）：
    // 挂上源站会话，图片请求才带得动 cf_clearance（独立图床仍是一枚都不带）。
    _pipeline.bindSession(widget.dataSource.section, widget.dataSource.id);
    // 模块设置（手势阈值 / 控件尺寸 / 间距）：与全局「漫画设置」同一份数据。
    _module = SectionModuleSettings.load(widget.library);
    _bookmarks = ComicBookmarks.decode(
      widget.library.setting(ComicBookmarks.keyFor(widget.target.itemId)),
    );
    _speechSettings = SpeechSettings.decode(
      widget.library.setting(SpeechSettings.settingKey),
    ).copyWith(autoDialogue: false);
    _openComicSpeech();
    _chapters = widget.chapters;
    _chapterIndex = widget.chapters.isEmpty
        ? 0
        : widget.initialChapterIndex.clamp(0, widget.chapters.length - 1);
    // 平台守卫：无运行时平台不落任何副作用（历史 / 进度都属于「真的读过」）。
    // `didChangeDependencies` 与 `build` 各拦了一道，这里也要拦——否则骨架
    // 渲染出来了，历史却已经多了一条记录。
    if (!_runtimeAvailable) return;
    // 进阅读器只记历史，**不加入收藏**。书架要有这一条（未读角标才有章节
    // 总数口径），但收藏必须由用户在详情页点心形 / 加入书架才会发生。
    widget.library.recordHistoryItem(
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
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_runtimeAvailable && state == AppLifecycleState.resumed) {
      unawaited(
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky),
      );
    }
  }

  @override
  void dispose() {
    _autoTimer?.cancel();
    _sleepTimer?.cancel();
    _zoneHintTimer?.cancel();
    _toolbarTimer?.cancel();
    _translationGeneration++;
    _speechGeneration++;
    if (_runtimeAvailable) {
      WidgetsBinding.instance.removeObserver(this);
      unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
      unawaited(
        SystemChrome.setPreferredOrientations(DeviceOrientation.values),
      );
    }
    final speech = _speech;
    _speech = null;
    unawaited(speech?.dispose());
    _speechState.dispose();
    _speechStatus.dispose();
    _speechCursor.dispose();
    _imageTools.dispose();
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
        case ImageContent(:final images, :final imageHeaders):
          _pipeline.configureImageHeaders(imageHeaders);
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
          _showStartupZoneHint();
          if (_translationScope == 'series') unawaited(_translatePages(true));
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
        _pageController = PageController(initialPage: _displayIndexOf(_page));
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
      controller.jumpTo(
        target.clamp(
          controller.position.minScrollExtent,
          controller.position.maxScrollExtent,
        ),
      );
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
      for (
        int i = _page + radius + 1;
        i <= _page + radius * 2 && i < _images.length;
        i++
      )
        _images[i],
      for (int i = _page - radius - 1; i >= _page - radius * 2 && i >= 0; i--)
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
      _pipeline.configureImageHeaders(content.imageHeaders);
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
    final previouslyWide = (_ratios[index] ?? 2) < 1;
    setState(() => _ratios[index] = ratio);
    if (_preferences.splitWide &&
        _settings.mode == ComicReadingMode.single &&
        previouslyWide != (ratio < 1)) {
      _rebuildControllers();
    }
  }

  /// 瀑布流滚动：结束时才更新页序号与进度，滚动过程中不做重计算。
  bool _onScroll(ScrollNotification notification) {
    if (notification is ScrollEndNotification) {
      final controller = _scrollController;
      if (controller != null && controller.hasClients) {
        final index = _waterfallIndexFor(controller.offset);
        final height = _itemHeight(index);
        final start = _waterfallOffsetFor(index);
        final fraction = height <= 0
            ? 0.0
            : ((controller.offset - start) / height).clamp(0.0, 1.0);
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
    await _imageModelReady;
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ComicReaderSettingsPage(
          chapterOrder: ChapterDisplayOrder(
            widget.library,
            widget.target.sourceId,
          ),
          settings: _settings,
          onChanged: _updateSettings,
          canSavePage: _images.isNotEmpty && !_saving,
          onSavePage: () => _saveImage(_page),
          onImageTools: _images.isEmpty
              ? null
              : () async {
                  final url = _images[_page.clamp(0, _images.length - 1)];
                  final applied = await Navigator.of(context).push<Uint8List>(
                    MaterialPageRoute<Uint8List>(
                      builder: (_) => ComicImageToolsPage(
                        imageStyle: _imageTools.imageStyle,
                        loadOriginal: () => _pipeline.bytes(url),
                        allowApply: true,
                      ),
                    ),
                  );
                  if (applied == null || !mounted) return;
                  setState(() => _pageOverrides[url] = applied);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('已应用到当前页（仅本次阅读，原图不被覆盖）')),
                  );
                },
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
    if (_startupZoneHint) {
      _zoneHintTimer?.cancel();
      setState(() => _startupZoneHint = false);
    }
    final delta = _tapDelta(details.localPosition, size);
    if (delta == 0) {
      _scheduleToolbarToggle();
      return;
    }
    _stepPage(delta);
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
        : _displayIndexOf(_page);
    final current = (controller.page ?? fallback.toDouble()).round();
    final pageCount = _settings.mode == ComicReadingMode.doublePage
        ? _settings.spreadCount(_images.length)
        : _displayPages.length;
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
      _wideHalf = 0;
      _fraction = 0;
    });
    _rebuildControllers();
    _scheduleSave();
    _primeWindow();
  }

  void _onPageChanged(int page) {
    if (page < 0 ||
        (_settings.mode != ComicReadingMode.doublePage &&
            page >= _displayPages.length)) {
      return;
    }
    // 双页模式下 PageView 的下标是「屏」，换算成图序号；首页单独配对时
    // 第 1 屏就是第 1 张图，因此用配对规则反查而不是简单乘 2。
    final next = _settings.mode == ComicReadingMode.doublePage
        ? _settings.imagesOfSpread(page, _images.length).$1
        : _displayPages[page].$1;
    if (next < 0) return;
    final half = _settings.mode == ComicReadingMode.doublePage
        ? 0
        : _displayPages[page].$2;
    if (next == _page && half == _wideHalf) return;
    setState(() {
      _wideHalf = half;
      _page = next;
      _fraction = 0;
    });
    _scheduleSave();
    _primeWindow();
  }

  void _updateSettings(ComicReaderSettings next) {
    final previous = _settings;
    setState(() => _settings = next);
    if (next.mode != previous.mode || next.direction != previous.direction) {
      _preferences.flow = next.mode == ComicReadingMode.waterfall
          ? 'webtoon'
          : next.mode == ComicReadingMode.doublePage
          ? 'spread'
          : next.isRightToLeft
          ? 'rtl'
          : ['vertical', 'horizontal'].contains(_preferences.flow)
          ? _preferences.flow
          : 'ltr';
      _rebuildControllers();
    }
    if (next.tapAction != previous.tapAction) {
      _preferences.tapZones = next.tapAction == ComicTapAction.pageTurn
          ? 'horizontal'
          : 'disabled';
    }
    _settings.save(widget.library);
    _saveExperience();
  }

  // ------------------------------------------------------------------ 书签

  /// 当前页是否已加书签。
  bool get _bookmarkedHere =>
      ComicBookmarks.at(_bookmarks, chapterIndex: _chapterIndex, page: _page) !=
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
    if (_autoScrolling) _stopAutoScroll();
    final selected = await showLumeBottomSheet<ComicBookmark>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _BookmarkSheet(
        bookmarks: _bookmarks,
        notes: {
          for (final bookmark in _bookmarks)
            bookmark.key:
                '${_annotations()['page-note:${bookmark.chapterId}:${bookmark.page}'] ?? ''}',
        },
        onEdit: (bookmark) => _editNote(pageNote: true, bookmark: bookmark),
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
    if (index < 0 || index >= _chapters.length || index == _chapterIndex) {
      return;
    }
    // 加载中不再受理换章：越界手势会连续触发，而 `_chapterIndex` 在加载**开始**时
    // 就已经改掉了，第二次通知会拿新章的边界再判一次，可能一路连跳好几章。
    if (_loading) return;
    _translationGeneration++;
    _translationBusy = false;
    _translations.clear();
    if (_translationScope != 'series') _translationScope = 'off';
    _speechContinuous = false;
    _speechCursor.value = null;
    _speechText = null;
    _speechUrl = null;
    _speechGeneration++;
    _speechWorking = false;
    unawaited(_speech?.stop());
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
    if (_autoScrolling) _stopAutoScroll();
    final selected = await showLumeBottomSheet<int>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _ChapterSheet(
        title: widget.target.title,
        pageCount: _images.length,
        chapters: _chapters,
        currentIndex: _chapterIndex,
        order: ChapterDisplayOrder(widget.library, widget.target.sourceId),
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
    final action = await showLumeBottomSheet<_ImageAction>(
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
      const SnackBar(duration: Duration(seconds: 1), content: Text('正在保存图片…')),
    );
    try {
      final url = _images[index];
      final bytes = await _pipeline.bytes(url);
      if (!mounted) return;
      if (bytes == null) {
        messenger.showSnackBar(const SnackBar(content: Text('保存失败：图片未能取到')));
        return;
      }
      final file = widget.library.saveImage(_fileNameFor(url, index), bytes);
      messenger.showSnackBar(SnackBar(content: Text('已保存到 ${file.path}')));
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
  Widget build(BuildContext context) =>
      ModuleGlassScope(module: GlassModule.comic, child: _legacyBuild(context));
  Widget _legacyBuild(BuildContext context) {
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
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    ColorFiltered(
                      colorFilter: ColorFilter.matrix(_preferences.colorMatrix),
                      child: _buildContent(),
                    ),
                    if (_preferences.brightness < 1)
                      IgnorePointer(
                        child: ColoredBox(
                          color: Colors.black.withValues(
                            alpha: 1 - _preferences.brightness,
                          ),
                        ),
                      ),
                    if (_preferences.showZones || _startupZoneHint)
                      IgnorePointer(
                        key: const Key('comic.tapZonesOverlay'),
                        child: _tapZonePreview(),
                      ),
                  ],
                ),
              ),
            ),
          ),
          if (_toolbar) ...<Widget>[_buildTopBar(), _buildBottomPanel()],
          if (_speechMini) _buildSpeechMini(),
          if (_speechPanelOpened && !_speechMini) _buildSpeechRestore(),
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
        action: (_failureDetail?.contains('NEED_WEBVIEW_VERIFY') ?? false)
            ? OutlinedButton.icon(
                icon: const LumeIcon(Icons.public, slot: 'comic_reader_page.1'),
                label: const Text('章节网页验证'),
                onPressed: () async {
                  final outcome = await runWafWebViewFlow(
                    context: context,
                    section: widget.library.section,
                    sourceId: widget.target.sourceId,
                    sourceName: widget.target.title,
                    failureMessage: _failureDetail,
                  );
                  if (mounted && outcome == WafWebViewOutcome.collected) {
                    await _loadChapter(resume: false);
                  }
                },
              )
            : null,
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
      ComicReadingMode.single =>
        ['horizontal', 'vertical'].contains(_preferences.flow)
            ? _buildContinuous()
            : _buildPaged(doublePage: false),
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
    final rtl = _settings.isRightToLeft && _preferences.flow != 'vertical';
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
    final margin = _settings.marginOf(
      MediaQuery.maybeSizeOf(context)?.width ?? 400,
    );
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
            overrideBytes: _pageOverrides[_images[index]],
            decodeWidth: _decodeWidth,
            fit: BoxFit.cover,
            cropRatio: _preferences.cropRatio,
            gamma: _preferences.gamma,
            sharpness: _preferences.sharpness,
            denoise: _preferences.denoise,
            loadBytes: widget.pageBytes,
            doubleTapZoom: _settings.doubleTapZoom,
            zoomLocked: _preferences.zoomLocked,
            speechCursor: _speechCursor,
            translations: _translations[_images[index]],
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
        : _displayPages.length;
    return NotificationListener<ScrollNotification>(
      onNotification: _onPagedScroll,
      child: PageView.builder(
        controller: _pageController,
        itemCount: pageCount,
        // 从右往左：PageView 反向，于是「右滑 = 下一页」符合日漫直觉。
        scrollDirection: _preferences.flow == 'vertical'
            ? Axis.vertical
            : Axis.horizontal,
        reverse: _settings.isRightToLeft && _preferences.flow != 'vertical',
        onPageChanged: _onPageChanged,
        itemBuilder: (context, page) {
          final physical = doublePage ? 0 : _displayPages[page].$1;
          final half = doublePage ? 0 : _displayPages[page].$2;
          return Padding(
            padding: EdgeInsets.symmetric(
              horizontal: margin,
              vertical: 4 + gap / 2,
            ),
            child: doublePage
                ? _buildSpread(page, gap)
                : _ComicImageTile(
                    pipeline: _pipeline,
                    url: _images[physical],
                    index: physical,
                    overrideBytes: _pageOverrides[_images[physical]],
                    decodeWidth: _decodeWidth,
                    gamma: _preferences.gamma,
                    sharpness: _preferences.sharpness,
                    denoise: _preferences.denoise,
                    loadBytes: widget.pageBytes,
                    cropRatio: _preferences.cropRatio,
                    splitHalf: half,
                    onRatio: (ratio) => _onRatio(physical, ratio),
                    doubleTapZoom: _settings.doubleTapZoom,
                    zoomLocked: _preferences.zoomLocked,
                    speechCursor: _speechCursor,
                    translations: _translations[_images[physical]],
                    // 双击放大 = 用户要的是放大，不是面板：把待呼出的那次撤掉。
                    onDoubleTapZoom: _cancelToolbarToggle,
                    onLongPress: () => _onImageLongPress(physical),
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
      if (second > first) Expanded(child: _tileFor(second)) else const Spacer(),
    ];
    // 从右往左时整屏镜像：两张图的左右顺序也跟着换，否则跨页内容是反的。
    return Row(
      children: _settings.isRightToLeft
          ? tiles.reversed.toList(growable: false)
          : tiles,
    );
  }

  Widget _tileFor(int index, {int half = 0}) => _ComicImageTile(
    cropRatio: _preferences.cropRatio,
    splitHalf: half,
    onRatio: (ratio) => _onRatio(index, ratio),
    pipeline: _pipeline,
    url: _images[index],
    index: index,
    overrideBytes: _pageOverrides[_images[index]],
    decodeWidth: _decodeWidth,
    gamma: _preferences.gamma,
    sharpness: _preferences.sharpness,
    denoise: _preferences.denoise,
    loadBytes: widget.pageBytes,
    doubleTapZoom: _settings.doubleTapZoom,
    zoomLocked: _preferences.zoomLocked,
    speechCursor: _speechCursor,
    translations: _translations[_images[index]],
    onLongPress: () => _onImageLongPress(index),
  );

  // ------------------------------------------------------------------ 朗读

  void _openComicSpeech() {
    final session = SpeechSession(
      backend: widget.speechBackend ?? createPlatformSpeechBackend(),
      onCompleted: _onComicSpeechCompleted,
      onPosition: _onComicSpeechPosition,
      onEvent: _onComicSpeechEvent,
    );
    _speech = session;
    // 把已保存的模式 / 音色 / 语速下发给后端；否则重新进阅读器后会退回系统默认。
    _applyComicSpeechSettings();
    session.state.addListener(_mirrorComicSpeechState);
    _mirrorComicSpeechState();
  }

  void _mirrorComicSpeechState() {
    final state = _speech?.state.value;
    if (state == null || !mounted) return;
    setState(() {});
    if (_speechState.value != state) _speechState.value = state;
    if (state == SpeechState.idle || state == SpeechState.unavailable) {
      _speechCursor.value = null;
    }
  }

  void _applyComicSpeechSettings() {
    final backend = _speech?.backend;
    if (backend is MethodChannelSpeechBackend) {
      backend.applySettings(_speechSettings);
    }
  }

  void _onComicSpeechCompleted() {
    if (!_speechContinuous) {
      _speechStatus.value = '本页读完';
      return;
    }
    unawaited(_advanceComicSpeechPage());
  }

  void _onComicSpeechEvent(SpeechEvent event) {
    if (event.kind != SpeechEventKind.failed) return;
    _speechCursor.value = null;
    _speechContinuous = false;
    _speechStatus.value = '朗读中断：${event.message ?? '未知原因'}';
  }

  Future<void> _advanceComicSpeechPage() async {
    final next = _speechPage + 1;
    if (next >= _images.length) {
      _speechContinuous = false;
      _speechStatus.value = '本章已读完';
      return;
    }
    _speechPage = next;
    await _speakComicPage(next);
  }

  /// 识别一页并交给听书会话朗读。OCR 与朗读串行，避免整章一次占满内存。
  Future<void> _speakComicPage(int index) async {
    final session = _speech;
    if (session == null || _speechWorking) return;
    if (index < 0 || index >= _images.length) return;
    if (_speechSettings.followAlong && index != _page) _goToPage(index);
    final generation = _speechGeneration;
    _speechWorking = true;
    _speechStatus.value = '正在识别第 ${index + 1}/${_images.length} 页…';
    try {
      final url = _images[index];
      final bytes =
          _pageOverrides[url] ??
          await (widget.pageBytes?.call(url) ?? _pipeline.bytes(url));
      if (bytes == null || bytes.isEmpty) {
        throw StateError('图片尚未下载完成');
      }
      if (!mounted || generation != _speechGeneration) return;
      final regions = await _imageTools.recognizeRegions(bytes);
      if (!mounted || generation != _speechGeneration) return;
      final pageText = ComicSpeechText(regions);
      final text = pageText.text;
      _speechText = pageText;
      _speechUrl = url;
      if (text.isEmpty) {
        _speechStatus.value = '第 ${index + 1} 页没有识别到文字';
        if (_speechContinuous) {
          _speechWorking = false;
          await _advanceComicSpeechPage();
          return;
        }
        return;
      }
      final segments = SpeechSegments.split(
        text,
        maxChars: _speechSettings.maxCharsPerSegment,
      );
      final rejection = await session.start(segments);
      if (!mounted || generation != _speechGeneration) {
        await session.stop();
        return;
      }
      if (rejection != null) {
        _speechContinuous = false;
        _speechStatus.value = rejection;
        return;
      }
      _speechStatus.value = '朗读中 · 第 ${index + 1}/${_images.length} 页';
    } catch (error) {
      if (!mounted || generation != _speechGeneration) return;
      _speechContinuous = false;
      _speechStatus.value = '漫画朗读失败：$error';
    } finally {
      if (generation == _speechGeneration) _speechWorking = false;
    }
  }

  Future<void> _startComicSpeech({required bool continuous}) async {
    if (_images.isEmpty) {
      _speechStatus.value = '本话还没有可朗读的图片';
      return;
    }
    _stopAutoScroll();
    _speechCursor.value = null;
    _speechText = null;
    _speechUrl = null;
    _speechGeneration++;
    _speechWorking = false;
    _speechContinuous = continuous;
    _speechPage = _page.clamp(0, _images.length - 1);
    await _speakComicPage(_speechPage);
  }

  Future<void> _showComicSpeechPanel() async {
    final session = _speech;
    if (session == null) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) => SafeArea(
          top: false,
          child: ListView(
            shrinkWrap: true,
            padding: EdgeInsets.fromLTRB(
              20,
              0,
              20,
              20 + MediaQuery.viewInsetsOf(context).bottom,
            ),
            children: <Widget>[
              Text(
                '漫画朗读',
                style: TextStyle(
                  fontSize: LumeTypography.sectionTitleSize,
                  fontWeight: FontWeight.w600,
                  color: LumeTheme.textPrimary,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '按页识别文字，使用听书里同一套 TTS；单说话人，不区分旁白与男女声。'
                '设备端文字识别目前仅 iOS。',
                style: TextStyle(
                  fontSize: LumeTypography.descriptionSize,
                  height: 1.5,
                  color: LumeTheme.descriptionColor,
                ),
              ),
              const SizedBox(height: 8),
              NovelSpeechModes(
                settings: _speechSettings,
                singleSpeaker: true,
                onChanged: (value) {
                  final next = value.copyWith(autoDialogue: false);
                  setState(() => _speechSettings = next);
                  if (context.mounted) setSheetState(() {});
                  _applyComicSpeechSettings();
                  widget.library.setSetting(
                    SpeechSettings.settingKey,
                    next.encode(),
                  );
                },
              ),
              const Divider(height: 24),
              ValueListenableBuilder<SpeechState>(
                valueListenable: _speechState,
                builder: (context, state, _) {
                  final active =
                      state == SpeechState.speaking ||
                      state == SpeechState.pausing;
                  final paused = state == SpeechState.paused;
                  final unavailable = state == SpeechState.unavailable;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: FilledButton.icon(
                              onPressed: unavailable
                                  ? null
                                  : () async {
                                      if (paused) {
                                        await session.resume();
                                      } else if (active) {
                                        await session.pause();
                                      } else {
                                        await _startComicSpeech(
                                          continuous: false,
                                        );
                                      }
                                      if (context.mounted) setSheetState(() {});
                                    },
                              icon: LumeIcon(
                                active
                                    ? Icons.pause
                                    : paused
                                    ? Icons.play_arrow
                                    : Icons.headphones_outlined,
                                slot: 'comic_reader_page.2',
                                variant: true,
                              ),
                              label: Text(
                                active
                                    ? '暂停'
                                    : paused
                                    ? '继续'
                                    : '朗读本页',
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          OutlinedButton(
                            onPressed: unavailable
                                ? null
                                : () async {
                                    await _startComicSpeech(continuous: true);
                                    if (context.mounted) setSheetState(() {});
                                  },
                            child: const Text('读到本章末'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      ValueListenableBuilder<String>(
                        valueListenable: _speechStatus,
                        builder: (context, value, _) => Text(
                          value.isEmpty
                              ? (unavailable ? '当前平台不支持语音朗读' : '')
                              : value,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: LumeTypography.descriptionSize,
                            fontWeight: FontWeight.w600,
                            color: LumeTheme.textPrimary,
                          ),
                        ),
                      ),
                      TextButton.icon(
                        onPressed: () async {
                          await _stopComicSpeech();
                          if (context.mounted) setSheetState(() {});
                        },
                        icon: const LumeIcon(
                          Icons.stop_circle_outlined,
                          slot: 'comic_reader_page.3',
                        ),
                        label: const Text('停止'),
                      ),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTopBar() => _readerTopBar();
  Widget _buildBottomPanel() => _readerBottomBar();
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
    this.zoomLocked = false,
    this.onRatio,
    this.fit = BoxFit.contain,
    this.overrideBytes,
    this.translations,
    this.speechCursor,
    this.cropRatio = 0,
    this.splitHalf = 0,
    this.gamma = 1,
    this.sharpness = 0,
    this.denoise = false,
    this.loadBytes,
  });

  final SectionImagePipeline pipeline;
  final String url;
  final int index;
  final int decodeWidth;
  final bool doubleTapZoom;
  final bool zoomLocked;

  /// 手动超分 / 上色后应用到当前页的临时图片（优先于管线结果）。
  final Uint8List? overrideBytes;

  /// 双击放大真正生效前回调（阅读器用它取消「待呼出工具栏」）。
  final VoidCallback? onDoubleTapZoom;
  final VoidCallback onLongPress;

  /// 解码完成后回报「高/宽」比（瀑布流据此精确定位）。
  final ValueChanged<double>? onRatio;

  final double cropRatio;
  final int splitHalf;
  final double gamma, sharpness;
  final bool denoise;
  final Future<Uint8List?> Function(String url)? loadBytes;
  final ValueListenable<ComicSpeechCursor?>? speechCursor;
  final List<ComicTextRegion>? translations;
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
  int _resolveGeneration = 0;
  bool _failed = false;
  bool _acquired = false;
  bool _ownsImage = false;
  Offset _zoomPoint = Offset.zero;

  @override
  void initState() {
    super.initState();
    _zoomAnimation.addListener(() {
      final tween = _zoomTween;
      if (tween != null) _transform.value = tween.value;
    });
    _zoomAnimation.addStatusListener((status) {
      if (status == AnimationStatus.completed && mounted) setState(() {});
    });
    _resolve();
  }

  @override
  void didUpdateWidget(_ComicImageTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.zoomLocked && !oldWidget.zoomLocked) _zoomAnimation.stop();
    if (oldWidget.url != widget.url ||
        oldWidget.decodeWidth != widget.decodeWidth ||
        oldWidget.overrideBytes != widget.overrideBytes) {
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
    _resolveGeneration++;
    if (_acquired) {
      widget.pipeline.release(_heldUrl ?? widget.url, targetWidth: _heldWidth);
      _acquired = false;
    }
    if (_ownsImage) {
      // RawImage 可能还在这一帧引用旧图：等本帧结束再释放原生位图。
      final owned = _image;
      _ownsImage = false;
      _image = null;
      if (owned != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) => owned.dispose());
      }
    } else {
      _image = null;
    }
    _heldUrl = null;
    _heldWidth = null;
  }

  Future<void> _resolve() async {
    if (mounted) setState(() => _failed = false);
    final url = widget.url;
    final width = widget.decodeWidth;
    final generation = ++_resolveGeneration;
    Uint8List? override;
    try {
      override = widget.overrideBytes ?? await widget.loadBytes?.call(url);
    } catch (_) {
      if (mounted && generation == _resolveGeneration) {
        setState(() => _failed = true);
      }
      return;
    }
    if (!mounted || generation != _resolveGeneration) return;
    if (override != null) {
      try {
        final codec = await ui.instantiateImageCodec(
          override,
          targetWidth: width,
        );
        final frame = await codec.getNextFrame();
        final image = frame.image;
        codec.dispose();
        if (!mounted || generation != _resolveGeneration) {
          image.dispose();
          return;
        }
        _ownsImage = true;
        _acquired = false;
        _heldUrl = null;
        _heldWidth = null;
        setState(() => _image = image);
        if (image.width > 0) {
          widget.onRatio?.call(image.height / image.width);
        }
      } catch (_) {
        if (mounted && generation == _resolveGeneration) {
          setState(() => _failed = true);
        }
      }
      return;
    }
    // image() 返回的图自带一次引用（见管线的引用契约），由 _release 归还。
    final image = await widget.pipeline.image(url, targetWidth: width);
    if (!mounted || generation != _resolveGeneration) {
      // 页面已退出：立刻归还这次引用，别把它钉在管线上。
      if (image != null) widget.pipeline.release(url, targetWidth: width);
      return;
    }
    if (image == null) {
      setState(() => _failed = true);
      return;
    }
    _acquired = true;
    _ownsImage = false;
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
    _zoomTween = Matrix4Tween(
      begin: _transform.value,
      end: target,
    ).animate(CurvedAnimation(parent: _zoomAnimation, curve: Curves.easeOut));
    _zoomAnimation.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    if (image == null) {
      return _failed ? _buildFailure() : _buildPlaceholder();
    }
    final content = ComicPageFilters(
      image: image,
      gamma: widget.gamma,
      sharpness: widget.sharpness,
      denoise: widget.denoise,
      builder: (image) => LayoutBuilder(
        builder: (context, constraints) {
          final full = Rect.fromLTWH(
            0,
            0,
            image.width.toDouble(),
            image.height.toDouble(),
          );
          final rawSource = comicPageSource(
            full.size,
            cropRatio: widget.cropRatio,
            half: widget.splitHalf,
          );
          final geometry = ComicPageGeometry(
            imageSize: full.size,
            source: rawSource,
            size: constraints.biggest,
            fit: widget.fit,
          );
          final source = geometry.source;
          final rect = geometry.destination;
          return Stack(
            fit: StackFit.expand,
            children: [
              if (image.width * image.height > 8000000 &&
                  (widget.gamma != 1 ||
                      widget.sharpness != 0 ||
                      widget.denoise))
                ComicShaderArtwork(
                  image: image,
                  geometry: geometry,
                  gamma: widget.gamma,
                  sharpness: widget.sharpness,
                  denoise: widget.denoise,
                )
              else if (widget.cropRatio == 0 && widget.splitHalf == 0)
                RawImage(
                  image: image,
                  fit: widget.fit,
                  filterQuality: FilterQuality.medium,
                )
              else
                CustomPaint(
                  painter: _ComicArtworkPainter(image, source, widget.fit),
                ),
              if (widget.speechCursor != null)
                Positioned.fill(
                  child: IgnorePointer(
                    child: ValueListenableBuilder<ComicSpeechCursor?>(
                      valueListenable: widget.speechCursor!,
                      builder: (context, cursor, _) {
                        final region = cursor?.url == widget.url
                            ? cursor?.line?.region
                            : null;
                        if (region == null) return const SizedBox.shrink();
                        final box =
                            Rect.fromLTWH(
                                  rect.left +
                                      (region.x * full.width - source.left) /
                                          source.width *
                                          rect.width,
                                  rect.top +
                                      (region.y * full.height - source.top) /
                                          source.height *
                                          rect.height,
                                  region.width *
                                      full.width /
                                      source.width *
                                      rect.width,
                                  region.height *
                                      full.height /
                                      source.height *
                                      rect.height,
                                )
                                .intersect(rect)
                                .intersect(Offset.zero & constraints.biggest);
                        if (box.isEmpty) return const SizedBox.shrink();
                        return Stack(
                          children: [
                            Positioned.fromRect(
                              rect: box,
                              child: Container(
                                key: ValueKey(
                                  'comic.speech.region.${widget.index}',
                                ),
                                decoration: BoxDecoration(
                                  color: _readerAccent.withValues(alpha: .12),
                                  borderRadius: BorderRadius.circular(4),
                                  border: Border.all(
                                    color: _readerAccent,
                                    width: 2,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ),
              if (widget.translations?.isNotEmpty ?? false)
                Positioned.fill(
                  child: IgnorePointer(
                    child: CustomPaint(
                      painter: ComicTranslationPainter(
                        geometry: geometry,
                        regions: widget.translations!,
                        textScaler: MediaQuery.textScalerOf(context),
                        fontFamily: DefaultTextStyle.of(context)
                            .style
                            .fontFamily,
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
    if (!widget.doubleTapZoom && _transform.value.getMaxScaleOnAxis() <= 1.01) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onLongPress: widget.onLongPress,
        child: Center(child: content),
      );
    }
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPress: widget.onLongPress,
      onDoubleTapDown: widget.zoomLocked || !widget.doubleTapZoom
          ? null
          : (details) => _zoomPoint = details.localPosition,
      onDoubleTap: widget.zoomLocked || !widget.doubleTapZoom
          ? null
          : () {
              widget.onDoubleTapZoom?.call();
              _toggleZoom();
            },
      child: InteractiveViewer(
        transformationController: _transform,
        minScale: 1,
        maxScale: 4,
        // 未放大时不抢纵向拖动，列表照常滚动；放大后拖动用于看图。
        scaleEnabled: !widget.zoomLocked,
        panEnabled:
            !widget.zoomLocked && _transform.value.getMaxScaleOnAxis() > 1.01,
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
      icon: const LumeIcon(
        Icons.refresh,
        slot: 'comic_reader_page.4',
        size: 18,
      ),
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
class _ComicArtworkPainter extends CustomPainter {
  const _ComicArtworkPainter(this.image, this.source, this.fit);
  final ui.Image image;
  final Rect source;
  final BoxFit fit;
  @override
  void paint(Canvas canvas, Size size) {
    final fitted = applyBoxFit(fit, source.size, size);
    final src = Alignment.center.inscribe(fitted.source, source);
    final dest = Alignment.center.inscribe(
      fitted.destination,
      Offset.zero & size,
    );
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    canvas.drawImageRect(
      image,
      src,
      dest,
      Paint()..filterQuality = FilterQuality.medium,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ComicArtworkPainter old) =>
      old.image != image || old.source != source || old.fit != fit;
}

class _ChapterSheet extends StatefulWidget {
  const _ChapterSheet({
    required this.chapters,
    required this.currentIndex,
    required this.order,
    required this.title,
    required this.pageCount,
  });
  final String title;
  final int pageCount;
  final ChapterDisplayOrder order;

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

  ScrollController? _chapterScroll;
  bool _showOrder = false;

  @override
  void dispose() {
    _chapterScroll?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final indexes = widget.order.indexes(widget.chapters);
    final scaler = MediaQuery.textScalerOf(context);
    final rowHeight = math.max(54.0, scaler.scale(14) * 2.6 + 24);
    double extent(int position) =>
        rowHeight +
        (indexes[position] == widget.currentIndex
            ? scaler.scale(12) * 1.3 + 4
            : 0);
    double currentOffset() {
      var offset = 0.0;
      for (
        var i = 0;
        i < indexes.length && indexes[i] != widget.currentIndex;
        i++
      ) {
        offset += extent(i);
      }
      return math.max(0, offset - MediaQuery.sizeOf(context).height * .22);
    }

    _chapterScroll ??= ScrollController(
      initialScrollOffset: currentOffset(),
      keepScrollOffset: false,
    );
    return AnimatedContainer(
      duration: _dragging ? Duration.zero : const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      transform: Matrix4.translationValues(_dx, 0, 0),
      child: GestureDetector(
        onHorizontalDragUpdate: _onDragUpdate,
        onHorizontalDragEnd: _onDragEnd,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(32),
          child: ColoredBox(
            color: const Color(0xFFF2F2F7),
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 18, 12, 16),
                    child: Row(
                      children: [
                        TextButton(
                          style: TextButton.styleFrom(
                            backgroundColor: Colors.white.withValues(alpha: .7),
                            shape: const StadiumBorder(
                              side: BorderSide(
                                color: Color(0x22000000),
                                width: .6,
                              ),
                            ),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 12,
                            ),
                          ),
                          onPressed: () => Navigator.pop(context),
                          child: const Text(
                            '取消',
                            style: TextStyle(color: _readerAccent),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            widget.title,
                            key: const Key('comic.chapters.header'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              color: Colors.black,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: '章节顺序',
                          visualDensity: VisualDensity.compact,
                          onPressed: () =>
                              setState(() => _showOrder = !_showOrder),
                          icon: const LumeIcon(
                            Icons.sort,
                            slot: 'comic_reader_page.5',
                            size: 20,
                          ),
                        ),
                        DecoratedBox(
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: .7),
                            borderRadius: BorderRadius.circular(30),
                            border: Border.all(color: const Color(0x22000000)),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                tooltip: '上一章',
                                visualDensity: VisualDensity.compact,
                                onPressed: widget.currentIndex > 0
                                    ? () => Navigator.pop(
                                        context,
                                        widget.currentIndex - 1,
                                      )
                                    : null,
                                icon: const LumeIcon(
                                  Icons.chevron_left,
                                  slot: 'comic_reader_page.6',
                                ),
                              ),
                              IconButton(
                                tooltip: '下一章',
                                visualDensity: VisualDensity.compact,
                                onPressed:
                                    widget.currentIndex + 1 <
                                        widget.chapters.length
                                    ? () => Navigator.pop(
                                        context,
                                        widget.currentIndex + 1,
                                      )
                                    : null,
                                icon: LumeIcon(
                                  Icons.chevron_right,
                                  slot: 'comic_reader_page.7',
                                  color:
                                      widget.currentIndex + 1 <
                                          widget.chapters.length
                                      ? _readerAccent
                                      : const Color(0xFFABACB2),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (_showOrder)
                    Align(
                      alignment: Alignment.centerRight,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: ChapterManualOrderDropdown(
                          order: widget.order,
                          onChanged: () {
                            setState(() {});
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              final scroll = _chapterScroll;
                              if (!mounted ||
                                  scroll == null ||
                                  !scroll.hasClients) {
                                return;
                              }
                              // Recompute after the order change, rather than using this build's indexes.
                              final next = widget.order.indexes(
                                widget.chapters,
                              );
                              final position = next.indexOf(
                                widget.currentIndex,
                              );
                              scroll.jumpTo(
                                math
                                    .max(
                                      0.0,
                                      position * rowHeight -
                                          MediaQuery.sizeOf(context).height *
                                              .22,
                                    )
                                    .clamp(
                                      0.0,
                                      scroll.position.maxScrollExtent,
                                    ),
                              );
                            });
                          },
                        ),
                      ),
                    ),
                  Flexible(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(18, 8, 18, 0),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(24),
                        child: Material(
                          color: Colors.white,
                          child: ListView.builder(
                            key: const Key('comic.chapters.list'),
                            controller: _chapterScroll,
                            padding: const EdgeInsets.only(bottom: 20),
                            shrinkWrap: true,
                            itemCount: indexes.length,
                            itemExtentBuilder: (position, _) =>
                                extent(position),
                            itemBuilder: (context, position) {
                              final index = indexes[position];
                              final chapter = widget.chapters[index];
                              final current = index == widget.currentIndex;
                              return Column(
                                children: [
                                  Expanded(
                                    child: ListTile(
                                      key: ValueKey(
                                        'comic.chapter.${chapter.id}',
                                      ),
                                      contentPadding:
                                          const EdgeInsets.symmetric(
                                            horizontal: 18,
                                          ),
                                      minLeadingWidth: 20,
                                      horizontalTitleGap: 12,
                                      leading: const LumeIcon(
                                        Icons.circle,
                                        slot: 'comic_reader_page.8',
                                        size: 18,
                                        color: _readerAccent,
                                      ),
                                      title: Text(
                                        chapter.title,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontSize: 14,
                                          height: 1.3,
                                          fontWeight: FontWeight.w600,
                                          color: Colors.black,
                                        ),
                                      ),
                                      subtitle: current
                                          ? Text(
                                              '${widget.pageCount} 页',
                                              style: const TextStyle(
                                                fontSize: 12,
                                                height: 1.3,
                                                color: Colors.grey,
                                              ),
                                            )
                                          : null,
                                      trailing: current
                                          ? const LumeIcon(
                                              Icons.check,
                                              slot: 'comic_reader_page.9',
                                              size: 20,
                                              color: _readerAccent,
                                            )
                                          : null,
                                      onTap: () =>
                                          Navigator.pop(context, index),
                                    ),
                                  ),
                                  if (position < indexes.length - 1)
                                    const Divider(
                                      height: 1,
                                      thickness: .6,
                                      indent: 50,
                                      endIndent: 18,
                                      color: Color(0xFFDCDCE1),
                                    ),
                                ],
                              );
                            },
                          ),
                        ),
                      ),
                    ),
                  ),
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
      child: Material(
        color: LumeTheme.base,
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              ListTile(
                leading: LumeIcon(
                  Icons.download,
                  slot: 'comic_reader_page.10',
                  color: LumeTheme.textSecondary,
                ),
                title: Text(
                  '保存图片',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: LumeTheme.textPrimary,
                  ),
                ),
                subtitle: Text(
                  '存到本板块的导出目录（不写入系统相册）',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: LumeTypography.descriptionSize,
                    color: LumeTheme.descriptionColor,
                  ),
                ),
                onTap: () => Navigator.of(context).pop(_ImageAction.save),
              ),
              ListTile(
                leading: LumeIcon(
                  Icons.link,
                  slot: 'comic_reader_page.11',
                  color: LumeTheme.textSecondary,
                ),
                title: Text(
                  '复制图片地址',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: LumeTheme.textPrimary,
                  ),
                ),
                subtitle: Text(
                  '粘到任意 App 都能用',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: LumeTypography.descriptionSize,
                    color: LumeTheme.descriptionColor,
                  ),
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
  const _BookmarkSheet({
    required this.bookmarks,
    required this.onRemove,
    required this.notes,
    required this.onEdit,
  });

  final List<ComicBookmark> bookmarks;
  final Map<String, String> notes;
  final Future<String?> Function(ComicBookmark) onEdit;

  /// 删除一条：宿主负责落库。
  final ValueChanged<ComicBookmark> onRemove;

  @override
  State<_BookmarkSheet> createState() => _BookmarkSheetState();
}

class _BookmarkSheetState extends State<_BookmarkSheet> {
  late List<ComicBookmark> _items = List<ComicBookmark>.of(widget.bookmarks);
  late final _notes = Map<String, String>.of(widget.notes);
  bool _editing = false;

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
                    fontSize: LumeTypography.titleSize,
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
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: LumeTypography.bodySize,
                      color: LumeTheme.muted,
                    ),
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
                        key: ValueKey('comic.bookmark.${bookmark.key}'),
                        dense: true,
                        title: Text(
                          bookmark.describe(),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: LumeTypography.titleSize,
                            color: LumeTheme.textPrimary,
                          ),
                        ),
                        subtitle: (_notes[bookmark.key] ?? '').trim().isEmpty
                            ? null
                            : Text(
                                _notes[bookmark.key]!,
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                              ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: '编辑书签备注',
                              icon: const LumeIcon(
                                Icons.edit_note,
                                slot: 'comic_reader_page.12',
                                size: 20,
                              ),
                              onPressed: _editing
                                  ? null
                                  : () async {
                                      setState(() => _editing = true);
                                      try {
                                        final note = await widget.onEdit(
                                          bookmark,
                                        );
                                        if (mounted && note != null) {
                                          setState(
                                            () => _notes[bookmark.key] = note,
                                          );
                                        }
                                      } finally {
                                        if (mounted) {
                                          setState(() => _editing = false);
                                        }
                                      }
                                    },
                            ),
                            IconButton(
                              tooltip: '删除书签',
                              icon: LumeIcon(
                                Icons.delete_outline,
                                slot: 'comic_reader_page.13',
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
                          ],
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
