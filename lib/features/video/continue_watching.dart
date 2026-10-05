import 'package:flutter/material.dart';

import '../../core/reading/reading.dart';
import '../../core/theme/lume_theme.dart';
import '../../shared/widgets/glass_card.dart';

/// 首页的「继续观看」区块：最近播放过的作品，带进度条与一键续看。
///
/// 只在有播放记录时出现（没有记录整块隐藏，不占首页版面）。每一条显示作品名、
/// 剧集与时间点、以及一个进度条；点整条即从上次位置继续。
///
/// 数据全部来自本板块的阅读库（`sections/video/reading.db`）：视频进度与其他
/// 板块的阅读进度同表不同形状，靠板块与 [VideoProgress] 类型区分。
class ContinueWatchingSection extends StatelessWidget {
  const ContinueWatchingSection({
    super.key,
    required this.library,
    required this.onResume,
    this.onRemove,
    this.onShowAll,
    this.maxItems = 10,
  });

  /// 本板块阅读库；为空时整块不显示（库没打开就没记录可读）。
  final ReadingLibrary? library;

  /// 点某一条：从上次位置继续。
  final void Function(LibraryItem item, VideoProgress progress) onResume;

  /// 移除记录（长按）。为空时不提供该操作。
  final void Function(LibraryItem item)? onRemove;

  /// 打开完整播放历史；为空时不显示「全部」入口。
  final VoidCallback? onShowAll;

  /// 最多显示几条。
  final int maxItems;

  @override
  Widget build(BuildContext context) {
    final entries = _entries();
    if (entries.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
          child: Row(
            children: <Widget>[
              const Expanded(
                child: Text(
                  '继续观看',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
              ),
              if (onShowAll != null)
                GestureDetector(
                  onTap: onShowAll,
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                    child: Text(
                      '全部',
                      style: TextStyle(fontSize: 13, color: LumeTheme.muted),
                    ),
                  ),
                ),
            ],
          ),
        ),
        for (final entry in entries)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _ContinueTile(
              item: entry.item,
              progress: entry.progress,
              onTap: () => onResume(entry.item, entry.progress),
              onRemove: onRemove == null ? null : () => onRemove!(entry.item),
            ),
          ),
      ],
    );
  }

  /// 读取条目：只取有视频进度的（没有记录的作品不出现）。
  List<({LibraryItem item, VideoProgress progress})> _entries() {
    final source = library;
    if (source == null) return const <({LibraryItem item, VideoProgress progress})>[];
    final result = <({LibraryItem item, VideoProgress progress})>[];
    for (final item in source.continueWatching(limit: maxItems)) {
      final progress = source.videoProgress(item.itemId);
      if (progress == null) continue;
      result.add((item: item, progress: progress));
    }
    return result;
  }
}

/// 一条继续观看：作品名 + 剧集与时间点 + 进度条。
///
/// 长按移除记录（与书架「长按删除」同一套手感）；点整条续播。
class _ContinueTile extends StatelessWidget {
  const _ContinueTile({
    required this.item,
    required this.progress,
    required this.onTap,
    this.onRemove,
  });

  final LibraryItem item;
  final VideoProgress progress;
  final VoidCallback onTap;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final finished = progress.isFinished;
    return GestureDetector(
      onLongPress: onRemove,
      child: _buildCard(finished),
    );
  }

  Widget _buildCard(bool finished) {
    return GlassCard(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
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
              if (finished)
                const Text(
                  '已看完',
                  style: TextStyle(fontSize: 12, color: LumeTheme.muted),
                )
              else
                const Icon(
                  Icons.play_circle_outline,
                  size: 20,
                  color: LumeTheme.muted,
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            progress.describe(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, color: LumeTheme.muted),
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
    );
  }
}
