import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';

import '../../core/reading/browse_layout.dart';
import '../../core/reading/reading.dart';
import '../../core/session/section.dart';
import '../../core/source/source.dart';
import '../../core/theme/lume_theme.dart';
import '../../core/util/lume_log.dart';
import '../../shared/widgets/glass_card.dart';
import '../../shared/widgets/state_view.dart';
import 'explore_view.dart';
import 'poster_card.dart';
import 'section_toolbar.dart';

/// 独立的**搜索结果页**（用户口径：搜索完必须离开首页推荐网格，跳到这里）。
///
/// 以前搜索是「就地替换首页网格」，于是三件事都出问题：首页推荐看起来没动、
/// 空结果和「这个源没有内容」分不清、也没有独立的加载 / 失败态。现在搜索是一段
/// 自成一体的流程：请求中 → 转圈；失败 → 错误提示 + 重试；命中 → 结果列表；
/// 一条都没有 → 「未搜索到相关内容」。
///
/// 三种板块共用本页（小说 / 漫画 / 视频），两种范围共用同一套渲染：
/// - [SearchMode.aggregate]：并发问本板块全部已启用源，逐条标注来源；
/// - [SearchMode.single]：只问进来时选中的那个源，并支持继续翻页。
class SearchResultsPage extends StatefulWidget {
  const SearchResultsPage({
    super.key,
    required this.section,
    required this.keyword,
    required this.mode,
    required this.onOpenItem,
    this.manager,
    this.pipeline,
    this.sourceId,
  });

  final Section section;

  /// 搜索关键词（页面抬头与请求都用它）。
  final String keyword;

  final SearchMode mode;

  /// 点条目：交给板块页决定进哪个详情页（与探索页同一口径）。
  final ValueChanged<ExploreSelection> onOpenItem;

  /// 图源管理端口；为空时用正式实现。
  final SourceManager? manager;

  /// 本板块的图片管线（封面）。
  final SectionImagePipeline? pipeline;

  /// 当前源 id（当前源搜索用；聚合搜索忽略）。
  final String? sourceId;

  @override
  State<SearchResultsPage> createState() => _SearchResultsPageState();
}

class _SearchResultsPageState extends State<SearchResultsPage> {
  /// 请求中（含首次进入与重试）。
  bool _loading = true;

  /// 失败原因（网络 / 脚本错误）。
  Object? _failure;

  /// 聚合结果（带来源）；当前源搜索时为空表。
  List<SearchHit> _hits = const <SearchHit>[];

  /// 当前源搜索结果。
  List<SourceItem> _items = const <SourceItem>[];

  /// 聚合搜索里没取到数据的源数量（如实说明，不假装全部成功）。
  int _aggregateFailed = 0;

  /// 结果里出现的图源名字（列表行显示来源用）。
  final Map<String, String> _sourceNames = <String, String>{};

  /// 当前源搜索的翻页状态。
  int _page = 1;
  bool _hasMore = false;
  bool _loadingMore = false;

  /// 请求代号：重试 / 翻页交错时丢弃过期结果。
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  SourceManager get _manager =>
      widget.manager ?? LumeSources.manager(widget.section);

  Future<void> _run() async {
    final seq = ++_seq;
    setState(() {
      _loading = true;
      _failure = null;
      _hits = const <SearchHit>[];
      _items = const <SourceItem>[];
      _page = 1;
      _hasMore = false;
      _aggregateFailed = 0;
    });
    try {
      if (widget.mode == SearchMode.aggregate) {
        final sources = await _manager.list();
        final result = await AggregateSearch.run(
          sources: sources,
          keyword: widget.keyword,
          open: (sourceId) => _manager.open(sourceId),
        );
        if (!mounted || seq != _seq) return;
        final names = <String, String>{
          for (final descriptor in sources) descriptor.id: descriptor.name,
        };
        setState(() {
          _sourceNames
            ..clear()
            ..addAll(names);
          _hits = result.hits;
          _aggregateFailed = result.failed;
          _loading = false;
        });
        return;
      }

      // 当前源搜索：与浏览页同一套 list(keyword:)。
      final sourceId = widget.sourceId ?? (await _manager.current())?.id;
      final DataSource? source =
          sourceId == null ? null : await _manager.open(sourceId);
      if (!mounted || seq != _seq) return;
      if (source == null) {
        setState(() {
          _loading = false;
          _failure = const SourceException(
            SourceErrorKind.notFound,
            '当前源不可用（未启用或脚本载入失败）',
          );
        });
        return;
      }
      final result = await source.list(keyword: widget.keyword, page: 1);
      if (!mounted || seq != _seq) return;
      setState(() {
        _sourceNames[source.id] = source.name;
        _items = result.items;
        _hasMore = result.hasMore;
        _loading = false;
      });
    } catch (error, stackTrace) {
      if (error is! SourceException) {
        LumeLog.error(error, stackTrace);
      } else {
        LumeLog.warn('[${widget.section.id}] 搜索失败: $error');
      }
      if (!mounted || seq != _seq) return;
      setState(() {
        _loading = false;
        _failure = error;
      });
    }
  }

