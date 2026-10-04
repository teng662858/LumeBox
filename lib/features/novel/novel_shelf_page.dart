import 'package:flutter/material.dart';

import '../../core/reading/reading.dart';
import '../../core/source/source.dart';
import '../../core/theme/lume_theme.dart';
import '../../shared/widgets/glass_card.dart';
import '../reading/poster_card.dart';
import 'novel_detail_page.dart';

/// 小说书架：列表卡片，展示读到哪一章、本章读了百分之多少。
///
/// 小说不设未读角标（角标是漫画的口径）：小说的进度信息更有用的是
/// 「第几章 · 百分之多少」，直接写在卡片上比一个数字更清楚。
class NovelShelfPage extends StatefulWidget {
  const NovelShelfPage({
    super.key,
    required this.library,
    required this.pipeline,
    required this.manager,
  });

  final ReadingLibrary library;
  final SectionImagePipeline pipeline;
  final SourceManager manager;

  @override
  State<NovelShelfPage> createState() => _NovelShelfPageState();
}

class _NovelShelfPageState extends State<NovelShelfPage> {
  List<LibraryItem> _items = const <LibraryItem>[];
  Map<String, ReadingProgress> _progress = const <String, ReadingProgress>{};

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    final items = widget.library.shelf();
    final progress = <String, ReadingProgress>{};
    for (final item in items) {
      final saved = widget.library.progress(item.itemId);
      if (saved != null) progress[item.itemId] = saved;
    }
    setState(() {
      _items = items;
      _progress = progress;
    });
  }

  Future<void> _open(LibraryItem item, {bool resume = false}) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => NovelDetailPage(
          library: widget.library,
          manager: widget.manager,
          target: ReadingTarget(
            sourceId: item.sourceId,
            itemId: item.itemId,
            title: item.title,
            cover: item.cover,
            subtitle: item.subtitle,
          ),
          continueOnOpen: resume,
        ),
      ),
    );
    if (!mounted) return;
    _reload();
  }

  Future<void> _confirmRemove(LibraryItem item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('移出书架'),
        content: Text('把「${item.title}」移出书架？阅读进度也会一并清除。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('移出'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    widget.library.unshelve(item.itemId);
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    if (_items.isEmpty) {
      return ShelfEmptyHint(
        title: '书架还是空的',
        subtitle: '去探索页找一本，进详情即会留在书架上',
        action: FilledButton(
          onPressed: () => DefaultTabController.of(context).animateTo(1),
          child: const Text('去探索'),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: () async => _reload(),
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        itemCount: _items.length,
        separatorBuilder: (_, _) => const SizedBox(height: 10),
        itemBuilder: (context, index) {
          final item = _items[index];
          final progress = _progress[item.itemId];
          // 长按移出书架：卡片壳不带长按，这里补一层手势。
          return GestureDetector(
            onLongPress: () => _confirmRemove(item),
            child: GlassCard(
              radius: 14,
              padding: const EdgeInsets.all(10),
              onTap: () => _open(item),
              child: Row(
                children: <Widget>[
                  SizedBox(
                    width: 54,
                    height: 74,
                    child: PosterCover(
                      pipeline: widget.pipeline,
                      url: item.cover,
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
                          item.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          progress?.describe() ?? '共 ${item.chapterCount} 章',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12,
                            color: LumeTheme.muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (progress != null)
                    TextButton(
                      onPressed: () => _open(item, resume: true),
                      child: const Text('续读'),
                    )
                  else
                    const Icon(Icons.chevron_right, color: LumeTheme.muted),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
