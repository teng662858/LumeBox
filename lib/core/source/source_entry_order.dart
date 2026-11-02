import 'dart:convert';

import '../reading/reading_library.dart';
import '../session/section.dart';

class SourceEntryOrder {
  static List<(String, String)> read(
    Section section,
    String key,
    List<(String, String)> defaults,
  ) {
    List<String> saved = [];
    try {
      saved = (jsonDecode(
        ReadingLibrary.find(section)?.setting(key) ?? '[]',
      ) as List).whereType<String>().toList();
    } catch (_) {
      /* Missing/damaged preferences use the current definitions. */
    }
    final result = <(String, String)>[];
    for (final id in [...saved, ...defaults.map((entry) => entry.$1)]) {
      final entry = defaults.where((entry) => entry.$1 == id).firstOrNull;
      if (entry != null && !result.any((old) => old.$1 == id)) {
        result.add(entry);
      }
    }
    return result;
  }

  static Future<void> save(
    Section section,
    String key,
    List<String> ids,
  ) async {
    final library = await ReadingLibrary.open(section);
    library.setSetting(key, jsonEncode(ids.toSet().toList()));
  }
}
