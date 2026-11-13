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
  bool confident(SourceChapter chapter, {String workTitle = ''}) =>
      _matcher(workTitle, allowUnknownSeason: false)(chapter);

  bool _exactTitle(SourceChapter chapter, String label) =>
      chapterTitle.trim().isNotEmpty &&
      (chapter.title.trim() == chapterTitle.trim() ||
          label == chapterTitle.trim());

  List<SourceChapter> candidates(
    List<SourceChapter> chapters, {
    String workTitle = '',
  }) => chapters.where(_matcher(workTitle, allowUnknownSeason: true)).toList();

  bool Function(SourceChapter) _matcher(
    String workTitle, {
    required bool allowUnknownSeason,
  }) {
    final wanted = VideoEpisodeCatalog.episodeNumber(chapterTitle);
    final desiredSeason =
        VideoEpisodeCatalog.seasonNumber(chapterTitle) ??
        VideoEpisodeCatalog.seasonNumber(title);
    final workSeason = VideoEpisodeCatalog.seasonNumber(workTitle);
    final wantedPart = VideoEpisodeCatalog.episodePart(chapterTitle);
    return (chapter) {
      final label = VideoEpisodeCatalog.labelOf(chapter);
      final actualSeason =
          VideoEpisodeCatalog.seasonNumber(label) ?? workSeason;
      if (desiredSeason != actualSeason &&
          (!allowUnknownSeason ||
              (desiredSeason != null && actualSeason != null))) {
        return false;
      }
      if (wanted == null) return _exactTitle(chapter, label);
      return VideoEpisodeCatalog.episodeNumber(label)?.episode ==
              wanted.episode &&
          VideoEpisodeCatalog.episodePart(label) == wantedPart;
    };
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
