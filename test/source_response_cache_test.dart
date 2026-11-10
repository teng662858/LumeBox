import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/cache/media_preload.dart';
import 'package:lume_box/core/cache/section_memory_cache.dart';
import 'package:lume_box/core/cache/source_response_cache.dart';
import 'package:lume_box/core/net/network_cancellation.dart';
import 'package:lume_box/core/session/section.dart';

void main() {
  late SectionMemoryCache cache;
  setUp(() {
    cache = SectionMemoryCache();
    MediaPreload.instance.pages = true;
    MediaPreload.instance.pageCacheSeconds = 120;
  });
  test('identical reads share work; arguments, settings, source and section stay isolated', () async {
    var calls = 0;
    final gate = Completer<Map<String, dynamic>>();
    Future<Map<String, dynamic>> read({
      int page = 1,
      String id = 'a',
      Section section = Section.video,
      Object? settings = const {'a': 1, 'b': 2},
    }) => SourceResponseCache.read(
      cache: cache,
      section: section,
      sourceId: id,
      method: 'list',
      arguments: {'page': page},
      settings: settings,
      load: () {
        calls++;
        return gate.future;
      },
    );
    final first = read();
    final same = read(settings: {'b': 2, 'a': 1});
    gate.complete({
      'items': ['first'],
    });
    expect(await first, await same);
    expect(calls, 1);
    await read();
    expect(calls, 1);
    await read(page: 2);
    await read(id: 'b');
    await read(section: Section.comic);
    await read(settings: {'a': 3});
    expect(calls, 5);
  });
  test('refresh bypasses old value and updates cache; errors do not poison retries', () async {
    var calls = 0;
    Future<int> read() => SourceResponseCache.read(
      cache: cache,
      section: Section.video,
      sourceId: 'a',
      method: 'home',
      load: () async => ++calls,
    );
    expect(await read(), 1);
    expect(await read(), 1);
    expect(await SourceResponseCache.fresh(read), 2);
    expect(await read(), 2);
    cache.clearAll();
    await expectLater(
      SourceResponseCache.read<int>(
        cache: cache,
        section: Section.video,
        sourceId: 'a',
        method: 'home',
        load: () async => throw StateError('offline'),
      ),
      throwsStateError,
    );
    expect(await read(), 3);
  });
  test(
    'clear or source replacement prevents late cache resurrection',
    () async {
      final gate = Completer<int>();
      final old = SourceResponseCache.read(
        cache: cache,
        section: Section.video,
        sourceId: 'a',
        method: 'home',
        load: () => gate.future,
      );
      cache.removeSource(Section.video, 'a');
      gate.complete(1);
      await old;
      expect(cache.usageOf(Section.video).entries, 0);
      expect(
        await SourceResponseCache.read(
          cache: cache,
          section: Section.video,
          sourceId: 'a',
          method: 'home',
          load: () async => 2,
        ),
        2,
      );
    },
  );
  test('different page owners never share cancellation', () async {
    final a = NetworkCancellation(), b = NetworkCancellation();
    final gate = Completer<int>();
    var calls = 0;
    Future<int> read() => SourceResponseCache.read(
      cache: cache,
      section: Section.video,
      sourceId: 'a',
      method: 'home',
      load: () {
        calls++;
        return gate.future;
      },
    );
    final one = NetworkCancellation.runWith(a, read);
    final two = NetworkCancellation.runWith(b, read);
    final failure = expectLater(one, throwsA(isA<NetworkCancelled>()));
    a.cancel();
    gate.complete(2);
    await failure;
    expect(await two, 2);
    expect(calls, 2);
  });
  test('playback URLs, bodies and actions are never cached', () async {
    for (final method in ['play', 'content', 'settingsAction', 'danmaku']) {
      var calls = 0;
      Future<int> read() => SourceResponseCache.read(
        cache: cache,
        section: Section.video,
        sourceId: 'a',
        method: method,
        load: () async => ++calls,
      );
      await read();
      expect(await read(), 2);
    }
  });
  test('disabled cache does not reuse a previous result', () async {
    var calls = 0;
    Future<int> read() => SourceResponseCache.read(
      cache: cache,
      section: Section.video,
      sourceId: 'a',
      method: 'home',
      load: () async => ++calls,
    );
    await read();
    MediaPreload.instance.pages = false;
    expect(await read(), 2);
    expect(await read(), 3);
  });
}
