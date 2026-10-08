import 'package:flutter/material.dart';

import '../../core/net/waf.dart';
import '../../core/net/waf_auto_verify.dart';
import '../../core/source/source.dart';
import '../../core/theme/lume_theme.dart';
import '../../core/util/lume_log.dart';
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
    // 图源没实现这个可选契约：如实返回空表（页面据此提示「本源未提供筛选标签」）。
    return const <SourceFilterGroup>[];
  }
  final capable = source as FilterCapable;
  try {
    // 先问「脚本到底有没有 filters」：老脚本（比如大哥视频）没有这个入口，
    // 直接调会抛脚本错误，筛选页就变成一条红字报错（真机反馈的「筛选 2 页」问题）。
    if (!await capable.supportsFilters()) {
      cache.write(source.id, const <SourceFilterGroup>[]);
      return const <SourceFilterGroup>[];
    }
  } catch (error) {
    // 探测本身失败（引擎没起来等）按「没有标签」处理：宁可少一行标签，
    // 也不要让整页变成错误页。
    LumeLog.info('[filter] filters 支持探测失败，按「没有标签」处理：$error');
    return const <SourceFilterGroup>[];
  }
  try {
    final groups = await capable.filters();
    cache.write(source.id, groups);
    return groups;
  } on SourceException catch (error) {
    // 兜底：脚本运行期才暴露「没有实现 filters」时，同样按「没有标签」处理。
    if (error.message.contains('没有实现')) {
      cache.write(source.id, const <SourceFilterGroup>[]);
      return const <SourceFilterGroup>[];
    }
    rethrow;
  }
}

/// 筛选页（用户口径：**多行横向标签**，三板块共用）：
///
/// - **一行一个筛选维度**，每行横向可滚动（分类 / 剧集类型 / 题材 / 地区 / 年份…）；
///   分类那一行来自图源的 `categories()`，其余组来自 `filters()` 契约（**实时抓**）；
/// - 组内多选、组间叠加：所有选中的条件组合同时生效；
/// - 页面整体**垂直可滚动**（分组很多也不挤）；
/// - 底部固定「重置 / 应用筛选」两个按钮；
/// - 图源没有给任何标签 → 提示「本源未提供筛选标签」。
///
/// 不再有「先点一层分类列表再进标签页」那种树形点选（用户明确要求去掉）。
class SourceFilterPage extends StatefulWidget {
  const SourceFilterPage({
    super.key,
    required this.source,
    required this.cache,
    this.categoryId,
    this.categoryTitle,
    this.initial = const <String, String>{},
    this.originUrl = '',
  });

  final DataSource source;

  /// 图源的订阅地址（可选）：过 WAF 时用它兜底拿站点 origin。
  final String originUrl;

  /// 当前已选的一级分类（进入时高亮）；为空表示没选过。
  final String? categoryId;

  /// 当前分类标题（标题行展示用）。
  final String? categoryTitle;

  final SourceFilterCache cache;

  /// 进入时已有的选择（重进筛选页时保持已选项）。
  final Map<String, String> initial;

  @override
  State<SourceFilterPage> createState() => _SourceFilterPageState();
}

class _SourceFilterPageState extends State<SourceFilterPage> {
  List<SourceFilterGroup>? _groups;
  List<SourceCategory> _categories = const <SourceCategory>[];
  Object? _error;

  /// 已选分类（点「应用」时一起回传）。
  String? _categoryId;

  /// 组 id → 已选中的选项 id 集合（多选）。
  final Map<String, Set<String>> _selected = <String, Set<String>>{};

