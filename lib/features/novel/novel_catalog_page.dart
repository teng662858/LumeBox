import 'package:flutter/material.dart';

import '../../core/reading/reading.dart';
import '../../core/source/source.dart';
import '../../core/theme/lume_theme.dart';
import '../../shared/widgets/glass_card.dart';
import '../../shared/widgets/state_view.dart';
import 'novel_reader_page.dart';

/// 小说章节目录页：整本目录，正序 / 倒序可切换，当前章高亮，点章即读。
///
/// 与详情页的分工：详情页只展示「章节概览 + 前若干章」，完整目录归本页。
/// 章节序号在页面内部一律按正序下标处理，倒序只是展示顺序的翻转——
/// 阅读进度、阅读器的 chapterIndex 都用正序下标，两套顺序不会串。
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

  /// 从本页读到哪一章（读完返回时高亮跟着更新）。
  late int _current = widget.initialChapterIndex;

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
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: const Text('目录'),
        actions: <Widget>[
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
        child: widget.chapters.isEmpty
            ? const SourceStateView(
                state: SourceStateKind.empty,
                detail: '该源没有提供章节',
              )
            : ListView.builder(
                padding: EdgeInsets.fromLTRB(
                  16,
                  kToolbarHeight + MediaQuery.paddingOf(context).top + 8,
                  16,
                  24,
                ),
                itemCount: widget.chapters.length,
                itemBuilder: (context, position) {
                  final index = _descending
                      ? widget.chapters.length - 1 - position
                      : position;
                  return _CatalogTile(
                    title: widget.chapters[index].title,
                    current: index == _current,
                    onTap: () => _open(index),
                  );
                },
              ),
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
