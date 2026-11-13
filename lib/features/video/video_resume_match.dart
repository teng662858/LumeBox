import '../../core/session/section.dart';
import '../../core/reading/reading.dart';
import '../../core/source/source.dart';
import 'video_episode_catalog.dart';

class VideoResumeRequest {
  const VideoResumeRequest({
    required this.title,
    required this.chapterTitle,
    required this.chapterIndex,
    required this.position,
    required this.duration,
  });
  final String title, chapterTitle;
  final int chapterIndex;
  final Duration position, duration;
  bool confident(SourceChapter chapter, {String workTitle = ''}) {
    final wanted = VideoEpisodeCatalog.episodeNumber(chapterTitle);
    if (wanted == null) return chapter.title.trim() == chapterTitle.trim();
    final found = VideoEpisodeCatalog.episodeNumber(
      VideoEpisodeCatalog.labelOf(chapter),
    );
    if (found == null || found.episode != wanted.episode) return false;
    final desiredSeason =
        wanted.season ?? VideoEpisodeCatalog.seasonNumber(title);
    final actualSeason =
        found.season ?? VideoEpisodeCatalog.seasonNumber(workTitle);
    return desiredSeason == null || actualSeason == desiredSeason;
  }

  List<SourceChapter> candidates(
    List<SourceChapter> chapters, {
    String workTitle = '',
  }) {
    final wanted = VideoEpisodeCatalog.episodeNumber(chapterTitle);
    if (wanted == null) {
      return chapters
          .where((c) => c.title.trim() == chapterTitle.trim())
          .toList();
    }
    final desiredSeason =
        wanted.season ?? VideoEpisodeCatalog.seasonNumber(title);
    final workSeason = VideoEpisodeCatalog.seasonNumber(workTitle);
    return chapters.where((c) {
      final found = VideoEpisodeCatalog.episodeNumber(
        VideoEpisodeCatalog.labelOf(c),
      );
      final actualSeason = found?.season ?? workSeason;
      return found != null &&
          found.episode == wanted.episode &&
          (desiredSeason == null ||
              actualSeason == null ||
              desiredSeason == actualSeason);
    }).toList();
  }

  VideoProgress progress(
    String sourceId,
    String itemId,
    SourceChapter chapter,
    int index,
    Section section,
  ) => VideoProgress(
    sourceId: sourceId,
    section: section,
    itemId: itemId,
    chapterIndex: index,
    chapterId: chapter.id,
    chapterTitle: chapter.title,
    position: position,
    duration: duration,
    updatedAt: DateTime.now(),
  );
}
