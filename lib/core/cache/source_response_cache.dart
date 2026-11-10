import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../net/network_cancellation.dart';
import '../session/section.dart';
import 'media_preload.dart';
import 'section_memory_cache.dart';

/// Cache source metadata only. Playback URLs, chapter bodies, live covers and
/// actions always bypass it. Keys include all arguments and source settings.
abstract final class SourceResponseCache {
  static final _pending =
      <(Object, Section, String, String, Object?, int), Future<Object?>>{};
  static final _versions = <Section, int>{};
  static final Object _bypass = Object();

  static const methods = {
    'home',
    'homeVod',
    'homeVideo',
    'list',
    'category',
    'search',
    'categories',
    'detail',
    'chapters',
    'chapterPage',
    'filters',
  };
  static bool get bypassed => Zone.current[_bypass] == true;
  static T fresh<T>(T Function() action) =>
      runZoned(action, zoneValues: {_bypass: true});
  static void invalidate(Section section) {
    _versions[section] = (_versions[section] ?? 0) + 1;
    SectionMemoryCache.instance.clear(section);
  }

  static Future<T> read<T>({
    required SourceReadCache cache,
    required Section section,
    required String sourceId,
    required String method,
    Object? arguments,
    Object? settings,
    required Future<T> Function() load,
  }) async {
    NetworkCancellation.current?.check();
    if (!MediaPreload.instance.pages || !methods.contains(method)) {
      return load();
    }
    final bypass = bypassed;
    final key =
        'response/${sha256.convert(utf8.encode(jsonEncode(_canonical([method, arguments, settings]))))}';
    final cached = cache.read(section, sourceId, key);
    if (!bypass &&
        cached is Map &&
        cached['at'] is int &&
        cached['value'] is T &&
        DateTime.now().millisecondsSinceEpoch - (cached['at'] as int) <
            MediaPreload.instance.pageCacheSeconds * 1000) {
      NetworkCancellation.current?.check();
      return cached['value'] as T;
    }
    final version = _versions[section] ?? 0;
    final generation = cache is SectionMemoryCache ? cache.generation : 0;
    // Owners stay separate: leaving one page must not cancel another page's load.
    final identity = (
      cache,
      section,
      sourceId,
      key,
      bypass
          ? (NetworkCancellation.current, true)
          : NetworkCancellation.current,
      version + generation,
    );
    final pending = _pending[identity];
    if (pending != null) return (await pending) as T;
    if (_pending.length >= 128) return load();
    final task = Future<T>.sync(load).then((value) {
      NetworkCancellation.current?.check();
      if (MediaPreload.instance.pages &&
          value != null &&
          version == (_versions[section] ?? 0) &&
          (cache is! SectionMemoryCache || generation == cache.generation)) {
        cache.write(section, sourceId, key, {
          'at': DateTime.now().millisecondsSinceEpoch,
          'value': value,
        });
      }
      return value;
    });
    _pending[identity] = task;
    try {
      return await task;
    } finally {
      if (identical(_pending[identity], task)) _pending.remove(identity);
    }
  }

  static Object? _canonical(Object? value) {
    if (value is Map) {
      final keys = value.keys.map((k) => '$k').toList()..sort();
      return {for (final k in keys) k: _canonical(value[k])};
    }
    if (value is List) return value.map(_canonical).toList();
    return value;
  }
}
