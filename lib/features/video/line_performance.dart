import 'dart:convert';

import '../../core/reading/reading.dart';
import 'player_speed_meter.dart';

/// Scoped to a source and work; signed addresses and headers are never persisted.
class LinePerformance {
  LinePerformance(this.library, this.work);
  final ReadingLibrary library;
  final String work;
  String get _key => 'video.linePerformance.v1.$work';
  Map<String, dynamic> _privateRows = {};
  bool get _private => library.setting('history.incognito') == 'true';
  Map<String, dynamic> _read() {
    if (_private) return Map.of(_privateRows);
    try {
      return Map<String, dynamic>.from(
        jsonDecode(library.setting(_key) ?? '{}') as Map,
      );
    } catch (_) {
      return {};
    }
  }

  Map<String, dynamic> result(String line) {
    final row = _read()[line];
    if (row is! Map) return {};
    final time = DateTime.tryParse('${row['time']}');
    if (time == null ||
        DateTime.now().difference(time) > const Duration(hours: 6)) {
      return {};
    }
    return {
      for (final key in ['kbps', 'startupMs', 'failures'])
        if (row[key] is num &&
            (row[key] as num).isFinite &&
            (row[key] as num) >= 0)
          key: row[key],
      'time': row['time'],
    };
  }

  void record(String line, {int? kbps, int? startupMs, bool failed = false}) {
    final all = _read();
    final old = result(line);
    all.remove(line);
    all[line] = {
      ...old,
      'kbps': ?kbps,
      'startupMs': ?startupMs,
      'failures': failed ? ((old['failures'] as num?)?.toInt() ?? 0) + 1 : 0,
      'time': DateTime.now().toIso8601String(),
    };
    final bounded = Map<String, dynamic>.fromEntries(
      all.entries.toList().reversed.take(32),
    );
    if (_private) {
      _privateRows = bounded;
    } else {
      library.setSetting(_key, jsonEncode(bounded));
    }
  }

  int compare(String a, String b) {
    final x = result(a), y = result(b);
    final failures = ((x['failures'] as num?) ?? 0).compareTo(
      (y['failures'] as num?) ?? 0,
    );
    if (failures != 0) return failures;
    final speed = ((y['kbps'] as num?) ?? 0).compareTo(
      (x['kbps'] as num?) ?? 0,
    );
    if (speed != 0) return speed;
    return ((x['startupMs'] as num?) ?? 999999).compareTo(
      (y['startupMs'] as num?) ?? 999999,
    );
  }

  String describe(String line) {
    final r = result(line);
    if (r.isEmpty) return '尚未测速';
    return [
      if ((r['failures'] as num? ?? 0) > 0) '失败 ${r['failures']} 次',
      if (r['kbps'] is num)
        '探测 ${PlaybackSpeedMeter.describe((r['kbps'] as num).toInt())}',
      if (r['startupMs'] is num)
        '起播 ${((r['startupMs'] as num) / 1000).toStringAsFixed(1)} 秒',
    ].join(' · ');
  }
}
