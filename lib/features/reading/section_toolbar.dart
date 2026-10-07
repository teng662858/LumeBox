import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../core/reading/browse_layout.dart';
import '../../core/reading/reading.dart';
import '../../core/session/section.dart';
import '../../core/source/source.dart';
import '../../core/theme/lume_theme.dart';
import '../../core/util/lume_log.dart';
import '../../shared/widgets/glass_card.dart';
import 'source_bar.dart';

/// 排序方式（三个板块共用一套）。默认「默认」= 图源给的顺序，不改动。
///
/// 排序是**客户端**行为：只对**已经加载出来的这批条目**排序，不影响分页请求
/// （图源契约里没有排序参数，硬塞一个会变成「声称支持但没验证」）。
enum BrowseSort {
  none('none', '默认'),
  title('title', '标题'),
  duration('duration', '时长'),
  updated('updated', '更新时间');

  const BrowseSort(this.id, this.label);

  final String id;
  final String label;

  static BrowseSort fromId(String? id) {
    for (final sort in values) {
      if (sort.id == id) return sort;
    }
    return BrowseSort.none;
  }

  /// 对一批条目排序。**缺字段的条目永远排在后面**（不编造、不丢弃）。
  List<SourceItem> apply(List<SourceItem> items) {
    final sorted = List<SourceItem>.of(items);
    switch (this) {
      case BrowseSort.none:
        break;
      case BrowseSort.title:
        sorted.sort(
          (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
        );
      case BrowseSort.duration:
        sorted.sort((a, b) {
          final left = a.duration;
          final right = b.duration;
          if (left == null && right == null) return 0;
          if (left == null) return 1;
          if (right == null) return -1;
          return right.compareTo(left); // 长的在前
        });
      case BrowseSort.updated:
        sorted.sort((a, b) {
          final left = a.updatedAt;
          final right = b.updatedAt;
          if (left == null && right == null) return 0;
          if (left == null) return 1;
          if (right == null) return -1;
          return right.compareTo(left); // 新的在前
        });
    }
    return sorted;
  }
}

/// 搜索模式（用户点名的两种）。
enum SearchMode {
  aggregate('aggregate', '聚合搜索', '跨本板块全部已启用源统一搜索'),
  single('single', '当前源搜索', '只在当前选中的源内搜索');

  const SearchMode(this.id, this.label, this.detail);

  final String id;
  final String label;
  final String detail;
}

/// 一条搜索结果：条目 + 它来自哪个源（聚合搜索必须能说清来源）。
@immutable
class SearchHit {
  const SearchHit({
    required this.sourceId,
    required this.sourceName,
    required this.item,
  });

  final String sourceId;
  final String sourceName;
  final SourceItem item;
}

/// 聚合搜索：**并发**问本板块所有已启用的源，把结果合并回来。
///
/// 三条口径：
/// - 单个源失败只丢它自己（结果里带一条 failed 说明），其余照常返回；
/// - 结果按「源顺序」排列（保持用户看图源列表时的顺序感），不做跨源去重
///   （同名作品在不同源上就是不同条目，去重会把用户想切的源吃掉）；
/// - 不做串行等待：全部并发发出去，网络层自己的并发额度会兜住防封。
class AggregateSearch {
  AggregateSearch._();

  static Future<({List<SearchHit> hits, int failed})> run({
    required List<SourceDescriptor> sources,
    required Future<DataSource?> Function(String sourceId) open,
    required String keyword,
    String? categoryId,
    int limitPerSource = 30,
  }) async {
    final enabled = sources.where((source) => source.enabled).toList();
    final results = await Future.wait(
      enabled.map((descriptor) async {
        try {
          final source = await open(descriptor.id);
          if (source == null) return (descriptor: descriptor, list: null);
          // 分类筛选同样下发到每个源（图源的分类是它自己的维度）。
          final list = await source.list(
            categoryId: categoryId,
            keyword: keyword,
            page: 1,
          );
          return (descriptor: descriptor, list: list);
        } catch (error) {
          LumeLog.info('[search] 聚合搜索跳过 ${descriptor.name}：$error');
          return (descriptor: descriptor, list: null);
        }
      }),
    );

    final hits = <SearchHit>[];
    var failed = 0;
    for (final entry in results) {
      final list = entry.list;
      if (list == null) {
        failed++;
        continue;
      }
      for (final item in list.items.take(limitPerSource)) {
        hits.add(
          SearchHit(
            sourceId: entry.descriptor.id,
            sourceName: entry.descriptor.name,
            item: item,
          ),
        );
      }
    }
    return (hits: hits, failed: failed);
  }
}

/// 搜索历史（按板块分开存；也是「没有 suggest 接口的源」的联想词来源）。
///
/// 存储直接用本板块阅读库的 settings 表（`reading_setting`），与浏览布局偏好同一层：
/// 搜索历史是本地偏好，不是新数据源。
class SearchHistoryStore {
  const SearchHistoryStore(this._section, this._library);

