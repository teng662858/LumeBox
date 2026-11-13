import 'dart:convert';

import '../../core/reading/chapter_display_order.dart';
import '../../core/source/source.dart';

/// Route grouping never rewrites chapter IDs: the original source still resolves them.
abstract final class VideoEpisodeCatalog {
  static Future<List<SourceChapter>> load(
    DataSource source,
    String itemId,
  ) async {
    try {
      final chapters = await source.chapters(itemId);
      if (chapters.isNotEmpty) return chapters;
    } catch (_) {
      final metadata = await source.detail(itemId);
      if (metadata?.chapters.isNotEmpty == true) return metadata!.chapters;
      rethrow;
    }
    return (await source.detail(itemId))?.chapters ?? [];
  }

  static String lineOf(SourceChapter chapter) {
    if (chapter.line.trim().isNotEmpty) return chapter.line.trim();
    try {
      final data = jsonDecode(chapter.id);
      if (data is Map &&
          data['flag'] is String &&
          (data['flag'] as String).trim().isNotEmpty) {
        return (data['flag'] as String).trim();
      }
    } catch (_) {}
    final match = RegExp(r'^(.{1,60}?)\s+[·|｜]\s+(.+)$')
        .firstMatch(chapter.title);
    return match?.group(1)?.trim() ?? '默认线路';
  }

  static String labelOf(SourceChapter chapter) {
    final line = lineOf(chapter);
    final prefix = RegExp('^${RegExp.escape(line)}\\s+[·|｜]\\s+');
    return chapter.title.replaceFirst(prefix, '').trim();
  }

  static const _ordinal = r'[0-9０-９零〇一二两兩三四五六七八九十百千]+';
  static const _episodeOrdinal = '$_ordinal(?:[.．点點]$_ordinal)?';
  static final _season = RegExp(
    '第\\s*($_ordinal)\\s*季|'
    r'(?:(?:^|[^a-z0-9])(?:season|s)[ ._-]*|s(?=[0-9]{1,3}e[0-9]))'
    r'([0-9]{1,3})(?![0-9])',
    caseSensitive: false,
  );
  static final _episode = RegExp(
    '第\\s*($_episodeOrdinal)\\s*[集话話期]|'
    '(?:^|[^a-z0-9]|s[0-9]{1,3})(?:episode|ep?)[ ._-]*'
    r'([0-9]{1,4}(?:[.．][0-9]+(?![0-9a-z]))?)(?![0-9])',
    caseSensitive: false,
  );
  static final _numberOnly = RegExp('^($_episodeOrdinal)(?:集|话|話)?\$');
  static final _partAfterNumber = RegExp(
    r'^[\s.·_\-（(【\[]*([上中下])(?:篇|部|段|半(?:集|场|場)?)?(?=$|[\s.·_\-）)】\]])',
  );
  static final _preview = RegExp(
    r'预告|預告|(?:^|[^a-z])(?:trailer|teaser|preview)(?:$|[^a-z])',
    caseSensitive: false,
  );

  static String episodePart(String label) {
    final end = _episode.firstMatch(label)?.end;
    final part = end == null
        ? ''
        : _partAfterNumber.firstMatch(label.substring(end))?.group(1) ?? '';
    return _preview.hasMatch(label) ? '$part预告' : part;
  }

  static num? _matchedNumber(RegExpMatch? match) {
    if (match == null) return null;
    final digits = match[1] ?? match[2]!;
    final value = ChapterDisplayOrder.parseNumber(digits);
    if (value == null || !value.isFinite) return null;
    return value == value.toInt() ? value.toInt() : value;
  }

  static int? seasonNumber(String label) =>
      _matchedNumber(_season.firstMatch(label))?.toInt();

  static ({int? season, num episode})? episodeNumber(String label) {
    final number = _matchedNumber(
      _episode.firstMatch(label) ?? _numberOnly.firstMatch(label.trim()),
    );
    return number == null
        ? null
        : (season: seasonNumber(label), episode: number);
  }

  /// Only explicit episode numbers are comparable; a missing episode never falls back by index.
  static String? episodeKey(SourceChapter chapter) {
    final label = labelOf(chapter);
    final number = episodeNumber(label);
    if (number == null) return null;
    final part = episodePart(label);
    final key = '${number.season ?? 1}:${number.episode}';
    return part.isEmpty ? key : '$key:$part';
  }

  static int matchingIndex(
    SourceChapter current,
    List<SourceChapter> candidates,
  ) {
    final label = labelOf(current);
    if (label.isEmpty) return -1;
    final exact = [
      for (var i = 0; i < candidates.length; i++)
        if (labelOf(candidates[i]) == label) i,
    ];
    if (exact.isNotEmpty) return exact.length == 1 ? exact.single : -1;
    final key = episodeKey(current);
    if (key == null) return -1;
    final matches = [
      for (var i = 0; i < candidates.length; i++)
        if (episodeKey(candidates[i]) == key) i,
    ];
    return matches.length == 1 ? matches.single : -1;
  }

  static String displayLabel(SourceChapter chapter, int index) {
    final label = labelOf(chapter);
    if (RegExp(
          r'\.(mkv|mp4|avi|mov|m4v|ts)(?:\b|$)',
          caseSensitive: false,
        ).hasMatch(label) ||
        label.length > 35 ||
        RegExp(r'^\d+$').hasMatch(label)) {
      final episode = episodeNumber(label);
      final number = episode?.episode ?? index + 1;
      final digits = number.toString();
      final formatted = number < 10 ? '0$digits' : digits;
      final part = episodePart(label);
      return '第 $formatted 集${part.isEmpty ? '' : '（$part）'}';
    }
    return label.isEmpty ? '第 ${index + 1} 集' : label;
  }

  static Map<String, List<SourceChapter>> group(List<SourceChapter> chapters) {
    final lines = <String, List<SourceChapter>>{};
    for (final chapter in chapters) {
      (lines[lineOf(chapter)] ??= []).add(chapter);
    }
    return lines;
  }

  static List<SourceChapter> forChapter(
    List<SourceChapter> chapters,
    String id,
  ) {
    final selected = chapters.where((c) => c.id == id).firstOrNull;
    if (selected == null) return chapters;
    final line = lineOf(selected);
    return chapters.where((c) => lineOf(c) == line).toList();
  }
}
