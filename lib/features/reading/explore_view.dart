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
import '../source/source_section_page.dart';
import 'poster_card.dart';
import 'source_bar.dart';
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
    required this.pipeline,
    required this.onOpenItem,
    this.manager,
    this.layout = ExploreLayout.grid,
  });

  final Section section;

  /// 本页面的图片管线（由外壳页持有并负责释放）。
  final SectionImagePipeline pipeline;

  /// 点条目：由板块页决定进哪个详情页。回调里带着条目所属图源。
  final ValueChanged<ExploreSelection> onOpenItem;

  /// 图源管理端口；为空时用正式实现。
  final SourceManager? manager;

  final ExploreLayout layout;

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
  String _keyword = '';

  final List<SourceItem> _items = <SourceItem>[];
  int _page = 1;
  bool _hasMore = false;
  bool _loadingMore = false;
  bool _loadMoreFailed = false;
  bool _switching = false;
  bool _searching = false;

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
  void dispose() {
    _layoutSettings.removeListener(_onLayoutChanged);
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
      setState(() {
        _sources = sources;
        _current = current;
        _source = source;
        _state = SourceStateKind.ready;
        _items.clear();
        _page = 1;
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

  /// 取一页列表。[more] 为真时追加，否则替换。
  Future<void> _loadPage({bool more = false}) async {
    final source = _source;
    if (source == null) return;
    if (more) {
      if (_loadingMore || !_hasMore) return;
      setState(() {
        _loadingMore = true;
        _loadMoreFailed = false;
      });
    } else {
      setState(() {
        _failure = null;
      });
    }
    final page = more ? _page + 1 : 1;
    try {
      final result = await source.list(
        categoryId: _categoryId,
        keyword: _keyword.isEmpty ? null : _keyword,
        page: page,
      );
      if (!mounted) return;
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
    } catch (error) {
      if (error is! SourceException) {
        LumeLog.error(error, StackTrace.current);
        if (!mounted) return;
        setState(() {
          _loadingMore = false;
          _loadMoreFailed = true;
          _hasMore = false;
        });
        return;
      }
      LumeLog.warn('[${source.id}] 列表获取失败: $error');
      if (!mounted) return;
      setState(() {
        _loadingMore = false;
        if (more) {
          _loadMoreFailed = true;
        } else {
          _failure = error;
        }
      });
    }
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

  void _selectCategory(String? categoryId) {
    if (_categoryId == categoryId) return;
    setState(() => _categoryId = categoryId);
    _loadPage();
  }

  void _submitSearch(String value) {
    _keyword = value.trim();
    _loadPage();
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
      body: Column(
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
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    final current = _current;
    return Row(
      children: <Widget>[
        Expanded(
          child: ReadingSourceBar(
            sources: _sources
                .where((source) => source.enabled)
                .toList(growable: false),
            currentId: current?.id,
            busy: _switching,
            onSelect: _selectSource,
            onManage: _manageSources,
          ),
        ),
        const SizedBox(width: 8),
        // 布局切换：三档（单列 / 双列 / 三列），选择按板块记住。
        _RoundAction(
          icon: switch (_mode) {
            BrowseLayoutMode.list => Icons.view_list_outlined,
            BrowseLayoutMode.grid2 => Icons.grid_view_outlined,
            BrowseLayoutMode.grid3 => Icons.apps_outlined,
          },
          tooltip: '布局',
          onTap: _chooseLayout,
        ),
        const SizedBox(width: 8),
        _RoundAction(
          icon: Icons.search,
          tooltip: '搜索',
          onTap: () => setState(() => _searching = true),
        ),
        const SizedBox(width: 8),
        _RoundAction(
          icon: Icons.filter_list,
          tooltip: '筛选',
          onTap: () => _scaffold.currentState?.openEndDrawer(),
        ),
      ],
    );
  }

  Widget _buildSearchField() {
    return Row(
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
                hintText: '搜索',
                hintStyle: TextStyle(color: LumeTheme.muted),
                icon: Icon(Icons.search, color: LumeTheme.muted),
              ),
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
            setState(() => _searching = false);
            if (_keyword.isNotEmpty) {
              _keyword = '';
              _loadPage();
            }
          },
        ),
      ],
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

  /// 切换布局：当场重排 + 落盘（下次进来自动沿用）。
  Future<void> _chooseLayout() async {
    final current = _mode;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Row(
                children: <Widget>[
                  Text(
                    '布局',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: LumeTheme.textPrimary,
                    ),
                  ),
                ],
              ),
            ),
            for (final mode in BrowseLayoutMode.values)
              ListTile(
                leading: Icon(
                  mode == current ? Icons.check_circle : Icons.circle_outlined,
                  color: mode == current ? LumeTheme.accent : LumeTheme.textHint,
                ),
                title: Text(mode.label),
                subtitle: Text(mode.hint),
                onTap: () {
                  Navigator.of(context).pop();
                  unawaited(
                    BrowseLayoutSettings.instance.setMode(widget.section, mode),
                  );
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
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
    if (_items.isEmpty && !_loadingMore) {
      return SourceStateView(
        state: SourceStateKind.empty,
        detail: '换个分类或关键词试试',
        onRetry: _bootstrap,
      );
    }
    return switch (_mode) {
      BrowseLayoutMode.list => _buildList(),
      BrowseLayoutMode.grid2 => _buildGrid(crossAxisCount: 2),
      BrowseLayoutMode.grid3 => _buildGrid(crossAxisCount: 3),
    };
  }

  Widget _buildGrid({int crossAxisCount = 3}) {
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification.metrics.extentAfter < 400) _loadPage(more: true);
        return false;
      },
      child: GridView.builder(
        padding: EdgeInsets.fromLTRB(16, 8, 16, 16 + _keyboardInset(context)),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: crossAxisCount,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          // 列越少封面越大，卡片比例也相应放宽（双列时标题有一行更宽的余地）。
          childAspectRatio: crossAxisCount <= 2 ? 0.72 : 0.62,
        ),
        itemCount: _items.length + 1,
        itemBuilder: (context, index) {
          if (index == _items.length) return _buildFooter();
          final item = _items[index];
          return _PosterTile(
            item: item,
            pipeline: widget.pipeline,
            onTap: () => _open(item),
          );
        },
      ),
    );
  }

  Widget _buildList() {
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification.metrics.extentAfter < 400) _loadPage(more: true);
        return false;
      },
      child: ListView.separated(
        padding: EdgeInsets.fromLTRB(16, 8, 16, 16 + _keyboardInset(context)),
        itemCount: _items.length + 1,
        separatorBuilder: (_, _) => const SizedBox(height: 10),
        itemBuilder: (context, index) {
          if (index == _items.length) return _buildFooter();
          final item = _items[index];
          return GlassCard(
            padding: const EdgeInsets.all(10),
            onTap: () => _open(item),
            child: Row(
              children: <Widget>[
                SizedBox(
                  width: 56,
                  height: 76,
                  child: PosterCover(
                    pipeline: widget.pipeline,
                    url: item.cover,
                    width: 160,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
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
    required this.pipeline,
    required this.onTap,
  });

  final SourceItem item;
  final SectionImagePipeline pipeline;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return PosterCard(
      onTap: onTap,
      footnote: Text(
        item.title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 12,
          height: 1.25,
          color: LumeTheme.textPrimary,
        ),
      ),
      child: PosterCover(pipeline: pipeline, url: item.cover, width: 300),
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
