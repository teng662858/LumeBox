import '../../shared/widgets/network_owned_state.dart';
import '../../core/net/network_cancellation.dart';

import 'package:lume_box/shared/widgets/lume_icon.dart';

import '../../core/search/search_settings.dart';

import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/reading/browse_layout.dart';
import '../../core/reading/reading.dart';
import '../../core/session/section.dart';
import '../../core/session/privacy_settings.dart';
import '../../core/source/source.dart';
import '../../core/theme/lume_theme.dart';
import '../../core/util/lume_log.dart';
import '../../shared/widgets/glass_card.dart';
import '../../shared/widgets/frosted_glass_widget.dart';
import '../../shared/widgets/native_glass_preview.dart';
import '../../shared/widgets/state_view.dart';
import 'explore_view.dart';
import 'aggregate_search_results.dart';
import 'poster_card.dart';
import 'section_toolbar.dart';
import 'source_search_dialog.dart';
import '../source/waf_webview_page.dart';

/// 独立的**搜索结果页**（用户口径：搜索完必须离开首页推荐网格，跳到这里）。
///
/// 以前搜索是「就地替换首页网格」，于是三件事都出问题：首页推荐看起来没动、
/// 空结果和「这个源没有内容」分不清、也没有独立的加载 / 失败态。现在搜索是一段
/// 自成一体的流程：请求中 → 转圈；失败 → 错误提示 + 重试；命中 → 结果列表；
/// 一条都没有 → 「未搜索到相关内容」。
///
/// 三种板块共用本页（漫画 / 视频），两种范围共用同一套渲染：
/// - [SearchMode.aggregate]：并发问本板块选中的已启用源，逐条标注来源；
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
    this.sourceIds,
    this.onSourcesChanged,
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
  final Set<String>? sourceIds;
  final ValueChanged<Set<String>?>? onSourcesChanged;

  @override
  State<SearchResultsPage> createState() => _SearchResultsPageState();
}

