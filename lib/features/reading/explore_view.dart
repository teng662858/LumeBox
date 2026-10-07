import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/reading/reading.dart';
import '../../core/reading/browse_layout.dart';
import '../../core/session/section.dart';
import '../../core/source/source.dart';
import '../../core/theme/lume_theme.dart';
import '../../core/util/lume_log.dart';
import '../../shared/widgets/glass_card.dart';
import '../../shared/widgets/notice_card.dart';
import '../../shared/widgets/state_view.dart';
import '../shell/section_preloader.dart';
import '../source/source_section_page.dart';
import 'poster_card.dart';
import 'section_toolbar.dart';
import '../shell/board_tabs.dart';

/// 探索内容布局：漫画是海报墙（网格），小说是条目列表（网格同样是海报形状，
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
    this.showSort = true,
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

  /// 是否显示「排序」按钮（用户要求小说 / 漫画去掉，视频保留）。
  final bool showSort;

  /// 外挂的「筛选」入口（**视频板块专用**：分页跳转式筛选）。
  ///
  /// 宿主返回选中的一级分类与各组标签；返回 null 表示用户取消。
  /// 为空时「筛选」按钮沿用原有行为（右侧分类抽屉）。
  final Future<({String? categoryId, Map<String, String> filters})?> Function(
    BuildContext context,
    DataSource source,
    String? currentCategoryId,
  )? onOpenFacetFilter;

  @override
  State<ExploreView> createState() => _ExploreViewState();
}

class _ExploreViewState extends State<ExploreView> {
  /// 布局偏好是应用级单例：本页监听它，别处改了这里也当场重排。
  final BrowseLayoutSettings _layoutSettings = BrowseLayoutSettings.instance;

  late final SourceManager _manager =
      widget.manager ?? LumeSources.manager(widget.section);

  final GlobalKey<ScaffoldState> _scaffold = GlobalKey<ScaffoldState>();
  final TextEditingController _search = TextEditingController();

  List<SourceDescriptor> _sources = const <SourceDescriptor>[];
  SourceDescriptor? _current;
  DataSource? _source;

  SourceStateKind _state = SourceStateKind.loading;
  String? _title;
  String? _detail;

  List<SourceCategory> _categories = const <SourceCategory>[];
  String? _categoryId;

  /// 已生效的分组筛选（视频板块的分页筛选写进来；其它板块恒为空）。
  Map<String, String> _facetFilters = const <String, String>{};
  String _keyword = '';

  final List<SourceItem> _items = <SourceItem>[];
  int _page = 1;
  bool _hasMore = false;
  bool _loadingMore = false;
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

  /// 排序（客户端，只作用于已加载的条目；图源契约里没有排序参数）。
  BrowseSort _sort = BrowseSort.none;

  /// 搜索模式（用户点名的两种）：聚合 / 当前源。
  SearchMode _searchMode = SearchMode.single;

  /// 联想候选（非空即展示下拉列表）。
  List<String> _suggestions = const <String>[];

  /// 联想取词节流：输入停顿后再问，避免每敲一个字都发请求。
  Timer? _suggestDebounce;

  /// 联想请求代号：过期结果直接丢弃（用户可能已经改了关键词）。
  int _suggestSeq = 0;

  /// 聚合搜索结果（非空即处于「结果页」形态）。单源搜索沿用 [_items]。
  List<SearchHit>? _hits;

  /// 聚合搜索里没取到数据的源数量（结果页顶部如实说明）。
  int _aggregateFailed = 0;

  /// 搜索结果的关键词（结果页顶部保留）。
  String _resultKeyword = '';

  /// 首页列表失败的原因（分类失败不算）。
  Object? _failure;

  @override
  void initState() {
    super.initState();
    _layoutSettings.addListener(_onLayoutChanged);
    if (_manager.runtimeAvailable) _bootstrap();
  }

  void _onLayoutChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(ExploreView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 宿主说「图源变了」：原地重新解析（不换 Key，见 [revision] 的说明）。
    if (widget.revision != oldWidget.revision) {
      unawaited(_bootstrap());
    }
  }

  @override
  void dispose() {
    _layoutSettings.removeListener(_onLayoutChanged);
    // 离开页面即作废在飞请求的结果（回来的数据直接丢，不再 setState），
    // 也不让它们继续占着网络队列拖慢下一个页面。
    _requestSeq++;
    _suggestSeq++;
    _suggestDebounce?.cancel();
    _search.dispose();
    _manager.close();
    super.dispose();
  }

