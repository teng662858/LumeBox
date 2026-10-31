import '../../shared/widgets/source_translation.dart';
import '../../core/source/source_labels.dart';
import '../../core/net/network_cancellation.dart';
import '../../shared/widgets/network_owned_state.dart';
import 'browse_header_motion.dart';

import 'package:lume_box/shared/widgets/lume_icon.dart';

import '../../core/media/media_library.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;

import '../../core/reading/reading.dart';
import '../../core/reading/browse_layout.dart';
import '../../core/js/source_registry.dart';
import '../../core/session/module_ui_scale.dart';
import '../../core/session/section.dart';
import '../../core/net/waf.dart';
import '../../core/source/source.dart';
import '../../core/source/source_subscription_sync.dart';
import '../../core/theme/lume_theme.dart';
import '../../core/theme/floating_modules.dart';
import '../../core/util/lume_log.dart';
import '../../shared/widgets/glass_card.dart';
import '../../shared/widgets/notice_card.dart';
import '../../shared/widgets/state_view.dart';
import '../source/waf_webview_page.dart';
import 'source_home_view.dart';
import 'source_filter_page.dart';
import 'browse_choice_access.dart';
import '../shell/section_preloader.dart';
import '../shell/shell_dock.dart';
import '../source/source_section_page.dart';
import 'poster_card.dart';
import 'search_results_page.dart';
import 'section_toolbar.dart';
import 'cover_viewport.dart';
import 'source_bar.dart';
import 'compact_browse_header.dart';
import '../shell/board_tabs.dart';

/// 但列表更适合展示章节数与简介）。
enum ExploreLayout { grid, list }

/// 探索页选中的条目：条目 + 它来自哪个图源。
///
/// 带上 `sourceId` 是必需的——详情页要按它重新打开同一个图源；否则详情页只能
/// 猜「当前图源」，切源与开页之间会串味。
class ExploreSelection {
  const ExploreSelection({required this.sourceId, required this.item});

  final String sourceId;
  final SourceItem item;
}

/// 探索视图：顶部图源下拉、搜索、右侧筛选抽屉、内容海报网格。
///
/// 与 Phase1 的 `BrowseView` 的关系：那一个是列表式浏览的最小实现，这里补的
/// 是 Phase2 要的探索体验（图源下拉 + 抽屉筛选 + 海报网格 + 翻页加载）。
/// 两者都只依赖统一数据源接口 [DataSource]——不认识沙箱、脚本与数据库。
///
/// 隔离：图源列表与切换目标都只来自本板块的管理器；打开后的数据源再校验一次
/// [DataSource.section]，不符即拒绝渲染。平台边界与 Phase1 一致：没有图源运行
/// 时的平台上只显示骨架提示。
class ExploreView extends StatefulWidget {
  const ExploreView({
    super.key,
    required this.section,
    this.pipeline,
    required this.onOpenItem,
    this.manager,
    this.layout = ExploreLayout.grid,
    this.showSourceManage = true,
    this.showSort = false,
    this.onOpenFacetFilter,
    this.revision = 0,
  });

  final Section section;

  /// 本页面的图片管线（由外壳页持有并负责释放）。
  ///
  /// 可以为空：管线就绪前封面先出主题占位——**不要**为等它挂一个转圈的加载态，
  /// 那会让「切过去先白一下」变成「一直白着」（视频板块的管线要等阅读库打开，
  /// 而库打开是真实 IO，慢的时候肉眼可见）。
  final SectionImagePipeline? pipeline;

  /// 点条目：由板块页决定进哪个详情页。回调里带着条目所属图源。
  final ValueChanged<ExploreSelection> onOpenItem;

  /// 图源管理端口；为空时用正式实现。
  final SourceManager? manager;

  final ExploreLayout layout;

  /// 图源变更代数：宿主导入 / 删除 / 停用图源后 +1，本页**原地**重新解析
  /// （重挂会与旧实例的 dispose 抢同一份板块注册表，真机上会报「图源存储不可用」）。
  final int revision;

  /// 图源条里是否显示「源管理」入口。
  ///
  /// 宿主自己顶栏已经有「源管理」时传 false：同一个入口在一屏里出现两次，
  /// 用户会以为是两个不同的东西（视频板块就是这种情况）。
  final bool showSourceManage;

  /// 是否显示「排序」按钮（用户要求漫画去掉，视频保留）。
  final bool showSort;

  /// 外挂的「筛选」入口（**视频板块专用**：分页跳转式筛选）。
  ///
  /// 宿主返回选中的一级分类与各组标签；返回 null 表示用户取消。
  /// 为空时「筛选」按钮沿用原有行为（右侧分类抽屉）。
  final Future<({String? categoryId, Map<String, String> filters})?> Function(
    BuildContext context,
    DataSource source,
    String? currentCategoryId,
    String originUrl,
  )?
  onOpenFacetFilter;

  @override
  State<ExploreView> createState() => _ExploreViewState();
}

