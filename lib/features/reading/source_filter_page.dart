import 'package:flutter/material.dart';

import '../../core/net/waf.dart';
import '../../core/source/source.dart';
import '../../core/theme/lume_theme.dart';
import '../../shared/widgets/glass_card.dart';
import '../../shared/widgets/notice_card.dart';
import '../source/waf_webview_page.dart';

/// 分页筛选：一次选择的结果（一级分类 + 各组选中的标签）。三板块共用。
///
/// 组内多选时，选中的 id 以英文逗号相连交给脚本（`{type: '1,3', area: '2'}`）——
/// 脚本自己决定怎么拼站点查询串（各站点的参数名与分隔符都不一样）。
class SourceFilterSelection {
  const SourceFilterSelection({required this.categoryId, required this.categoryTitle, required this.filters});

  final String categoryId;
  final String categoryTitle;

  /// 组 id → 选中项 id（多个用逗号相连）；空组不进来。
  final Map<String, String> filters;

  bool get isEmpty => filters.isEmpty;

  /// 供按钮高亮 / 摘要用的简述。
  String describe() {
    if (filters.isEmpty) return categoryTitle;
    return '$categoryTitle · ${filters.length} 项筛选';
  }
}

/// 筛选标签的**短时缓存**（用户要求：每次打开实时抓，但加短时缓存减少重复请求）。
///
/// 应用级单例（[instance]）：三板块共用一份，按图源 id 分开存。
///
/// 按「板块内的图源 id」分开存；TTL 默认 5 分钟——标签是站点结构的一部分，
/// 几分钟内不会变，而每次进退筛选页都抓一遍纯属浪费。刷新（下拉）时按
/// [invalidate] 作废。
class SourceFilterCache {
  SourceFilterCache({this.ttl = const Duration(minutes: 5), DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  final Duration ttl;
  final DateTime Function() _clock;

  /// 应用级单例：`loadSourceFilters` 与筛选页都用它，避免各板块各存一份。
  static final SourceFilterCache instance = SourceFilterCache();

  final Map<String, ({List<SourceFilterGroup> groups, DateTime at})> _entries = {};

  List<SourceFilterGroup>? read(String sourceId) {
    final entry = _entries[sourceId];
    if (entry == null) return null;
    if (_clock().difference(entry.at) >= ttl) {
      _entries.remove(sourceId);
      return null;
    }
    return entry.groups;
  }

  void write(String sourceId, List<SourceFilterGroup> groups) {
    _entries[sourceId] = (groups: groups, at: _clock());
  }

  void invalidate(String sourceId) => _entries.remove(sourceId);

  void clear() => _entries.clear();

  int get size => _entries.length;
}

/// 取某图源的筛选标签：先看短时缓存，没有（或过期）再向脚本要。
Future<List<SourceFilterGroup>> loadSourceFilters({
  required DataSource source,
  required SourceFilterCache cache,
  bool force = false,
}) async {
  if (!force) {
    final cached = cache.read(source.id);
    if (cached != null) return cached;
  }
  if (source is! FilterCapable) {
    // 图源没实现这个可选契约：如实返回空表（页面据此提示「本源不支持筛选」）。
    return const <SourceFilterGroup>[];
  }
  final groups = await (source as FilterCapable).filters();
  cache.write(source.id, groups);
  return groups;
}

/// 视频筛选的**第一层页面**（用户要求：点右上角「筛选」直接跳到这里）。
///
/// 只列一级大分类（电影 / 电视剧 / 综艺 / 动漫 / 短剧——由**图源实时给出**，
/// 脚本里不许硬编码、App 也不内置一份）；点任意一个进入筛选子页。
///
/// 层级与返回：第一层 →（选分类）→ 第二层（标签）→ 应用后**整条链路一起返回**，
/// 把 (分类, 各组标签) 交回浏览页去拉列表。
class SourceFilterCategoryPage extends StatefulWidget {
  const SourceFilterCategoryPage({
    super.key,
    required this.source,
    required this.cache,
    this.currentCategoryId,
  });

  final DataSource source;
  final SourceFilterCache cache;

  /// 当前已选的一级分类（列表里打勾）。
  final String? currentCategoryId;

  @override
  State<SourceFilterCategoryPage> createState() =>
      _SourceFilterCategoryPageState();
}

class _SourceFilterCategoryPageState extends State<SourceFilterCategoryPage> {
  List<SourceCategory>? _categories;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final categories = await widget.source.categories();
      if (!mounted) return;
      setState(() => _categories = categories);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error);
    }
  }

  Future<void> _openCategory(SourceCategory category) async {
    final selection = await Navigator.of(context).push<SourceFilterSelection>(
      MaterialPageRoute<SourceFilterSelection>(
        builder: (_) => SourceFilterPage(
          source: widget.source,
          categoryId: category.id,
          categoryTitle: category.title,
          cache: widget.cache,
        ),
      ),
    );
    if (selection == null || !mounted) return;
    // 整条链路一起返回：浏览页只处理一个结果。
    Navigator.of(context).pop(selection);
  }

  @override
  Widget build(BuildContext context) {
    final categories = _categories;
    return GlassScaffold(
      behindBar: true,
      title: '筛选',
      child: ListView(
        padding: GlassScaffold.barInset(context).add(
          const EdgeInsets.fromLTRB(16, 8, 16, 16),
        ),
        children: <Widget>[
          if (_error != null)
            NoticeCard(
              title: '分类没取到',
              subtitle: '${_error!}\n（分类来自源站，网络恢复后点「重新加载」）',
            )
          else if (categories == null)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 48),
              child: Center(child: CircularProgressIndicator(strokeWidth: 2.5)),
            )
          else if (categories.isEmpty)
            const NoticeCard(
              title: '本源没有分类',
              subtitle: '图源脚本没有返回分类（categories 契约），无法筛选。',
            )
          else
            GlassCard(
              radius: 14,
              padding: EdgeInsets.zero,
              child: Column(
                children: <Widget>[
                  for (final category in categories)
                    ListTile(
                      title: Text(
                        category.title,
                        style: TextStyle(color: LumeTheme.textPrimary),
                      ),
                      trailing: Icon(
                        category.id == widget.currentCategoryId
                            ? Icons.check_circle
                            : Icons.chevron_right,
                        size: 20,
                        color: category.id == widget.currentCategoryId
                            ? LumeTheme.accent
                            : LumeTheme.muted,
                      ),
                      onTap: () => _openCategory(category),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// 视频筛选子页面（用户要求的「分页跳转模式」）：
///
/// - 一行一组标签（剧集类型 / 题材 / 地区 / 年份 / 语言…，由**脚本实时提供**）；
/// - 每组横向可滚动，标签可多选，组与组之间叠加生效；
/// - 底部「应用筛选 / 重置」；应用后把选择回传给浏览页去请求列表。
///
/// 第一版不做「左右双栏联动」（用户口径）：先只做这套分页跳转，后续版本再加
/// 一个设置项，让用户在「分页模式 / 双栏模式」之间自己选。
class SourceFilterPage extends StatefulWidget {
  const SourceFilterPage({
    super.key,
    required this.source,
    required this.categoryId,
    required this.categoryTitle,
    required this.cache,
    this.initial = const <String, String>{},
  });

  final DataSource source;
  final String categoryId;
  final String categoryTitle;
  final SourceFilterCache cache;

  /// 进入时已有的选择（重进筛选页时保持已选项）。
  final Map<String, String> initial;

  @override
  State<SourceFilterPage> createState() => _SourceFilterPageState();
}

class _SourceFilterPageState extends State<SourceFilterPage> {
  List<SourceFilterGroup>? _groups;
  Object? _error;

  /// 组 id → 已选中的选项 id 集合（多选）。
  final Map<String, Set<String>> _selected = <String, Set<String>>{};

  @override
  void initState() {
    super.initState();
    widget.initial.forEach((groupId, value) {
      final ids = value
          .split(',')
          .map((id) => id.trim())
          .where((id) => id.isNotEmpty);
      if (ids.isNotEmpty) _selected[groupId] = ids.toSet();
    });
    _load();
  }

  Future<void> _load({bool force = false}) async {
    setState(() => _error = null);
    try {
      final groups = await loadSourceFilters(
        source: widget.source,
        cache: widget.cache,
        force: force,
      );
      if (!mounted) return;
      setState(() => _groups = groups);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error);
    }
  }

  void _toggle(String groupId, String optionId) {
    setState(() {
      final set = _selected.putIfAbsent(groupId, () => <String>{});
      if (!set.remove(optionId)) set.add(optionId);
      if (set.isEmpty) _selected.remove(groupId);
    });
  }

  void _reset() => setState(_selected.clear);

  /// 被 WAF 拦下时：内置网页视图过校验 → 存会话 → 重新加载标签（用户要求）。
  Future<void> _openWebViewForWaf() async {
    final reason = '$_error';
    final url = originOf(urlFromFailure(reason));
    if (url == null) return;
    await showWafWebView(
      context: context,
      url: url,
      sourceName: widget.source.name,
    ).then((cookies) {
      if (cookies == null) return;
      WafSessions.save(widget.source.section, widget.source.id, cookies);
    });
    if (!mounted) return;
    await _load(force: true);
  }

  Map<String, String> get _filters => <String, String>{
        for (final entry in _selected.entries)
          if (entry.value.isNotEmpty) entry.key: entry.value.join(','),
      };

  @override
  Widget build(BuildContext context) {
    final groups = _groups;
    return GlassScaffold(
      behindBar: true,
      title: '筛选 · ${widget.categoryTitle}',
      child: Column(
        children: <Widget>[
          Expanded(
            child: ListView(
              padding: GlassScaffold.barInset(context).add(
                const EdgeInsets.fromLTRB(16, 8, 16, 16),
              ),
              children: <Widget>[
                if (_error != null) ...<Widget>[
                  NoticeCard(
                    title: '筛选标签没取到',
                    subtitle: '${_error!}\n（筛选项来自源站；被防护拦下时可点下面的'
                        '「网页视图」过一下人机校验）',
                  ),
                  if (looksLikeWafFailure('$_error'))
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: OutlinedButton.icon(
                        onPressed: _openWebViewForWaf,
                        icon: const Icon(Icons.public, size: 18),
                        label: const Text('网页视图'),
                      ),
                    ),
                ]
                else if (groups == null)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 48),
                    child: Center(child: CircularProgressIndicator(strokeWidth: 2.5)),
                  )
                else if (groups.isEmpty)
                  const NoticeCard(
                    title: '本源不支持筛选',
                    subtitle: '图源脚本没有提供筛选标签（filters 契约）。\n'
                        '这不影响浏览与搜索，直接返回即可。',
                  )
                else
                  for (final group in groups) _buildGroup(group),
              ],
            ),
          ),
          _buildBottomBar(),
        ],
      ),
    );
  }

  /// 一组标签：标题 + 一行横向可滚动标签（多选）。
  Widget _buildGroup(SourceFilterGroup group) {
    final selected = _selected[group.id] ?? const <String>{};
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(2, 0, 2, 8),
            child: Text(
              group.title,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: LumeTheme.textSecondary,
              ),
            ),
          ),
          SizedBox(
            height: 36,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: group.options.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final option = group.options[index];
                final on = selected.contains(option.id);
                return ChoiceChip(
                  label: Text(option.title),
                  selected: on,
                  onSelected: (_) => _toggle(group.id, option.id),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomBar() {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        child: Row(
          children: <Widget>[
            OutlinedButton(
              onPressed: _reset,
              child: const Text('重置'),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FilledButton(
                onPressed: () => Navigator.of(context).pop(
                  SourceFilterSelection(
                    categoryId: widget.categoryId,
                    categoryTitle: widget.categoryTitle,
                    filters: _filters,
                  ),
                ),
                child: Text(
                  _filters.isEmpty ? '应用（不筛选）' : '应用筛选（${_filters.length} 组）',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 打开「分页跳转筛选」整条链路（三板块共用）：
/// 第一层（一级分类）→ 第二层（标签组）→ 应用后把 (分类 + 各组标签) 交回宿主。
///
/// 宿主拿到的结果直接喂给 `DataSource.list(categoryId:, filters:)`。
Future<({String? categoryId, Map<String, String> filters})?>
    openSourceFacetFilter({
  required BuildContext context,
  required DataSource source,
  String? currentCategoryId,
}) async {
  final selection = await Navigator.of(context).push<SourceFilterSelection>(
    MaterialPageRoute<SourceFilterSelection>(
      builder: (_) => SourceFilterCategoryPage(
        source: source,
        cache: SourceFilterCache.instance,
        currentCategoryId: currentCategoryId,
      ),
    ),
  );
  if (selection == null) return null;
  return (categoryId: selection.categoryId, filters: selection.filters);
}