  // ------------------------------------------------------------------ 数据

  /// 解析当前图源、打开数据源、取分类与首页列表。
  Future<void> _bootstrap() async {
    setState(() {
      _state = SourceStateKind.loading;
      _title = null;
      _detail = null;
    });
    try {
      final sources = await _manager.list();
      if (!mounted) return;
      final enabled =
          sources.where((source) => source.enabled).toList(growable: false);
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
      if (current == null || !mounted) {
        _settle(
          state: SourceStateKind.disabled,
          detail: '板块内没有可用的源',
          sources: sources,
        );
        return;
      }
      final source = await _manager.open(current.id);
      if (!mounted) return;
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
        _source = source;
        _state = SourceStateKind.ready;
        _failure = null;
      });
      await _loadCategories();
      await _loadPage();
    } on SourceException catch (error) {
      LumeLog.warn('[${widget.section.id}] 探索页源状态异常: $error');
      _settle(state: stateForError(error), detail: error.message);
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
      if (!mounted) return;
      setState(() {
        _state = SourceStateKind.scriptError;
        _detail = '$error';
        _source = null;
      });
    }
  }

  /// 分类失败不阻塞列表：拿不到分类就当图源没有分类。
  Future<void> _loadCategories() async {
    final source = _source;
    if (source == null) return;
    try {
      final categories = await source.categories();
      if (!mounted) return;
      setState(() {
        _categories = categories;
        if (_categoryId != null &&
            !categories.any((item) => item.id == _categoryId)) {
          _categoryId = null;
        }
      });
    } on SourceException catch (error) {
      LumeLog.warn('[${source.id}] 分类获取失败: $error');
    }
  }

  /// 重置分页：页码回 1、清空列表与「没有更多」标记。
  ///
  /// 换图源、换分类 / 关键词、下拉刷新都走这里——**每一个图源单独维护自己的
  /// 分页状态**（用户点名）：换源时必须清干净，否则会带着旧源的页码与
  /// hasMore 继续翻页。
  void _resetPagination() {
    _page = 1;
    _hasMore = false;
    _loadingMore = false;
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
        _items.clear();
      });
      // 预热命中：直接吃切页签时提前取好的第一页（省掉一次网络往返）。
      final warm = SectionPreloader.takeWarmPage(
        widget.section,
        sourceId: source.id,
        categoryId: _categoryId,
        keyword: _keyword,
      );
      if (warm != null) {
        setState(() {
          _page = 1;
          _hasMore = warm.hasMore;
          _loadingMore = false;
          _items.addAll(warm.items);
        });
        _preloadCovers(warm.items);
        return;
      }
    }
    _pendingPage = page;
    final seq = _requestSeq;
    try {
      final result = await source.list(
        categoryId: _categoryId,
        keyword: _keyword.isEmpty ? null : _keyword,
        page: page,
        filters: _facetFilters.isEmpty ? null : _facetFilters,
      );
      if (!mounted || seq != _requestSeq) return;
      setState(() {
        _page = page;
        _hasMore = result.hasMore;
        _loadingMore = false;
        if (more) {
          _items.addAll(result.items);
        } else {
          _items
            ..clear()
            ..addAll(result.items);
        }
      });
      _preloadCovers(result.items);
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
          _failure = error;
        }
      });
    } finally {
      if (_pendingPage == page) _pendingPage = 0;
    }
  }

  /// 下拉刷新：重置分页 + 重取分类 + 重取第 1 页（用户点名三件事都要做）。
  Future<void> _refresh() async {
    // 预热缓存作废：用户明确要求要新的。
    SectionPreloader.discard(widget.section);
    await _loadCategories();
    await _loadPage();
  }

  /// 预取这一页的封面：列表还在滑的时候图就已经在路上了。
  void _preloadCovers(List<SourceItem> items) {
    final pipeline = widget.pipeline;
    if (pipeline == null) return;
    pipeline.preload(
      <String>[
        for (final item in items)
          if ((item.cover ?? '').trim().isNotEmpty) item.cover!.trim(),
      ],
      targetWidth: 160,
    );
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('该源不可用')),
      );
      return;
    }
    await _bootstrap();
  }

  /// 点「筛选」：视频板块走外挂的分页筛选（一级分类 → 筛选子页），
  /// 其余板块沿用原来的分类抽屉。
  Future<void> _openFilter() async {
    final hook = widget.onOpenFacetFilter;
    final source = _source;
    if (hook == null || source == null) {
      _scaffold.currentState?.openEndDrawer();
      return;
    }
    final picked = await hook(context, source, _categoryId);
    if (picked == null || !mounted) return;
    setState(() {
      _categoryId = picked.categoryId;
      _facetFilters = picked.filters;
    });
    // 应用后从第一页重来（与换分类同口径）。
    _loadPage();
  }

  void _selectCategory(String? categoryId) {
    if (_categoryId == categoryId) return;
    setState(() => _categoryId = categoryId);
    _loadPage();
  }

  /// 点工具栏「搜索」：先选范围（聚合 / 当前源），再开搜索框。
  Future<void> _openSearch() async {
    final mode = await showSearchModeMenu(context);
    if (mode == null || !mounted) return;
    setState(() {
      _searchMode = mode;
      _searching = true;
      _suggestions = const <String>[];
    });
  }

  /// 输入变化：拉联想词（优先图源的 suggest，没有就用本地搜索历史）。
  ///
  /// 联想只是输入辅助：它不改搜索请求本身（见 [_submitSearch]）。
  void _onSearchChanged(String value) {
    _suggestDebounce?.cancel();
    final keyword = value.trim();
    if (keyword.isEmpty) {
      // 空输入不弹（用户点名）。
      setState(() => _suggestions = const <String>[]);
      return;
    }
    _suggestDebounce = Timer(
      const Duration(milliseconds: 200),
      () => unawaited(_loadSuggestions(keyword)),
    );
  }

  Future<void> _loadSuggestions(String keyword) async {
    final seq = ++_suggestSeq;
    final suggestions = await SearchSuggestions(
      source: _source,
      history: _historyStore?.load() ?? const <String>[],
    ).forKeyword(keyword);
    if (!mounted || seq != _suggestSeq) return;
    // 关键词可能已经被清掉 / 改掉：只在还匹配时上屏。
    if (_search.text.trim() != keyword) return;
    setState(() => _suggestions = suggestions);
  }

  /// 关掉联想弹窗（点页面空白 / 按返回时调用）。
  void _closeSuggestions() {
    if (_suggestions.isEmpty) return;
    _suggestDebounce?.cancel();
    _suggestSeq++;
    setState(() => _suggestions = const <String>[]);
  }

  /// 搜索历史（本板块自己的库；库没打开时为 null，联想退化为纯服务端）。
  SearchHistoryStore? get _historyStore {
    final library = ReadingLibrary.find(widget.section);
    return library == null ? null : SearchHistoryStore(widget.section, library);
  }

  /// 执行搜索。**两种模式共用同一份「请求」逻辑**，只是范围不同：
  /// - 当前源：与浏览页同一套 [DataSource.list]（关键词 + 分页）；
  /// - 聚合：并发问本板块全部已启用源，结果合并成一张结果页。
  void _submitSearch(String value) {
    final keyword = value.trim();
    _suggestions = const <String>[];
    _suggestDebounce?.cancel();
    if (keyword.isEmpty) return;
    _historyStore?.remember(keyword);
    _keyword = keyword;
    _resultKeyword = keyword;
    if (_searchMode == SearchMode.aggregate) {
      unawaited(_runAggregate(keyword));
      return;
    }
    setState(() => _hits = null);
    _loadPage();
  }

  /// 聚合搜索：并发问全部已启用源（单个源失败只丢它自己）。
  Future<void> _runAggregate(String keyword) async {
    final seq = ++_requestSeq;
    setState(() {
      _hits = null;
      _failure = null;
      _aggregateFailed = 0;
      _loadingMore = false;
    });
    final result = await AggregateSearch.run(
      sources: _sources,
      keyword: keyword,
      categoryId: _categoryId,
      open: (sourceId) => _manager.open(sourceId),
    );
    if (!mounted || seq != _requestSeq) return;
    setState(() {
      _hits = result.hits;
      _aggregateFailed = result.failed;
    });
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
        builder: (_) => SourceSectionPage(
          section: widget.section,
          manager: widget.manager,
        ),
      ),
    );
    if (!mounted) return;
    // 返回后重新解析：可能导入了新图源、改变了启用状态或当前图源。
    await _bootstrap();
  }

  // ------------------------------------------------------------------ 构建

  @override
  Widget build(BuildContext context) {
    if (!_manager.runtimeAvailable) return const SkeletonNotice();
    return Scaffold(
      // **本页不随键盘收缩**（真机反馈：唤起键盘后顶部搜索框被顶出屏幕，
      // 小说 / 漫画 / 视频三块都复现）。这里的布局契约是：
      //   顶栏占位 + 搜索行是**固定头部**，键盘只能影响下面的内容列表。
      // 交给 Scaffold 收缩的话，头部会跟着被挤压/位移；因此关掉自动收缩，
      // 让键盘的高度由列表自己用底部内边距让出来（见 _keyboardInset）。
      resizeToAvoidBottomInset: false,
      backgroundColor: Colors.transparent,
      key: _scaffold,
      drawerScrimColor: Colors.black54,
      endDrawer: _FilterDrawer(
        categories: _categories,
        selectedId: _categoryId,
        onSelect: (id) {
          Navigator.of(context).pop();
          _selectCategory(id);
        },
        onManage: () {
          Navigator.of(context).pop();
          _manageSources();
        },
      ),
      // 返回键：**联想弹窗开着时先关它**（用户点名「返回关闭联想弹窗」），
      // 而不是直接退出搜索 / 退出页面。
      body: PopScope(
        canPop: _suggestions.isEmpty,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _closeSuggestions();
        },
        child: Column(
          children: <Widget>[
            // 图源条 / 搜索行不在滚动视图里，自己让出玻璃顶栏（标题 + 页签条）。
            SizedBox(
              height: GlassScaffold.barHeight(
                context,
                extra: BoardTabHeader.height,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: _searching ? _buildSearchField() : _buildHeader(),
            ),
            // 点页面空白也关联想弹窗（用户点名）：这一层只处理「没被列表项吃掉」
            // 的那些点按，列表本身的点击 / 滚动照常（子级手势更靠内，优先胜出）。
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _closeSuggestions,
                child: _buildBody(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 顶部工具栏：**一行完整控件，顺序固定**（用户点名）：
  /// 源选择下拉框 → 排序 → 布局 → 搜索 → 筛选。
  ///
  /// 三个板块共用同一个 [SectionToolbar]：换板块也找得到那个按钮。
  Widget _buildHeader() {
    final showSourceManageFlag = widget.showSourceManage;
    return SectionToolbar(
      sources: _sources.where((source) => source.enabled).toList(growable: false),
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
      onFilter: _openFilter,
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
                  style: TextStyle(color: LumeTheme.textPrimary),
                  decoration: InputDecoration(
                    border: InputBorder.none,
                    hintText: _searchMode == SearchMode.aggregate
                        ? '搜索全部已启用源'
                        : '在当前源内搜索',
                    hintStyle: TextStyle(color: LumeTheme.muted),
                    icon: Icon(Icons.search, color: LumeTheme.muted),
                    suffixIcon: TextButton(
                      onPressed: _openSearch,
                      child: Text(
                        _searchMode.label,
                        style: const TextStyle(fontSize: 12),
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
                _suggestSeq++;
                setState(() {
                  _searching = false;
                  _suggestions = const <String>[];
                });
                if (_keyword.isNotEmpty || _hits != null) {
                  _keyword = '';
                  _resultKeyword = '';
                  setState(() => _hits = null);
                  _loadPage();
                }
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
            for (final suggestion in _suggestions)
              InkWell(
                onTap: () => _applySuggestion(suggestion),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  child: Row(
                    children: <Widget>[
                      Icon(Icons.search, size: 16, color: LumeTheme.muted),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          suggestion,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14,
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

  /// 键盘占住的高度：列表拿它做底部内边距。
  ///
  /// 本页关掉了 Scaffold 的自动收缩（见 build），所以键盘不会改变页面布局；
  /// 代价是列表底部会被键盘盖住，这里补上这段内边距，让最后几条仍能滚出来。
  double _keyboardInset(BuildContext context) =>
      MediaQuery.viewInsetsOf(context).bottom;

  /// 当前生效的布局档位。
  ///
  /// 用户选过的优先（按板块分别记住）；没选过时回落到本页的默认档
  /// （小说默认单列、漫画默认三列网格——由板块页传进来的 [ExploreLayout] 决定）。
  BrowseLayoutMode get _mode =>
      BrowseLayoutSettings.instance.modeFor(widget.section) ??
      (widget.layout == ExploreLayout.grid
          ? BrowseLayoutMode.grid3
          : BrowseLayoutMode.list);

  /// 是否处于「搜索结果」形态（单源搜索按关键词，聚合搜索看 [_hits]）。
  bool get _isSearchResult => _hits != null || _keyword.isNotEmpty;

  /// 排序后的条目（排序是客户端行为，只作用于已加载的这批）。
  List<SourceItem> get _sortedItems => _sort.apply(_items);

  /// 聚合搜索结果页：顶部保留关键词，列表逐条给出
  /// 「标题 + 时长 + 图源来源 + 更新时间」，排序 / 筛选 / 布局照常可用。
  Widget _buildAggregateResults() {
    final hits = _sort.apply(<SourceItem>[
      for (final hit in _hits!) hit.item,
    ]);
    final byId = <String, SearchHit>{
      for (final hit in _hits!) hit.item.id: hit,
    };
    // 结果页同样支持布局切换（用户点名）：网格档用海报卡，元信息进脚注。
    if (_mode != BrowseLayoutMode.list) {
      return RefreshIndicator(
        onRefresh: () async => _runAggregate(_resultKeyword),
        child: GridView.builder(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsets.fromLTRB(
            16,
            8,
            16,
            16 + _keyboardInset(context),
          ),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: _mode.columns,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: _mode.tileAspectRatio,
          ),
          itemCount: hits.length,
          itemBuilder: (context, index) {
            final item = hits[index];
            final hit = byId[item.id];
            return _PosterTile(
              item: item,
              pipeline: widget.pipeline,
              meta: _resultMeta(item, hit),
              onTap: () => _open(item),
            );
          },
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: () async => _runAggregate(_resultKeyword),
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.fromLTRB(16, 8, 16, 16 + _keyboardInset(context)),
        itemCount: hits.length + 1,
        separatorBuilder: (_, _) => const SizedBox(height: 10),
        itemBuilder: (context, index) {
          if (index == hits.length) {
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 14),
              child: Center(
                child: Text(
                  _aggregateFailed == 0
                      ? '共 ${hits.length} 条'
                      : '共 ${hits.length} 条（$_aggregateFailed 个源没取到）',
                  style: TextStyle(fontSize: 12, color: LumeTheme.muted),
                ),
              ),
            );
          }
          final item = hits[index];
          final hit = byId[item.id];
          return GlassCard(
            padding: const EdgeInsets.all(10),
            onTap: () => _open(item),
            child: Row(
              children: <Widget>[
                SizedBox(
                  width: 56,
                  height: 76,
                  child: _Cover(
                    pipeline: widget.pipeline,
                    url: item.cover,
                    width: 160,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(child: _searchResultInfo(item, hit)),
                Icon(Icons.chevron_right, color: LumeTheme.muted),
              ],
            ),
          );
        },
      ),
    );
  }

  /// 搜索结果条目的元信息串（时长 / 来源 / 更新时间，缺项自动省略，不编造）。
  static String? _resultMeta(SourceItem item, SearchHit? hit) {
    final pieces = <String>[
      if (item.duration != null) '时长 ${_formatDuration(item.duration!)}',
      if (hit != null) '来源 ${hit.sourceName}',
      if (item.updatedAt != null) '更新 ${_formatDate(item.updatedAt!)}',
    ];
    return pieces.isEmpty ? null : pieces.join(' · ');
  }

  /// 搜索结果条目信息：标题 + 元信息串。
  Widget _searchResultInfo(SourceItem item, SearchHit? hit) {
    final meta = _resultMeta(item, hit);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          item.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: LumeTheme.textPrimary,
          ),
        ),
        if (meta != null) ...<Widget>[
          const SizedBox(height: 4),
          Text(
            meta,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: LumeTheme.muted),
          ),
        ],
      ],
    );
  }

  /// `12:34` / `1:02:03`。
  static String _formatDuration(Duration value) {
    final hours = value.inHours;
    final minutes = value.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
    return hours > 0 ? '$hours:$minutes:$seconds' : '${value.inMinutes}:$seconds';
  }

  /// `2026-10-07`。
  static String _formatDate(DateTime value) {
    final local = value.toLocal();
    String two(int number) => number.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)}';
  }

  Widget _buildBody() {
    if (_state != SourceStateKind.ready) {
      return SourceStateView(
        state: _state,
        title: _title,
        detail: _detail,
        onRetry: _state == SourceStateKind.loading ? null : _bootstrap,
        action: _state == SourceStateKind.loading
            ? null
            : FilledButton(onPressed: _manageSources, child: const Text('源管理')),
      );
    }
    final failure = _failure;
    if (failure != null) {
      return SourceStateView(
        state: stateForError(failure),
        detail: failure is SourceException ? failure.message : '$failure',
        onRetry: _bootstrap,
      );
    }
    if (_hits != null) return _buildAggregateResults();
    if (_items.isEmpty && !_loadingMore) {
      return SourceStateView(
        state: SourceStateKind.empty,
        detail: _isSearchResult ? '没有搜到相关条目，换个关键词试试' : '换个分类或关键词试试',
        onRetry: _bootstrap,
      );
    }
    if (_mode == BrowseLayoutMode.list) return _buildList();
    return _buildGrid(crossAxisCount: _mode.columns);
  }

  Widget _buildGrid({int crossAxisCount = 3}) {
    return RefreshIndicator(
      onRefresh: _refresh,
      child: NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          if (notification.metrics.extentAfter < _preloadExtent) {
            _loadPage(more: true);
          }
          return false;
        },
        child: GridView.builder(
        // 内容不足一屏时也要能下拉刷新。
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.fromLTRB(16, 8, 16, 16 + _keyboardInset(context)),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: crossAxisCount,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          // 列越少封面越大，卡片比例也相应放宽（两列时标题有一行更宽的余地）——
          // 比例表在 BrowseLayoutMode.tileAspectRatio 里统一维护。
          childAspectRatio: BrowseLayoutMode.values
              .firstWhere((mode) => mode.columns == crossAxisCount,
                  orElse: () => _mode)
              .tileAspectRatio,
        ),
        itemCount: _sortedItems.length + 1,
        itemBuilder: (context, index) {
          final items = _sortedItems;
          if (index == items.length) return _buildFooter();
          final item = items[index];
            return _PosterTile(
              item: item,
              pipeline: widget.pipeline,
              onTap: () => _open(item),
            );
          },
        ),
      ),
    );
  }

  Widget _buildList() {
    return RefreshIndicator(
      onRefresh: _refresh,
      child: NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          if (notification.metrics.extentAfter < _preloadExtent) {
            _loadPage(more: true);
          }
          return false;
        },
        child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.fromLTRB(16, 8, 16, 16 + _keyboardInset(context)),
        itemCount: _sortedItems.length + 1,
        separatorBuilder: (_, _) => const SizedBox(height: 10),
        itemBuilder: (context, index) {
          final items = _sortedItems;
          if (index == items.length) return _buildFooter();
          final item = items[index];
          return GlassCard(
            padding: const EdgeInsets.all(10),
            onTap: () => _open(item),
            child: Row(
              children: <Widget>[
                SizedBox(
                  width: 56,
                  height: 76,
                  child: _Cover(
                    pipeline: widget.pipeline,
                    url: item.cover,
                    width: 160,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _isSearchResult
                      ? _searchResultInfo(item, null)
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            Text(
                              item.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                                color: LumeTheme.textPrimary,
                              ),
                            ),
                            if (item.subtitle != null) ...<Widget>[
                              const SizedBox(height: 4),
                              Text(
                                item.subtitle!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: LumeTheme.muted,
                                ),
                              ),
                            ],
                          ],
                        ),
                ),
                Icon(Icons.chevron_right, color: LumeTheme.muted),
              ],
            ),
            );
          },
        ),
      ),
    );
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
            onPressed: () => _loadPage(more: true),
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
            style: TextStyle(fontSize: 12, color: LumeTheme.muted),
          ),
        ),
      );
    }
    return const SizedBox(height: 8);
  }
}