  @override
  void initState() {
    super.initState();
    _categoryId = widget.categoryId;
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
      // 分类失败不阻塞标签（分类是「分类」那一行，标签是各维度行）。
      var categories = const <SourceCategory>[];
      try {
        categories = await widget.source.categories();
      } catch (error) {
        LumeLog.info('[filter] 分类取不到，只显示标签组：$error');
      }
      final groups = await loadSourceFilters(
        source: widget.source,
        cache: widget.cache,
        force: force,
      );
      if (!mounted) return;
      setState(() {
        _categories = categories;
        _groups = groups;
      });
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

  void _reset() => setState(() {
        _selected.clear();
        _categoryId = null;
      });

  /// 分类标题（回传给宿主做提示 / 结果页标题）。
  String _titleOf(String? id) {
    if (id == null) return '全部';
    for (final category in _categories) {
      if (category.id == id) return category.title;
    }
    return id;
  }

  /// 用户显式发起的一次尝试（卡片上的【重试】）：**先武装，再重放**。
  ///
  /// 武装是给 [WafAutoVerify] 的一次性许可：这一次若仍被 WAF 拦下，自动验证小窗
  /// **不自动开验证窗**（用户口径，连续两轮）：验证窗只在用户点【网页视图】时
  /// 打开；点【重试】若仍被拦下，看到的还是这张错误卡。
  Future<void> _retry() => _load(force: true);

  /// 被 WAF 拦下时：内置网页视图过校验 → 存会话 → 重新加载标签（用户要求）。
  ///
  /// 与首页 / 探索页共用同一份流程（[runWafWebViewFlow]）：地址四层兜底，全落空时
  /// 弹地址输入框，开窗失败也会弹窗说明——**点了不会没反应**。
  Future<void> _openWebViewForWaf() async {
    final outcome = await runWafWebViewFlow(
      context: context,
      section: widget.source.section,
      sourceId: widget.source.id,
      sourceName: widget.source.name,
      failureMessage: '$_error',
      originUrl: widget.originUrl,
    );
    if (!mounted) return;
    switch (outcome) {
      case WafWebViewOutcome.notOpened:
        return;
      case WafWebViewOutcome.emptySession:
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('没取到会话：等验证通过、站点页面真正显示出来后再点 ✕ 关闭'),
          ),
        );
        return;
      case WafWebViewOutcome.collected:
        await _load(force: true);
    }
  }

  Map<String, String> get _filters => <String, String>{
        for (final entry in _selected.entries)
          if (entry.value.isNotEmpty) entry.key: entry.value.join(','),
      };

  /// 卡片末尾追加的「将打开哪个站」（用户口径：报错信息里要能看出拿到了源站地址）。
  /// 解析不出时返回空串——点击时的地址输入框会兜住，卡片上不写空话。
  String _targetHint() {
    final hint = webViewTargetHint(
      failureMessage: '$_error',
      sourceId: widget.source.id,
      originUrl: widget.originUrl,
    );
    return hint == null ? '' : '\n\n$hint';
  }

  @override
  Widget build(BuildContext context) {
    final groups = _groups;
    return GlassScaffold(
      behindBar: true,
      title: widget.categoryTitle == null
          ? '筛选'
          : '筛选 · ${widget.categoryTitle}',
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
                    subtitle: '${_error!}\n（筛选项来自源站；被防护拦下时点【重试】——'
                        '仍被拦会弹出校验窗，也可以直接点「网页视图」自己过一下'
                        '人机校验）${_targetHint()}',
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Wrap(
                      spacing: 10,
                      runSpacing: 8,
                      alignment: WrapAlignment.center,
                      children: <Widget>[
                        // 【重试】= 用户**显式发起**的一次尝试：先武装，这一次若仍被
                        // WAF 拦下，自动验证小窗才允许弹出来（进页面时自己拉的那一次
                        // 是被动加载，不弹窗，只给这张卡）。
                        OutlinedButton(
                          onPressed: _retry,
                          child: const Text('重试'),
                        ),
                        if (looksLikeWafFailure('$_error'))
                          OutlinedButton.icon(
                            onPressed: _openWebViewForWaf,
                            icon: const Icon(Icons.public, size: 18),
                            label: const Text('网页视图'),
                          ),
                      ],
                    ),
                  ),
                ]
                else if (groups == null)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 48),
                    child: Center(child: CircularProgressIndicator(strokeWidth: 2.5)),
                  )
                else if (groups.isEmpty && _categories.isEmpty)
                  // 用户口径 3：这里就是那句点名的提示。
                  const NoticeCard(
                    title: '本源未提供筛选标签',
                    subtitle: '图源脚本没有给出可筛选的维度。\n'
                        '不影响浏览与搜索，直接返回即可。',
                  )
                else ...<Widget>[
                  // 分类独立一行（与其它维度同样的横向标签样式）。
                  if (_categories.isNotEmpty) _buildCategoryRow(),
                  // 有分类、但没有标签维度（老脚本只写了 categories）：
                  // 分类行照旧可用，同时如实说明「没有更细的标签」——真机上这里
                  // 以前会因为 filters 抛错而整页变成脚本错误（用户截图）。
                  if (groups.isEmpty)
                    const NoticeCard(
                      title: '本源未提供筛选标签',
                      subtitle: '这个图源只给了分类，没有更细的筛选维度。\n'
                          '点上面的分类即可浏览。',
                    )
                  else
                    for (final group in groups) _buildGroup(group),
                ],
              ],
            ),
          ),
          _buildBottomBar(),
        ],
      ),
    );
  }

  /// 分类行：横向标签，单选（再点一次取消 → 回到「全部」）。
  Widget _buildCategoryRow() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(2, 0, 2, 8),
            child: Text(
              '分类',
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
              itemCount: _categories.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final category = _categories[index];
                final on = _categoryId == category.id;
                return ChoiceChip(
                  label: Text(category.title),
                  selected: on,
                  onSelected: (_) => setState(
                    () => _categoryId = on ? null : category.id,
                  ),
                );
              },
            ),
          ),
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
                    categoryId: _categoryId ?? '',
                    categoryTitle: _titleOf(_categoryId),
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

/// 打开筛选页（三板块共用）：**一个页面搞定**（分类一行 + 各标签组多行），
/// 应用后把 (分类 + 各组标签) 交回宿主。
///
/// 宿主拿到的结果直接喂给 `DataSource.list(categoryId:, filters:)`。
Future<({String? categoryId, Map<String, String> filters})?>
    openSourceFacetFilter({
  required BuildContext context,
  required DataSource source,
  String? currentCategoryId,
  String originUrl = '',
}) async {
  final selection = await Navigator.of(context).push<SourceFilterSelection>(
    MaterialPageRoute<SourceFilterSelection>(
      builder: (_) => SourceFilterPage(
        source: source,
        cache: SourceFilterCache.instance,
        categoryId: currentCategoryId,
        originUrl: originUrl,
      ),
    ),
  );
  if (selection == null) return null;
  return (categoryId: selection.categoryId, filters: selection.filters);
}
