import 'intro_models.dart';
import 'intro_signals.dart';

/// Finds an aligned, varying sequence at episode edges, without a manual seed.
/// Proposals require confirmation: recurring logos/recaps may also match.
abstract final class RepeatedSegments {
  static List<SkipSegment> discover(
    List<Map<String, Object?>> frames,
    List<Map<String, Object?>> histories,
    int duration,
    IntroOptions options,
  ) {
    if (duration < 600000 || frames.length < 6) return [];
    final step = options.sampleEverySeconds * 1000;
    bool close(Map a, Map b) {
      bool hash(String key) {
        final x = a[key], y = b[key];
        if (x is! String ||
            y is! String ||
            !RegExp(r'^[0-9a-fA-F]{16}$').hasMatch(x) ||
            !RegExp(r'^[0-9a-fA-F]{16}$').hasMatch(y) ||
            RegExp(r'^(0{16}|[fF]{16})$').hasMatch(x)) {
          return false;
        }
        return IntroSignals.hamming(x, y) <= 4;
      }

      if (!hash('p')) return false;
      final aAudio = (a['m'] as List? ?? [])
          .whereType<num>()
          .map((n) => n.toDouble())
          .toList();
      final bAudio = (b['m'] as List? ?? [])
          .whereType<num>()
          .map((n) => n.toDouble())
          .toList();
      if (options.enabled('joint') &&
          aAudio.isNotEmpty &&
          aAudio.length == bAudio.length) {
        return IntroSignals.cosine(aAudio, bAudio) >= .95;
      }
      return options.enabled('phash') && options.enabled('dhash') && hash('d');
    }

    final proposals = <SkipSegment>[];
    for (final history in histories) {
      final oldDuration = (history['durationMs'] as num?)?.toInt();
      if (oldDuration == null || oldDuration < 600000) continue;
      final refs = (history['frames'] as List? ?? []).whereType<Map>().toList();
      for (final kind in [SegmentKind.opening, SegmentKind.ending]) {
        final offsets = <int, Map<int, Map<String, Object?>>>{};
        for (final frame in frames) {
          final at = (frame['at'] as num?)?.toInt();
          if (at == null ||
              (kind == SegmentKind.opening
                  ? at > 240000
                  : at < duration - 240000)) {
            continue;
          }
          for (final ref in refs) {
            final oldAt = (ref['at'] as num?)?.toInt();
            if (oldAt == null ||
                (kind == SegmentKind.opening
                    ? oldAt > 240000
                    : oldAt < oldDuration - 240000)) {
              continue;
            }
            if (close(frame, ref)) {
              (offsets[((at - oldAt) / step).round()] ??= {})[at] = frame;
            }
          }
        }
        for (final aligned in offsets.values) {
          final times = aligned.keys.toList()..sort();
          var run = <int>[];
          void finish() {
            if (run.length < 6 ||
                run.last - run.first < 20000 ||
                run.map((t) => aligned[t]!['p']).toSet().length < 4) {
              return;
            }
            final end = (run.last + step).clamp(0, duration);
            final segment = SkipSegment(
              kind: kind,
              startMs: run.first,
              endMs: end,
              confidence: .93,
              source: 'fingerprint.repeat',
              evidence: '同季两集存在连续重复画面；需确认边界',
            );
            if (segment.validFor(duration) &&
                !proposals.any((s) => s.kind == kind)) {
              proposals.add(segment);
            }
          }

          for (final time in times) {
            if (run.isNotEmpty && time - run.last > step * 2) {
              finish();
              run = [];
            }
            run.add(time);
          }
          finish();
        }
      }
    }
    return proposals;
  }
}