  final Section _section;
  final ReadingLibrary _library;

  /// 最多记住多少条（用户点名联想最多展示 8–10 条，历史留 20 条够挑）。
  static const int maxEntries = 20;

  static String keyFor(Section section) => 'search.history.${section.id}';

  List<String> load() {
    final raw = _library.setting(keyFor(_section));
    if (raw == null || raw.trim().isEmpty) return const <String>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const <String>[];
      return decoded
          .map((item) => '$item'.trim())
          .where((item) => item.isNotEmpty)
          .toList(growable: false);
    } catch (error) {
      LumeLog.warn('[search] 搜索历史解析失败：$error');
      return const <String>[];
    }
  }

  /// 记一条（去重后放最前，超出上限截断）。
  List<String> remember(String keyword) {
    final text = keyword.trim();
    if (text.isEmpty) return load();
    final next = <String>[
      text,
      for (final item in load())
        if (item != text) item,
    ].take(maxEntries).toList(growable: false);
    try {
      _library.setSetting(keyFor(_section), jsonEncode(next));
    } catch (error) {
      // 写不进去不影响搜索本身。
      LumeLog.warn('[search] 搜索历史写库失败：$error');
    }
    return next;
  }

  void clear() {
    try {
      _library.setSetting(keyFor(_section), jsonEncode(const <String>[]));
    } catch (error) {
      LumeLog.warn('[search] 搜索历史清空失败：$error');
    }
  }
}

/// 联想词来源：优先图源的 `suggest`，没实现就用本地搜索历史。
class SearchSuggestions {
  const SearchSuggestions({required this.source, required this.history});

  /// 当前源（可能没有 suggest 能力）。
  final DataSource? source;

  /// 本地搜索历史。
  final List<String> history;

  /// 最多给几条（用户点名 8–10 条）。
  static const int maxEntries = 10;

  /// 取 [keyword] 的联想候选。
  ///
  /// 空输入不返回任何候选（用户点名「空输入不弹出」）。图源的 suggest 失败时
  /// **退回本地历史**——联想是输入辅助，绝不能因为服务端挂了就空着。
  Future<List<String>> forKeyword(String keyword) async {
    final text = keyword.trim();
    if (text.isEmpty) return const <String>[];
    final source = this.source;
    if (source is SuggestCapable) {
      try {
        final remote = await (source as SuggestCapable).suggest(text);
        final cleaned = _dedupe(remote, text);
        if (cleaned.isNotEmpty) return cleaned.take(maxEntries).toList();
      } catch (error) {
        LumeLog.info('[search] 联想接口失败，改用本地历史：$error');
      }
    }
    return _dedupe(history, text).take(maxEntries).toList();
  }

  /// 去重 + 只留包含关键词的 + 去掉与关键词本身相同的那条。
  static List<String> _dedupe(List<String> values, String keyword) {
    final seen = <String>{};
    final out = <String>[];
    for (final value in values) {
      final text = value.trim();
      if (text.isEmpty || text == keyword) continue;
      if (!text.toLowerCase().contains(keyword.toLowerCase())) continue;
      if (!seen.add(text)) continue;
      out.add(text);
    }
    return out;
  }
}

/// 板块浏览页的统一工具栏：**一行完整控件**，顺序固定（用户点名）：
/// 源选择下拉框 → 排序 → 布局切换 → 搜索 → 筛选。
///
/// 三个板块共用同一个组件，因此「换了板块还找得到那个按钮」这件事不需要靠记忆。
class SectionToolbar extends StatelessWidget {
  const SectionToolbar({
    super.key,
    required this.sources,
    required this.currentId,
    required this.onSelect,
    this.onManage,
    required this.sort,
    required this.onSortChanged,
    required this.layoutMode,
    required this.onLayoutChanged,
    required this.onSearch,
    required this.onFilter,
    this.filterActive = false,
    this.busy = false,
  });

  /// 本板块已启用的源。
  final List<SourceDescriptor> sources;
  final String? currentId;
  final ValueChanged<String> onSelect;

  /// 打开图源管理；为空时图源条里不显示这个入口（宿主顶栏已经有了）。
  final VoidCallback? onManage;
  final bool busy;

  final BrowseSort sort;
  final ValueChanged<BrowseSort> onSortChanged;

  final BrowseLayoutMode layoutMode;
  final ValueChanged<BrowseLayoutMode> onLayoutChanged;

  /// 点「搜索」：由宿主决定是弹模式菜单还是直接开搜索框。
  final VoidCallback onSearch;

  /// 点「筛选」：由宿主打开筛选抽屉。
  final VoidCallback onFilter;

