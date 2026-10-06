import 'package:flutter/material.dart';

import '../../core/reading/reading.dart';
import '../../core/session/section.dart';
import '../../core/theme/lume_theme.dart';
import '../../shared/widgets/glass_card.dart';
import '../../shared/widgets/notice_card.dart';

/// 视频播放历史页：本板块全部播放记录（不只「最近 10 条」）。
///
/// 首页的「继续观看」是快捷入口（只到最近 10 条），这里是完整列表：
/// 按最近播放倒序、显示剧集与时间点、可续看 / 单条删除 / 一键清空。
///
/// 数据全部来自本板块阅读库（`sections/video/reading.db`）：视频进度与阅读进度
/// 同表不同形状，靠板块与 [VideoProgress] 类型区分——因此这里只可能看到视频记录。
class VideoHistoryPage extends StatefulWidget {
  const VideoHistoryPage({
    super.key,
    required this.library,
    required this.onResume,
    this.clock,
  });

  /// 本板块阅读库（由调用方打开，本页不负责释放）。
  final ReadingLibrary library;

  /// 点某条续看。
  final void Function(LibraryItem item, VideoProgress progress) onResume;

  /// 测试用时钟（相对时间的基准）；为空时取当前时间。
  final DateTime Function()? clock;

  @override
  State<VideoHistoryPage> createState() => _VideoHistoryPageState();
}

class _VideoHistoryPageState extends State<VideoHistoryPage> {
  /// 记录条数上限：历史页给全部（本地库，量级有限）。
  static const int maxEntries = 500;

  List<({LibraryItem item, VideoProgress progress})> _entries = const [];

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    final entries = <({LibraryItem item, VideoProgress progress})>[];
    for (final item in widget.library.continueWatching(limit: maxEntries)) {
      final progress = widget.library.videoProgress(item.itemId);
      if (progress == null) continue;
      entries.add((item: item, progress: progress));
    }
    setState(() => _entries = entries);
  }

  /// 删除单条记录（连同书架条目：历史页删了就不该再出现在继续观看里）。
  void _remove(LibraryItem item) {
    widget.library.unshelve(item.itemId);
    _reload();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 1),
        content: Text('已删除「${item.title}」的播放记录'),
      ),
    );
  }

  /// 清空全部记录（二次确认；只清视频记录，不动其他板块数据）。
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
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已清空播放历史')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return GlassScaffold(
      title: '${Section.video.label} · 播放历史',
      actions: <Widget>[
        if (_entries.isNotEmpty)
          IconButton(
            tooltip: '清空历史',
            icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: _clearAll,
          ),
      ],
      child: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_entries.isEmpty) {
      return const NoticeCard(
        title: '还没有播放记录',
        subtitle: '从源列表点开一个视频，这里就会记下进度',
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: _entries.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final entry = _entries[index];
        return _HistoryTile(
          item: entry.item,
          progress: entry.progress,
          now: (widget.clock ?? DateTime.now)(),
          onResume: () => widget.onResume(entry.item, entry.progress),
          onRemove: () => _remove(entry.item),
        );
      },
    );
  }
}

/// 一条历史记录：标题 + 剧集/时间点 + 相对时间 + 进度条。
class _HistoryTile extends StatelessWidget {
  const _HistoryTile({
    required this.item,
    required this.progress,
    required this.now,
    required this.onResume,
    required this.onRemove,
  });

  final LibraryItem item;
  final VideoProgress progress;
  final DateTime now;
  final VoidCallback onResume;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final finished = progress.isFinished;
    return GlassCard(
      radius: 14,
      padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
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
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
                      ),
                    ),
                    Text(
                      _relativeTime(now, progress.updatedAt),
                      style: const TextStyle(
                        fontSize: 11,
                        color: LumeTheme.muted,
                      ),
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
                        style: const TextStyle(
                          fontSize: 12,
                          color: LumeTheme.muted,
                        ),
                      ),
                    ),
                    if (finished)
                      const Text(
                        '已看完',
                        style: TextStyle(fontSize: 11, color: LumeTheme.muted),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: progress.ratio,
                    minHeight: 3,
                    backgroundColor: Colors.white24,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      finished ? LumeTheme.muted : Colors.white,
                    ),
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: '删除记录',
            icon: const Icon(Icons.close, size: 18, color: LumeTheme.muted),
            onPressed: onRemove,
          ),
        ],
      ),
    );
  }

  /// 相对时间：刚刚 / N 分钟前 / N 小时前 / N 天前 / 具体日期。
  static String _relativeTime(DateTime now, DateTime time) {
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
