import 'package:flutter/material.dart';

import '../../core/source/source.dart';
import '../../core/theme/lume_theme.dart';
import '../../core/util/lume_log.dart';
import '../../shared/widgets/glass_card.dart';
import '../../shared/widgets/state_view.dart';
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
class BrowseView extends StatefulWidget {
  const BrowseView({super.key, required this.dataSource});

  final DataSource dataSource;

  @override
  State<BrowseView> createState() => _BrowseViewState();
}

class _BrowseViewState extends State<BrowseView> {
  final TextEditingController _search = TextEditingController();

  List<SourceCategory> _categories = const <SourceCategory>[];
  List<SourceItem> _items = const <SourceItem>[];
  String? _categoryId;
  String _keyword = '';
  bool _loading = true;

  /// 列表失败的原因（分类失败不算：拿不到分类就当图源没有分类）。
  Object? _failure;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
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

  /// 取第一页。分页语义已由接口的 [SourceList.hasMore] 预留，Phase1 不翻页。
  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failure = null;
    });
    try {
      final result = await widget.dataSource.list(
        categoryId: _categoryId,
        keyword: _keyword.isEmpty ? null : _keyword,
        page: 1,
      );
      if (!mounted) return;
      setState(() {
        _items = result.items;
        _loading = false;
      });
    } catch (error) {
      if (error is! SourceException) rethrow;
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failure = error;
      });
    }
  }

  void _selectCategory(String? categoryId) {
    if (_categoryId == categoryId) return;
    setState(() => _categoryId = categoryId);
    _load();
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
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
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
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      itemCount: _items.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final item = _items[index];
        return GlassCard(
          padding: const EdgeInsets.all(14),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) =>
                  DetailPage(dataSource: widget.dataSource, item: item),
            ),
          ),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
                    if (item.subtitle != null) ...<Widget>[
                      const SizedBox(height: 4),
                      Text(
                        item.subtitle!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          color: LumeTheme.muted,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: LumeTheme.muted),
            ],
          ),
        );
      },
    );
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
            color: selected ? Colors.white : LumeTheme.muted,
          ),
        ),
      ),
    );
  }
}
