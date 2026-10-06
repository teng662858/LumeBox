import 'package:flutter/material.dart';

import '../../core/reading/reading.dart';
import '../../core/source/source.dart';
import '../../core/theme/lume_theme.dart';
import '../../shared/widgets/glass_card.dart';
import '../shell/board_tabs.dart';
import '../reading/poster_card.dart';
import 'comic_detail_page.dart';

/// 漫画书架：网格卡片，右上角是未读章节角标。
///
/// 角标口径只有一个来源——[LibraryItem.unreadChapters]：章节总数减去已读到的
/// 章节序号。章节总数由详情页同步进本板块的 reading.db，进度由阅读器写入，
/// 因此角标在「没进过详情页」时不会瞎猜（宁可不显示）。
///
/// 书架只读本板块的阅读库：条目、进度、封面缓存目录都在漫画板块之内。
class ComicShelfPage extends StatefulWidget {
  const ComicShelfPage({
    super.key,
    required this.library,
    required this.pipeline,
    required this.manager,
  });

  final ReadingLibrary library;

  /// 封面用的图片管线（由外壳页持有并负责释放）。
  final SectionImagePipeline pipeline;

  final SourceManager manager;

  @override
  State<ComicShelfPage> createState() => _ComicShelfPageState();
}

class _ComicShelfPageState extends State<ComicShelfPage> {
  List<LibraryItem> _items = const <LibraryItem>[];

  /// 每本书的进度（书架一次取出，避免逐格查询）。
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

  Future<void> _open(LibraryItem item) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ComicDetailPage(
          library: widget.library,
          manager: widget.manager,
          target: ReadingTarget(
            sourceId: item.sourceId,
            itemId: item.itemId,
            title: item.title,
            cover: item.cover,
            subtitle: item.subtitle,
          ),
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
      child: GridView.builder(
        // 让出玻璃顶栏（标题 + 页签条）：内边距随内容滚走，列表从栏下穿过。
        padding: GlassScaffold.barInset(context, extra: BoardTabHeader.height)
            .add(const EdgeInsets.fromLTRB(16, 12, 16, 24)),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          mainAxisSpacing: 14,
          crossAxisSpacing: 14,
          childAspectRatio: 0.58,
        ),
        itemCount: _items.length,
        itemBuilder: (context, index) {
          final item = _items[index];
          final progress = _progress[item.itemId];
          return PosterCard(
            onTap: () => _open(item),
            onLongPress: () => _confirmRemove(item),
            badge: UnreadBadge(count: item.unreadChapters),
            footnote: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  item.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    height: 1.25,
                    color: LumeTheme.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  progress?.describe() ?? '共 ${item.chapterCount} 章',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 10,
                    color: LumeTheme.muted,
                  ),
                ),
              ],
            ),
            child: PosterCover(
              pipeline: widget.pipeline,
              url: item.cover,
              width: 300,
            ),
          );
        },
      ),
    );
  }
}
