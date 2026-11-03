import '../../core/session/section.dart';
import '../../core/reading/reading.dart';
import '../../core/source/source.dart';

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
  static int? season(String raw) {
    final match = RegExp(
      r'S\s*(\d+)|第\s*(\d+)\s*季',
      caseSensitive: false,
    ).firstMatch(raw);
    return int.tryParse(match?.group(1) ?? match?.group(2) ?? '');
  }

  static ({int? season, int episode})? episode(String raw) {
    final s = RegExp(
      r'S\s*(\d+)|第\s*(\d+)\s*季',
      caseSensitive: false,
    ).firstMatch(raw);
    final e = RegExp(
      r'E(?:P)?\s*(\d+)|第\s*(\d+)\s*[集话]',
      caseSensitive: false,
    ).firstMatch(raw);
    final numeric = RegExp(r'^\s*0*(\d+)\s*$').firstMatch(raw);
    final n = int.tryParse(
      e?.group(1) ?? e?.group(2) ?? numeric?.group(1) ?? '',
    );
    if (n == null) return null;
    return (
      season: raw.toLowerCase().contains('s') || raw.contains('季')
          ? int.tryParse(s?.group(1) ?? s?.group(2) ?? '')
          : null,
      episode: n,
    );
  }

  bool confident(SourceChapter chapter, {String workTitle = ''}) {
    final wanted = episode(chapterTitle);
    if (wanted == null) return chapter.title.trim() == chapterTitle.trim();
    final found = episode(chapter.title);
    if (found == null || found.episode != wanted.episode) return false;
    final desiredSeason = wanted.season ?? season(title);
    final actualSeason = episode(chapter.title)?.season ?? season(workTitle);
    return desiredSeason == null || actualSeason == desiredSeason;
  }

  List<SourceChapter> candidates(
    List<SourceChapter> chapters, {
    String workTitle = '',
  }) {
    final wanted = episode(chapterTitle);
    if (wanted == null) {
      return chapters
          .where((c) => c.title.trim() == chapterTitle.trim())
          .toList();
    }
    return chapters.where((c) {
      final found = episode(c.title);
      return found != null &&
          found.episode == wanted.episode &&
          ((wanted.season ?? season(title)) == null ||
              (found.season ?? season(workTitle)) == null ||
              (wanted.season ?? season(title)) ==
                  (found.season ?? season(workTitle)));
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
