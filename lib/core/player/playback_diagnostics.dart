import '../util/sensitive_data.dart';

/// Bounded metadata only: never store playback paths, query strings or headers.
abstract final class PlaybackDiagnostics {
  static final List<Map<String, Object?>> _events = [];
  static List<Map<String, Object?>> get snapshot => [
    for (final e in _events) Map.unmodifiable(e),
  ];

  /// [positionObservedMs] is the first near-target snapshot, not a render timestamp.
  static void record(
    String stage, {
    String? source,
    String? kernel,
    Uri? uri,
    int? elapsedMs,
    int? positionObservedMs,
    String? error,
  }) {
    _events.add({
      'time': DateTime.now().toIso8601String(),
      'stage': stage,
      'source': ?source,
      'kernel': ?kernel,
      if (uri != null) 'host': uri.host,
      // 只记类型不记路径：hls / file，以及是否走 Python 本地代理（127.0.0.1）。
      // 缓冲慢时这两项决定排查方向（ABR 失效 vs 代理整包转发）。
      if (uri != null)
        'stream': uri.path.toLowerCase().endsWith('.m3u8') ? 'hls' : 'file',
      if (uri != null)
        'loopback': uri.host == '127.0.0.1' || uri.host == 'localhost',
      'elapsedMs': ?elapsedMs,
      'positionObservedMs': ?positionObservedMs,
      if (error != null)
        'error': SensitiveData.redact(error)
            .replaceAll(RegExp(r'https?://[^\s]+'), '[URL omitted]'),
    });
    if (_events.length > 30) _events.removeAt(0);
  }
}