/// 海报网格单元：封面 + 标题（底部渐变压字），与书架卡片同一套视觉。
class _PosterTile extends StatelessWidget {
  const _PosterTile({
    required this.item,
    this.pipeline,
    required this.onTap,
    this.meta,
  });

  final SourceItem item;
  final SectionImagePipeline? pipeline;
  final VoidCallback onTap;

  /// 额外的元信息行（搜索结果页用它显示时长 / 来源 / 更新时间）。
  final String? meta;

  @override
  Widget build(BuildContext context) {
    final meta = this.meta;
    // 标题风格是全局偏好（设置页可切），这里按当前值渲染。
    final style = BrowseLayoutSettings.instance.gridTitleStyle;
    return PosterCard(
      onTap: onTap,
      // 标题风格：遮罩内置（白字压在封面上）/ 外置独立（黑字在封面下方）。
      // 外置时封面不画任何遮罩，文字落在卡片浅色底上，因此用主题主文字色。
      footnoteBelow: style == GridTitleStyle.below,
      footnote: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            item.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            // 内置：压在封面底部的深色遮罩上 → **一律白字 + 加粗 + 浅描边**
            //（原来用 LumeTheme.textPrimary，浅色主题下深色字压深色遮罩，
            //  真机反馈「标题看着很淡」）；外置：封面外的浅色底 → 主题主文字色。
            style: style == GridTitleStyle.below
                ? TextStyle(
                    fontSize: 12.5,
                    height: 1.25,
                    fontWeight: FontWeight.w600,
                    color: LumeTheme.textPrimary,
                  )
                : const TextStyle(
                    fontSize: 12.5,
                    height: 1.25,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                    shadows: <Shadow>[
                      Shadow(color: Color(0xB3000000), blurRadius: 4),
                    ],
                  ),
          ),
          if (meta != null) ...<Widget>[
            const SizedBox(height: 2),
            Text(
              meta,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              // 内置：白字降透明度做层级；外置：主题辅助色。
              style: style == GridTitleStyle.below
                  ? TextStyle(fontSize: 10, color: LumeTheme.muted)
                  : TextStyle(
                      fontSize: 10,
                      color: Colors.white.withValues(alpha: 0.72),
                    ),
            ),
          ],
        ],
      ),
      child: _Cover(pipeline: pipeline, url: item.cover, width: 300),
    );
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
            child: Icon(icon, size: 20, color: LumeTheme.textPrimary),
          ),
        ),
      ),
    );
  }
}

