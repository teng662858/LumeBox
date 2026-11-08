import 'dart:async';
import 'dart:convert';

import 'dandanplay_client.dart';
import 'danmaku_models.dart';

/// Owns one episode's lazy segment requests. Replacing it closes all requests.
class DanmakuStream {
  DanmakuStream(this.client, this.payload);
  final DandanplayClient client;
  final Map<String, dynamic> payload;
  final Map<String, DanmakuTrack> _loaded = {};
  final Set<String> _pending = {};
  bool _closed = false;
  int revision = 0;
  final Map<String, DateTime> _retryAfter = {};
  double get duration =>
      ((payload['videoDuration'] ?? payload['duration']) as num?)?.toDouble() ??
      0;
  List<Map<String, dynamic>> get segments => [
    for (final raw in (payload['segmentList'] as List? ?? const []))
      if (raw is Map) Map<String, dynamic>.from(raw),
  ];
  DanmakuTrack get track {
    final items = <DanmakuItem>[
      ...DandanplayClient.parseComments(payload).items,
    ];
    for (final part in _loaded.values) {
      items.addAll(part.items);
    }
    final seen = <String>{};
    return DanmakuTrack.parse(
      items
          .where(
            (i) => seen.add(
              '${i.time.inMilliseconds}|${i.mode.id}|${i.color}|${i.text}',
            ),
          )
          .toList(),
    );
  }

  Future<void> loadAt(Duration position) async {
    final seconds = position.inMilliseconds / 1000;
    for (final part in segments) {
      final start = (part['segment_start'] as num?)?.toDouble();
      final end = (part['segment_end'] as num?)?.toDouble();
      if (start == null ||
          end == null ||
          start > seconds + 60 ||
          end < seconds) {
        continue;
      }
      final key = jsonEncode(part);
      if (_closed ||
          _loaded.containsKey(key) ||
          (_retryAfter[key]?.isAfter(DateTime.now()) ?? false) ||
          !_pending.add(key)) {
        continue;
      }
      try {
        final value = await client.segment(part);
        if (!_closed) {
          _loaded[key] = value;
          revision++;
          while (_loaded.length > 12) {
            _loaded.remove(_loaded.keys.first);
          }
        }
      } catch (_) {
        _retryAfter[key] = DateTime.now().add(const Duration(seconds: 15));
        rethrow;
      } finally {
        _pending.remove(key);
      }
    }
  }

  void close() {
    _closed = true;
    client.close();
  }
}