  /// 当前是否有生效的筛选（按钮高亮）。
  final bool filterActive;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        // 1) 源选择下拉框
        Expanded(
          child: ReadingSourceBar(
            sources: sources,
            currentId: currentId,
            busy: busy,
            onSelect: onSelect,
            onManage: onManage ?? () {},
            showManage: onManage != null,
          ),
        ),
        const SizedBox(width: 8),
        // 2) 排序（当前档位在弹窗里选中；这里靠高亮表示「不是默认」）
        _ToolbarAction(
          icon: Icons.sort,
          tooltip: '排序',
          highlighted: sort != BrowseSort.none,
          onTap: () => _pickSort(context),
        ),
        // 3) 布局切换
        _ToolbarAction(
          icon: switch (layoutMode) {
            BrowseLayoutMode.list => Icons.view_list_outlined,
            BrowseLayoutMode.grid2 => Icons.grid_view_outlined,
            BrowseLayoutMode.grid3 => Icons.apps_outlined,
          },
          tooltip: '布局',
          highlighted: layoutMode != BrowseLayoutMode.grid3,
          onTap: () => _pickLayout(context),
        ),
        // 4) 搜索
        _ToolbarAction(
          icon: Icons.search,
          tooltip: '搜索',
          onTap: onSearch,
        ),
        // 5) 筛选
        _ToolbarAction(
          icon: Icons.filter_list,
          tooltip: '筛选',
          highlighted: filterActive,
          onTap: onFilter,
        ),
      ],
    );
  }

  Future<void> _pickSort(BuildContext context) async {
    final picked = await showModalBottomSheet<BrowseSort>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => _ToolbarSheet<BrowseSort>(
        title: '排序',
        current: sort,
        options: BrowseSort.values,
        labelOf: (value) => value.label,
        note: '只对已加载的条目排序（图源不提供排序参数）',
      ),
    );
    if (picked != null) onSortChanged(picked);
  }

  Future<void> _pickLayout(BuildContext context) async {
    final picked = await showModalBottomSheet<BrowseLayoutMode>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => _ToolbarSheet<BrowseLayoutMode>(
        title: '布局',
        current: layoutMode,
        options: BrowseLayoutMode.values,
        labelOf: (value) => value.label,
        // 副标题说清这一档长什么样（旧版探索页的读法，保持一致）。
        detailOf: (value) => value.hint,
      ),
    );
    if (picked != null) onLayoutChanged(picked);
  }
}

/// 工具栏上的圆角小按钮。
class _ToolbarAction extends StatelessWidget {
  const _ToolbarAction({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.highlighted = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 6),
      child: GlassCard(
        radius: 12,
        padding: EdgeInsets.zero,
        onTap: onTap,
        child: Tooltip(
          message: tooltip,
          child: SizedBox(
            width: 42,
            height: 42,
            child: Icon(
              icon,
              size: 20,
              color: highlighted ? LumeTheme.accent : LumeTheme.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

/// 工具栏用的选择弹窗（排序 / 布局 / 搜索模式共用一套外观）。
class _ToolbarSheet<T> extends StatelessWidget {
  const _ToolbarSheet({
    required this.title,
    required this.current,
    required this.options,
    required this.labelOf,
    this.detailOf,
    this.note,
  });

  final String title;
  final T current;
  final List<T> options;
  final String Function(T option) labelOf;
  final String Function(T option)? detailOf;
  final String? note;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      child: DecoratedBox(
        decoration: LumeTheme.background,
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    title,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: LumeTheme.textPrimary,
                    ),
                  ),
                ),
              ),
              for (final option in options)
                ListTile(
                  dense: true,
                  leading: Icon(
                    option == current
                        ? Icons.check_circle
                        : Icons.circle_outlined,
                    size: 20,
                    color: option == current
                        ? LumeTheme.accent
                        : LumeTheme.muted,
                  ),
                  title: Text(
                    labelOf(option),
                    style: TextStyle(color: LumeTheme.textPrimary),
                  ),
                  subtitle: detailOf == null
                      ? null
                      : Text(
                          detailOf!(option),
                          style: TextStyle(
                            fontSize: 12,
                            color: LumeTheme.muted,
                          ),
                        ),
                  onTap: () => Navigator.of(context).pop(option),
                ),
              if (note != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 6),
                  child: Text(
                    note!,
                    style: TextStyle(fontSize: 11, color: LumeTheme.muted),
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

/// 打开「搜索模式」选择菜单（用户点名的两种模式）。
Future<SearchMode?> showSearchModeMenu(BuildContext context) {
  return showModalBottomSheet<SearchMode>(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (_) => _ToolbarSheet<SearchMode>(
      title: '搜索范围',
      current: SearchMode.single,
      options: SearchMode.values,
      labelOf: (mode) => mode.label,
      detailOf: (mode) => mode.detail,
    ),
  );
}
