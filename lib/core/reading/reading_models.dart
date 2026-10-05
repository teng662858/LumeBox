/// 阅读体系的数据模型：书架条目与阅读进度。
///
/// 模型自身不碰网络与脚本，只负责「库里的行 ↔ 内存对象」以及角标、进度这类
/// 纯计算。所有条目都带归属板块标记（[LibraryItem.section] / [ReadingProgress.section]），
/// 与打开它的板块不符的记录在读写两条路径上都被拒绝——库文件被挪到别的板块
/// 目录下也不会被误用。
///
/// 板块差异：漫画、小说、视频的进度形状不同（页位置 / 字符偏移 / 剧集+时间点），
/// 用密封类 [ReadingProgress] 的各支表达；读取方按板块断言具体类型，口径不会混用。
library;

import 'package:sqlite3/sqlite3.dart';

import '../session/section.dart';

/// 由稳定 id 反查板块；未知 id 返回 null。
Section? sectionFromId(String id) {
  for (final section in Section.values) {
    if (section.id == id) return section;
  }
  return null;
}

/// 阅读目标：一部作品 + 它来自哪个图源。
///
/// 详情页、阅读器、书架三处都用它传递「要读哪本书」，避免每个页面各自拼一串
/// `sourceId / itemId / title / cover` 参数。它只是数据，不含任何行为。
class ReadingTarget {
  const ReadingTarget({
    required this.sourceId,
    required this.itemId,
    required this.title,
    this.cover,
    this.subtitle,
  });

  /// 所属图源 id（本板块内）。
  final String sourceId;

  /// 作品在图源内的 id。
  final String itemId;

  final String title;
  final String? cover;
  final String? subtitle;

  @override
  String toString() => 'ReadingTarget($sourceId, $itemId, $title)';
}

/// 书架条目。漫画书架、小说书架共用同一形状，展示口径各自决定。
class LibraryItem {
  const LibraryItem({
    required this.section,
    required this.itemId,
    required this.sourceId,
    required this.title,
    required this.chapterCount,
    required this.readChapterIndex,
    required this.addedAt,
    required this.updatedAt,
    this.cover,
    this.subtitle,
  });

  /// 归属板块。
  final Section section;

  /// 作品在本板块图源内的 id。
  final String itemId;

  /// 加入书架时所用的图源 id。
  final String sourceId;

  final String title;
  final String? cover;
  final String? subtitle;

  /// 章节总数；0 表示尚未同步（还没进过详情页）。
  final int chapterCount;

  /// 已读到的章节序号（0 起）；-1 表示还没有阅读记录。
  final int readChapterIndex;

  final DateTime addedAt;

  /// 最近一次加入或阅读的时间。书架按它倒序，最近在读的自然浮到最前。
  final DateTime updatedAt;

  /// 未读章节数，漫画书架右上角角标的唯一口径。
  ///
  /// 章节总数未知（0）时返回 0：宁可不显示角标，也不显示编造的数字。
  int get unreadChapters {
    if (chapterCount <= 0) return 0;
    final unread = chapterCount - readChapterIndex - 1;
    return unread < 0 ? 0 : unread;
  }

  /// 已读到的章节序号（1 起）；没有阅读记录时为 0。
  int get readChapterOrdinal => readChapterIndex < 0 ? 0 : readChapterIndex + 1;

