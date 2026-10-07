import 'package:flutter/material.dart';

import '../../core/reading/reading.dart';
import '../../core/session/section.dart';
import '../../core/theme/lume_theme.dart';
import '../../shared/widgets/glass_card.dart';
import '../../shared/widgets/notice_card.dart';

/// 历史抽屉：在底部 Sheet 里浏览本板块的播放 / 阅读记录。
///
/// 为什么是抽屉而不是整页（真机反馈）：右上角的时钟图标是「随手看一眼就回去」
/// 的入口，整页跳转会打断浏览；抽屉从底部升起、下拉即关，三个板块共用同一套。
///
/// 数据来自本板块的阅读库（`sections/<板块>/reading.db`）：一条记录 = 书架条目
/// + 一条进度（视频 / 小说 / 漫画三种形状），按最近更新倒序。**跨板块不可见**：
/// 每个板块只看到自己库里的记录。
///
/// 删除能力按板块区分（有意为之）：
/// - 视频：抽屉里可以删单条 / 清空全部——视频的「书架」就等于播放记录，
///   清掉不会丢别的东西；
/// - 小说 / 漫画：抽屉**只读**（浏览 + 点开）。它们的书架是用户的书库/收藏，
///   顺手清空会把收藏一起抹掉；要删请到书架长按（那里有明确的操作语义）。
Future<void> showReadingHistorySheet({
  required BuildContext context,
  required Section section,
  required ReadingLibrary library,
  required void Function(LibraryItem item, ReadingProgress progress) onResume,
  DateTime Function()? clock,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (_) => ReadingHistorySheet(
      section: section,
      library: library,
      onResume: onResume,
      clock: clock,
    ),
  );
}

/// 历史抽屉本体（可单独嵌入测试）。
class ReadingHistorySheet extends StatefulWidget {
  const ReadingHistorySheet({
    super.key,
    required this.section,
    required this.library,
    required this.onResume,
    this.clock,
  });

  final Section section;

  /// 本板块阅读库（调用方打开，本组件不负责释放）。
  final ReadingLibrary library;

  /// 点某条：续看 / 续读（由调用方决定打开什么）。
  final void Function(LibraryItem item, ReadingProgress progress) onResume;

  /// 测试用时钟（相对时间的基准）；为空时取当前时间。
  final DateTime Function()? clock;

  /// 记录条数上限（本地库，量级有限）。
  static const int maxEntries = 500;

  @override
  State<ReadingHistorySheet> createState() => _ReadingHistorySheetState();
}

class _ReadingHistorySheetState extends State<ReadingHistorySheet> {
  List<({LibraryItem item, ReadingProgress progress})> _entries = const [];

