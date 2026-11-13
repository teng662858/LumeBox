import '../source/source.dart';
import '../source/source_preferences.dart';
import 'reading_library.dart';

/// Presentation indexes only. Source chapters, IDs and saved progress indexes
/// are never rewritten. Unknown titles keep their slots; volume headings split
/// independent ranges so numbering restarted in another volume is not mixed.
class ChapterDisplayOrder {
  ChapterDisplayOrder(this.library, this.sourceId);
  final ReadingLibrary library;
  final String sourceId;
  static const automaticKey = 'reader.chapterAutoOrder';
  bool get automatic => library.setting(automaticKey) == 'true';
  set automatic(bool value) => library.setSetting(automaticKey, '$value');
  String get _manualKey => 'reader.chapterDescending.$sourceId';
  bool get descending => switch (library.setting(_manualKey)) {
    'true' => true,
    'false' => false,
    _ => SourcePreferences.read(library.section, sourceId).newestFirst,
  };
  set descending(bool value) => library.setSetting(_manualKey, '$value');
  List<int> indexes(List<SourceChapter> chapters, {bool? manualDescending}) =>
      automatic
      ? correctedIndexes(chapters)
      : [
          if (manualDescending ?? descending)
            for (var i = chapters.length - 1; i >= 0; i--) i
          else
            for (var i = 0; i < chapters.length; i++) i,
        ];

  static const _digits = '0-9零〇○一二两兩三四五六七八九十百千万萬亿億壹贰貳叁參肆伍陆陸柒捌玖拾佰仟廿卅';
  static final _chapter = RegExp(
    '(?:第\\s*)?([$_digits]+(?:[.点點][$_digits]+)?)\\s*[章话話回节節集幕]',
  );
  static final _english = RegExp(
    r'\b(?:chapter|chap|ch|episode|ep)\.?\s*#?\s*(\d+(?:\.\d+)?)',
    caseSensitive: false,
  );
  static final _leading = RegExp(
    r'^\s*[\[【(（]?\s*(\d+(?:\.\d+)?)(?=[\]】)）\s、.．:：_\-]|$)',
  );
  static final _volume = RegExp(
    '(?:第\\s*)?([$_digits]+)\\s*[卷部册冊]|\\bvol(?:ume)?\\.?\\s*(\\d+)',
    caseSensitive: false,
  );
  static String _normalize(String value) => String.fromCharCodes(
    value.runes.map((r) => r >= 0xff10 && r <= 0xff19 ? r - 0xfee0 : r),
  ).replaceAll('．', '.');

  static double? chapterNumber(String title) {
    final text = _normalize(title);
    final matched =
        _chapter.firstMatch(text) ??
        _english.firstMatch(text) ??
        _leading.firstMatch(text);
    return matched == null ? null : parseNumber(matched.group(1)!);
  }

  static double? parseNumber(String value) {
    value = _normalize(value);
    if (value.isEmpty) return null;
    final decimal = double.tryParse(value);
    if (decimal != null && decimal.isFinite) return decimal;
    final pieces = value.replaceAll('點', '点').replaceAll('.', '点').split('点');
    if (pieces.length > 2) return null;
    const digits = {
      '零': 0,
      '〇': 0,
      '○': 0,
      '一': 1,
      '壹': 1,
      '二': 2,
      '两': 2,
      '兩': 2,
      '贰': 2,
      '貳': 2,
      '三': 3,
      '叁': 3,
      '參': 3,
      '四': 4,
      '肆': 4,
      '五': 5,
      '伍': 5,
      '六': 6,
      '陆': 6,
      '陸': 6,
      '七': 7,
      '柒': 7,
      '八': 8,
      '捌': 8,
      '九': 9,
      '玖': 9,
    };
    const units = {
      '十': 10,
      '拾': 10,
      '百': 100,
      '佰': 100,
      '千': 1000,
      '仟': 1000,
      '万': 10000,
      '萬': 10000,
      '亿': 100000000,
      '億': 100000000,
    };
    final integer = pieces.first.replaceAll('廿', '二十').replaceAll('卅', '三十');
    int? digit(String c) => int.tryParse(c) ?? digits[c];
    var total = 0, section = 0, number = 0;
    final hasUnits = integer.split('').any(units.containsKey);
    if (!hasUnits) {
      final values = integer.split('').map(digit).toList();
      if (values.any((v) => v == null)) return null;
      total = int.tryParse(values.join()) ?? 0;
    } else {
      for (final c in integer.split('')) {
        final d = digit(c);
        if (d != null) {
          number = number * 10 + d;
          continue;
        }
        final unit = units[c];
        if (unit == null) return null;
        if (unit < 10000) {
          section += (number == 0 ? 1 : number) * unit;
        } else if (unit == 10000) {
          total += (section + number) * unit;
          section = 0;
        } else {
          total = (total + section + number) * unit;
          section = 0;
        }
        number = 0;
      }
      total += section + number;
    }
    if (pieces.length == 1) return total.toDouble();
    final fraction = pieces.last.split('').map(digit).toList();
    if (fraction.isEmpty || fraction.any((v) => v == null)) return null;
    return double.tryParse('$total.${fraction.join()}');
  }

  static List<int> correctedIndexes(List<SourceChapter> chapters) {
    final indexes = List.generate(chapters.length, (i) => i);
    final numbers = chapters.map((c) => chapterNumber(c.title)).toList();
    final volumes = chapters.map((c) {
      final match = _volume.firstMatch(_normalize(c.title));
      return match == null ? null : parseNumber(match.group(1) ?? match.group(2)!);
    }).toList();
    final numbered = indexes.where((i) => numbers[i] != null).toList();
    final allHaveVolumes =
        numbered.isNotEmpty && numbered.every((i) => volumes[i] != null);
    void sortRange(int start, int end) {
      final slots = [
        for (var i = start; i < end; i++)
          if (numbers[i] != null) i,
      ];
      final ordered = [...slots]
        ..sort((a, b) {
          final volume = allHaveVolumes
              ? volumes[a]!.compareTo(volumes[b]!)
              : 0;
          final number = volume == 0
              ? numbers[a]!.compareTo(numbers[b]!)
              : volume;
          return number == 0 ? a.compareTo(b) : number;
        });
      for (var i = 0; i < slots.length; i++) {
        indexes[slots[i]] = ordered[i];
      }
    }

    var start = 0;
    for (var i = 0; i < chapters.length; i++) {
      if (numbers[i] == null && volumes[i] != null) {
        sortRange(start, i);
        start = i + 1;
      }
    }
    sortRange(start, chapters.length);
    return indexes;
  }
}