  /// 翻页（只有当前源搜索有下一页；聚合搜索一次问全）。
  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore || widget.mode == SearchMode.aggregate) return;
    final sourceId = widget.sourceId ?? (await _manager.current())?.id;
    if (sourceId == null) return;
    setState(() => _loadingMore = true);
    final seq = _seq;
    try {
      final source = await _manager.open(sourceId);
      final result = await source?.list(
        keyword: widget.keyword,
        page: _page + 1,
      );
      if (!mounted || seq != _seq || result == null) {
        if (mounted) setState(() => _loadingMore = false);
        return;
      }
      setState(() {
        _page++;
        _hasMore = result.hasMore;
        _loadingMore = false;
        _items = <SourceItem>[..._items, ...result.items];
      });
    } catch (error) {
      LumeLog.warn('[${widget.section.id}] 搜索翻页失败: $error');
      if (!mounted || seq != _seq) return;
      setState(() {
        _loadingMore = false;
        _hasMore = false; // 失败就不再追，避免反复打源站
      });
    }
  }

  /// 命中的条目数。
  int get _count =>
      widget.mode == SearchMode.aggregate ? _hits.length : _items.length;

  /// 条目 +（聚合时）它来自哪个源。
  List<({SourceItem item, String? sourceName})> get _rows {
    if (widget.mode == SearchMode.aggregate) {
      return <({SourceItem item, String? sourceName})>[
        for (final hit in _hits) (item: hit.item, sourceName: hit.sourceName),
      ];
    }
    final name = _sourceNames.values.isEmpty ? null : _sourceNames.values.first;
    return <({SourceItem item, String? sourceName})>[
      for (final item in _items) (item: item, sourceName: name),
    ];
  }

  /// 元信息串：时长 / 来源 / 更新时间，缺项自动省略（不编造）。
  static String? _metaOf(SourceItem item, String? sourceName) {
    final pieces = <String>[
      if (item.duration != null) '时长 ${_duration(item.duration!)}',
      if (sourceName != null && sourceName.isNotEmpty) '来源 $sourceName',
      if (item.updatedAt != null) '更新 ${_date(item.updatedAt!)}',
    ];
    return pieces.isEmpty ? null : pieces.join(' · ');
  }

  static String _duration(Duration value) {
    final hours = value.inHours;
    final minutes = value.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
    return hours > 0 ? '$hours:$minutes:$seconds' : '${value.inMinutes}:$seconds';
  }

  static String _date(DateTime value) {
    final local = value.toLocal();
    String two(int number) => number.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)}';
  }

  void _open(SourceItem item, String? sourceName) {
    // 条目所属源：聚合搜索优先用它带的来源名反查 id，当前源搜索直接用当前源。
    var sourceId = widget.sourceId;
    if (widget.mode == SearchMode.aggregate) {
      for (final hit in _hits) {
        if (identical(hit.item, item) || hit.item.id == item.id) {
          sourceId = hit.sourceId;
          break;
        }
      }
    }
    if (sourceId == null) return;
    widget.onOpenItem(ExploreSelection(sourceId: sourceId, item: item));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: DecoratedBox(
        decoration: LumeTheme.background,
        child: Column(
          children: <Widget>[
            _buildHeader(context),
            Expanded(child: _buildBody()),
          ],
        ),
      ),
    );
  }

  /// 顶栏：返回 + 「搜索 · 关键词」+ 结果条数。
  Widget _buildHeader(BuildContext context) {
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: LumeTheme.glass,
            border: Border(bottom: BorderSide(color: LumeTheme.hairline)),
          ),
          child: Padding(
            padding: EdgeInsets.only(
              top: MediaQuery.paddingOf(context).top,
            ),
            child: SizedBox(
              height: kToolbarHeight,
              child: Row(
                children: <Widget>[
                  IconButton(
                    tooltip: '返回',
                    icon: const Icon(Icons.arrow_back),
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          '搜索 · ${widget.keyword}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: LumeTheme.textPrimary,
                          ),
                        ),
                        Text(
                          _loading
                              ? '正在搜索…'
                              : '${widget.mode.label} · $_count 条',
                          style: TextStyle(fontSize: 12, color: LumeTheme.muted),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) return const SourceStateView(state: SourceStateKind.loading);
    final failure = _failure;
    if (failure != null) {
      final detail = failure is SourceException
          ? failure.message
          : '$failure';
      return SourceStateView(
        state: stateForError(failure),
        detail: detail,
        onRetry: _run,
      );
    }
    if (_count == 0) {
      return SourceStateView(
        state: SourceStateKind.empty,
        // 用户点名的文案：搜不到就说搜不到，不跟「源里没内容」混为一谈。
        detail: '未搜索到相关内容',
        title: _aggregateFailed > 0 ? '有 $_aggregateFailed 个源没取到' : null,
        onRetry: _run,
      );
    }
    return _mode == BrowseLayoutMode.list ? _buildList() : _buildGrid();
  }

  /// 布局档：与探索页同一套偏好（用户选过的按板块记住）。
  BrowseLayoutMode get _mode =>
      BrowseLayoutSettings.instance.modeFor(widget.section) ??
      (widget.section == Section.novel
          ? BrowseLayoutMode.list
          : BrowseLayoutMode.grid3);

  Widget _buildGrid() {
    final rows = _rows;
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification.metrics.extentAfter < 600) unawaited(_loadMore());
        return false;
      },
      child: GridView.builder(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: _mode.columns,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: _mode.tileAspectRatio,
        ),
        itemCount: rows.length,
        itemBuilder: (context, index) {
          final row = rows[index];
          return PosterTile(
            item: row.item,
            pipeline: widget.pipeline,
            meta: _metaOf(row.item, row.sourceName),
            onTap: () => _open(row.item, row.sourceName),
          );
        },
      ),
    );
  }

  Widget _buildList() {
    final rows = _rows;
    final footer = widget.mode == SearchMode.aggregate ? _count : null;
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification.metrics.extentAfter < 600) unawaited(_loadMore());
        return false;
      },
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        itemCount: rows.length + 1,
        separatorBuilder: (_, _) => const SizedBox(height: 10),
        itemBuilder: (context, index) {
          if (index == rows.length) return _buildFooter(footer);
          final row = rows[index];
          return GlassCard(
            padding: const EdgeInsets.all(10),
            onTap: () => _open(row.item, row.sourceName),
            child: Row(
              children: <Widget>[
                SizedBox(
                  width: 56,
                  height: 76,
                  child: CoverThumb(
                    pipeline: widget.pipeline,
                    url: row.item.cover,
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
                        row.item.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: LumeTheme.textPrimary,
                        ),
                      ),
                      if (_metaOf(row.item, row.sourceName) != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            _metaOf(row.item, row.sourceName)!,
                            style: TextStyle(
                              fontSize: 12,
                              color: LumeTheme.muted,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right, size: 20),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildFooter(int? count) {
    final text = _loadingMore
        ? '正在加载…'
        : count != null
            ? (_aggregateFailed == 0
                ? '共 $count 条'
                : '共 $count 条（$_aggregateFailed 个源没取到）')
            : null;
    if (text == null) return const SizedBox(height: 8);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Center(
        child: Text(
          text,
          style: TextStyle(fontSize: 12, color: LumeTheme.muted),
        ),
      ),
    );
  }
}
