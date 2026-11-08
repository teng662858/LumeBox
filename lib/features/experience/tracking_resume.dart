import 'dart:convert';

import '../../core/experience/content_center.dart';
import '../../core/reading/reading.dart';
import '../../core/source/source.dart';
import '../video/video_episode_catalog.dart';

abstract final class TrackingResume {
  static String chapterKey(SourceChapter chapter) =>
      VideoEpisodeCatalog.episodeKey(chapter) ??
      jsonEncode([chapter.line, chapter.id]);
  static List<SourceChapterFact> facts(List<SourceChapter> chapters) => {
    for (final chapter in chapters)
      chapterKey(chapter): SourceChapterFact(
        chapterKey(chapter),
        VideoEpisodeCatalog.labelOf(chapter),
      ),
  }.values.toList();

  static List<SourceChapter> episodes(
    List<SourceChapter> chapters,
    VideoProgress? progress,
  ) {
    if (chapters.isEmpty) return [];
    final current = chapters
        .where((c) => c.id == progress?.chapterId)
        .firstOrNull;
    return VideoEpisodeCatalog.forChapter(
      chapters,
      current?.id ?? chapters.first.id,
    );
  }

  static int index(List<SourceChapter> episodes, VideoProgress? progress) {
    if (episodes.isEmpty) return -1;
    if (progress == null) return 0;
    final found = episodes.indexWhere((c) => c.id == progress.chapterId);
    // Never guess a different episode when a source has removed the saved one.
    if (found < 0) return -1;
    final next = found + (progress.isFinished ? 1 : 0);
    return next < episodes.length ? next : -1;
  }

  static String label(VideoProgress? progress) => progress == null
      ? '开始观看'
      : progress.isFinished
      ? '播放下一集'
      : '继续 ${progress.chapterTitle}';
}
