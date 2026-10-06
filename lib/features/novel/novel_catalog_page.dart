import 'package:flutter/material.dart';

import '../../core/reading/reading.dart';
import '../../core/source/source.dart';
import '../../core/theme/lume_theme.dart';
import '../../shared/widgets/glass_card.dart';
import '../../shared/widgets/state_view.dart';
import 'novel_reader_page.dart';

/// 小说章节目录页：整本目录，可搜索章节、正序 / 倒序切换，当前章高亮，点章即读。
///
/// 与详情页的分工：详情页只展示「章节概览 + 前若干章」，完整目录归本页。
/// 章节序号在页面内部一律按正序下标处理，倒序只是展示顺序的翻转——
/// 阅读进度、阅读器的 chapterIndex 都用正序下标，两套顺序不会串。
/// 搜索同样只筛「显示哪些行」，行上带的仍是正序下标，因此搜索与倒序可以叠加。
class NovelCatalogPage extends StatefulWidget {
  const NovelCatalogPage({
    super.key,
    required this.library,
    required this.dataSource,
    required this.target,
    required this.chapters,
    required this.initialChapterIndex,
  });

  final ReadingLibrary library;

  /// 已打开并校验过板块归属的数据源。
  final DataSource dataSource;

  final ReadingTarget target;
  final List<SourceChapter> chapters;

  /// 打开时所处的章节（高亮它）。
  final int initialChapterIndex;

  @override
  State<NovelCatalogPage> createState() => _NovelCatalogPageState();
}

class _NovelCatalogPageState extends State<NovelCatalogPage> {
  bool _descending = false;

  /// 搜索开关与关键词。搜索框默认收起：目录页的主用途是「翻到某一章」，
  /// 一进来就占一行输入框会挤掉本就有限的目录可视区。
  bool _searching = false;
  String _keyword = '';
  final TextEditingController _searchController = TextEditingController();

  /// 从本页读到哪一章（读完返回时高亮跟着更新）。
  late int _current = widget.initialChapterIndex;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// 命中的章节下标（正序），已按 [_descending] 排好显示顺序。
  ///
  /// 关键词为空时返回全部——搜索与倒序正交，两者叠加而不是互相覆盖。
  List<int> get _visibleIndexes {
    final keyword = _keyword.trim().toLowerCase();
    final indexes = <int>[];
    for (var index = 0; index < widget.chapters.length; index++) {
      if (keyword.isNotEmpty &&
          !widget.chapters[index].title.toLowerCase().contains(keyword)) {
        continue;
      }
      indexes.add(index);
    }
    if (_descending) {
      return indexes.reversed.toList(growable: false);
    }
    return indexes;
  }

  void _toggleSearch() {
    setState(() {
      _searching = !_searching;
      if (!_searching) {
        // 收起搜索即清空关键词：下次打开是干净状态，不留下上次的过滤。
        _keyword = '';
        _searchController.clear();
      }
    });
  }

  Future<void> _open(int index) async {
    setState(() => _current = index);
    final progress = widget.library.novelProgress(widget.target.itemId);
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => NovelReaderPage(
          library: widget.library,
          dataSource: widget.dataSource,
          target: widget.target,
          chapters: widget.chapters,
          initialChapterIndex: index,
          // 点同一章时续读，点别的章从头开始。
          initialCharOffset: progress != null && progress.chapterIndex == index
              ? progress.charOffset
              : 0,
        ),
      ),
    );
    if (!mounted) return;
    final saved = widget.library.novelProgress(widget.target.itemId);
    if (saved != null) setState(() => _current = saved.chapterIndex);
  }

  @override
  Widget build(BuildContext context) {
    final visible = _visibleIndexes;
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: const Text('目录'),
        actions: <Widget>[
          IconButton(
            tooltip: _searching ? '收起搜索' : '搜索章节',
            icon: Icon(_searching ? Icons.search_off : Icons.search, size: 20),
            onPressed: _toggleSearch,
          ),
          TextButton.icon(
            onPressed: () => setState(() => _descending = !_descending),
            icon: Icon(
              _descending ? Icons.arrow_downward : Icons.arrow_upward,
              size: 16,
            ),
            label: Text(_descending ? '倒序' : '正序'),
          ),
        ],
      ),
      body: DecoratedBox(
        decoration: LumeTheme.background,
        child: Column(
          children: <Widget>[
            SizedBox(height: kToolbarHeight + MediaQuery.paddingOf(context).top),
            if (_searching) _buildSearchField(),
            Expanded(
              child: widget.chapters.isEmpty
                  ? const SourceStateView(
                      state: SourceStateKind.empty,
                      detail: '该源没有提供章节',
                    )
                  : visible.isEmpty
                      ? const SourceStateView(
                          state: SourceStateKind.empty,
                          detail: '没有匹配的章节',
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                          itemCount: visible.length,
                          itemBuilder: (context, position) {
                            final index = visible[position];
                            return _CatalogTile(
                              title: widget.chapters[index].title,
                              current: index == _current,
                              onTap: () => _open(index),
                            );
                          },
                        ),
            ),
          ],
        ),
      ),
    );
  }

  /// 搜索输入行：输入即筛（本地内存过滤，章节列表已在手上，不需要网络）。
  Widget _buildSearchField() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: TextField(
        controller: _searchController,
        autofocus: true,
        style: const TextStyle(fontSize: 14),
        decoration: InputDecoration(
          isDense: true,
          hintText: '搜索章节标题',
          prefixIcon: const Icon(Icons.search, size: 18),
          suffixIcon: _keyword.isEmpty
              ? null
              : IconButton(
                  tooltip: '清空',
                  icon: const Icon(Icons.clear, size: 18),
                  onPressed: () {
                    _searchController.clear();
                    setState(() => _keyword = '');
                  },
                ),
          border: const OutlineInputBorder(),
        ),
        onChanged: (value) => setState(() => _keyword = value),
      ),
    );
  }
}

/// 目录行：当前章加亮并标「在读」。
class _CatalogTile extends StatelessWidget {
  const _CatalogTile({
    required this.title,
    required this.current,
    required this.onTap,
  });

  final String title;
  final bool current;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: GlassCard(
        radius: 12,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
        onTap: onTap,
        child: Row(
          children: <Widget>[
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 14,
                  color: current ? Colors.white : LumeTheme.muted,
                  fontWeight: current ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
            if (current)
              const Text(
                '在读',
                style: TextStyle(fontSize: 11, color: Colors.white),
              ),
          ],
        ),
      ),
    );
  }
}

/// 章节概览行：详情页与目录入口共用同一套口径。
class NovelChapterSummary extends StatelessWidget {
  const NovelChapterSummary({
    super.key,
    required this.chapterCount,
    required this.progress,
  });

  final int chapterCount;
  final ReadingProgress? progress;

  @override
  Widget build(BuildContext context) {
    final saved = progress;
    return Text(
      saved == null
          ? '共 $chapterCount 章'
          : '共 $chapterCount 章 · 读至 ${saved.describe()}',
      style: const TextStyle(fontSize: 12, color: LumeTheme.muted),
    );
  }
}