  LibraryItem copyWith({
    String? sourceId,
    String? title,
    String? cover,
    String? subtitle,
    int? chapterCount,
    int? readChapterIndex,
    DateTime? updatedAt,
  }) {
    return LibraryItem(
      section: section,
      itemId: itemId,
      sourceId: sourceId ?? this.sourceId,
      title: title ?? this.title,
      cover: cover ?? this.cover,
      subtitle: subtitle ?? this.subtitle,
      chapterCount: chapterCount ?? this.chapterCount,
      readChapterIndex: readChapterIndex ?? this.readChapterIndex,
      addedAt: addedAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  /// 从库行还原。归属标记非法（未知板块 id）时抛 [FormatException]，
  /// 由读取路径转成「记录不存在」，避免脏行被当成有效条目。
  factory LibraryItem.fromRow(Row row) {
    final section = sectionFromId(row['section'] as String);
    if (section == null) {
      throw FormatException('书架条目归属板块未知: ${row['section']}');
    }
    return LibraryItem(
      section: section,
      itemId: row['item_id'] as String,
      sourceId: row['source_id'] as String,
      title: row['title'] as String,
      cover: row['cover'] as String?,
      subtitle: row['subtitle'] as String?,
      chapterCount: row['chapter_count'] as int,
      readChapterIndex: row['read_chapter_index'] as int,
      addedAt: DateTime.fromMillisecondsSinceEpoch(row['added_at'] as int),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(row['updated_at'] as int),
    );
  }

  @override
  String toString() =>
      'LibraryItem(${section.id}, $itemId, $chapterCount章, '
      '未读$unreadChapters)';
}

/// 阅读进度基类。
///
/// 漫画与小说的进度形状不同，因此分两支；两支都带板块标记，且只在所属板块的
/// 库里读写。进度与书架条目分表存放：清空书架不应连带丢掉阅读记录，
/// 反之亦然。
sealed class ReadingProgress {
  const ReadingProgress({
    required this.section,
    required this.itemId,
    required this.chapterIndex,
    required this.chapterId,
    required this.chapterTitle,
    required this.updatedAt,
  });

  final Section section;
  final String itemId;

  /// 章节序号（0 起）。
  final int chapterIndex;

  final String chapterId;

  /// 章节标题快照：章节列表可能改名或消失，进度仍要能说清读到哪。
  final String chapterTitle;

  final DateTime updatedAt;

  /// 跳到另一章：章内位置归零（漫画回第 1 页，小说回字符 0，视频回 0:00）。
  ReadingProgress withChapter({
    required int chapterIndex,
    required String chapterId,
    required String chapterTitle,
  });

  /// 书架与详情页的进度文案。
  String describe();
}

/// 漫画进度：章节序号 + 当前页面位置。
final class ComicProgress extends ReadingProgress {
  const ComicProgress({
    required super.section,
    required super.itemId,
    required super.chapterIndex,
    required super.chapterId,
    required super.chapterTitle,
    required super.updatedAt,
    required this.page,
    this.pageFraction = 0,
  });

  /// 当前页序号（0 起）。
  final int page;

  /// 页内比例 0..1。条漫瀑布流下同一个「页」可能是长图的一部分，
  /// 用它在重新进入时把滚动位置还原到更细的粒度。
  final double pageFraction;

  @override
  ComicProgress withChapter({
    required int chapterIndex,
    required String chapterId,
    required String chapterTitle,
  }) {
    return ComicProgress(
      section: section,
      itemId: itemId,
      chapterIndex: chapterIndex,
      chapterId: chapterId,
      chapterTitle: chapterTitle,
      updatedAt: DateTime.now(),
      page: 0,
    );
  }

  @override
  String describe() => '第 ${chapterIndex + 1} 章 · 第 ${page + 1} 页';
}

/// 小说进度：章节索引 + 章节内文本字符偏移量。
final class NovelProgress extends ReadingProgress {
  const NovelProgress({
    required super.section,
    required super.itemId,
    required super.chapterIndex,
    required super.chapterId,
    required super.chapterTitle,
    required super.updatedAt,
    required this.charOffset,
    this.chapterLength = 0,
  });

  /// 章节内字符偏移量（相对规范化后的章节文本）。
  final int charOffset;

  /// 章节字符数快照；0 表示未知。用于书架展示百分比。
  final int chapterLength;

  /// 本章读了多少（0..1）。长度未知时返回 0。
  double get chapterRatio {
    if (chapterLength <= 0) return 0;
    return (charOffset / chapterLength).clamp(0.0, 1.0);
  }

  @override
  NovelProgress withChapter({
    required int chapterIndex,
    required String chapterId,
    required String chapterTitle,
  }) {
    return NovelProgress(
      section: section,
      itemId: itemId,
      chapterIndex: chapterIndex,
      chapterId: chapterId,
      chapterTitle: chapterTitle,
      updatedAt: DateTime.now(),
      charOffset: 0,
    );
  }

  @override
  String describe() {
    final percent = (chapterRatio * 100).round();
    return '第 ${chapterIndex + 1} 章 · $percent%';
  }
}

/// 视频进度：剧集序号 + 播放时间点（文档要求「视频记忆到集数 + 播放时间点」）。
///
/// 与阅读进度的差别在于「位置」的含义：这里是**播放时间**（毫秒），而漫画是页
/// 序号、小说是字符偏移。三者共用一张表，靠板块与形状区分（见 [ReadingProgress]）。
///
/// 剧集序号沿用 [chapterIndex]：视频的「章」就是剧集，选集列表的下标即它。
final class VideoProgress extends ReadingProgress {
  const VideoProgress({
    required super.section,
    required super.itemId,
    required super.chapterIndex,
    required super.chapterId,
    required super.chapterTitle,
    required super.updatedAt,
    required this.position,
    this.duration = Duration.zero,
  });

  /// 已播放到的时间点。
  final Duration position;

  /// 该视频总时长；[Duration.zero] 表示未知（还没拿到元数据）。
  final Duration duration;

  /// 是否已接近播完（≥95%）：继续观看列表据此标记「已看完」。
  ///
  /// 时长未知时一律返回 false——宁可不标记，也不凭空说人家看完了。
  bool get isFinished {
    if (duration <= Duration.zero) return false;
    return position.inMilliseconds / duration.inMilliseconds >= 0.95;
  }

  /// 已观看比例 0..1；时长未知时为 0。
  double get ratio {
    if (duration <= Duration.zero) return 0;
    return (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);
  }

  /// 进度文案：`第 3 集 · 12:34 / 45:10`；时长未知时只给已看时间。
  @override
  String describe() {
    final episode = '第 ${chapterIndex + 1} 集';
    if (duration <= Duration.zero) return '$episode · ${_clock(position)}';
    return '$episode · ${_clock(position)} / ${_clock(duration)}';
  }

  /// 跳到另一集：时间点归零（新一集从头播）。
  @override
  VideoProgress withChapter({
    required int chapterIndex,
    required String chapterId,
    required String chapterTitle,
  }) {
    return VideoProgress(
      section: section,
      itemId: itemId,
      chapterIndex: chapterIndex,
      chapterId: chapterId,
      chapterTitle: chapterTitle,
      updatedAt: DateTime.now(),
      position: Duration.zero,
    );
  }

  /// `12:34` / `1:02:03`。
  static String _clock(Duration value) {
    final total = value.inSeconds;
    final hours = total ~/ 3600;
    final minutes = (total % 3600) ~/ 60;
    final seconds = total % 60;
    final mm = minutes.toString().padLeft(hours > 0 ? 2 : 1, '0');
    final ss = seconds.toString().padLeft(2, '0');
    return hours > 0 ? '$hours:$mm:$ss' : '$mm:$ss';
  }
}