class _SearchResultsPageState extends State<SearchResultsPage>
    with NetworkOwnedState<SearchResultsPage> {
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
  int _aggregateSiteCount = 0;
  int _aggregateCompleted = 0;
  List<SourceDescriptor> _aggregateSites = const [];
  Set<String> _completedSourceIds = const {};
  Set<String> _failedSourceIds = const {};
  String? _resolvedSourceId;
  String? _chosenSourceId;

  /// 结果里出现的图源名字（列表行显示来源用）。
  final Map<String, String> _sourceNames = <String, String>{};

  /// 当前源搜索的翻页状态。
  int _page = 1;
  bool _hasMore = false;
  bool _loadingMore = false;
  Object? _moreFailure;

  /// 请求代号：重试 / 翻页交错时丢弃过期结果。
  int _seq = 0;
  late Set<String>? _sourceIds = widget.sourceIds;
  late String _keyword = widget.keyword;

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  SourceManager get _manager =>
      widget.manager ?? LumeSources.manager(widget.section);

  Future<void> _run() async {
    try {
      networkRequests.cancelAll();
      await networkRequests.run('search', _runOwned);
    } on NetworkCancelled {
      // Leaving the page or replacing this load is not a source failure.
    }
  }

  Future<void> _retryFailed(Set<String> ids) async {
    if (_loading || ids.isEmpty) return;
    final seq = ++_seq;
    final selected = ids.intersection(_failedSourceIds);
    if (selected.isEmpty) return;
    final previousHits = _hits
        .where((hit) => !selected.contains(hit.sourceId))
        .toList();
    final previousCompleted = _completedSourceIds.difference(selected);
    final previousFailed = _failedSourceIds.difference(selected);
    setState(() {
      _loading = true;
      _completedSourceIds = previousCompleted;
      _failedSourceIds = previousFailed;
    });
    try {
      await networkRequests.run(
        'search',
        () => AggregateSearch.run(
          sources: _aggregateSites,
          sourceIds: selected,
          keyword: SearchSettings.instance.prepare(_keyword),
          open: _manager.open,
          onProgress: (progress) {
            if (!mounted || seq != _seq) return;
            final notRetried = selected.difference(
              progress.sources.map((site) => site.id).toSet(),
            );
            setState(() {
              _hits = [
                ...previousHits,
                ...progress.hits.where(
                  (hit) =>
                      SearchSettings.instance.accepts(hit.item.title, _keyword),
                ),
              ];
              _completedSourceIds = {
                ...previousCompleted,
                ...notRetried,
                ...progress.completedSourceIds,
              };
              _failedSourceIds = {
                ...previousFailed,
                ...notRetried,
                ...progress.failedSourceIds,
              };
              _aggregateFailed = _failedSourceIds.length;
              _aggregateCompleted = _completedSourceIds.length;
              _loading = progress.completed < progress.total;
            });
          },
        ),
      );
    } on NetworkCancelled {
      // The page was closed or a new search replaced this retry.
    } catch (error) {
      if (mounted && seq == _seq) {
        setState(() {
          _failedSourceIds = {
            ..._failedSourceIds,
            ...selected.difference(_completedSourceIds),
          };
          _aggregateFailed = _failedSourceIds.length;
          _loading = false;
        });
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('重试未完成：$error')));
      }
    }
  }

  Future<void> _verifySearch(String message) async {
    final id =
        _chosenSourceId ??
        widget.sourceId ??
        _resolvedSourceId ??
        (await _manager.current())?.id;
    if (!mounted || id == null) return;
    final descriptors = await _manager.list();
    if (!mounted) return;
    final source = descriptors.where((item) => item.id == id).firstOrNull;
    if (source == null) return;
    final outcome = await runWafWebViewFlow(
      context: context,
      section: widget.section,
      sourceId: id,
      sourceName: source.name,
      failureMessage: message,
      originUrl: source.originUrl,
    );
    if (!mounted) return;
    if (outcome == WafWebViewOutcome.collected) {
      await _run();
    } else if (outcome == WafWebViewOutcome.emptySession) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('未取得验证会话，请完成验证后再关闭网页')));
    }
  }

  Future<void> _chooseSingleSource() async {
    try {
      final sources = (await _manager.list())
          .where(
            (source) =>
                source.enabled &&
                PrivacySettings.instance.allowsSource(source.id, source.name),
          )
          .toList();
      if (!mounted) return;
      final selected = await showDialog<String>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('选择搜索站点'),
          content: SizedBox(
            width: double.maxFinite,
            child: sources.isEmpty
                ? const Text('没有可用站点')
                : ListView.builder(
                    shrinkWrap: true,
                    itemCount: sources.length,
                    itemBuilder: (_, index) => ListTile(
                      title: Text(sources[index].name),
                      onTap: () =>
                          Navigator.pop(dialogContext, sources[index].id),
                    ),
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('取消'),
            ),
          ],
        ),
      );
      if (selected == null || !mounted) return;
      _chosenSourceId = selected;
      await _run();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('读取站点失败：$error')));
      }
    }
  }

  Future<void> _runOwned() async {
    final seq = ++_seq;
    setState(() {
      _loading = true;
      _failure = null;
      _hits = const <SearchHit>[];
      _items = const <SourceItem>[];
      _page = 1;
      _hasMore = false;
      _loadingMore = false;
      _moreFailure = null;
      _aggregateFailed = 0;
      _aggregateSiteCount = 0;
      _aggregateCompleted = 0;
      _aggregateSites = const [];
      _completedSourceIds = const {};
      _failedSourceIds = const {};
      _sourceNames.clear();
    });
    try {
      if (widget.mode == SearchMode.aggregate) {
        final sources = await _manager.list();
        if (!mounted || seq != _seq) return;
        await AggregateSearch.run(
          sources: sources,
          sourceIds: _sourceIds,
          keyword: SearchSettings.instance.prepare(_keyword),
          open: (sourceId) => _manager.open(sourceId),
          onProgress: (progress) {
            if (!mounted || seq != _seq) return;
            setState(() {
              _hits = progress.hits
                  .where(
                    (hit) => SearchSettings.instance.accepts(
                      hit.item.title,
                      _keyword,
                    ),
                  )
                  .toList();
              _aggregateSites = progress.sources;
              _completedSourceIds = progress.completedSourceIds;
              _failedSourceIds = progress.failedSourceIds;
              _aggregateFailed = progress.failed;
              _aggregateSiteCount = progress.total;
              _aggregateCompleted = progress.completed;
              _loading = progress.completed < progress.total;
            });
          },
        );
        return;
      }

      // 当前源搜索：与浏览页同一套 list(keyword:)。
      final sourceId =
          _chosenSourceId ??
          widget.sourceId ??
          _resolvedSourceId ??
          (await _manager.current())?.id;
      final DataSource? source = sourceId == null
          ? null
          : await _manager.open(sourceId);
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
      final result = await source.list(
        keyword: SearchSettings.instance.prepare(_keyword),
        page: 1,
      );
      if (!mounted || seq != _seq) return;
      setState(() {
        _resolvedSourceId = sourceId;
        _sourceNames[sourceId!] = source.name;
        _items = result.items
            .where(
              (item) => SearchSettings.instance.accepts(item.title, _keyword),
            )
            .toList();
        _hasMore = result.hasMore;
        _loading = false;
      });
    } on NetworkCancelled {
      rethrow;
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

  Future<void> _editKeyword() async {
    final library = await ReadingLibrary.open(widget.section);
    DataSource? suggestionSource;
    try {
      final id =
          _chosenSourceId ??
          widget.sourceId ??
          _resolvedSourceId ??
          (await _manager.current())?.id;
      if (id != null) suggestionSource = await _manager.open(id);
    } catch (_) {
      // Cached titles and history remain available if the source cannot open.
    }
    if (!mounted) return;
    final query = await showDialog<String>(
      context: context,
      builder: (_) => SourceSearchDialog(
        source: suggestionSource,
        candidateTitles: [for (final row in _rows) row.item.title],
        library: library,
        initialQuery: _keyword,
        title: widget.mode.label,
      ),
    );
    if (!mounted ||
        query == null ||
        query.trim().isEmpty ||
        query.trim() == _keyword) {
      return;
    }
    _keyword = query.trim();
    await _run();
  }

  Future<void> _chooseSources() async {
    try {
      final sources = await _manager.list();
      if (!mounted) return;
      final selection = await showSearchModeMenu(
        context,
        current: SearchMode.aggregate,
        sources: sources,
        sourceIds: _sourceIds,
        sitesOnly: true,
      );
      if (selection == null || !mounted) return;
      _sourceIds = selection.sourceIds;
      final library = ReadingLibrary.find(widget.section);
      if (library != null) SearchSourceSelectionStore(library).save(_sourceIds);
      widget.onSourcesChanged?.call(_sourceIds);
      await _run();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('读取搜索站点失败：$error')));
      }
    }
  }

  /// 翻页（只有当前源搜索有下一页；聚合搜索一次问全）。
  Future<void> _loadMore({bool retry = false}) async {
    try {
      if (_loading ||
          _loadingMore ||
          !_hasMore ||
          (_moreFailure != null && !retry)) {
        return;
      }
      await networkRequests.run('more', _loadMoreOwned);
    } on NetworkCancelled {
      // A superseded search no longer needs its next page.
    }
  }

  Future<void> _loadMoreOwned() async {
    if (_loading ||
        _loadingMore ||
        !_hasMore ||
        widget.mode == SearchMode.aggregate) {
      return;
    }
    final sourceId = _resolvedSourceId;
    if (sourceId == null) return;
    setState(() {
      _loadingMore = true;
      _moreFailure = null;
    });
    final seq = _seq;
    try {
      final source = await _manager.open(sourceId);
      final result = await source?.list(
        keyword: SearchSettings.instance.prepare(_keyword),
        page: _page + 1,
      );
      if (!mounted || seq != _seq) return;
      if (result == null) {
        throw const SourceException(
          SourceErrorKind.notFound,
          '当前源不可用，请切换或重新启用',
        );
      }
      setState(() {
        _page++;
        final seen = _items.map((item) => item.id).toSet();
        final fresh = result.items.where((item) => seen.add(item.id)).toList();
        _hasMore = result.hasMore && fresh.isNotEmpty;
        _loadingMore = false;
        _items = <SourceItem>[
          ..._items,
          ...fresh.where(
            (item) => SearchSettings.instance.accepts(item.title, _keyword),
          ),
        ];
      });
    } on NetworkCancelled {
      rethrow;
    } catch (error) {
      LumeLog.warn('[${widget.section.id}] 搜索翻页失败: $error');
      if (!mounted || seq != _seq) return;
      setState(() {
        _loadingMore = false;
        _moreFailure = error; // 保留下一页，等待用户明确重试。
      });
    }
  }

  /// 命中的条目数。
  int get _count =>
      widget.mode == SearchMode.aggregate ? _hits.length : _items.length;

  /// 条目 +（聚合时）它来自哪个源。
  List<({SourceItem item, String? sourceName, String? sourceId})> get _rows {
    if (widget.mode == SearchMode.aggregate) {
      return <({SourceItem item, String? sourceName, String? sourceId})>[
        for (final hit in _hits)
          (item: hit.item, sourceName: hit.sourceName, sourceId: hit.sourceId),
      ];
    }
    final name = _sourceNames.values.isEmpty ? null : _sourceNames.values.first;
    return <({SourceItem item, String? sourceName, String? sourceId})>[
      for (final item in _items)
        (item: item, sourceName: name, sourceId: _resolvedSourceId),
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
    return hours > 0
        ? '$hours:$minutes:$seconds'
        : '${value.inMinutes}:$seconds';
  }

  static String _date(DateTime value) {
    final local = value.toLocal();
    String two(int number) => number.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)}';
  }

  void _open(SourceItem item, String? sourceId) {
    if (sourceId == null) return;
    widget.onOpenItem(ExploreSelection(sourceId: sourceId, item: item));
  }

  @override
  Widget build(BuildContext context) => ModuleGlassScope(
    module: GlassModule.search,
    child: _legacyBuild(context),
  );
  Widget _legacyBuild(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Material(
        color: LumeTheme.base,
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
    final preview = NativeGlassPreview.enabledOf(context);
    final header = DecoratedBox(
      decoration: BoxDecoration(
        color: preview ? Colors.transparent : LumeTheme.glass,
        border: Border(bottom: BorderSide(color: LumeTheme.hairline)),
      ),
      child: Padding(
        padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
        child: SizedBox(
          height:
              (widget.mode == SearchMode.aggregate ? 52 : kToolbarHeight) *
              MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 2.0),
          child: Row(
            children: <Widget>[
              IconButton(
                tooltip: '返回',
                icon: const LumeIcon(
                  Icons.arrow_back,
                  slot: 'search_results_page.1',
                ),
                onPressed: () => Navigator.of(context).maybePop(),
              ),
              Expanded(
                child: Tooltip(
                  message: '修改关键词',
                  child: InkWell(
                    onTap: _editKeyword,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                '搜索 · $_keyword',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: widget.mode == SearchMode.aggregate
                                      ? 16
                                      : LumeTypography.sectionTitleSize,
                                  fontWeight: FontWeight.w600,
                                  color: LumeTheme.textPrimary,
                                ),
                              ),
                            ),
                            const SizedBox(width: 4),
                            const Icon(Icons.edit_outlined, size: 16),
                          ],
                        ),
                        if (widget.mode != SearchMode.aggregate)
                          Text(
                            _loading
                                ? (widget.mode == SearchMode.aggregate
                                      ? '正在搜索 $_aggregateCompleted/$_aggregateSiteCount 个站点 · $_count 条'
                                      : '正在搜索…')
                                : '${widget.mode.label} · $_count 条',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: LumeTypography.descriptionSize,
                              color: LumeTheme.descriptionColor,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              if (widget.mode == SearchMode.aggregate)
                TextButton.icon(
                  style: TextButton.styleFrom(
                    minimumSize: const Size(0, 36),
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    textStyle: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  onPressed: _chooseSources,
                  icon: const LumeIcon(
                    Icons.checklist,
                    slot: 'search_results_page.2',
                    size: 18,
                  ),
                  label: Text(
                    _sourceIds == null ? '站点' : '站点 ${_sourceIds!.length}',
                  ),
                ),
              const SizedBox(width: 12),
            ],
          ),
        ),
      ),
    );
    return ClipRect(
      child: preview
          ? Stack(
              children: [
                const Positioned.fill(
                  child: FrostedGlassWidget(
                    nativeGlass: true,
                    radius: 0,
                    child: SizedBox.expand(),
                  ),
                ),
                header,
              ],
            )
          : header,
    );
  }

  Widget _buildBody() {
    if (_loading && _count == 0 && widget.mode == SearchMode.single) {
      return const SourceStateView(state: SourceStateKind.loading);
    }
    final failure = _failure;
    if (failure != null) {
      final detail = failure is SourceException ? failure.message : '$failure';
      return SourceStateView(
        state: stateForError(failure),
        detail: detail,
        onRetry: _run,
        action: widget.mode == SearchMode.single
            ? Wrap(
                spacing: 8,
                children: [
                  OutlinedButton(
                    onPressed: _chooseSingleSource,
                    child: const Text('换源搜索'),
                  ),
                  if (shouldOfferWebView(detail))
                    OutlinedButton.icon(
                      onPressed: () => _verifySearch(detail),
                      icon: const Icon(Icons.public),
                      label: const Text('打开网页验证'),
                    ),
                ],
              )
            : null,
      );
    }
    if (widget.mode == SearchMode.aggregate &&
        (_loading || _aggregateSites.isNotEmpty)) {
      return AggregateSearchResults(
        query: _keyword,
        section: widget.section,
        hits: _hits,
        sites: _aggregateSites,
        completed: _completedSourceIds,
        failed: _failedSourceIds,
        loading: _loading,
        pipeline: widget.pipeline,
        onOpen: (hit) => _open(hit.item, hit.sourceId),
        onRetry: () => unawaited(_run()),
        onRetryFailed: (ids) => unawaited(_retryFailed(ids)),
      );
    }
    if (_count == 0) {
      return SourceStateView(
        state: SourceStateKind.empty,
        // 用户点名的文案：搜不到就说搜不到，不跟「源里没内容」混为一谈。
        detail: widget.mode == SearchMode.aggregate && _aggregateSiteCount == 0
            ? '没有可用的已选站点，请重新选择搜索站点'
            : '未搜索到相关内容',
        title: _aggregateFailed > 0 ? '有 $_aggregateFailed 个源没取到' : null,
        onRetry: _run,
        action: widget.mode == SearchMode.single
            ? OutlinedButton(
                onPressed: _chooseSingleSource,
                child: const Text('换源搜索'),
              )
            : null,
      );
    }
    return Column(
      children: [
        if (_loading)
          LinearProgressIndicator(
            value: _aggregateSiteCount == 0
                ? null
                : _aggregateCompleted / _aggregateSiteCount,
          ),
        if (_aggregateFailed > 0)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text('$_aggregateFailed 个源未取得结果，其他来源正常显示'),
          ),
        Expanded(
          child: _mode == BrowseLayoutMode.list ? _buildList() : _buildGrid(),
        ),
        if (_moreFailure != null)
          TextButton.icon(
            onPressed: () => unawaited(_loadMore(retry: true)),
            icon: const Icon(Icons.refresh),
            label: const Text('加载下一页失败，点击重试'),
          )
        else if (_loadingMore)
          const LinearProgressIndicator(),
      ],
    );
  }

  /// 布局档：与探索页同一套偏好（用户选过的按板块记住）。
  BrowseLayoutMode get _mode =>
      BrowseLayoutSettings.instance.modeFor(widget.section) ??
      BrowseLayoutMode.grid3;

  Widget _buildGrid() {
    final rows = _rows;
    final horizontal = _mode == BrowseLayoutMode.list2;
    return LayoutBuilder(
      builder: (context, constraints) =>
          NotificationListener<ScrollNotification>(
            onNotification: (notification) {
              if (notification.metrics.extentAfter < 600) {
                unawaited(_loadMore());
              }
              return false;
            },
            child: GridView.builder(
              padding: EdgeInsets.fromLTRB(
                horizontal ? TwoColumnSourceLayout.sidePadding : 16,
                12,
                horizontal ? TwoColumnSourceLayout.sidePadding : 16,
                24,
              ),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: _mode.columns,
                mainAxisSpacing: horizontal
                    ? TwoColumnSourceLayout.rowSpacing
                    : 12,
                crossAxisSpacing: horizontal
                    ? TwoColumnSourceLayout.spacing
                    : 12,
                mainAxisExtent: horizontal
                    ? TwoColumnSourceLayout.itemExtent(
                        context,
                        TwoColumnSourceLayout.cellWidth(constraints.maxWidth),
                      )
                    : null,
                childAspectRatio: _mode.tileAspectRatio,
              ),
              itemCount: rows.length,
              itemBuilder: (context, index) {
                final row = rows[index];
                return PosterTile(
                  horizontal: _mode == BrowseLayoutMode.list2,
                  item: row.item,
                  pipeline: widget.pipeline,
                  meta: _metaOf(row.item, row.sourceName),
                  onTap: () => _open(row.item, row.sourceId),
                );
              },
            ),
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
            onTap: () => _open(row.item, row.sourceId),
            child: Row(
              children: <Widget>[
                SizedBox(
                  width: 56,
                  height: 76,
                  child: CoverThumb(
                    pipeline: widget.pipeline,
                    url: row.item.cover,
                    title: row.item.title,
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
                          fontSize: LumeTypography.titleSize,
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
                              fontWeight: FontWeight.w600,
                              fontSize: LumeTypography.descriptionSize,
                              color: LumeTheme.descriptionColor,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const LumeIcon(
                  Icons.chevron_right,
                  slot: 'search_results_page.3',
                  size: 20,
                ),
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
        ? (_loading
              ? '正在搜索 $_aggregateCompleted/$_aggregateSiteCount 个站点 · 已找到 $count 条'
              : _aggregateFailed == 0
              ? '共 $count 条'
              : '共 $count 条（$_aggregateFailed 个源没取到）')
        : null;
    if (text == null) return const SizedBox(height: 8);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Center(
        child: Text(
          text,
          style: TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: LumeTypography.descriptionSize,
            color: LumeTheme.descriptionColor,
          ),
        ),
      ),
    );
  }
}
