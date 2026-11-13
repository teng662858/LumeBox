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
    final label = VideoEpisodeCatalog.labelOf(chapter);
    if (wanted == null) return _exactTitle(chapter, label);
    if (VideoEpisodeCatalog.episodePart(label) !=
        VideoEpisodeCatalog.episodePart(chapterTitle)) {
      return false;
    }
    final found = VideoEpisodeCatalog.episodeNumber(label);
    if (found == null || found.episode != wanted.episode) return false;
    final desiredSeason =
        wanted.season ?? VideoEpisodeCatalog.seasonNumber(title);
    final actualSeason =
        found.season ?? VideoEpisodeCatalog.seasonNumber(workTitle);
    return desiredSeason == null || actualSeason == desiredSeason;
  }

  bool _exactTitle(SourceChapter chapter, String label) =>
      chapterTitle.trim().isNotEmpty &&
      (chapter.title.trim() == chapterTitle.trim() || label == chapterTitle.trim());

  List<SourceChapter> candidates(
    List<SourceChapter> chapters, {
    String workTitle = '',
  }) {
    final wanted = VideoEpisodeCatalog.episodeNumber(chapterTitle);
    if (wanted == null) {
      return chapters
          .where((c) => _exactTitle(c, VideoEpisodeCatalog.labelOf(c)))
          .toList();
    }
    final desiredSeason =
        wanted.season ?? VideoEpisodeCatalog.seasonNumber(title);
    final workSeason = VideoEpisodeCatalog.seasonNumber(workTitle);
    final wantedPart = VideoEpisodeCatalog.episodePart(chapterTitle);
    return chapters.where((c) {
      final label = VideoEpisodeCatalog.labelOf(c);
      final found = VideoEpisodeCatalog.episodeNumber(label);
      final actualSeason = found?.season ?? workSeason;
      return found != null &&
          found.episode == wanted.episode &&
          VideoEpisodeCatalog.episodePart(label) == wantedPart &&
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
