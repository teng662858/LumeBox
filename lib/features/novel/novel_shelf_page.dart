import 'package:flutter/material.dart';

import '../../core/reading/reading.dart';
import '../../core/source/source.dart';
import '../../core/theme/lume_theme.dart';
import '../../shared/widgets/glass_card.dart';
import '../shell/shell_dock.dart';
import '../reading/poster_card.dart';
import '../shell/board_tabs.dart';
import 'novel_detail_page.dart';

/// 小说书架：网格 / 列表双视图，展示读到哪一章、本章读了百分之多少。
///
/// 小说不设未读角标（角标是漫画的口径）：小说的进度信息更有用的是
/// 「第几章 · 百分之多少」，直接写在卡片上比一个数字更清楚。
///
/// 视图偏好落本板块阅读库的 `reading_setting`（与排版参数同一张表、同一套
/// 隔离），下次进入书架沿用上次的选择——它属于「怎么看书」的用户习惯，
/// 不该每次进来重选。
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

  /// 视图偏好在本板块阅读库里的键（板块库各自独立，不会跨板块串）。
  static const String viewModeKey = 'novel.shelf.viewMode';

  @override
  State<NovelShelfPage> createState() => _NovelShelfPageState();
}

/// 书架展示形态。
///
/// 默认**列表**（与漫画书架相反，这是刻意的）：小说是文字内容，封面的信息量
/// 远不如「读到第几章、百分之多少」+ 一键续读；漫画才靠封面挑书。保持列表为
/// 默认也意味着老用户升级后看到的书架形态不变。
enum ShelfViewMode {
  grid('grid', '网格'),
  list('list', '列表');

  const ShelfViewMode(this.id, this.label);

  /// 落库标识（稳定，不随文案变）。
  final String id;

  /// 展示文案。
  final String label;

  /// 从落库值解析；认不出时回退到 [fallback]（默认列表）。
  static ShelfViewMode parse(
    String? value, {
    ShelfViewMode fallback = ShelfViewMode.list,
  }) {
    for (final mode in ShelfViewMode.values) {
      if (mode.id == value) return mode;
    }
    return fallback;
  }
}

class _NovelShelfPageState extends State<NovelShelfPage> {
  List<LibraryItem> _items = const <LibraryItem>[];
  Map<String, ReadingProgress> _progress = const <String, ReadingProgress>{};

  /// 当前视图；初值在 [initState] 里从库中读回。
  ShelfViewMode _viewMode = ShelfViewMode.list;

  @override
  void initState() {
    super.initState();
    _viewMode = ShelfViewMode.parse(
      widget.library.setting(NovelShelfPage.viewModeKey),
    );
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

  /// 切换视图并落库（只改展示形态，不动书架数据）。
  void _setViewMode(ShelfViewMode mode) {
    if (mode == _viewMode) return;
    widget.library.setSetting(NovelShelfPage.viewModeKey, mode.id);
    setState(() => _viewMode = mode);
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
    return Column(
      children: <Widget>[
        // 切换行不是滚动视图，自己让出玻璃顶栏（标题 + 页签条）的高度。
        SizedBox(
          height: GlassScaffold.barHeight(
            context,
            extra: BoardTabHeader.height,
          ),
        ),
        _buildViewToggle(),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () async => _reload(),
            child: _viewMode == ShelfViewMode.grid
                ? _buildGrid()
                : _buildList(),
          ),
        ),
      ],
    );
  }

  /// 视图切换：两个图标按钮，选中态用品牌紫表达（与页签条同一套视觉口径）。
  Widget _buildViewToggle() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: <Widget>[
          for (final mode in ShelfViewMode.values)
            IconButton(
              tooltip: mode.label,
              visualDensity: VisualDensity.compact,
              icon: Icon(
                mode == ShelfViewMode.grid
                    ? Icons.grid_view_rounded
                    : Icons.view_list_rounded,
                size: 20,
                color: _viewMode == mode ? LumeTheme.accent : LumeTheme.textSecondary,
              ),
              onPressed: () => _setViewMode(mode),
            ),
        ],
      ),
    );
  }

  /// 网格视图：3 列海报（与漫画书架同口径，跨板块手感一致）。
  Widget _buildGrid() {
    return GridView.builder(
      padding: EdgeInsets.fromLTRB(
        16,
        8,
        16,
        // 滚到最末才让出悬浮 Dock 那一段。
        24 + ShellDockScope.bottomInset(context),
      ),
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
          footnote: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                item.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
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
                style: TextStyle(fontSize: 10, color: LumeTheme.muted),
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
    );
  }

  /// 列表视图：横向卡片，进度与「续读」按钮一眼可见（信息量比网格大）。
  Widget _buildList() {
    return ListView.separated(
      padding: EdgeInsets.fromLTRB(
        16,
        8,
        16,
        // 滚到最末才让出悬浮 Dock 那一段。
        24 + ShellDockScope.bottomInset(context),
      ),
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
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: LumeTheme.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        progress?.describe() ?? '共 ${item.chapterCount} 章',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
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
                  Icon(Icons.chevron_right, color: LumeTheme.muted),
              ],
            ),
          ),
        );
      },
    );
  }
}
