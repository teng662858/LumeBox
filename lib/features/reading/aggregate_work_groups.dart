import 'dart:convert';

import '../../core/reading/reading.dart';
import 'section_toolbar.dart';

class AggregateWorkGroups {
  static final _separators = RegExp(r'[\s\p{P}\p{S}]+', unicode: true);
  static final _year = RegExp(r'\b(?:19|20)\d{2}\b');
  static final _episodes = RegExp(r'(?:更新至|全|共)\s*(?:第\s*)?(\d+)\s*集');

  static String normalized(String text) =>
      text.toLowerCase().replaceAll(_separators, '');
  static String identity(SearchHit hit) {
    final year = _year.firstMatch(hit.item.subtitle ?? '')?.group(0) ?? '';
    return jsonEncode([normalized(hit.item.title), year]);
  }

  static int episodes(SearchHit hit) =>
      int.tryParse(
        _episodes.firstMatch(hit.item.subtitle ?? '')?.group(1) ?? '',
      ) ??
      -1;
  static int relevance(SearchHit hit, String query) {
    return _relevanceNormalized(hit, normalized(query));
  }

  static int _relevanceNormalized(SearchHit hit, String wanted) {
    final title = normalized(hit.item.title);
    return title == wanted
        ? 3
        : title.startsWith(wanted)
        ? 2
        : title.contains(wanted)
        ? 1
        : 0;
  }

  static int health(SearchHit hit, ReadingLibrary? library) {
    try {
      final data = jsonDecode(
        library?.setting('source.health.last.${hit.sourceId}') ?? '',
      ) as Map;
      final at = DateTime.parse(data['at'] as String);
      if (DateTime.now().difference(at) > const Duration(days: 7)) return 0;
      return (data['issues'] as List).every((v) => v == 'none')
          ? at.millisecondsSinceEpoch
          : -1;
    } catch (_) {
      return 0;
    }
  }

  static List<List<SearchHit>> group(
    List<SearchHit> hits, {
    String order = 'relevance',
    String query = '',
    ReadingLibrary? library,
  }) {
    final sorted = List<SearchHit>.of(hits);
    final healthScores = <String, int>{};
    final wanted = order != 'episodes' && order != 'health'
        ? normalized(query)
        : '';
    int score(SearchHit hit) => switch (order) {
      'episodes' => episodes(hit),
      'health' => healthScores.putIfAbsent(
        hit.sourceId,
        () => health(hit, library),
      ),
      _ => _relevanceNormalized(hit, wanted),
    };
    final scores = {for (final hit in sorted) hit: score(hit)};
    sorted.sort((a, b) {
      final result = scores[b]!.compareTo(scores[a]!);
      return result == 0 ? a.item.title.compareTo(b.item.title) : result;
    });
    final groups = <String, List<SearchHit>>{};
    for (final hit in sorted) {
      (groups[identity(hit)] ??= []).add(hit);
    }
    return groups.values.toList();
  }
}
