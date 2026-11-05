import 'aggregate_work_groups.dart';

import 'package:flutter/material.dart';

import '../../core/reading/reading.dart';
import '../../core/session/section.dart';
import '../../core/source/source.dart';
import 'poster_card.dart';
import 'section_toolbar.dart';
import 'aggregate_search_poster.dart';

enum _SiteLayout { grouped, top, left, merged }

/// Search presentation is local to the section and never starts new requests.
class AggregateSearchResults extends StatefulWidget {
  const AggregateSearchResults({
    super.key,
    required this.section,
    required this.hits,
    required this.sites,
    required this.completed,
    required this.failed,
    required this.loading,
    required this.onOpen,
    required this.onRetry,
    this.pipeline,
    this.query = '',
    this.onRetryFailed,
  });
  final Section section;
  final String query;
  final List<SearchHit> hits;
  final List<SourceDescriptor> sites;
  final Set<String> completed;
  final Set<String> failed;
  final bool loading;
  final ValueChanged<SearchHit> onOpen;
  final VoidCallback onRetry;
  final ValueChanged<Set<String>>? onRetryFailed;
  final SectionImagePipeline? pipeline;

  @override
  State<AggregateSearchResults> createState() => _AggregateSearchResultsState();
}

class _AggregateSearchResultsState extends State<AggregateSearchResults> {
  void _showFailures() {
    final failedSites = widget.sites
        .where((site) => widget.failed.contains(site.id))
        .toList();
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('搜索失败 · ${failedSites.length} 个站点'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final site in failedSites)
                ListTile(
                  title: Text(site.name),
                  trailing: TextButton(
                    onPressed: widget.onRetryFailed == null
                        ? null
                        : () {
                            Navigator.pop(dialogContext);
                            widget.onRetryFailed!({site.id});
                          },
                    child: const Text('重试'),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('关闭'),
          ),
          if (widget.onRetryFailed != null)
            FilledButton(
              onPressed: () {
                Navigator.pop(dialogContext);
                widget.onRetryFailed!(
                  failedSites.map((site) => site.id).toSet(),
                );
              },
              child: const Text('重试失败站点'),
            ),
        ],
      ),
    );
  }

  static const _layoutKey = 'search.results.siteLayout';
  static const _cardsKey = 'search.results.cards';
  static const _referenceVersionKey = 'search.results.threeColumnVersion';
  _SiteLayout _layout = _SiteLayout.left;
  bool _cards = true;
  String _sort = 'relevance';
  String? _selected;
  List<SearchHit>? _groupedHits;
  final _siteGroups = <String, List<SearchHit>>{};
  final _mergedCache = <String, List<List<SearchHit>>>{};

  void _prepareGroups() {
    if (identical(_groupedHits, widget.hits)) return;
    _groupedHits = widget.hits;
    _siteGroups.clear();
    _mergedCache.clear();
    for (final hit in widget.hits) {
      (_siteGroups[hit.sourceId] ??= []).add(hit);
    }
  }

  List<SourceDescriptor> get _visibleSites {
    final matching = widget.hits.map((hit) => hit.sourceId).toSet();
    return widget.sites
        .where(
          (site) =>
              matching.contains(site.id) ||
              (!widget.completed.contains(site.id) &&
                  !widget.failed.contains(site.id)),
        )
        .toList();
  }

  @override
  void initState() {
    super.initState();
    final library = ReadingLibrary.find(widget.section);
    // Adopt the requested reference once, then keep subsequent layout choices.
    if (library != null && library.setting(_referenceVersionKey) != '1') {
      library.setSetting(_layoutKey, 'left');
      library.setSetting(_cardsKey, 'true');
      library.setSetting(_referenceVersionKey, '1');
    }
    final saved = library?.setting(_layoutKey);
    _layout = _SiteLayout.values.firstWhere(
      (value) => value.name == saved,
      orElse: () => _SiteLayout.left,
    );
    _sort = library?.setting('search.results.workSort') ?? 'relevance';
    _cards = library?.setting(_cardsKey) != 'false';
  }

  @override
  void didUpdateWidget(covariant AggregateSearchResults oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_selected != null &&
        !_visibleSites.any((site) => site.id == _selected)) {
      _selected = null;
    }
  }

  void _configure(String value) {
    setState(() {
      if (value.startsWith('sort_')) {
        _sort = value.substring(5);
        _layout = _SiteLayout.merged;
      } else if (value == 'cards' || value == 'list') {
        _cards = value == 'cards';
      } else {
        _layout = _SiteLayout.values.byName(value);
      }
    });
    final library = ReadingLibrary.find(widget.section);
    library?.setSetting(_layoutKey, _layout.name);
    library?.setSetting(_cardsKey, '$_cards');
    library?.setSetting('search.results.workSort', _sort);
  }

  String _status(SourceDescriptor site, int count) {
    if (widget.failed.contains(site.id)) return '请求失败';
    if (!widget.completed.contains(site.id)) return '搜索中';
    return count == 0 ? '无结果' : '$count 条';
  }

  String _meta(SearchHit hit) {
    final duration = hit.item.duration;
    final updated = hit.item.updatedAt?.toLocal();
    String two(int value) => '$value'.padLeft(2, '0');
    return [
      '来源 ${hit.sourceName}',
      if (duration != null)
        '时长 ${duration.inMinutes}:${two(duration.inSeconds.remainder(60))}',
      if (updated != null)
        '更新 ${updated.year}-${two(updated.month)}-${two(updated.day)}',
      if (hit.item.subtitle?.trim().isNotEmpty == true) hit.item.subtitle!,
    ].join(' · ');
  }

  Widget _tile(SearchHit hit) => _cards
      ? AggregateSearchPoster(
          key: ValueKey('search-hit-${hit.sourceId}-${hit.item.id}'),
          hit: hit,
          pipeline: widget.pipeline,
          metadata: _meta(hit),
          onTap: () => widget.onOpen(hit),
        )
      : CompactSourceItemTile(
          key: ValueKey('search-hit-${hit.sourceId}-${hit.item.id}'),
          item: hit.item,
          pipeline: widget.pipeline,
          meta: _meta(hit),
          flat: true,
          showMenu: false,
          onTap: () => widget.onOpen(hit),
        );

  Widget _menu() => PopupMenuButton<String>(
    tooltip: '搜索结果布局',
    onSelected: _configure,
    icon: const Icon(Icons.view_quilt_outlined, size: 19),
    padding: const EdgeInsets.all(8),
    constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
    itemBuilder: (_) => [
      for (final entry in const {
        'grouped': '站点分组',
        'top': '顶部站点分类',
        'left': '左侧站点分类',
        'merged': '同名作品合并',
      }.entries)
        CheckedPopupMenuItem(
          height:
              48 * MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 2.0),
          value: entry.key,
          checked: _layout.name == entry.key,
          child: Text(entry.value),
        ),
      const PopupMenuDivider(),
      for (final option in const {
        'relevance': '按匹配度',
        'episodes': '按更新集数',
        'health': '按近期体检可用情况',
      }.entries)
        CheckedPopupMenuItem(
          value: 'sort_${option.key}',
          checked: _sort == option.key,
          child: Text(option.value),
        ),
      const PopupMenuDivider(),
      CheckedPopupMenuItem(
        height: 48 * MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 2.0),
        value: 'cards',
        checked: _cards,
        child: const Text('封面卡片'),
      ),
      CheckedPopupMenuItem(
        height: 48 * MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 2.0),
        value: 'list',
        checked: !_cards,
        child: const Text('简洁列表'),
      ),
    ],
  );

  Widget _sitePicker(
    Map<String, List<SearchHit>> groups, {
    required bool vertical,
  }) {
    final entries = <({String? id, String name, String detail})>[
      (id: null, name: '全部', detail: '${widget.hits.length} 条'),
      for (final site in _visibleSites)
        (
          id: site.id,
          name: site.name,
          detail: _status(site, groups[site.id]?.length ?? 0),
        ),
    ];
    return ListView.separated(
      key: ValueKey(vertical ? 'search-sites-left' : 'search-sites-top'),
      scrollDirection: vertical ? Axis.vertical : Axis.horizontal,
      padding: vertical
          ? const EdgeInsets.symmetric(vertical: 8)
          : const EdgeInsets.all(8),
      itemCount: entries.length,
      separatorBuilder: (context, _) => vertical
          ? Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Divider(
                height: 1,
                thickness: 1 / MediaQuery.devicePixelRatioOf(context),
                color: Theme.of(context).colorScheme.onSurface.withValues(
                  alpha: AggregateSearchLayout.siteSeparatorOpacity,
                ),
              ),
            )
          : const SizedBox(width: 6),
      itemBuilder: (context, index) {
        final entry = entries[index];
        final selected = entry.id == _selected;
        if (vertical) {
          final accent = Theme.of(context).colorScheme.primary;
          return Semantics(
            selected: selected,
            button: true,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              child: Tooltip(
                message: entry.name,
                child: Material(
                  borderRadius: BorderRadius.circular(
                    AggregateSearchLayout.siteRowRadius,
                  ),
                  clipBehavior: Clip.antiAlias,
                  color: selected
                      ? accent.withValues(
                          alpha: AggregateSearchLayout.selectedSiteOpacity,
                        )
                      : Colors.transparent,
                  child: InkWell(
                    key: ValueKey('search-filter-${entry.id ?? 'all'}'),
                    onTap: () => setState(() => _selected = entry.id),
                    child: Stack(
                      children: [
                        Container(
                          constraints: BoxConstraints(
                            minHeight:
                                AggregateSearchLayout.siteRowMinHeight *
                                MediaQuery.textScalerOf(context)
                                    .scale(1)
                                    .clamp(1.0, 2.0),
                          ),
                          padding: const EdgeInsets.fromLTRB(8, 6, 7, 6),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                entry.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12,
                                  height: 1.2,
                                  fontWeight: selected
                                      ? FontWeight.w600
                                      : FontWeight.w400,
                                  color: selected
                                      ? accent
                                      : Theme.of(context).colorScheme.onSurface,
                                ),
                              ),
                              const SizedBox(height: 1.5),
                              Text(
                                entry.detail,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 10.5,
                                  height: 1.2,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (selected)
                          Positioned(
                            left: 0,
                            top: 0,
                            bottom: 0,
                            child: Center(
                              child: Container(
                                key: const ValueKey(
                                  'search-selected-site-indicator',
                                ),
                                width: AggregateSearchLayout
                                    .selectedIndicatorWidth,
                                height: AggregateSearchLayout
                                    .selectedIndicatorHeight,
                                decoration: BoxDecoration(
                                  color: accent,
                                  borderRadius: BorderRadius.circular(2),
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
        return Semantics(
          selected: selected,
          button: true,
          child: Material(
            color: selected
                ? Theme.of(context).colorScheme.primaryContainer
                : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
            child: InkWell(
              key: ValueKey('search-filter-${entry.id ?? 'all'}'),
              borderRadius: BorderRadius.circular(12),
              onTap: () => setState(() => _selected = entry.id),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                child: vertical
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            entry.name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            entry.detail,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      )
                    : Center(child: Text('${entry.name} · ${entry.detail}')),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _empty() {
    final failed = _selected == null
        ? widget.failed.isNotEmpty
        : widget.failed.contains(_selected);
    final waiting =
        widget.loading &&
        (_selected == null || !widget.completed.contains(_selected));
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          waiting
              ? '正在搜索，结果将陆续显示…'
              : failed
              ? '部分站点请求失败，可刷新重试或更换搜索站点'
              : '未搜索到相关内容',
        ),
      ),
    );
  }

  Widget _flat(List<SearchHit> hits) {
    if (hits.isEmpty) return _empty();
    if (!_cards) {
      return ListView.separated(
        key: ValueKey('search-list-${_selected ?? 'all'}'),
        padding: const EdgeInsets.all(12),
        itemCount: hits.length,
        separatorBuilder: (_, _) => const Divider(height: 12),
        itemBuilder: (_, index) => _tile(hits[index]),
      );
    }
    return _grid(hits, key: ValueKey('search-grid-${_selected ?? 'all'}'));
  }

  Widget _grid(List<SearchHit> hits, {Key? key, bool embedded = false}) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final scale = MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 2.0);
        return GridView.builder(
          key: key,
          shrinkWrap: embedded,
          physics: embedded ? const NeverScrollableScrollPhysics() : null,
          padding: const EdgeInsets.all(AggregateSearchLayout.gridPadding),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: AggregateSearchLayout.columns,
            mainAxisExtent: AggregateSearchLayout.itemExtent(
              constraints.maxWidth,
              scale,
            ),
            crossAxisSpacing: AggregateSearchLayout.columnGap,
            mainAxisSpacing: AggregateSearchLayout.rowGap,
          ),
          itemCount: hits.length,
          itemBuilder: (_, index) => _tile(hits[index]),
        );
      },
    );
  }

  Widget _grouped(Map<String, List<SearchHit>> groups) {
    final visibleSites = _visibleSites;
    if (visibleSites.isEmpty) return _empty();
    final sites = [
      ...visibleSites.where((site) => groups[site.id]?.isNotEmpty == true),
      ...visibleSites.where((site) => groups[site.id]?.isNotEmpty != true),
    ];
    return ListView.builder(
      key: const ValueKey('search-groups'),
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      itemCount: sites.length,
      itemBuilder: (context, index) {
        final site = sites[index];
        final hits = groups[site.id] ?? const <SearchHit>[];
        return Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(
                  site.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                subtitle: Text(_status(site, hits.length)),
                trailing: hits.isEmpty ? null : const Icon(Icons.chevron_right),
                onTap: hits.isEmpty
                    ? null
                    : () => setState(() => _selected = site.id),
              ),
              if (hits.isNotEmpty && _cards)
                _grid(hits, embedded: true)
              else if (hits.isNotEmpty) ...[
                for (final hit in hits.take(3)) _tile(hit),
                if (hits.length > 3)
                  TextButton(
                    onPressed: () => setState(() => _selected = site.id),
                    child: Text('查看全部 ${hits.length} 条'),
                  ),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget mergedWorks(List<SearchHit> hits) {
    final cacheKey = '$_sort:${widget.query}:${_selected ?? ''}';
    if (_mergedCache.length >= 8 && !_mergedCache.containsKey(cacheKey)) {
      _mergedCache.remove(_mergedCache.keys.first);
    }
    final groups = _mergedCache.putIfAbsent(
      cacheKey,
      () => AggregateWorkGroups.group(
        hits,
        order: _sort,
        query: widget.query,
        library: ReadingLibrary.find(widget.section),
      ),
    );
    return ListView.builder(
      itemCount: groups.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) {
          return const Padding(
            padding: EdgeInsets.all(12),
            child: Text(
              '按完整片名与年份分组；请选择来源并核对季数、版本。',
              style: TextStyle(fontSize: 12),
            ),
          );
        }
        final group = groups[index - 1], first = groups[index - 1].first;
        return Card(
          child: ListTile(
            title: Text(first.item.title),
            subtitle: Text(
              '${group.map((e) => e.sourceId).toSet().length} 个来源 · ${first.item.subtitle ?? ''}',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => showModalBottomSheet<void>(
              context: context,
              isScrollControlled: true,
              builder: (context) => SafeArea(
                child: SizedBox(
                  height: MediaQuery.sizeOf(context).height * .6,
                  child: ListView(
                    children: [
                      for (final hit in group)
                        ListTile(
                          title: Text(hit.sourceName),
                          subtitle: Text(hit.item.subtitle ?? hit.item.title),
                          onTap: () {
                            Navigator.pop(context);
                            widget.onOpen(hit);
                          },
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    _prepareGroups();
    final groups = _siteGroups;
    final filtered = _selected == null
        ? widget.hits
        : groups[_selected] ?? const <SearchHit>[];
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 16, right: 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  widget.loading
                      ? '${widget.completed.length}/${widget.sites.length} 站点 · ${widget.hits.length} 条'
                      : _selected == null
                      ? '${widget.hits.length} 条结果 · ${_visibleSites.length} 个来源'
                      : '${widget.sites.where((s) => s.id == _selected).firstOrNull?.name ?? '所选站点'} · ${filtered.length} 条',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11.5,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              if (widget.failed.isNotEmpty)
                Tooltip(
                  message: '${widget.failed.length} 个源未取得结果，其他来源正常显示',
                  child: TextButton(
                    onPressed: widget.loading ? null : () => _showFailures(),
                    child: Text('失败 ${widget.failed.length}'),
                  ),
                ),
              IconButton(
                tooltip: '刷新搜索',
                onPressed: widget.onRetry,
                icon: const Icon(Icons.refresh, size: 19),
                padding: const EdgeInsets.all(8),
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
              ),
              _menu(),
            ],
          ),
        ),
        if (widget.loading)
          LinearProgressIndicator(
            value: widget.sites.isEmpty
                ? 0
                : widget.completed.length / widget.sites.length,
          ),
        if (_layout == _SiteLayout.top ||
            (_layout == _SiteLayout.grouped && _selected != null))
          SizedBox(
            height:
                68 * MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 2.0),
            child: _sitePicker(groups, vertical: false),
          ),
        Expanded(
          child: _layout == _SiteLayout.merged
              ? mergedWorks(filtered)
              : _layout == _SiteLayout.left
              ? LayoutBuilder(
                  builder: (context, constraints) => Row(
                    children: [
                      SizedBox(
                        width: AggregateSearchLayout.sidebarWidth(
                          constraints.maxWidth,
                        ),
                        child: _sitePicker(groups, vertical: true),
                      ),
                      VerticalDivider(
                        key: const ValueKey('search-sites-divider'),
                        width: AggregateSearchLayout.dividerSlotWidth,
                        thickness: 1 / MediaQuery.devicePixelRatioOf(context),
                        color: Theme.of(context).colorScheme.onSurface
                            .withValues(
                              alpha: AggregateSearchLayout.dividerOpacity,
                            ),
                      ),
                      Expanded(child: _flat(filtered)),
                    ],
                  ),
                )
              : _layout == _SiteLayout.grouped && _selected == null
              ? _grouped(groups)
              : _flat(filtered),
        ),
        if (!widget.loading && widget.hits.isEmpty && widget.failed.isEmpty)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('未搜索到相关内容，可修改关键词或搜索站点'),
          ),
      ],
    );
  }
}
