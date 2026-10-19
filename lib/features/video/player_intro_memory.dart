import '../../core/intro/intro_controller.dart';
import '../../core/intro/intro_models.dart';
import '../../core/intro/intro_store.dart';
import '../../core/player/skip_marks.dart';
import 'video_play_target.dart';

/// Both player layouts share the same per-series memory, independent of IDs.
Future<void> rememberPlayerSkip(
  VideoPlayTarget target,
  SkipMarks marks,
  Duration duration, {
  bool? intro,
  IntroController? controller,
}) async {
  final store = controller?.store ?? await IntroStore.open();
  final series = '${target.sourceId}:${target.itemId}';
  final identity = store.identity(series);
  final episode = EpisodeIdentity(
    series: series,
    episode: target.chapterIndex + 1,
    season: (identity['season'] as num?)?.toInt() ?? 1,
    movie: identity['movie'] == true,
  );
  if (marks.isEmpty) {
    store.clearSeriesMemory(episode);
  } else {
    if (duration <= Duration.zero) return;
    store.rememberSeries(episode, duration.inMilliseconds, [
      if (intro != false && marks.intro != null && marks.intro! < duration)
        SkipSegment(
          kind: SegmentKind.opening,
          startMs: 0,
          endMs: marks.intro!.inMilliseconds,
          confidence: 1,
          source: 'manual',
          evidence: 'User quick opening mark',
        ),
      if (intro != true && marks.outro != null && marks.outro! < duration)
        SkipSegment(
          kind: SegmentKind.ending,
          startMs: marks.outro!.inMilliseconds,
          endMs: duration.inMilliseconds,
          confidence: 1,
          source: 'manual',
          evidence: 'User quick ending mark',
        ),
    ]);
  }
  if (controller?.request?.episode.key == episode.key) {
    controller!.refreshSeriesMemory(
      justMarked: marks.isEmpty || intro == null
          ? null
          : intro
          ? SegmentKind.opening
          : SegmentKind.ending,
    );
  }
}
