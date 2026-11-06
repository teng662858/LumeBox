import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:lume_box/core/cache/media_preload.dart';
import 'package:lume_box/core/cat/cat_data_source.dart';
import 'package:lume_box/core/cat/cat_service.dart';
import 'package:lume_box/core/net/network_queue.dart';
import 'package:lume_box/core/net/network_settings.dart';
import 'package:lume_box/core/reading/cover_byte_cache.dart';
import 'package:lume_box/core/reading/cover_warmup.dart';
import 'package:lume_box/core/reading/image_pipeline.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/features/reading/cover_viewport.dart';
import 'package:lume_box/features/reading/section_image.dart';
import 'package:lume_box/features/shell/section_preloader.dart';

import 'support/fake_source_manager.dart';

final _png = Uint8List.fromList(img.encodePng(img.Image(width: 2, height: 2)));
NetworkResponse _response() =>
    NetworkResponse(statusCode: 200, body: _png, headers: const {});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    SectionPreloader.discard();
    CoverWarmup.discard();
    MediaPreload.instance.update(images: true);
  });

  test('lazy page cover resolves only in image queue and never forwards page credentials', () async {
    final cache = Directory.systemTemp.createTempSync('lazy-cover-');
    addTearDown(() => cache.deleteSync(recursive: true));
    final requests = <NetworkRequest>[];
    final pipeline = SectionImagePipeline(
      cacheDir: cache.path,
      diskCache: true,
      maxConcurrent: 1,
      maxRetries: 0,
      requestSender: (request) async {
        requests.add(request);
        if (request.url == 'https://books.test/book/1') {
          return NetworkResponse(
            statusCode: 200,
            headers: const {},
            body: utf8.encode(
              '<html><img src="/ad.png"><div class="imgbox"><img src="/blank.png" data-src="//cdn.test/cover.png"></div></html>',
            ),
          );
        }
        return _response();
      },
    );
    addTearDown(pipeline.dispose);
    pipeline.configureImageHeaders({
      'https://books.test/book/1': {
        'x-lume-image-page-selector': '.imgbox img',
        'Cookie': 'private=1',
        'Authorization': 'secret',
        'User-Agent': 'test-agent',
      },
    });
    expect(requests, isEmpty);
    expect(
      await pipeline.bytes('https://books.test/book/1'),
      orderedEquals(_png),
    );
    expect(requests.map((r) => r.url), [
      'https://books.test/book/1',
      'https://cdn.test/cover.png',
    ]);
    expect(
      requests.last.headers.keys.map((k) => k.toLowerCase()),
      isNot(
        anyElement(
          anyOf('cookie', 'authorization', 'x-lume-image-page-selector'),
        ),
      ),
    );
    expect(requests.last.headers['Referer'], 'https://books.test/book/1');
    await pipeline.bytes('https://books.test/book/1');
    expect(
      requests.length,
      2,
      reason: 'resolved bytes reuse the page URL cache',
    );
  });

  test('lazy page cover without an image or with a non-HTTP image stops without recursion', () async {
    for (final html in [
      '<html><p>No cover</p></html>',
      '<html><img src="javascript:bad()"></html>',
      '<html><img src="https://books.test/book/1"></html>',
    ]) {
      var calls = 0;
      final pipeline = SectionImagePipeline(
        cacheDir: '',
        diskCache: false,
        maxRetries: 0,
        requestSender: (_) async {
          calls++;
          return NetworkResponse(
            statusCode: 200,
            headers: const {},
            body: utf8.encode(html),
          );
        },
      );
      pipeline.configureImageHeaders({
        'https://books.test/book/1': {'x-lume-image-page-selector': 'img'},
      });
      expect(await pipeline.bytes('https://books.test/book/1'), isNull);
      expect(calls, 1);
      pipeline.dispose();
    }
  });

  test('thumbnail wins over the full cover and keeps its own headers', () {
    final item = SourceItem.parse({
      'id': 'a',
      'title': 'A',
      'cover': 'https://img.test/original.jpg',
      'thumbnail': 'https://img.test/small.jpg',
      'thumbnailHeaders': {'Referer': 'https://thumb.test/'},
      'coverHeaders': {'Referer': 'https://original.test/'},
    })!;
    expect(item.cover, 'https://img.test/small.jpg');
    expect(item.coverHeaders, {'Referer': 'https://thumb.test/'});
    expect(
      SourceItem.parse({
        'id': 'b',
        'title': 'B',
        'thumbnail': ' ',
        'cover': 'original',
      })!.cover,
      'original',
    );
    expect(
      SourceItem.parse({
        'id': 'c',
        'title': 'C',
        'thumb': 'small',
        'coverHeaders': {'A': 'B'},
      })!.coverHeaders,
      {'A': 'B'},
    );
  });

  test('original cover byte cache expires and evicts by byte budget', () {
    var now = DateTime.utc(2026, 10, 27);
    final cache = CoverByteCache(
      budgetBytes: 6,
      maxEntryBytes: 4,
      ttl: const Duration(seconds: 10),
      now: () => now,
    );
    cache.put('a', Uint8List(3));
    cache.put('b', Uint8List(3));
    expect(cache.get('a'), isNotNull);
    cache.put('c', Uint8List(3));
    expect(cache.get('b'), isNull);
    cache.put('large', Uint8List(5));
    expect(cache.get('large'), isNull);
    expect(cache.bytes, 6);
    now = now.add(const Duration(seconds: 11));
    expect(cache.get('a'), isNull);
    expect(cache.get('c'), isNull);
    expect(cache.bytes, 0);
  });

  test(
    'cat list uses explicit thumbnails while detail keeps the full cover',
    () {
      final source = CatDataSource(
        CatService.instance,
        const CatSite(subscriptionId: 'covers', key: 'a', name: 'A', api: '/a'),
      );
      final raw = <String, dynamic>{
        'vod_id': 'a',
        'vod_name': 'A',
        'vod_pic': 'https://img.test/original.jpg',
        'thumbnail': 'https://img.test/small.jpg',
        'thumbnailHeaders': {'Referer': 'https://thumb.test/'},
        'pic_headers': {'Referer': 'https://original.test/'},
      };
      expect(source.item(raw)!.cover, 'https://img.test/small.jpg');
      expect(source.item(raw)!.coverHeaders['Referer'], 'https://thumb.test/');
      expect(
        source.item(raw, preferThumbnail: false)!.cover,
        'https://img.test/original.jpg',
      );
      expect(
        source.item(raw, preferThumbnail: false)!.coverHeaders['Referer'],
        'https://original.test/',
      );
      raw['thumbnail'] = '';
      expect(source.item(raw)!.cover, 'https://img.test/original.jpg');
    },
  );

  test(
    'preload cleanup cancels active warming and rejects late original bytes',
    () async {
      final root = Directory.systemTemp.createTempSync('cover-clear-');
      addTearDown(() => root.deleteSync(recursive: true));
      final source = _Source();
      final items = (await source.list()).items;
      final gates = <Completer<NetworkResponse>>[];
      final warming = CoverWarmup.start(
        source: source,
        network: NetworkProfile.none,
        cacheDir: root.path,
        items: items,
        requestSender: (request) {
          final gate = Completer<NetworkResponse>();
          gates.add(gate);
          return request.cancellation!.guard(gate.future);
        },
      );
      await Future<void>.delayed(Duration.zero);
      expect(gates, hasLength(2));
      await MediaPreload.instance.clear();
      await warming;
      for (final gate in gates) {
        gate.complete(_response());
      }
      await Future<void>.delayed(Duration.zero);
      var freshRequests = 0;
      final parent = SectionImagePipeline(
        cacheDir: root.path,
        diskCache: false,
        requestSender: (_) async {
          freshRequests++;
          return _response();
        },
      );
      addTearDown(parent.dispose);
      final foreground = parent.forSource(
        Section.comic,
        source.id,
        NetworkProfile.none,
      )..bindSource(source);
      final first = items.first;
      foreground.configureImageHeaders({first.cover!: first.coverHeaders});
      await foreground.bytes(first.cover!);
      expect(freshRequests, 1);
      expect(
        gates,
        hasLength(2),
        reason: 'cleanup must not start further covers',
      );
    },
  );

  test('a foreground cover joins an active background download', () async {
    final root = Directory.systemTemp.createTempSync('cover-inflight-');
    addTearDown(() => root.deleteSync(recursive: true));
    final source = _Source();
    final item = (await source.list()).items.first;
    final gate = Completer<NetworkResponse>();
    var sends = 0;
    final queue = NetworkQueue(
      settings: const NetworkSettings(maxRetries: 0),
      sender: (_) {
        sends++;
        return gate.future;
      },
    );
    final warming = CoverWarmup.start(
      source: source,
      network: NetworkProfile.none,
      section: Section.cat,
      cacheDir: root.path,
      items: [item],
      requestSender: queue.send,
    );
    await Future<void>.delayed(Duration.zero);
    final parent = SectionImagePipeline(
      cacheDir: root.path,
      diskCache: false,
      requestSender: queue.send,
    );
    addTearDown(parent.dispose);
    final foreground = parent.forSource(
      Section.cat,
      source.id,
      NetworkProfile.none,
    )..bindSource(source);
    foreground.configureImageHeaders({item.cover!: item.coverHeaders});
    final showing = foreground.bytes(item.cover!);
    await Future<void>.delayed(Duration.zero);
    expect(sends, 1);
    gate.complete(_response());
    await warming;
    expect(await showing, _png);
    expect(sends, 1);
  });

  test('comic covers reuse bytes after page disposal, isolated by source and headers, without disk writes', () async {
    final root = Directory.systemTemp.createTempSync('cover-cache-');
    addTearDown(() => root.deleteSync(recursive: true));
    var sends = 0;
    SectionImagePipeline open(
      String source, {
      NetworkProfile profile = NetworkProfile.none,
    }) {
      final parent = SectionImagePipeline(
        cacheDir: root.path,
        diskCache: false,
        requestSender: (_) async {
          sends++;
          return _response();
        },
      );
      addTearDown(parent.dispose);
      return parent.forSource(Section.comic, source, profile);
    }

    final first = open('a');
    expect(await first.bytes('http://img.test/cover.png'), _png);
    first.dispose();
    final second = open('a');
    expect(await second.bytes('https://img.test/cover.png'), _png);
    expect(sends, 1);
    final small = await second.image(
      'https://img.test/cover.png',
      targetWidth: 200,
    );
    final large = await second.image(
      'https://img.test/cover.png',
      targetWidth: 300,
    );
    expect(small, isNotNull);
    expect(large, isNotNull);
    second.release('http://img.test/cover.png', targetWidth: 200);
    second.release('https://img.test/cover.png', targetWidth: 300);
    expect(sends, 1, reason: 'different decode buckets reuse original bytes');
    await open('b').bytes('https://img.test/cover.png');
    await open(
      'a',
      profile: const NetworkProfile(userAgent: 'different'),
    ).bytes('https://img.test/cover.png');
    second.configureImageHeaders({
      'https://img.test/cover.png': {'Referer': 'https://new.test/'},
    });
    await second.bytes('https://img.test/cover.png');
    expect(sends, 4);
    expect(root.listSync(recursive: true).whereType<File>(), isEmpty);
    await MediaPreload.instance.clear();
    await second.bytes('https://img.test/cover.png');
    expect(sends, 5, reason: 'clear also releases the transient byte cache');
  });

  test(
    'global slots prefer visible work and promote an existing shared preload',
    () async {
      final started = <String>[];
      final gate = Completer<void>();
      final queue = NetworkQueue(
        settings: const NetworkSettings(
          globalConcurrency: 1,
          perHostConcurrency: 1,
          maxRetries: 0,
        ),
        sender: (request) async {
          started.add(request.url);
          if (request.url.endsWith('/busy')) await gate.future;
          return _response();
        },
      );
      final busy = queue.send(
        const NetworkRequest(url: 'https://img.test/busy'),
      );
      await Future<void>.delayed(Duration.zero);
      final cold = queue.send(
        NetworkRequest(url: 'https://img.test/cold', isForeground: () => false),
      );
      final promoted = queue.send(
        NetworkRequest(
          url: 'https://img.test/promoted',
          isForeground: () => false,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      final visible = queue.send(
        const NetworkRequest(url: 'https://img.test/promoted'),
      );
      gate.complete();
      await Future.wait([busy, cold, promoted, visible]);
      expect(started, [
        'https://img.test/busy',
        'https://img.test/promoted',
        'https://img.test/cold',
      ]);
      expect(queue.activeGlobal, 0);
      expect(queue.waitingCount, 0);
    },
  );

  test(
    'image slots prioritize visible images and drop obsolete queued preloads',
    () async {
      final started = <String>[];
      final gate = Completer<void>();
      final pipeline = SectionImagePipeline(
        cacheDir: '',
        diskCache: false,
        maxConcurrent: 1,
        maxRetries: 0,
        requestSender: (request) async {
          started.add(Uri.parse(request.url).path);
          if (request.url.endsWith('/busy')) await gate.future;
          return _response();
        },
      );
      addTearDown(pipeline.dispose);
      final busy = pipeline.bytes('https://img.test/busy');
      await Future<void>.delayed(Duration.zero);
      final stale = pipeline.bytes('https://img.test/stale', preload: true);
      final next = pipeline.bytes('https://img.test/next', preload: true);
      final visible = pipeline.bytes('https://img.test/visible');
      pipeline.replacePreloads(['https://img.test/next']);
      gate.complete();
      await Future.wait([busy, stale, next, visible]);
      expect(started.take(2), ['/busy', '/visible']);
      expect(started, isNot(contains('/stale')));
      expect(started.where((path) => path == '/next'), hasLength(1));
    },
  );

  test('background list hands its first covers to the comic foreground without downloading twice', () async {
    final root = Directory.systemTemp.createTempSync('cover-warm-');
    addTearDown(() => root.deleteSync(recursive: true));
    final source = _Source();
    final manager = FakeSourceManager(
      sources: const [
        SourceDescriptor(id: 'warm', name: 'Warm', version: '1', enabled: true),
      ],
      opened: {'warm': source},
    );
    var sends = 0;
    Future<void>? images;
    await SectionPreloader.warm(
      Section.comic,
      manager: manager,
      preloadCovers: (source, descriptor, items) async {
        images = CoverWarmup.start(
          source: source,
          network: descriptor.network,
          cacheDir: root.path,
          items: items,
          requestSender: (request) async {
            expect(request.isForeground!(), isFalse);
            expect(request.headers['Referer'], 'https://site.test/');
            sends++;
            return _response();
          },
        );
      },
    );
    await images;
    expect(sends, 12);
    final base = SectionImagePipeline(
      cacheDir: root.path,
      diskCache: false,
      requestSender: (_) async {
        sends++;
        return _response();
      },
    );
    addTearDown(base.dispose);
    final pipeline = base.forSource(
      Section.comic,
      source.id,
      NetworkProfile.none,
    )..bindSource(source);
    final items = SectionPreloader.takeWarmPage(
      Section.comic,
      sourceId: source.id,
    )!.items;
    for (final item in items.take(12)) {
      pipeline.configureImageHeaders({item.cover!: item.coverHeaders});
      expect(await pipeline.bytes(item.cover!), _png);
    }
    expect(sends, 12);
    expect(root.listSync(recursive: true).whereType<File>(), isEmpty);
    MediaPreload.instance.update(images: false);
    await CoverWarmup.start(
      source: source,
      network: NetworkProfile.none,
      cacheDir: root.path,
      items: items,
      requestSender: (_) async {
        fail('disabled preloading must not send');
      },
    );
  });

  testWidgets(
    'cover viewport loads visible tiles first and skips queued covers after a fast scroll',
    (tester) async {
      final started = <String>[];
      final gates = <String, Completer<NetworkResponse>>{};
      final pipeline = SectionImagePipeline(
        cacheDir: '',
        diskCache: false,
        maxConcurrent: 1,
        maxRetries: 0,
        requestSender: (request) {
          final path = Uri.parse(request.url).path;
          started.add(path);
          return (gates[path] = Completer<NetworkResponse>()).future;
        },
      );
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      addTearDown(pipeline.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 100,
                height: 200,
                child: CoverViewport(
                  child: ListView.builder(
                    controller: scroll,
                    padding: EdgeInsets.zero,
                    itemExtent: 100,
                    scrollCacheExtent: const ScrollCacheExtent.viewport(1),
                    itemCount: 30,
                    itemBuilder: (_, index) => SectionImage(
                      pipeline: pipeline,
                      url: 'https://img.test/$index',
                      targetWidth: 200,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(started, ['/0']);
      gates['/0']!.complete(_response());
      await tester.pump();
      expect(started.take(2), ['/0', '/1']);
      scroll.jumpTo(1000);
      await tester.pump();
      await tester.pump();
      gates['/1']!.complete(_response());
      await tester.pump();
      expect(
        started[2],
        '/10',
        reason: 'old offscreen preloads must yield to the new viewport',
      );
      expect(started, isNot(contains('/3')));
      await tester.pumpWidget(const SizedBox());
      pipeline.dispose();
      for (final gate in gates.values) {
        if (!gate.isCompleted) gate.complete(_response());
      }
      await tester.pump();
    },
  );
}

class _Source implements DataSource {
  @override
  String get id => 'warm';
  @override
  Section get section => Section.comic;
  @override
  Future<SourceList> list({
    String? categoryId,
    int page = 1,
    String? keyword,
    Map<String, String>? filters,
  }) async => SourceList(
    items: List.generate(
      20,
      (index) => SourceItem(
        id: '$index',
        title: '$index',
        cover: 'https://img.test/$index',
        coverHeaders: const {'Referer': 'https://site.test/'},
      ),
    ),
    hasMore: false,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}
