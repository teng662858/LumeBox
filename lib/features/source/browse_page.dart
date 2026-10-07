import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/reading/reading.dart';
import '../../core/source/source.dart';
import '../../core/theme/lume_theme.dart';
import '../../core/util/lume_log.dart';
import '../../shared/widgets/glass_card.dart';
import '../../shared/widgets/state_view.dart';
import '../reading/poster_card.dart';
import '../shell/section_preloader.dart';
import 'detail_page.dart';

/// 图源浏览页：板块业务页里「进详情」的独立入口。
///
/// 管理器里的「浏览」按钮走这里；板块业务页直接嵌入 [BrowseView]，
/// 两者共用同一套浏览逻辑。
class BrowsePage extends StatelessWidget {
  const BrowsePage({super.key, required this.dataSource});

  final DataSource dataSource;

  @override
  Widget build(BuildContext context) => GlassScaffold(
        title: '${dataSource.section.label} · ${dataSource.name}',
        child: BrowseView(dataSource: dataSource),
      );
}

/// 浏览面：分类、列表与搜索，全部经统一数据源接口取得。
///
/// 本组件只认识 [DataSource]：分类是否提供、列表怎么取、失败原因是什么，都由
/// 接口层决定；它不接触沙箱、脚本与网络。嵌进业务页时由外层提供页面骨架。
/// Phase1 的浏览链路止于详情与章节列表，不进入阅读器。
///
/// 封面：宿主提供图片管线（[pipeline]）时，条目行左侧渲染封面缩略图
/// （与小说 / 漫画的探索列表同一范式：56×76、按 160px 解码）；没提供管线
/// 的宿主（图源管理里的浏览入口）保持纯文字排布，行为与从前完全一致。
class BrowseView extends StatefulWidget {
  const BrowseView({
    super.key,
    required this.dataSource,
    this.onItemTap,
    this.pipeline,
  });

  final DataSource dataSource;

  /// 条目点击。为空时按通用口径进入详情页（[DetailPage]）；视频板块传自己的
  /// 回调——它要的是「点条目就起播」，而不是先看详情。
  final ValueChanged<SourceItem>? onItemTap;

  /// 封面图管线（可选）。条目自带的封面（`SourceItem.cover`）由它取图，
  /// 取不到时显示占位，不会把列表拖下水。
  final SectionImagePipeline? pipeline;

  @override
  State<BrowseView> createState() => _BrowseViewState();
}

class _BrowseViewState extends State<BrowseView> {
  final TextEditingController _search = TextEditingController();

  List<SourceCategory> _categories = const <SourceCategory>[];
  final List<SourceItem> _items = <SourceItem>[];
  String? _categoryId;
  String _keyword = '';
  bool _loading = true;

  /// 列表失败的原因（分类失败不算：拿不到分类就当图源没有分类）。
  Object? _failure;

  // ------------------------------------------------------------------ 分页
  //
  // 真机反馈：列表只能看到第 1 页，滑到底不再拉下一页。这一版把分页做齐：
  // 页码 / hasMore / 每页一次的请求保护 / 触底预加载 / 下拉刷新重置。

  /// 当前已加载到第几页（1 起）。
  int _page = 1;

  /// 还有没有下一页（由图源返回的 [SourceList.hasMore] 决定）。
  bool _hasMore = false;

  /// 正在取下一页（**同时充当重复请求保护**：请求在飞时不再发第二次）。
  bool _loadingMore = false;

  /// 下一页加载失败（列表尾部给「点击重试」）。
  bool _loadMoreFailed = false;

  /// 正在为哪一页发请求（0 = 空闲）。用它挡住「同一页被并发请求两次」——
  /// 触底通知一帧能来好几次，只靠 `_loadingMore` 不够，因为 setState 之后
  /// 还有 await 边界。
  int _pendingPage = 0;

  /// 触底预加载距离：距底部还有这么多像素时就开始取下一页（不必真的滑到底）。
  static const double _preloadExtent = 600;