  /// 只有视频板块在抽屉里提供删除（见 [showReadingHistorySheet] 的说明）。
  bool get _removable => widget.section == Section.video;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    setState(() {
      _entries = widget.library.continueReading(
        limit: ReadingHistorySheet.maxEntries,
      );
    });
  }

  /// 删除单条记录（连同书架条目：抽屉里删了就不该再出现在继续观看里）。
  void _remove(LibraryItem item) {
    widget.library.unshelve(item.itemId);
    _reload();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 1),
        content: Text('已删除「${item.title}」的记录'),
      ),
    );
  }

  /// 清空全部记录（二次确认；只清本板块的数据）。
  Future<void> _clearAll() async {
    if (_entries.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空播放历史'),
        content: Text(
          '将删除 ${_entries.length} 条播放记录（含「继续观看」列表）。\n'
          '其他板块的阅读记录、已保存的图片都不受影响。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    for (final entry in _entries) {
      widget.library.unshelve(entry.item.itemId);
    }
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    final now = (widget.clock ?? DateTime.now)();
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      child: DecoratedBox(
        decoration: LumeTheme.background,
        child: SafeArea(
          top: false,
          child: ConstrainedBox(
            // 抽屉最多占七成屏高：上面留出正在看的内容，一眼就知道还能关掉。
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.7,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 8, 8),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              '${widget.section.label} · 历史',
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                                color: LumeTheme.textPrimary,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '${_entries.length} 条记录 · 最近在前',
                              style: TextStyle(
                                fontSize: 12,
                                color: LumeTheme.muted,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (_removable && _entries.isNotEmpty)
                        IconButton(
                          tooltip: '清空历史',
                          icon: const Icon(Icons.delete_sweep_outlined),
                          onPressed: _clearAll,
                        ),
                      IconButton(
                        tooltip: '关闭',
                        icon: const Icon(Icons.close),
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                    ],
                  ),
                ),
                Flexible(child: _buildBody(now)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBody(DateTime now) {
    if (_entries.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: NoticeCard(
          title: '还没有记录',
          subtitle: widget.section == Section.video
              ? '从源列表点开一个视频，这里就会记下进度'
              : '从源列表打开一本作品读几页，这里就会记下进度',
        ),
      );
    }
    return ListView.separated(
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      itemCount: _entries.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final entry = _entries[index];
        return HistoryEntryTile(
          item: entry.item,
          progress: entry.progress,
          now: now,
          onResume: () => widget.onResume(entry.item, entry.progress),
          onRemove: _removable ? () => _remove(entry.item) : null,
        );
      },
    );
  }
}

/// 一条历史记录：标题 + 进度文案 + 相对时间 + 进度条。
///
/// 历史抽屉与视频播放历史页共用这一份，避免两处各长一副样子。
class HistoryEntryTile extends StatelessWidget {
  const HistoryEntryTile({
    super.key,
    required this.item,
    required this.progress,
    required this.now,
    required this.onResume,
    this.onRemove,
  });

  final LibraryItem item;
  final ReadingProgress progress;
  final DateTime now;
  final VoidCallback onResume;

  /// 删除这条记录；为空时不显示删除按钮（小说 / 漫画的抽屉只读）。
  final VoidCallback? onRemove;

  /// 进度条比例：只有算得出比例的形状才画（漫画是页位置，没有总页数）。
  static double? ratioOf(ReadingProgress progress) => switch (progress) {
        VideoProgress p => p.ratio,
        NovelProgress p => p.chapterLength > 0 ? p.chapterRatio : null,
        ComicProgress _ => null,
      };

  /// 是否已看完（只有视频有「看完」这个明确口径）。
  static bool isFinished(ReadingProgress progress) =>
      progress is VideoProgress && progress.isFinished;

  @override
  Widget build(BuildContext context) {
    final ratio = ratioOf(progress);
    final finished = isFinished(progress);
    return GlassCard(
      radius: 14,
      padding: EdgeInsets.fromLTRB(14, 12, onRemove == null ? 14 : 6, 12),
      onTap: onResume,
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        item.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: LumeTheme.textPrimary,
                        ),
                      ),
                    ),
                    Text(
                      relativeTime(now, progress.updatedAt),
                      style: TextStyle(fontSize: 11, color: LumeTheme.muted),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        progress.describe(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: LumeTheme.muted),
                      ),
                    ),
                    if (finished)
                      Text(
                        '已看完',
                        style: TextStyle(fontSize: 11, color: LumeTheme.muted),
                      ),
                  ],
                ),
                if (ratio != null) ...<Widget>[
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      value: ratio,
                      minHeight: 3,
                      backgroundColor: LumeTheme.fillStrong,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        finished ? LumeTheme.muted : LumeTheme.textPrimary,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (onRemove != null)
            IconButton(
              tooltip: '删除记录',
              icon: Icon(Icons.close, size: 18, color: LumeTheme.muted),
              onPressed: onRemove,
            ),
        ],
      ),
    );
  }

  /// 相对时间：刚刚 / N 分钟前 / N 小时前 / N 天前 / 具体日期。
  static String relativeTime(DateTime now, DateTime time) {
    final diff = now.difference(time);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
    if (diff.inHours < 24) return '${diff.inHours} 小时前';
    if (diff.inDays < 30) return '${diff.inDays} 天前';
    final local = time.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)}';
  }
}
