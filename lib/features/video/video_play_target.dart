/// 一次播放的「作品身份」：记进度需要它，手动贴地址时没有。
///
/// 视频板块的播放来源有两类：
/// - **图源条目**（含剧集）：有 sourceId / itemId / 剧集，能记进「继续观看」；
/// - **手动地址**：只有一个 URL，没有作品身份，不记进度（记了也无从还原）。
///
/// 这里只承载数据与少量格式化，不碰播放器与数据库。
class VideoPlayTarget {
  const VideoPlayTarget({
    required this.sourceId,
    required this.itemId,
    required this.title,
    required this.chapterIndex,
    required this.chapterId,
    required this.chapterTitle,
    this.cover,
  });

  /// 所属图源 id（本板块内）。
  final String sourceId;

  /// 作品在图源内的 id。
  final String itemId;

  /// 作品标题（继续观看列表的展示名）。
  final String title;

  /// 剧集序号（0 起）。直接起播的条目固定为 0（单集）。
  final int chapterIndex;

  final String chapterId;
  final String chapterTitle;

  final String? cover;

  /// 同一作品的同一集：用于判断「是不是又点开了刚才那一集」。
  bool isSameEpisode(VideoPlayTarget other) =>
      sourceId == other.sourceId &&
      itemId == other.itemId &&
      chapterIndex == other.chapterIndex;

  /// 播放器标题：作品 + 剧集（单集作品不重复显示）。
  String get mediaTitle =>
      chapterTitle.isEmpty || chapterTitle == title
          ? title
          : '$title · $chapterTitle';

  @override
  String toString() => 'VideoPlayTarget($sourceId, $itemId, 第${chapterIndex + 1}集)';
}