  /// 列表请求的代号：下拉刷新 / 换源 / 换筛选都会 +1，
  /// 过期请求回来时直接丢弃（否则旧结果会把新列表覆盖回去）。
  int _requestSeq = 0;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    // 离开页面即作废在飞的请求结果（回来的数据直接丢，不再 setState）。
    _requestSeq++;
    _search.dispose();
    super.dispose();
  }

  /// 先取分类再取列表。分类失败不阻塞列表：拿不到分类就当图源没有分类。
  Future<void> _bootstrap() async {
    try {
      final categories = await widget.dataSource.categories();
      if (!mounted) return;
      setState(() => _categories = categories);
    } on SourceException catch (error) {
      LumeLog.warn('[${widget.dataSource.id}] 分类获取失败: $error');
    }
    await _load();
  }

  /// 重置分页：页码回 1、清空列表与「没有更多」标记。
  ///
  /// 三个入口共用它：下拉刷新、换分类 / 换关键词、换图源（组件按图源 key 重挂，
  /// 但同一次挂载内换了筛选也要重来）。
  void _resetPagination() {
    _page = 1;
    _hasMore = false;
    _loadingMore = false;
    _loadMoreFailed = false;
    _pendingPage = 0;
    _requestSeq++;
  }

  /// 取第一页（替换列表）。分页状态一并重置。
  Future<void> _load() async {
    _resetPagination();
    final seq = ++_requestSeq;
    setState(() {
      _loading = true;
      _failure = null;
      _items.clear();
    });
    // 预热命中：切页签时已经取好的第一页直接用（省掉一次网络往返）。
    final warm = SectionPreloader.takeWarmPage(
      widget.dataSource.section,
      sourceId: widget.dataSource.id,
      categoryId: _categoryId,
      keyword: _keyword,
    );
    if (warm != null) {
      if (!mounted || seq != _requestSeq) return;
      setState(() {
        _items
          ..clear()
          ..addAll(warm.items);
        _page = 1;
        _hasMore = warm.hasMore;
        _loading = false;
      });
      _preloadCovers(warm.items);
      return;
    }
    try {
      final result = await widget.dataSource.list(
        categoryId: _categoryId,
        keyword: _keyword.isEmpty ? null : _keyword,
        page: 1,
      );
      if (!mounted || seq != _requestSeq) return;
      setState(() {
        _items
          ..clear()
          ..addAll(result.items);
        _page = 1;
        _hasMore = result.hasMore;
        _loading = false;
      });
      _preloadCovers(result.items);
    } catch (error) {
      if (error is! SourceException) rethrow;
      if (!mounted || seq != _requestSeq) return;
      setState(() {
        _loading = false;
        _failure = error;
      });
    }
  }

  /// 下拉刷新：重置分页 + 重取分类 + 重取第 1 页。
  ///
  /// 三件事都做齐（用户点名）：**页码回 1、清掉 hasMore、清空列表缓存**——
  /// 否则刷新之后要么看到旧内容混着新内容，要么明明还有下一页却停在「没有更多了」。
  Future<void> _refresh() async {
    SectionPreloader.discard(widget.dataSource.section);
    try {
      final categories = await widget.dataSource.categories();
      if (mounted) setState(() => _categories = categories);
    } on SourceException catch (error) {
      LumeLog.warn('[${widget.dataSource.id}] 刷新分类失败: $error');
    }
    await _load();
  }

  /// 取下一页并追加。触底时调用；重复调用由 [_pendingPage] 挡掉。
  Future<void> _loadMore() async {
    if (_loading || _loadingMore || !_hasMore) return;
    final next = _page + 1;
    if (_pendingPage == next) return; // 同一页已经在飞
    _pendingPage = next;
    final seq = _requestSeq;
    setState(() {
      _loadingMore = true;
      _loadMoreFailed = false;
    });
    try {
      final result = await widget.dataSource.list(
        categoryId: _categoryId,
        keyword: _keyword.isEmpty ? null : _keyword,
        page: next,
      );
      if (!mounted || seq != _requestSeq) return;
      setState(() {
        _page = next;
        _hasMore = result.hasMore;
        _items.addAll(result.items);
        _loadingMore = false;
      });
      _preloadCovers(result.items);
    } catch (error) {
      if (error is! SourceException) {
        LumeLog.error(error, StackTrace.current);
      } else {
        LumeLog.warn('[${widget.dataSource.id}] 下一页取失败: $error');
      }
      if (!mounted || seq != _requestSeq) return;
      // 失败**不**清 hasMore：清掉就再也拉不动了（真机反馈的那类「提前标记没有更多」）。
      setState(() {
        _loadingMore = false;
        _loadMoreFailed = true;
      });
    } finally {
      if (_pendingPage == next) _pendingPage = 0;
    }
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

  void _selectCategory(String? categoryId) {
    if (_categoryId == categoryId) return;
    setState(() => _categoryId = categoryId);
    _load();
  }

  /// 条目点击：外层给了回调就交出去（视频板块起播），否则按通用口径进详情页。
  void _openItem(SourceItem item) {
    final hook = widget.onItemTap;
    if (hook != null) {
      hook(item);
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DetailPage(dataSource: widget.dataSource, item: item),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: GlassCard(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: TextField(
              controller: _search,
              textInputAction: TextInputAction.search,
              style: TextStyle(color: LumeTheme.textPrimary),
              decoration: InputDecoration(
                border: InputBorder.none,
                hintText: '搜索',
                hintStyle: TextStyle(color: LumeTheme.muted),
                icon: Icon(Icons.search, color: LumeTheme.muted),
              ),
              onSubmitted: (value) {
                _keyword = value.trim();
                _load();
              },
            ),
          ),
        ),
        _buildCategories(),
        Expanded(child: _buildBody()),
      ],
    );
  }

  /// 分类行。图源不提供分类时整行隐藏。
  Widget _buildCategories() {
    if (_categories.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 52,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        children: <Widget>[
          _CategoryChip(
            label: '全部',
            selected: _categoryId == null,
            onTap: () => _selectCategory(null),
          ),
          for (final category in _categories)
            _CategoryChip(
              label: category.title,
              selected: _categoryId == category.id,
              onTap: () => _selectCategory(category.id),
            ),
        ],
      ),
    );
  }

  /// 封面缩略图：宿主给了管线、且条目带封面时才占位；否则整块不出现，
  /// 列表与从前一样是纯文字排布（条目没封面时也不会留一块空图位）。
  ///
  /// 尺寸与小说 / 漫画的探索列表一致：56×76、按 160px 解码，取不到图时
  /// [PosterCover] 显示主题占位，不抛异常。
  List<Widget> _buildCover(SourceItem item) {
    final pipeline = widget.pipeline;
    final cover = item.cover?.trim() ?? '';
    if (pipeline == null || cover.isEmpty) return const <Widget>[];
    return <Widget>[
      SizedBox(
        width: 56,
        height: 76,
        child: PosterCover(pipeline: pipeline, url: cover, width: 160),
      ),
      const SizedBox(width: 12),
    ];
  }

  /// 加载中 / 异常 / 空数据统一走状态视图，失败可重试（重试连分类一起重取）。
  Widget _buildBody() {
    if (_loading) {
      return const SourceStateView(state: SourceStateKind.loading);
    }
    final failure = _failure;
    if (failure != null) {
      return SourceStateView(
        state: stateForError(failure),
        detail: failure is SourceException ? failure.message : '$failure',
        onRetry: _bootstrap,
      );
    }
    if (_items.isEmpty) {
      return SourceStateView(
        state: SourceStateKind.empty,
        detail: '换个分类或关键词试试',
        onRetry: _load,
      );
    }
    return RefreshIndicator(
      onRefresh: _refresh,
      child: NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          if (notification.metrics.extentAfter < _preloadExtent) _loadMore();
          return false;
        },
        child: ListView.separated(
          // 列表短于一屏时也要能下拉刷新。
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          itemCount: _items.length + 1,
          separatorBuilder: (_, _) => const SizedBox(height: 10),
          itemBuilder: (context, index) {
            if (index == _items.length) return _buildFooter();
            final item = _items[index];
            return GlassCard(
              padding: const EdgeInsets.all(14),
              onTap: () => _openItem(item),
              child: Row(
                children: <Widget>[
                  ..._buildCover(item),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(
                          item.title,
                          maxLines: 1,
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

  /// 列表尾部：加载中 / 加载失败可重试 / 到底了 / 还有下一页（占位待拉）。
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
            onPressed: _loadMore,
            child: const Text('加载失败，点击重试'),
          ),
        ),
      );
    }
    if (!_hasMore && _items.isNotEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
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

class _CategoryChip extends StatelessWidget {
  const _CategoryChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: GlassCard(
        radius: 14,
        onTap: onTap,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            color: selected ? LumeTheme.textPrimary : LumeTheme.muted,
          ),
        ),
      ),
    );
  }
}