/// 右侧筛选抽屉：分类选择 + 图源管理入口。
class _FilterDrawer extends StatelessWidget {
  const _FilterDrawer({
    required this.categories,
    required this.selectedId,
    required this.onSelect,
    required this.onManage,
  });

  final List<SourceCategory> categories;
  final String? selectedId;
  final ValueChanged<String?> onSelect;
  final VoidCallback onManage;

  @override
  Widget build(BuildContext context) {
    return Drawer(
      width: 280,
      backgroundColor: LumeTheme.surface,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: EdgeInsets.fromLTRB(20, 18, 20, 8),
              child: Text(
                '筛选',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: LumeTheme.textPrimary,
                ),
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                children: <Widget>[
                  _option('全部', selectedId == null, () => onSelect(null)),
                  for (final category in categories)
                    _option(
                      category.title,
                      selectedId == category.id,
                      () => onSelect(category.id),
                    ),
                  if (categories.isEmpty)
                    Padding(
                      padding: EdgeInsets.fromLTRB(12, 8, 12, 0),
                      child: Text(
                        '当前源没有提供分类',
                        style: TextStyle(fontSize: 12, color: LumeTheme.muted),
                      ),
                    ),
                ],
              ),
            ),
            Divider(height: 1, color: LumeTheme.divider),
            ListTile(
              leading: Icon(Icons.tune, color: LumeTheme.textSecondary),
              title: const Text('源管理'),
              onTap: onManage,
            ),
          ],
        ),
      ),
    );
  }

  Widget _option(String label, bool selected, VoidCallback onTap) {
    return ListTile(
      dense: true,
      title: Text(
        label,
        style: TextStyle(
          fontSize: 14,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
          color: selected ? LumeTheme.textPrimary : LumeTheme.muted,
        ),
      ),
      trailing: selected
          ? Icon(Icons.check, size: 18, color: LumeTheme.textPrimary)
          : null,
      onTap: onTap,
    );
  }
}

/// 封面位：管线就绪时走 [PosterCover]，否则出主题占位（图位不变，避免列表跳动）。
class _Cover extends StatelessWidget {
  const _Cover({required this.pipeline, required this.url, required this.width});

  final SectionImagePipeline? pipeline;
  final String? url;
  final int width;

  @override
  Widget build(BuildContext context) {
    final pipeline = this.pipeline;
    if (pipeline == null) {
      return DecoratedBox(
        decoration: BoxDecoration(
          color: LumeTheme.fillStrong,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(Icons.image_outlined, size: 18, color: LumeTheme.muted),
      );
    }
    return PosterCover(pipeline: pipeline, url: url, width: width);
  }
}
