import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'chinese_search_map.dart';

class SearchSettings extends ChangeNotifier {
  SearchSettings._();
  static final instance = SearchSettings._();
  bool simplify = true;
  bool exact = false;
  File? _file;
  Future<void> _writing = Future.value();
  Future<void> boot() async {
    try {
      _file = File(
        '${(await getApplicationSupportDirectory()).path}/search_settings.json',
      );
      if (await _file!.exists()) {
        final data =
            jsonDecode(await _file!.readAsString()) as Map<String, dynamic>;
        simplify = data['simplify'] != false;
        exact = data['exact'] == true;
      }
    } catch (_) {
      /* A damaged preference must not prevent searching. */
    }
  }

  Future<void> update({bool? simplify, bool? exact}) async {
    if (_file == null) await boot();
    this.simplify = simplify ?? this.simplify;
    this.exact = exact ?? this.exact;
    notifyListeners();
    final data = jsonEncode({'simplify': this.simplify, 'exact': this.exact});
    _writing = _writing.catchError((Object _) {}).then((_) async {
      if (_file == null) await boot();
      final file = _file;
      if (file != null) {
        final temp = File('${file.path}.tmp');
        await temp.writeAsString(data, flush: true);
        await temp.rename(file.path);
      }
    });
    await _writing;
  }

  static final int _maxLength = searchChineseMap.keys.fold(
    1,
    (n, key) => key.length > n ? key.length : n,
  );
  static String toSimplified(String input) {
    final out = StringBuffer();
    var index = 0;
    while (index < input.length) {
      String? value;
      var length = (input.length - index).clamp(1, _maxLength);
      for (; length > 0; length--) {
        value = searchChineseMap[input.substring(index, index + length)];
        if (value != null) break;
      }
      if (value != null) {
        out.write(value);
        index += length;
      } else {
        out.write(input[index++]);
      }
    }
    return out.toString();
  }

  String prepare(String input) =>
      simplify ? toSimplified(input.trim()) : input.trim();
  bool accepts(String title, String query) =>
      !exact ||
      query.trim().isEmpty ||
      prepare(title).toLowerCase() == prepare(query).toLowerCase();

  /// Some sites return their homepage/recommendations when search has no hits.
  /// Aggregate results must have title evidence even with exact mode disabled.
  bool acceptsAggregate(String title, String query) =>
      aggregateMatcher(query)(title);

  /// Prepare the query once for a batch of results from multiple sources.
  bool Function(String) aggregateMatcher(String query) {
    final useSimplified = simplify;
    final useExact = exact;
    String normalize(String value) {
      final trimmed = value.trim();
      final prepared = useSimplified ? toSimplified(trimmed) : trimmed;
      final width = String.fromCharCodes(
        prepared.runes.map(
          (rune) => rune >= 0xFF01 && rune <= 0xFF5E ? rune - 0xFEE0 : rune,
        ),
      );
      return width.toLowerCase().replaceAll(_aggregateSeparators, ' ').trim();
    }

    final needle = normalize(query);
    final terms = needle.split(' ');
    final patterns = [
      for (final term in terms)
        _latinTerm.hasMatch(term)
            ? RegExp('(^|[^a-z0-9])${RegExp.escape(term)}(?=\$|[^a-z0-9])')
            : null,
    ];
    return (title) {
      if (needle.isEmpty) return false;
      final candidate = normalize(title);
      if (candidate.isEmpty) return false;
      if (useExact) return candidate == needle;
      final compact = candidate.replaceAll(' ', '');
      for (var i = 0; i < terms.length; i++) {
        if (!(patterns[i]?.hasMatch(candidate) ?? compact.contains(terms[i]))) {
          return false;
        }
      }
      return true;
    };
  }

  static final _aggregateSeparators = RegExp(r'[^\p{L}\p{N}]+', unicode: true);
  static final _latinTerm = RegExp(r'^[a-z0-9]+$');
}