class _ExploreViewState extends State<ExploreView>
    with NetworkOwnedState<ExploreView> {
  /// 布局偏好是应用级单例：本页监听它，别处改了这里也当场重排。
  final BrowseLayoutSettings _layoutSettings = BrowseLayoutSettings.instance;

  late final SourceManager _manager =
      widget.manager ?? LumeSources.manager(widget.section);

  final GlobalKey<ScaffoldState> _scaffold = GlobalKey<ScaffoldState>();
  final TextEditingController _search = TextEditingController();

  List<SourceDescriptor> _sources = const <SourceDescriptor>[];
  SourceDescriptor? _current;
  DataSource? _source;

  SectionImagePipeline? get _imagePipeline {
    final current = _current;
    final pipeline = widget.pipeline;
    if (current == null || pipeline == null) return pipeline;
    return pipeline.forSource(widget.section, current.id, current.network)
      ..bindSource(_source);
  }

  SourceStateKind _state = SourceStateKind.loading;
  String? _title;
  String? _detail;

  String? _categoryId;
  String? _homeBrowseMode;
  List<String> _homeTranslationTexts = const [];
  List<SourceCategory> _categories = const [];
  List<SourceFilterGroup> _filterGroups = const [];
  final SourceFilterCache _inlineFilterCache = SourceFilterCache();
  final GlobalKey _floatingHeaderKey = GlobalKey();
  double _floatingHeaderHeight = 52;
  bool _headerHidden = false;
  bool get _compactHome =>
      widget.section == Section.comic || widget.section == Section.video;
  int _facetRequestSeq = 0;
  double get _contentTop =>
      GlassScaffold.barHeight(context, extra: BoardTabHeader.height) +
      _floatingHeaderHeight +
      FloatingModules.instance.style(FloatingModule.home).y.clamp(0, 80) +
      HomePanelLayout.contentGap;

  void _measureFloatingHeader() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final box = _floatingHeaderKey.currentContext?.findRenderObject();
      if (box is RenderBox &&
          (box.size.height - _floatingHeaderHeight).abs() > .5) {
        setState(() => _floatingHeaderHeight = box.size.height);
      }
    });
  }

  /// 当前图源是否真的实现了 home()（老脚本没有 → 照旧走分类列表）。
  /// 在 [_bootstrap] 里探测一次，换源时重探。
  bool _homeSupported = false;

  /// 已生效的分组筛选（视频板块的分页筛选写进来；其它板块恒为空）。
  Map<String, String> _facetFilters = const <String, String>{};

  final List<SourceItem> _items = <SourceItem>[];
  int _page = 1;
  bool _hasMore = false;
  bool _loadingMore = false;

  /// 首屏（第 1 页）请求是否在飞。
  ///
  /// 这个标记专门用来区分「真的没内容」和「还没取回来」：以前两者都表现为
  /// `_items.isEmpty`，于是进板块的瞬间会先闪一屏「暂无内容 / 换个分类或关键词
  /// 试试」，等网络回来才换成真实列表（用户报的就是这个 2 秒假空态）。
  bool _loadingFirst = false;
  bool _loadMoreFailed = false;
  bool _switching = false;
  bool _searching = false;

  /// 正在为哪一页发请求（0 = 空闲）：挡住「同一页被并发请求两次」。
  ///
  /// 光靠 `_loadingMore` 不够：触底通知一帧能来好几次，而 `setState` 之后还有
  /// await 边界，重复请求会真的发出去（真机表现为同一页拉两遍、列表里出现重复条目）。
  int _pendingPage = 0;

  /// 触底预加载距离：距底部还有这么多像素就开始取下一页（不必真的滑到底）。
  static const double _preloadExtent = 600;

  /// 请求代号：下拉刷新 / 换源 / 换筛选都会 +1；过期结果直接丢弃，
  /// 否则旧请求回来会把新列表覆盖回去。
  int _requestSeq = 0;
  int _bootstrapSeq = 0;

  /// 排序（客户端，只作用于已加载的条目；图源契约里没有排序参数）。
  BrowseSort _sort = BrowseSort.none;

  /// 搜索模式（用户点名的两种）：聚合 / 当前源。
  SearchMode _searchMode = SearchMode.single;
  Set<String>? _searchSourceIds;

  /// 联想候选（非空即展示下拉列表）。
  List<String> _suggestions = const <String>[];

  /// 联想取词节流：输入停顿后再问，避免每敲一个字都发请求。
  Timer? _suggestDebounce;

  /// 联想请求代号：过期结果直接丢弃（用户可能已经改了关键词）。
  int _suggestSeq = 0;

  /// 首页列表失败的原因（分类失败不算）。
  Object? _failure;

  /// 板块的「控件尺寸 / 间距」倍率（设置 → 各模块独立设置 → UI 与控件）。
  ///
  /// 真机反馈「显示模式全都没有生效」：那套值原来只写库、没有任何界面读。
  /// 这里把**间距**接到浏览网格 / 列表上（[ModuleUiScale] 是读取端）。
  double get _spacingScale =>
      ModuleUiScale.instance.spacingScale(widget.section);

  @override
  void initState() {
    super.initState();
    MediaLibrary.instance.addListener(_mediaChanged);
    _layoutSettings.addListener(_onLayoutChanged);
    ModuleUiScale.instance.addListener(_onLayoutChanged);
    ModuleUiScale.instance.ensure(widget.section);
    if (widget.manager == null) {
      SourceSubscriptionSync.revision(widget.section)
          .addListener(_onSubscriptionsChanged);
      if (_manager.runtimeAvailable) {
        unawaited(SourceSubscriptionSync.refresh(widget.section));
      }
    }
    if (_manager.runtimeAvailable) _bootstrap();
  }

  void _onLayoutChanged() {
    if (mounted) setState(() {});
  }

  void _onSubscriptionsChanged() {
    if (mounted) unawaited(_bootstrap());
  }

  @override
  void didUpdateWidget(ExploreView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 宿主说「图源变了」：原地重新解析（不换 Key，见 [revision] 的说明）。
    if (widget.revision != oldWidget.revision) {
      unawaited(_bootstrap());
    }
  }

  void _mediaChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    MediaLibrary.instance.removeListener(_mediaChanged);
    ModuleUiScale.instance.removeListener(_onLayoutChanged);
    _layoutSettings.removeListener(_onLayoutChanged);
    SourceSubscriptionSync.revision(widget.section)
        .removeListener(_onSubscriptionsChanged);
    // 离开页面即作废在飞请求的结果（回来的数据直接丢，不再 setState），
    // 也不让它们继续占着网络队列拖慢下一个页面。
    _requestSeq++;
    _suggestSeq++;
    _suggestDebounce?.cancel();
    networkRequests.cancel('suggestions');
    _search.dispose();
    // 图源管理器是**板块级共享**的（本页只是借用）：这里**不 close**。
    // 关掉它等于关掉整个板块的图源库与运行时——本页在图源变更后会原地刷新、
    // 也可能被宿主重挂，而板块里的书架 / 详情 / 播放页还在用它，关了它们随后
    // 就报「This database has already been closed」（真机复现过两次）。
    // dispose，同一条纪律），与播放器页对图源管理器的口径一致。
    super.dispose();
  }

  // ------------------------------------------------------------------ 数据

  /// 解析当前图源、打开数据源、取分类与首页列表。
  Future<void> _bootstrap() async {
    final bootstrapSeq = ++_bootstrapSeq;
    networkRequests.cancelAll();
    _resetPagination();
    setState(() {
      _state = SourceStateKind.loading;
      _headerHidden = false;
      _title = null;
      _detail = null;
    });
    try {
      final sources = await _manager.list();
      if (!mounted || bootstrapSeq != _bootstrapSeq) return;
      final enabled = sources
          .where((source) => source.enabled)
          .toList(growable: false);
      if (sources.isEmpty) {
        _settle(
          state: SourceStateKind.empty,
          title: '暂无源',
          detail: '导入并启用源后即可探索',
          sources: sources,
        );
        return;
      }
      if (enabled.isEmpty) {
        _settle(
          state: SourceStateKind.disabled,
          detail: '板块内的源都被停用，去源管理里启用',
          sources: sources,
        );
        return;
      }
      final current = await _manager.current();
      if (!mounted || bootstrapSeq != _bootstrapSeq) return;
      if (current == null) {
        _settle(
          state: SourceStateKind.disabled,
          detail: '板块内没有可用的源',
          sources: sources,
        );
        return;
      }
      final source = await _manager.open(current.id);
      if (!mounted || bootstrapSeq != _bootstrapSeq) return;
      if (source == null) {
        _settle(
          state: SourceStateKind.scriptError,
          detail: '当前源打不开（脚本载入失败或源不可用）',
          sources: sources,
          current: current,
        );
        return;
      }
      if (source.section != widget.section) {
        // 双保险：跨板块的数据源一律不渲染。
        LumeLog.warn(
          '[${widget.section.id}] 拒绝渲染跨板块数据源: ${source.id} '
          '归属「${source.section.id}」',
        );
        _settle(
          state: SourceStateKind.disabled,
          title: '源不可用',
          detail: '源板块不符，已拒绝加载',
          sources: sources,
          current: current,
        );
        return;
      }
      _resetPagination();
      setState(() {
        _sources = sources;
        _current = current;
        if (!identical(_source, source)) {
          _categories = const [];
          _homeTranslationTexts = const [];
          _filterGroups = const [];
          _categoryId = null;
          _homeBrowseMode = null;
          _facetFilters = const {};
          _homeSupported = false;
        }
        _source = source;
        _state = SourceStateKind.ready;
        _failure = null;
      });
      // 首页探针**并行**跑：它是一次 JS 求值，串行会把列表加载整整推后一拍
      //（真机表现：进板块先闪两秒「暂无内容」才出数据）。
      unawaited(_probeHomeSupport());
      // 分类同样**并行**：它是第二次 JS 往返（`categories()`），而首屏要的是
      // `list()`。串行等于让用户多等一整次往返（真机反馈：切板块 / 切图源整体偏慢）。
      // 代价：万一刚选中的分类在新分类表里已经没了，这一屏会先按旧分类拉一次
      // （拿不到就落空态 + 【重试】），分类表回来后 _categoryId 被清掉，
      // 点重试即回到「全部」——可恢复，且比每次都多等一拍划算。
      unawaited(_loadCategories());
      await _loadPage();
      if (mounted &&
          bootstrapSeq == _bootstrapSeq &&
          identical(source, _source) &&
          (_categories.isEmpty || _filterGroups.isEmpty)) {
        // Some script hosts populate metadata during their first list request.
        // Recheck once after it completes instead of waiting for a pull refresh.
        await _loadCategories();
      }
    } on NetworkCancelled {
      // A newer source load owns the page.
    } on SourceException catch (error) {
      if (!mounted || bootstrapSeq != _bootstrapSeq) return;
      LumeLog.warn('[${widget.section.id}] 探索页源状态异常: $error');
      _settle(state: stateForError(error), detail: error.message);
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
      if (!mounted || bootstrapSeq != _bootstrapSeq) return;
      setState(() {
        _state = SourceStateKind.scriptError;
        _detail = '$error';
        _source = null;
      });
    }
  }

  /// 错误卡 / 空态卡上的【重试】。
  ///
  /// **不做任何「自动过验证」的动作**（用户口径，连续两轮点名）：验证窗只在用户
  /// 点卡片上的【网页视图】时打开。点【重试】若仍被 WAF 拦下，看到的还是这张
  /// 错误卡——自动蹦出来的验证窗无法预期，等用户以为「切个源它自己就弹」。
  /// 引擎层那条「许可驱动」的自动通道因此在这三个页面里都不再被许可（见
  /// `WafAutoVerify.run` 的说明）。
  Future<void> _retry() => _source == null ? _bootstrap() : _refresh();

  /// 列表尾部「加载失败，点击重试」：同上，也不自动开验证窗。
  Future<void> _retryMore() => _loadPage(more: true);

  /// 探测「本源有没有 home()」：老脚本没有就永远不进首页模式（照旧分类列表）。
  ///
  /// 探测失败（引擎没起来等）一律按「没有」处理——宁可走老路径，也不要让整块
  /// 首页变成一个错误页。
  Future<void> _probeHomeSupport() async {
    final source = _source;
    var supported = false;
    if (source is HomeCapable) {
      try {
        supported = await (source as HomeCapable).supportsHome();
      } on NetworkCancelled {
        return;
      } catch (error) {
        LumeLog.info('[${widget.section.id}] home() 探测失败，按「没有首页」处理：$error');
      }
    }
    if (!mounted || !identical(source, _source)) return;
    setState(() => _homeSupported = supported);
  }

  /// 分类失败不阻塞列表：拿不到分类就当图源没有分类。
  Future<void> _loadCategories() async {
    final source = _source;
    if (source == null) return;
    final seq = ++_facetRequestSeq;
    // Filters can be populated by categories()/homeClassContent(). Fetch them
    // after categories rather than racing the script's initialization.
    await (() async {
      try {
        final categories = await networkRequests.run(
          'categories',
          () => source.categories(),
        );
        if (!mounted ||
            seq != _facetRequestSeq ||
            !identical(source, _source)) {
          return;
        }
        setState(() {
          _categories = categories;
          if (_categoryId != null &&
              !categories.any((item) => item.id == _categoryId)) {
            _categoryId = null;
          }
        });
      } catch (error) {
        if (error is! NetworkCancelled) {
          LumeLog.warn('[${source.id}] 分类获取失败: $error');
        }
      }
    })();
    if (!mounted || seq != _facetRequestSeq || !identical(source, _source)) {
      return;
    }
    await (() async {
      try {
        final groups = await networkRequests.run(
          'filters',
          () => loadSourceFilters(
            source: source,
            cache: _inlineFilterCache,
            force: true,
            categoryId: _categoryId,
            selection: Map.of(_facetFilters),
          ),
        );
        if (!mounted ||
            seq != _facetRequestSeq ||
            !identical(source, _source)) {
          return;
        }
        setState(() {
          _filterGroups = groups
              .where((group) => group.options.isNotEmpty)
              .toList();
          _facetFilters = Map.of(_facetFilters)
            ..removeWhere(
              (key, value) => !groups.any(
                (group) =>
                    group.id == key &&
                    group.options.any((option) => option.id == value),
              ),
            );
          for (final group in _filterGroups.where(_duplicatesCategories)) {
            final selected = _facetFilters.remove(group.id);
            final option = group.options
                .where((o) => o.id == selected)
                .firstOrNull;
            if (_categoryId == null && option != null) {
              _categoryId = _categories
                  .where(
                    (c) => sourceLabel(c.title) == sourceLabel(option.title),
                  )
                  .firstOrNull
                  ?.id;
            }
          }
        });
      } catch (error) {
        if (error is! NetworkCancelled) {
          LumeLog.warn('[${source.id}] 筛选获取失败: $error');
        }
      }
    })();
  }

  bool _duplicatesCategories(SourceFilterGroup group) {
    String label(String text) => sourceLabel(text).trim().toLowerCase();
    const all = {'全部', '不限', '所有', 'all'};
    final categories = _categories
        .map((c) => label(c.title))
        .where((v) => !all.contains(v))
        .toSet();
    final options = group.options
        .map((o) => label(o.title))
        .where((v) => !all.contains(v))
        .toSet();
    // 站点常用 cid:22 做主分类、22 做筛选值，名称集合一致才认作重复。
    return categories.isNotEmpty &&
        categories.length == options.length &&
        categories.containsAll(options);
  }

  Iterable<SourceFilterGroup> get _distinctFilterGroups =>
      _filterGroups.where((group) => !_duplicatesCategories(group));

  void _selectPrimaryCategory(String? id) {
    setState(() {
      _homeBrowseMode = null;
      _categoryId = id;
      _facetFilters = Map.of(_facetFilters)
        ..remove('tid')
        ..remove('class');
      for (final group in _filterGroups.where(_duplicatesCategories)) {
        _facetFilters.remove(group.id);
      }
    });
    unawaited(_refresh());
  }

  Future<void> _openCombinedFilters() async {
    final selected = await showBrowseFilters(
      context: context,
      categories: _categories,
      groups: _distinctFilterGroups.toList(),
      category: _categoryId,
      filters: _facetFilters,
    );
    if (!mounted || selected == null) return;
    setState(() {
      _homeBrowseMode = null;
      _categoryId = selected.category;
      _facetFilters = selected.filters;
    });
    await _refresh();
  }

  Widget _buildInlineFacets() => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      if (_categories.isEmpty && _filterGroups.isNotEmpty)
        Align(
          alignment: Alignment.centerRight,
          child: IconButton(
            tooltip: '展开全部筛选',
            onPressed: _openCombinedFilters,
            icon: const LumeIcon(Icons.tune, slot: 'explore_view.1'),
          ),
        ),
      if (_categories.isNotEmpty)
        BrowseChoiceAccess(
          choices: _categories,
          onOpen: _openCombinedFilters,
          selectedId: _categoryId,
          onSelected: _selectPrimaryCategory,
          child: SizedBox(
            height: 34,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                _facetChip(
                  '全部',
                  _categoryId == null,
                  () => _selectPrimaryCategory(null),
                ),
                for (final category in _categories.where(
                  (c) => c.title != '全部',
                ))
                  _facetChip(
                    sourceLabel(category.title),
                    _categoryId == category.id,
                    () => _selectPrimaryCategory(category.id),
                  ),
              ],
            ),
          ),
        ),
      for (final group in _distinctFilterGroups)
        Row(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: SourceText(
                sourceLabel(group.title),
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: LumeTypography.captionSize,
                  color: LumeTheme.muted,
                ),
              ),
            ),
            Expanded(
              child: BrowseChoiceAccess(
                title: sourceLabel(group.title),
                showAccess: false,
                choices: group.options
                    .map((o) => SourceCategory(id: o.id, title: o.title))
                    .toList(),
                includeAll: !group.options.any((o) => o.title == '全部'),
                selectedId:
                    _facetFilters[group.id] ??
                    group.options.where((o) => o.title == '全部').firstOrNull?.id,
                onSelected: (id) {
                  setState(() {
                    _homeBrowseMode = null;
                    _facetFilters = Map.of(_facetFilters);
                    if (id == null) {
                      _facetFilters.remove(group.id);
                    } else {
                      _facetFilters[group.id] = id;
                    }
                    if (group.id == 'tid') _facetFilters.remove('class');
                  });
                  unawaited(_refresh());
                },
                child: SizedBox(
                  height: 34,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    children: [
                      if (!group.options.any((o) => o.title == '全部'))
                        _facetChip(
                          '全部',
                          !_facetFilters.containsKey(group.id),
                          () {
                            setState(
                              () =>
                                  _facetFilters = Map.of(_facetFilters)
                                    ..remove(group.id),
                            );
                            unawaited(_refresh());
                          },
                        ),
                      for (final option in group.options)
                        _facetChip(
                          sourceLabel(option.title),
                          (_facetFilters[group.id] ??
                                  (group.id == 'tid' &&
                                          group.options.any(
                                            (o) => o.id == _categoryId,
                                          )
                                      ? _categoryId
                                      : (group.options.any(
                                              (o) => o.title == '全部',
                                            )
                                            ? group.options
                                                  .firstWhere(
                                                    (o) => o.title == '全部',
                                                  )
                                                  .id
                                            : null))) ==
                              option.id,
                          () {
                            setState(() {
                              _homeBrowseMode = null;
                              _facetFilters = {
                                ..._facetFilters,
                                group.id: option.id,
                              };
                              if (group.id == 'tid') {
                                _facetFilters.remove('class');
                              }
                            });
                            unawaited(_refresh());
                          },
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
    ],
  );

  Widget _facetChip(String title, bool selected, VoidCallback onTap) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 3),
    child: TextButton(
      style: TextButton.styleFrom(
        backgroundColor: selected
            ? LumeTheme.accent.withValues(alpha: .15)
            : Colors.transparent,
        foregroundColor: selected ? LumeTheme.accent : LumeTheme.textPrimary,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        minimumSize: const Size(32, 28),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape: const StadiumBorder(),
      ),
      onPressed: onTap,
      child: SourceText(
        title,
        style: TextStyle(
          fontSize: LumeTypography.bodySize,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w600,
        ),
      ),
    ),
  );

  /// 重置分页：页码回 1、清空列表与「没有更多」标记。
  ///
  /// 换图源、换分类 / 关键词、下拉刷新都走这里——**每一个图源单独维护自己的
  /// 分页状态**（用户点名）：换源时必须清干净，否则会带着旧源的页码与
  /// hasMore 继续翻页。
  void _resetPagination() {
    _page = 1;
    _hasMore = false;
    _loadingMore = false;
    _loadingFirst = false;
    _loadMoreFailed = false;
    _pendingPage = 0;
    _items.clear();
    _requestSeq++;
  }

  /// 取一页列表。[more] 为真时追加，否则替换。
  Future<void> _loadPage({bool more = false}) async {
    final source = _source;
    if (source == null) return;
    final page = more ? _page + 1 : 1;
    if (more) {
      // 触底通知来得密集，三重条件都要满足才发请求：还有下一页、没有在飞的、
      // 且这一页不是正在飞的那一页。
      if (_loadingMore || !_hasMore || _pendingPage == page) return;
      setState(() {
        _loadingMore = true;
        _loadMoreFailed = false;
      });
    } else {
      if (_pendingPage == 1) return; // 首页已经在飞
      _resetPagination();
      setState(() {
        _failure = null;
        // 请求在飞期间只显示加载态，绝不落到空态（见 [_loadingFirst] 注释）。
        _loadingFirst = true;
        _items.clear();
      });
      // 预热命中：直接吃切页签时提前取好的第一页（省掉一次网络往返）。
      final warmSeq = _requestSeq;
      _pendingPage = page;
      if (_categoryId == null && _facetFilters.isEmpty) {
        await SectionPreloader.waitForWarm(
          widget.section,
          sourceId: source.id,
          home: false,
        );
      }
      if (!mounted || warmSeq != _requestSeq) return;
      final warm = _facetFilters.isNotEmpty
          ? null
          : SectionPreloader.takeWarmPage(
              widget.section,
              sourceId: source.id,
              categoryId: _categoryId,
            );
      if (warm != null) {
        setState(() {
          _page = 1;
          _hasMore = warm.hasMore;
          _loadingMore = false;
          _loadingFirst = false;
          _items.addAll(warm.items);
        });
        _pendingPage = 0;
        _preloadCovers(warm.items);
        return;
      }
    }
    _pendingPage = page;
    final seq = _requestSeq;
    try {
      final result = await networkRequests.run(
        'browse',
        () => source.list(
          categoryId: _categoryId,
          page: page,
          filters: _facetFilters.isEmpty ? null : _facetFilters,
        ),
        timeout: const Duration(seconds: 40),
        timeoutError: () => const SourceException(
          SourceErrorKind.network,
          '列表请求超时，请重试或检查网页验证会话',
        ),
      );
      if (!mounted || seq != _requestSeq) return;
      // 翻页拿到「一条新条目都没有」的一页，通常是两种事：真的到底了，或者
      // 站点的分页参数写法不对（第 2 页又返回了第 1 页）。前者照常收尾；
      // 后者如果就这么停下，用户看到的就是「下拉到底再也不加载」——真机反馈过。
      // 这里只做一件事：把重复页记进日志（下一轮按日志收敛脚本的分页写法），
      // 并据此收尾，不再空转。
      final fresh = more ? _countFresh(result.items) : result.items.length;
      final repeated = more && result.items.isNotEmpty && fresh == 0;
      if (repeated) {
        LumeLog.warn(
          '[${source.id}] 第 $page 页没有新条目（疑似分页写法不对：'
          '又返回了上一页），先按到底处理',
        );
      }
      setState(() {
        _page = page;
        _hasMore = repeated ? false : result.hasMore;
        _loadingMore = false;
        _loadingFirst = false;
        if (more) {
          _items.addAll(result.items);
        } else {
          _items
            ..clear()
            ..addAll(result.items);
        }
      });
      _preloadCovers(result.items, more: more);
    } on NetworkCancelled {
      // Replaced requests belong to the previous source/filter/page lifetime.
      return;
    } catch (error) {
      if (error is! SourceException) {
        LumeLog.error(error, StackTrace.current);
      } else {
        LumeLog.warn('[${source.id}] 列表获取失败: $error');
      }
      if (!mounted || seq != _requestSeq) return;
      setState(() {
        _loadingMore = false;
        if (more) {
          // 失败**不**清 hasMore：清掉就再也拉不动了（「提前标记没有更多」的那种）。
          _loadMoreFailed = true;
        } else {
          _loadingFirst = false;
          _failure = error;
        }
      });
    } finally {
      if (seq == _requestSeq && _pendingPage == page) _pendingPage = 0;
    }
  }

  /// 下拉刷新：重置分页 + 重取分类 + 重取第 1 页（用户点名三件事都要做）。
  Future<void> _refresh() async {
    final refreshSeq = ++_bootstrapSeq;
    networkRequests.cancelAll();
    setState(() {
      _resetPagination();
      _loadingFirst = true;
      _failure = null;
    });
    // 预热缓存作废：用户明确要求要新的。
    SectionPreloader.discard(widget.section);
    await _loadCategories();
    if (!mounted || refreshSeq != _bootstrapSeq) return;
    await _loadPage();
  }

  /// 这一页里有几条是**新**的（按 id 与已有列表比）。
  int _countFresh(List<SourceItem> items) {
    final seen = <String>{for (final item in _items) item.id};
    var fresh = 0;
    for (final item in items) {
      if (seen.add(item.id)) fresh++;
    }
    return fresh;
  }

  /// 网格与列表分别使用 300 / 200 的解码档，与实际卡片共用缓存键。
  int get _coverWidth => switch (_mode) {
    BrowseLayoutMode.list => 200,
    BrowseLayoutMode.list2 => 200,
    _ => 300,
  };

  /// 预取这一页的封面：列表还在滑的时候图就已经在路上了。
  ///
  /// 数据返回即预取开头一小段；布局完成后由 CoverViewport 接管滚动窗口，
  /// 可见封面优先，屏幕附近的封面低优先级预取。
  void _preloadCovers(List<SourceItem> items, {bool more = false}) {
    final pipeline = _imagePipeline;
    if (pipeline == null) return;
    // 翻页追加时，用户正停在列表末尾：接下来会看到的是新这批的开头几条。
    final limit = more ? 8 : 12;
    final urls = <String>[];
    for (final item in items) {
      if (urls.length >= limit) break;
      final cover = (item.cover ?? '').trim();
      if (cover.isNotEmpty) {
        pipeline.configureImageHeaders({cover: item.coverHeaders});
        urls.add(cover);
      }
    }
    pipeline.preload(urls, targetWidth: _coverWidth);
  }

  void _settle({
    required SourceStateKind state,
    String? title,
    String? detail,
    List<SourceDescriptor>? sources,
    SourceDescriptor? current,
  }) {
    if (!mounted) return;
    setState(() {
      _state = state;
      _title = title;
      _detail = detail;
      _sources = sources ?? _sources;
      _current = current;
      _source = null;
      _items.clear();
    });
  }

  // ------------------------------------------------------------------ 交互

  Future<void> _selectSource(String sourceId) async {
    if (sourceId == _current?.id || _switching) return;
    SectionPreloader.discard(widget.section);
    setState(() => _switching = true);
    final selected = await _manager.select(sourceId);
    if (!mounted) return;
    setState(() => _switching = false);
    if (selected == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('该源不可用')));
      return;
    }
    await _bootstrap();
  }

  /// 可读提示（不冒泡异常）。
  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(duration: const Duration(seconds: 2), content: Text(message)),
    );
  }

  /// 打开内置网页视图过 WAF 校验；关闭时把会话 Cookie 存进**当前图源**，
  /// 然后自动重拉一次数据（用户口径第 3、4 条）。
  ///
  /// 点这个按钮**一定会有反应**（真机反馈过三轮「点了没反应」）：地址走统一兜底链
  /// （报错文案 → 该源最近请求过的地址 → 订阅地址 → 源 id 域名），四层全落空时
  /// 弹地址输入框；开窗失败也会弹窗说明。三条出口都在 [runWafWebViewFlow] 里。
  Future<void> _openWebViewForWaf() async {
    final source = _source;
    if (source == null) return;
    final failure = _failure;
    final reason = failure is SourceException ? failure.message : null;
    final outcome = await runWafWebViewFlow(
      context: context,
      section: widget.section,
      sourceId: source.id,
      sourceName: source.name,
      failureMessage: reason,
      originUrl: _current?.originUrl ?? '',
    );
    if (!mounted) return;
    switch (outcome) {
      case WafWebViewOutcome.notOpened:
        // 用户取消了地址输入框（或开窗失败，异常已单独弹窗说明）：不再追着提示。
        return;
      case WafWebViewOutcome.emptySession:
        _toast('没取到会话：等验证通过、站点页面真正显示出来后再点 ✕ 关闭');
        return;
      case WafWebViewOutcome.collected:
        _toast(
          '已取回会话（${WafSessions.countFor(widget.section, source.id)} 项），正在重新拉取',
        );
        await _refresh();
    }
  }

  /// 点「筛选」：视频板块走外挂的分页筛选（一级分类 → 筛选子页），
  /// 其余板块沿用原来的分类抽屉。

  /// 点工具栏「搜索」：先选范围（聚合 / 当前源），再开搜索框。
  Future<void> _openSearch() async {
    final library = ReadingLibrary.find(widget.section);
    List<SourceDescriptor> sources;
    try {
      sources = await _manager.list();
    } catch (error) {
      if (mounted) _toast('读取搜索站点失败：$error');
      return;
    }
    if (!mounted) return;
    final selection = await showSearchModeMenu(
      context,
      current: _searchMode,
      sources: sources,
      sourceIds: library == null
          ? _searchSourceIds
          : SearchSourceSelectionStore(library).load(),
    );
    if (selection == null || !mounted) return;
    if (library != null) {
      SearchSourceSelectionStore(library).save(selection.sourceIds);
    }
    setState(() {
      _searchMode = selection.mode;
      _searchSourceIds = selection.sourceIds;
      _searching = true;
      _headerHidden = false;
      _suggestions = _historyStore?.load() ?? const <String>[];
    });
  }

  /// 输入变化：拉联想词（优先图源的 suggest，没有就用本地搜索历史）。
  ///
  /// 联想只是输入辅助：它不改搜索请求本身（见 [_submitSearch]）。
  void _onSearchChanged(String value) {
    _suggestDebounce?.cancel();
    networkRequests.cancel('suggestions');
    final keyword = value.trim();
    _suggestSeq++;
    if (keyword.isEmpty) {
      setState(() => _suggestions = _historyStore?.load() ?? const <String>[]);
      return;
    }
    setState(
      () => _suggestions = SearchSuggestions(
        source: _source,
        history: _historyStore?.load() ?? const <String>[],
        candidates: _items.map((item) => item.title).toList(),
      ).localForKeyword(keyword),
    );
    if (_source is! SuggestCapable) return;
    _suggestDebounce = Timer(
      const Duration(milliseconds: 300),
      () => unawaited(_loadSuggestions(keyword)),
    );
  }

  Future<void> _loadSuggestions(String keyword) async {
    final seq = ++_suggestSeq;
    List<String> suggestions;
    try {
      suggestions = await networkRequests.run(
        'suggestions',
        () => SearchSuggestions(
          source: _source,
          history: _historyStore?.load() ?? const <String>[],
          candidates: _items.map((item) => item.title).toList(),
        ).forKeyword(keyword),
      );
    } on NetworkCancelled {
      return;
    }
    if (!mounted || seq != _suggestSeq) return;
    // 关键词可能已经被清掉 / 改掉：只在还匹配时上屏。
    if (_search.text.trim() != keyword) return;
    setState(() => _suggestions = suggestions);
  }

  /// 关掉联想弹窗（点页面空白 / 按返回时调用）。
  void _closeSuggestions() {
    _suggestDebounce?.cancel();
    networkRequests.cancel('suggestions');
    _suggestSeq++;
    setState(() => _suggestions = const <String>[]);
  }

  /// 搜索历史（本板块自己的库；库没打开时为 null，联想退化为纯服务端）。
  SearchHistoryStore? get _historyStore {
    final library = ReadingLibrary.find(widget.section);
    return library == null ? null : SearchHistoryStore(widget.section, library);
  }

  /// 执行搜索：**离开首页推荐网格，跳独立结果页**（用户口径）。
  ///
  /// 以前是「就地替换首页网格」，用户看到的像是首页没动；现在搜索自成一段流程
  /// （[SearchResultsPage] 负责加载 / 空态 / 失败态），首页推荐原样留在身后。
  void _submitSearch(String value) {
    final keyword = value.trim();
    _suggestDebounce?.cancel();
    networkRequests.cancel('suggestions');
    _suggestSeq++;
    if (keyword.isEmpty) return;
    _historyStore?.remember(keyword);
    setState(() {
      _suggestions = const <String>[];
      _searching = false; // 收起搜索行，回首页网格的样子
    });
    _search.clear();
    unawaited(
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => SearchResultsPage(
            section: widget.section,
            keyword: keyword,
            mode: _searchMode,
            sourceIds: _searchSourceIds,
            onSourcesChanged: (ids) {
              if (mounted) setState(() => _searchSourceIds = ids);
            },
            sourceId: _current?.id,
            manager: widget.manager,
            pipeline: _imagePipeline,
            onOpenItem: (selection) => _openFromSource(selection),
          ),
        ),
      ),
    );
  }

  /// 点联想条目：直接填入并搜索（用户点名）。
  void _applySuggestion(String value) {
    _search.text = value;
    _search.selection = TextSelection.collapsed(offset: value.length);
    _submitSearch(value);
  }

  Future<void> _manageSources() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            SourceSectionPage(section: widget.section, manager: widget.manager),
      ),
    );
    if (!mounted) return;
    // 源设置可能更改镜像/自定义域名；同 id 的预热首页已不再可信。
    SectionPreloader.discard(widget.section);
    // 返回后重新解析：可能导入了新图源、改变了启用状态或当前图源。
    await _bootstrap();
  }

  // ------------------------------------------------------------------ 构建

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: FloatingModules.instance,
      builder: (context, _) => Scaffold(
        // **本页不随键盘收缩**（真机反馈：唤起键盘后顶部搜索框被顶出屏幕，
        // 漫画 / 视频三块都复现）。这里的布局契约是：
        //   顶栏占位 + 搜索行是**固定头部**，键盘只能影响下面的内容列表。
        // 交给 Scaffold 收缩的话，头部会跟着被挤压/位移；因此关掉自动收缩，
        // 让键盘的高度由列表自己用底部内边距让出来（见 _keyboardInset）。
        resizeToAvoidBottomInset: false,
        backgroundColor: Colors.transparent,
        key: _scaffold,
        drawerScrimColor: Colors.black54,
        // 返回键：**联想弹窗开着时先关它**（用户点名「返回关闭联想弹窗」），
        // 而不是直接退出搜索 / 退出页面。
        body: PopScope(
          canPop: _suggestions.isEmpty,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) _closeSuggestions();
          },
          child: Stack(
            children: [
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _closeSuggestions,
                  child: NotificationListener<ScrollNotification>(
                    onNotification: (notification) {
                      final hidden = BrowseHeaderScroll.hiddenAfter(
                        notification,
                        _headerHidden,
                      );
                      if (hidden != _headerHidden) {
                        setState(() => _headerHidden = hidden);
                      }
                      return false;
                    },
                    child: _buildBody(),
                  ),
                ),
              ),
              Positioned(
                top:
                    GlassScaffold.barHeight(
                      context,
                      extra: BoardTabHeader.height,
                    ) +
                    FloatingModules.instance.style(FloatingModule.home).y,
                left:
                    HomePanelLayout.sidePadding +
                    FloatingModules.instance.style(FloatingModule.home).x,
                right:
                    HomePanelLayout.sidePadding -
                    FloatingModules.instance.style(FloatingModule.home).x,
                child: BrowseHeaderMotion(
                  hidden: _headerHidden,
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      _measureFloatingHeader();
                      return ConstrainedBox(
                        constraints: BoxConstraints(
                          maxHeight: MediaQuery.sizeOf(context).height * .5,
                        ),
                        child: GlassPanel(
                          module: null,
                          key: _floatingHeaderKey,
                          radius: HomePanelLayout.radius,
                          color: LumeTheme.glass.withValues(
                            alpha: FloatingModules.instance
                                .style(FloatingModule.home)
                                .opacity,
                          ),
                          blur: FloatingModules.instance
                              .style(FloatingModule.home)
                              .blur,
                          padding: HomePanelLayout.padding,
                          child: SingleChildScrollView(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (!_compactHome)
                                  ?HomeHeaderScope.headerOf(context),
                                _searching
                                    ? _buildSearchField()
                                    : _buildHeader(),
                                if (!_searching) _buildInlineFacets(),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
              if (_compactHome)
                BrowseSearchButton(
                  onPressed: _openSearch,
                  visible: !_searching,
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 顶部工具栏：源选择与记录快捷入口。
  /// 源选择下拉框 → 排序 → 布局 → 搜索 → 筛选。
  ///
  /// 三个板块共用同一个 [SectionToolbar]：换板块也找得到那个按钮。
  Widget _buildHeader() {
    final showSourceManageFlag = widget.showSourceManage;
    if (_compactHome) {
      return CompactBrowseHeader(
        source: ReadingSourceBar(
          sources: _sources.where((s) => s.enabled).toList(),
          currentId: _current?.id,
          onSelect: _selectSource,
          onManage: _manageSources,
          showManage: false,
          compact: true,
          busy: _switching,
          floating: true,
          section: widget.section,
          manager: _manager,
          onSourcesChanged: _bootstrap,
        ),
        actions: [
          ...HomeHeaderScope.actionsOf(context),
          SourceTranslationAction(
            texts: [
              ..._categories.map((category) => category.title),
              for (final group in _filterGroups) ...[
                group.title,
                ...group.options.map((option) => option.title),
              ],
              ..._homeTranslationTexts,
              ..._items.map((item) => item.title),
            ],
          ),
        ],
        mode: _mode,
        onLayoutChanged: (mode) => unawaited(
          BrowseLayoutSettings.instance.setMode(widget.section, mode),
        ),
      );
    }
    return SectionToolbar(
      section: widget.section,
      manager: _manager,
      onSourcesChanged: _bootstrap,
      floating: true,
      sources: [..._sources.where((source) => source.enabled)],
      currentId: _current?.id,
      busy: _switching,
      onSelect: _selectSource,
      onManage: showSourceManageFlag ? _manageSources : null,
      sort: _sort,
      onSortChanged: (sort) => setState(() => _sort = sort),
      layoutMode: _mode,
      onLayoutChanged: (mode) => unawaited(
        BrowseLayoutSettings.instance.setMode(widget.section, mode),
      ),
      showSort: widget.showSort,
      onSearch: _openSearch,
      onFilter: null,
      filterActive: _categoryId != null || _facetFilters.isNotEmpty,
    );
  }

  /// 搜索行：输入框（带当前模式标签）+ 联想下拉列表。
  ///
  /// 联想是**输入辅助**：只填关键词，搜索请求本身仍走 [_submitSearch] 那两条路径
  /// （聚合 / 当前源），逻辑不变。
  Widget _buildSearchField() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: GlassCard(
                radius: 14,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: TextField(
                  controller: _search,
                  autofocus: true,
                  textInputAction: TextInputAction.search,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: LumeTheme.textPrimary,
                  ),
                  decoration: InputDecoration(
                    border: InputBorder.none,
                    hintText: _searchMode == SearchMode.aggregate
                        ? (_searchSourceIds == null
                              ? '搜索全部已启用源'
                              : '搜索已选 ${_searchSourceIds!.length} 个站点')
                        : '在当前源内搜索',
                    hintStyle: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: LumeTheme.muted,
                    ),
                    icon: LumeIcon(
                      Icons.search,
                      slot: 'explore_view.2',
                      color: LumeTheme.muted,
                    ),
                    suffixIcon: TextButton(
                      onPressed: _openSearch,
                      child: Text(
                        _searchMode.label,
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: LumeTypography.descriptionSize,
                        ),
                      ),
                    ),
                  ),
                  onChanged: _onSearchChanged,
                  onSubmitted: _submitSearch,
                ),
              ),
            ),
            const SizedBox(width: 8),
            _RoundAction(
              icon: Icons.close,
              tooltip: '退出搜索',
              onTap: () {
                _search.clear();
                _suggestDebounce?.cancel();
                networkRequests.cancel('suggestions');
                _suggestSeq++;
                setState(() {
                  _searching = false;
                  _suggestions = const <String>[];
                });
              },
            ),
          ],
        ),
        // 联想下拉：有候选才出现（空输入 / 无候选都不占位）。
        if (_suggestions.isNotEmpty) _buildSuggestions(),
      ],
    );
  }

  /// 联想候选列表（项目现有卡片样式，最多 10 条）。
  Widget _buildSuggestions() {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: GlassCard(
        radius: 14,
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (_search.text.trim().isEmpty)
              ListTile(
                dense: true,
                title: const Text('搜索历史'),
                trailing: TextButton(
                  onPressed: () {
                    _historyStore?.clear();
                    setState(() => _suggestions = const <String>[]);
                  },
                  child: const Text('清空全部'),
                ),
              ),
            for (final suggestion in _suggestions)
              InkWell(
                onTap: () => _applySuggestion(suggestion),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  child: Row(
                    children: <Widget>[
                      LumeIcon(
                        Icons.search,
                        slot: 'explore_view.3',
                        size: 16,
                        color: LumeTheme.muted,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text.rich(
                          _highlightSuggestion(suggestion),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: LumeTypography.titleSize,
                            color: LumeTheme.textPrimary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  TextSpan _highlightSuggestion(String title) {
    final query = _search.text.trim().toLowerCase();
    if (query.isEmpty) return TextSpan(text: title);
    final spans = <TextSpan>[];
    var offset = 0;
    final lower = title.toLowerCase();
    while (offset < title.length) {
      final start = lower.indexOf(query, offset);
      if (start < 0) {
        spans.add(TextSpan(text: title.substring(offset)));
        break;
      }
      if (start > offset) {
        spans.add(TextSpan(text: title.substring(offset, start)));
      }
      spans.add(
        TextSpan(
          text: title.substring(start, start + query.length),
          style: TextStyle(
            color: Theme.of(context).colorScheme.primary,
            fontWeight: FontWeight.bold,
          ),
        ),
      );
      offset = start + query.length;
    }
    return TextSpan(children: spans);
  }

  /// 键盘占住的高度：列表拿它做底部内边距。
  ///
  /// 本页关掉了 Scaffold 的自动收缩（见 build），所以键盘不会改变页面布局；
  /// 代价是列表底部会被键盘盖住，这里补上这段内边距，让最后几条仍能滚出来。
  double _keyboardInset(BuildContext context) =>
      MediaQuery.viewInsetsOf(context).bottom;

  /// 当前生效的布局档位。
  ///
  /// 用户选过的优先（按板块分别记住）；没选过时回落到本页的默认档
  /// （四个板块首页统一默认三列网格）。
  BrowseLayoutMode get _mode =>
      BrowseLayoutSettings.instance.modeFor(widget.section) ??
      BrowseLayoutMode.grid3;

  /// 排序后的条目（排序是客户端行为，只作用于已加载的这批）。
  List<SourceItem> get _sortedItems => _sort.apply(
    _items
        .where(
          (item) => MediaLibrary.instance.visibleAtOrigin(
            widget.section,
            _current?.id ?? '',
            item.id,
          ),
        )
        .toList(),
  );

  /// 是否处于「首页模式」（用户口径任务 3）：图源提供 home()，且当前没有
  /// 分类 / 分组筛选 / 关键词 / 搜索结果在生效。旧源没有 home() → 照旧分类列表。
  bool get _isHomeMode {
    if (!_homeSupported) return false;
    final source = _source;
    if (source is! HomeCapable) return false;
    if (_categoryId != null || _facetFilters.isNotEmpty) return false;
    return true;
  }

  Widget _buildBody() {
    if (!_manager.runtimeAvailable) {
      return Padding(
        padding: EdgeInsets.only(top: _contentTop),
        child: const SkeletonNotice(),
      );
    }
    // 首页模式：横滑板块（或旧兼容的普通网格），由 SourceHomeView 自理加载与空态。
    if (_isHomeMode) {
      return SourceHomeView(
        browseMode: _homeBrowseMode,
        source: _source!,
        topInset: _contentTop,
        bottomInset: ShellDockScope.bottomInset(context),
        onRefreshMetadata: _loadCategories,
        onTranslationTexts: (texts) {
          if (mounted) setState(() => _homeTranslationTexts = texts);
        },
        onHomeLoaded: () {
          if (_categories.isEmpty || _filterGroups.isEmpty) {
            unawaited(_loadCategories());
          }
        },
        pipeline: _imagePipeline,
        originUrl: _current?.originUrl ?? '',
        onOpenItem: _open,
        onOpenMore: (title, moreUrl) => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => SourceHomeMorePage(
              source: _source!,
              title: title,
              moreUrl: moreUrl,
              pipeline: _imagePipeline,
              onOpenItem: _open,
            ),
          ),
        ),
      );
    }

    if (_state != SourceStateKind.ready) {
      return SourceStateView(
        state: _state,
        title: _title,
        detail: _detail,
        onRetry: _state == SourceStateKind.loading ? null : _retry,
        action: _state == SourceStateKind.loading
            ? null
            : FilledButton(onPressed: _manageSources, child: const Text('源管理')),
      );
    }
    final failure = _failure;
    if (failure != null) {
      // 能定性的失败（Venera 那套 DOM 源等）在引擎原文后追加一句说明，
      // 原文照旧保留——用户看不懂「querySelectorAll of null」是什么意思。
      final detail = SourceRegistry.describeRuntimeFailure(
        failure is SourceException ? failure.message : '$failure',
      );
      // 被 Cloudflare / WAF 拦下时多给一个出口：在 App 内置网页视图里过真人校验
      // （用户要求；参考 AP 漫画那套）。普通失败照旧只有「重试」。
      final kind = wafKindOf(detail);
      final hasSession =
          _source != null &&
          WafSessions.countFor(widget.section, _source!.id) > 0;
      // 出口与提示**同时出现或同时不出现**（真机反馈：卡片写着「可点【网页视图】
      // 过校验」，按钮却不在——首页超时那类失败原本两边都不给，用户没处自救）。
      final offerWebView = shouldOfferWebView(detail);
      // 站址解析结果直接写在卡片上（用户口径：报错信息里要能看出拿到了源站地址）。
      final hint = offerWebView
          ? webViewTargetHint(
              failureMessage: detail,
              sourceId: _source?.id,
              originUrl: _current?.originUrl ?? '',
            )
          : null;
      return SourceStateView(
        state: stateForError(failure),
        // 需要外部桥接的那类（reCAPTCHA v3 等）直接把出路写在正文里：
        // 它**没有**可导出复用的会话，网页视图对它无效（用户口径 2.2）。
        detail: kind == WafFailureKind.bridge
            ? '$detail\n\n$wafBridgeHint'
            : (hint == null ? detail : '$detail\n\n$hint'),
        onRetry: _retry,
        action: offerWebView && _source != null
            ? OutlinedButton.icon(
                onPressed: _openWebViewForWaf,
                icon: const LumeIcon(
                  Icons.public,
                  slot: 'explore_view.4',
                  size: 18,
                ),
                label: Text(hasSession ? '网页视图（已存会话）' : '网页视图'),
              )
            : null,
      );
    }
    if (_items.isEmpty && _loadingFirst) {
      return const SourceStateView(state: SourceStateKind.loading);
    }
    if (_items.isEmpty && !_loadingMore) {
      if (_current?.isKazumi == true) {
        return SourceStateView(
          state: SourceStateKind.empty,
          title: '搜索这站的动漫',
          detail: '此 Kazumi 规则未提供首页分类，也未提取到首页封面。点击下方按钮，按作品名在当前站点搜索。',
          onRetry: _retry,
          action: FilledButton.icon(
            onPressed: () => setState(() {
              _searchMode = SearchMode.single;
              _searching = true;
              _headerHidden = false;
              _suggestions = _historyStore?.load() ?? const <String>[];
            }),
            icon: const Icon(Icons.search_rounded),
            label: const Text('搜索动漫'),
          ),
        );
      }
      return SourceStateView(
        state: SourceStateKind.empty,
        detail: '换个分类或关键词试试',
        onRetry: _retry,
      );
    }
    if (_mode == BrowseLayoutMode.list) return _buildList();
    return _buildGrid(crossAxisCount: _mode.columns);
  }

  Widget _buildGrid({int crossAxisCount = 3}) {
    final items = _sortedItems;
    final compactGrid = crossAxisCount == 3;
    final sidePadding = compactGrid
        ? ThreeColumnPosterLayout.sidePadding
        : TwoColumnSourceLayout.sidePadding;
    final spacing = compactGrid
        ? ThreeColumnPosterLayout.spacing
        : TwoColumnSourceLayout.spacing;
    return LayoutBuilder(
      builder: (context, constraints) => RefreshIndicator(
        onRefresh: _refresh,
        child: NotificationListener<ScrollNotification>(
          onNotification: (notification) {
            if (notification.metrics.extentAfter < _preloadExtent) {
              _loadPage(more: true);
            }
            return false;
          },
          child: CoverViewport(
            child: GridView.builder(
              scrollCacheExtent: const ScrollCacheExtent.viewport(1),
              // 内容不足一屏时也要能下拉刷新。
              physics: const AlwaysScrollableScrollPhysics(),
              padding: EdgeInsets.fromLTRB(
                sidePadding,
                _contentTop,
                sidePadding,
                // 底部内边距 = 常规间距 + 键盘 + **悬浮 Dock 的占用**：
                // 只有滚到最末才真正让出 Dock 那一段，没滚到底时内容尽量往下铺
                //（用户口径：不要固定预留一大块空白）。
                16 +
                    _keyboardInset(context) +
                    ShellDockScope.bottomInset(context),
              ),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: crossAxisCount,
                mainAxisSpacing: compactGrid
                    ? ThreeColumnPosterLayout.rowSpacing
                    : TwoColumnSourceLayout.rowSpacing,
                crossAxisSpacing: spacing,
                // 双列行高同时适配实际列宽和系统字号。
                mainAxisExtent: _mode == BrowseLayoutMode.list2
                    ? TwoColumnSourceLayout.itemExtent(
                        context,
                        TwoColumnSourceLayout.cellWidth(constraints.maxWidth),
                      )
                    : null,
                // mainAxisExtent 非空时会被忽略；给默认 1。
                childAspectRatio: _mode == BrowseLayoutMode.list2
                    ? 1
                    : _mode.tileAspectRatio,
              ),
              itemCount: items.length + 1,
              itemBuilder: (context, index) {
                if (index == items.length) return _buildFooter();
                final item = items[index];
                return PosterTile(
                  compactGrid: compactGrid,
                  horizontal: _mode == BrowseLayoutMode.list2,
                  item: item,
                  pipeline: _imagePipeline,
                  onTap: () => _open(item),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildList() {
    final items = _sortedItems;
    return RefreshIndicator(
      onRefresh: _refresh,
      child: NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          if (notification.metrics.extentAfter < _preloadExtent) {
            _loadPage(more: true);
          }
          return false;
        },
        child: CoverViewport(
          child: ListView.separated(
            scrollCacheExtent: const ScrollCacheExtent.viewport(1),
            physics: const AlwaysScrollableScrollPhysics(),
            padding: EdgeInsets.fromLTRB(
              16 * _spacingScale,
              _contentTop,
              16 * _spacingScale,
              // 底部内边距 = 常规间距 + 键盘 + **悬浮 Dock 的占用**：
              // 只有滚到最末才真正让出 Dock 那一段，没滚到底时内容尽量往下铺
              //（用户口径：不要固定预留一大块空白）。
              16 +
                  _keyboardInset(context) +
                  ShellDockScope.bottomInset(context),
            ),
            itemCount: items.length + 1,
            separatorBuilder: (_, _) => SizedBox(height: 10 * _spacingScale),
            itemBuilder: (context, index) {
              if (index == items.length) return _buildFooter();
              final item = items[index];
              return CompactSourceItemTile(
                item: item,
                pipeline: _imagePipeline,
                onTap: () => _open(item),
                columns: 1,
                coverWidth: 80,
                coverHeight: 100,
                flat: true,
                showMenu: true,
              );
            },
          ),
        ),
      ),
    );
  }

  /// 打开搜索结果里的一条：条目属于哪個源由结果页给出（聚合搜索跨源）。
  ///
  /// 与 [_open] 的区别只在图源来源：这里不重开「当前源」，直接用结果页给的 id。
  void _openFromSource(ExploreSelection selection) {
    widget.onOpenItem(selection);
  }

  /// 打开一个条目：把「图源 + 条目」一起交给板块页。
  void _open(SourceItem item) {
    final current = _current;
    if (current == null) return;
    widget.onOpenItem(ExploreSelection(sourceId: current.id, item: item));
  }

  /// 列表尾部：加载中 / 加载失败可重试 / 到底了。
  Widget _buildFooter() {
    if (_loadingMore) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 18),
        child: Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2.2),
          ),
        ),
      );
    }
    if (_loadMoreFailed) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Center(
          child: TextButton(
            onPressed: _retryMore,
            child: const Text('加载失败，点击重试'),
          ),
        ),
      );
    }
    if (!_hasMore && _items.isNotEmpty) {
      return Padding(
        padding: EdgeInsets.symmetric(vertical: 14),
        child: Center(
          child: Text(
            '没有更多了',
            style: TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: LumeTypography.descriptionSize,
              color: LumeTheme.descriptionColor,
            ),
          ),
        ),
      );
    }
    return const SizedBox(height: 8);
  }
}

/// 圆形动作按钮：搜索 / 筛选这类轻量入口，不用图标按钮的默认内边距。
class _RoundAction extends StatelessWidget {
  const _RoundAction({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: LumeTheme.fill,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(11),
            child: LumeIcon(
              icon,
              slot: 'explore_view.5',
              variant: true,
              size: 20,
              color: LumeTheme.textPrimary,
            ),
          ),
        ),
      ),
    );
  }
}

/// 右侧筛选抽屉：分类选择 + 图源管理入口。

/// 封面位：管线就绪时走 [PosterCover]，否则出主题占位（图位不变，避免列表跳动）。
