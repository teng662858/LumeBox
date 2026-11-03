import 'package:flutter/foundation.dart';

/// Session-only timings; never stores scripts, URLs, or credentials.
class SourceLoadProfile {
  static final entries = ValueNotifier<List<String>>(const []);

  static Future<T> measure<T>(String stage, Future<T> Function() action) async {
    final watch = Stopwatch()..start();
    var success = false;
    try {
      final result = await action();
      success = true;
      return result;
    } finally {
      entries.value = [
        '$stage · ${watch.elapsedMilliseconds} ms · ${success ? '完成' : '失败／超时'}',
        ...entries.value.take(29),
      ];
    }
  }
}
