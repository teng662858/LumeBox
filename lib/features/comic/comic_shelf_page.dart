import '../../core/reading/reading_identity.dart';
import '../../core/source/source_picker_groups.dart';
import '../source/source_entry_order_sheet.dart';
import '../../shared/widgets/native_glass_surfaces.dart';

import 'package:flutter/material.dart';

import '../../core/reading/reading.dart';
import '../../core/reading/browse_layout.dart';
import '../../core/source/source.dart';
import '../../shared/widgets/glass_card.dart';
import '../shell/shell_dock.dart';
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
  String _kind = 'all';
  Map<String, String> _sourceKinds = {};
  List<LibraryItem> _items = const <LibraryItem>[];

  /// 每本书的进度（书架一次取出，避免逐格查询）。
  Map<String, ReadingProgress> _progress = const <String, ReadingProgress>{};

  @override
  void initState() {
    super.initState();
    _reload();
    _loadSourceKinds();
    widget.library.settingsRevision.addListener(_settingsChanged);
  }

  void _settingsChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.library.settingsRevision.removeListener(_settingsChanged);
    super.dispose();
  }

  Future<void> _loadSourceKinds() async {
    final sources = await widget.manager.list();
    if (mounted) {
      setState(
        () => _sourceKinds = {
          for (final source in sources)
            source.id: SourcePickerGroups.groupFor(
              widget.library.section,
              source,
            ),
        },
      );
    }
  }

  String _itemKind(LibraryItem item) {
    final identity = ReadingIdentity.key(item.sourceId, item.itemId);
    final progress = _progress[identity];
    if (progress is NovelProgress ||
        widget.library.setting('item.contentType.$identity') == 'novel') {
      return 'novel';
    }
    final source = _sourceKinds[item.sourceId] ?? 'comic';
    if (source == 'kazumi' ||
        source == 'audiobook' ||
        source == 'photo' ||
        source == 'novel') {
      return source;
    }
    return 'comic';
  }

  void _reload() {
    final items = widget.library.shelf();
    final progress = <String, ReadingProgress>{};
    for (final item in items) {
      final saved = widget.library.progress(
        item.itemId,
        sourceId: item.sourceId,
      );
      if (saved != null) {
        progress[ReadingIdentity.key(item.sourceId, item.itemId)] = saved;
      }
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
    // 返回时主动通知历史/收藏视图重新取数，再刷新本页。
    widget.library.refresh();
    _reload();
  }

  Future<void> _confirmRemove(LibraryItem item) async {
    final confirmed = await showGlassDialog<bool>(
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
    widget.library.unshelve(item.itemId, sourceId: item.sourceId);
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    if (_items.isEmpty) {
      return ShelfEmptyHint(
        title: '书架还是空的',
        subtitle: '去探索页找一本；阅读只会进历史，点「加入书架」才会收藏',
        action: FilledButton(
          onPressed: () {
            if (Navigator.of(context).canPop()) {
              Navigator.of(context).pop();
            } else {
              DefaultTabController.of(context).animateTo(0);
            }
          },
          child: const Text('去探索'),
        ),
      );
    }
    final items = _items
        .where((item) => _kind == 'all' || _itemKind(item) == _kind)
        .toList();
    return Column(
      children: [
        Padding(
          padding: GlassScaffold.barInset(
            context,
            extra: BoardTabHeader.height,
          ).add(const EdgeInsets.only(top: 8)),
          child: Row(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (final entry in [
                        ('all', '全部'),
                        ...SourcePickerGroups.forSection(
                          widget.library.section,
                        ),
                      ])
                        Padding(
                          padding: const EdgeInsets.only(left: 6),
                          child: ChoiceChip(
                            label: Text(entry.$2),
                            selected: _kind == entry.$1,
                            onSelected: (_) => setState(() => _kind = entry.$1),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              IconButton(
                tooltip: '调整分类顺序',
                icon: const Icon(Icons.swap_vert),
                onPressed: () => showSourceEntryOrder(
                  context,
                  section: widget.library.section,
                  settingKey: SourcePickerGroups.orderKey,
                  entries: SourcePickerGroups.forSection(
                    widget.library.section,
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: items.isEmpty
              ? const Center(child: Text('这一类还没有收藏'))
              : RefreshIndicator(
                  onRefresh: () async => _reload(),
                  child: GridView.builder(
                    // 让出玻璃顶栏（标题 + 页签条）：内边距随内容滚走，列表从栏下穿过。
                    padding: EdgeInsets.fromLTRB(
                      16,
                      12,
                      16,
                      // 滚到最末才真正让出悬浮 Dock 那一段（没滚到底不预留）。
                      24 + ShellDockScope.bottomInset(context),
                    ),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 3,
                          mainAxisSpacing: ThreeColumnPosterLayout.rowSpacing,
                          crossAxisSpacing: ThreeColumnPosterLayout.spacing,
                          childAspectRatio: .62,
                        ),
                    itemCount: items.length,
                    itemBuilder: (context, index) {
                      final item = items[index];
                      final progress =
                          _progress[ReadingIdentity.key(
                            item.sourceId,
                            item.itemId,
                          )];
                      return PosterCard(
                        onTap: () => _open(item),
                        onLongPress: () => _confirmRemove(item),
                        badge: UnreadBadge(count: item.unreadChapters),
                        footnoteBelow:
                            BrowseLayoutSettings.instance.gridTitleStyle ==
                            GridTitleStyle.below,
                        footnoteGap: ThreeColumnPosterLayout.titleGap,
                        footnotePadding: const EdgeInsets.symmetric(
                          horizontal: 2,
                        ),
                        footnote: PosterCaption(
                          title: item.title,
                          meta:
                              progress?.describe() ??
                              '共 ${item.chapterCount} 章',
                          overlay:
                              BrowseLayoutSettings.instance.gridTitleStyle ==
                              GridTitleStyle.overlay,
                        ),
                        child: PosterCover(
                          pipeline: widget.pipeline,
                          url: item.cover,
                          title: item.title,
                          width: 300,
                        ),
                      );
                    },
                  ),
                ),
        ),
      ],
    );
  }
}
