import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lume_box/core/cache/media_preload.dart';
import 'package:lume_box/core/net/lume_http.dart';
import 'package:lume_box/core/net/network_queue.dart';
import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/core/source/source_favicon.dart';
import 'package:lume_box/core/tmdb/tmdb.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  setUp(() async {
    root = Directory.systemTemp.createTempSync('preload-management-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => root.path,
        );
    await MediaPreload.instance.boot(directory: root);
  });
  tearDown(() async {
    ReadingLibrary.disposeAll();
    ReadingStore.disposeAll();
    await SectionScope.closeAll();
    MediaPreload.instance.update(
      video: true,
      audio: true,
      images: true,
      capacityMb: 64,
      bufferSeconds: 5,
      triggerSeconds: 30,
    );
    await MediaPreload.instance.flush();
    root.deleteSync(recursive: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
  });
  final png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAF/gH8YQ3GAAAAAElFTkSuQmCC',
  );

  test('queued preload writes yield to UI and clear invalidates queued generations', () async {
    final policy = MediaPreload.instance;
    var responded = false;
    Timer.run(() => responded = true);
    await policy.cacheImage('large', Uint8List(1024 * 1024), policy.generation);
    expect(responded, isTrue);
    expect(await policy.image('large'), hasLength(1024 * 1024));
    final generation = policy.generation;
    final writes = [
      policy.cacheImage('queued-a', png, generation),
      policy.cacheImage('queued-b', png, generation),
    ];
    await policy.clear();
    await Future.wait(writes);
    expect(policy.diskBytes, 0);
    expect(await policy.image('large'), isNull);
    expect(await policy.image('queued-a'), isNull);
    expect(await policy.image('queued-b'), isNull);
  });

  test('预载设置可重开恢复，预算有界；清理隔离普通文件并拒绝晚到写入', () async {
    final policy = MediaPreload();
    await policy.boot(directory: root);
    policy.update(
      video: false,
      audio: false,
      images: true,
      triggerSeconds: 90,
      bufferSeconds: 30,
      capacityMb: 16,
    );
    await policy.flush();
    final reopened = MediaPreload();
    await reopened.boot(directory: root);
    expect(reopened.video, false);
    expect(reopened.audio, false);
    expect(reopened.triggerSeconds, 90);
    expect(reopened.bufferSeconds, 30);
    expect(reopened.mediaBudgetBytes, 4 * 1024 * 1024);
    final ordinary = File('${root.path}/ordinary.bin')
      ..writeAsStringSync('keep');
    final stale = policy.generation;
    await policy.cacheImage('first', Uint8List(5 * 1024 * 1024), stale);
    await policy.cacheImage('second', Uint8List(5 * 1024 * 1024), stale);
    expect(policy.diskBytes, lessThanOrEqualTo(8 * 1024 * 1024));
    var cleared = 0;
    final remove = policy.onClear(() => cleared++);
    expect(await policy.clear(), greaterThan(0));
    expect(cleared, 1);
    await policy.cacheImage('late', png, stale);
    expect(policy.diskBytes, 0);
    expect(ordinary.readAsStringSync(), 'keep');
    remove();
    await policy.flush();
    policy.dispose();
    reopened.dispose();
  });

  test('关闭图片预载不影响可见图片；预载缓存和普通缓存可分别清理', () async {
    final policy = MediaPreload.instance;
    await policy.boot(directory: root);
    policy.update(images: false);
    var requests = 0;
    final pipeline = SectionImagePipeline(
      cacheDir: '${root.path}/images',
      requestSender: (_) async {
        requests++;
        return NetworkResponse(
          statusCode: 200,
          body: png,
          headers: const {'content-type': 'image/png'},
        );
      },
    );
    addTearDown(pipeline.dispose);
    pipeline.preload(['https://fixture.test/a.png']);
    await Future<void>.delayed(Duration.zero);
    expect(requests, 0);
    expect(await pipeline.bytes('https://fixture.test/visible.png'), png);
    final visibleFile = File(
      pipeline.cachePathFor('https://fixture.test/visible.png'),
    );
    expect(visibleFile.existsSync(), true);
    policy.update(images: true);
    await pipeline.bytes('https://fixture.test/next.png', preload: true);
    expect(policy.diskBytes, greaterThan(0));
    expect(
      File(pipeline.cachePathFor('https://fixture.test/next.png')).existsSync(),
      false,
    );
    await policy.clear();
    expect(policy.diskBytes, 0);
    expect(visibleFile.existsSync(), true);
  });

  test('清理时在飞图片请求不能重新生成预载缓存', () async {
    final policy = MediaPreload.instance;
    await policy.boot(directory: root);
    final response = Completer<NetworkResponse>();
    final pipeline = SectionImagePipeline(
      cacheDir: '${root.path}/images',
      requestSender: (_) => response.future,
    );
    addTearDown(pipeline.dispose);
    final task = pipeline.bytes('https://fixture.test/late.png', preload: true);
    await Future<void>.delayed(Duration.zero);
    await policy.clear();
    response.complete(
      NetworkResponse(
        statusCode: 200,
        body: png,
        headers: const {'content-type': 'image/png'},
      ),
    );
    expect(await task, png);
    expect(policy.diskBytes, 0);
  });

  test('TMDB 单独清理资料，不删除密钥和代理配置', () async {
    final settings = TmdbSettings();
    await settings.boot();
    settings.enabled = true;
    settings.apiKey = 'fixture-only';
    settings.apiProxy = 'https://api.fixture.test';
    await settings.save();
    final key = settings.cacheKey('影片');
    await settings.cache(key, const TmdbMetadata(overview: '资料', posters: []));
    expect(await settings.clearMetadataCache(), 1);
    expect(await settings.cached(key), isNull);
    final reopened = TmdbSettings();
    await reopened.boot();
    expect(reopened.apiKey, 'fixture-only');
    expect(reopened.apiProxy, 'https://api.fixture.test');
    expect(await reopened.cached(key), isNull);
  });

  test('图标清理只删自动缓存，保留自定义图标包文件', () async {
    final directory = Directory('${root.path}/icons')..createSync();
    final custom = File('${directory.path}/custom.png')..writeAsBytesSync(png);
    final resolver = SourceFavicon(
      cacheDirectory: () async => directory,
      http: LumeHttp(
        client: MockClient((_) async => http.Response.bytes(png, 200)),
      ),
    );
    await resolver.load(origin: 'https://fixture.test');
    expect(await resolver.clearDiskCache(), greaterThan(0));
    expect(directory.listSync().length, 1);
    expect(custom.existsSync(), true);
    expect(resolver.cached(origin: 'https://fixture.test'), isNull);
  });

  test('清空历史覆盖超过500条和隐藏条目，保留收藏及其它板块', () async {
    final library = await ReadingLibrary.open(Section.video);
    for (var i = 0; i < 502; i++) {
      library.recordHistoryItem(
        sourceId: i == 501 ? 'p5mh_comic' : 's',
        itemId: '$i',
        title: '条目$i',
      );
    }
    library.shelve(sourceId: 's', itemId: 'favorite', title: '收藏');
    final other = await ReadingLibrary.open(Section.comic);
    other.recordHistoryItem(sourceId: 'c', itemId: 'keep', title: '其它板块');
    expect(library.clearHistory(), 502);
    expect(library.history(), isEmpty);
    expect(library.onShelf('favorite'), true);
    expect(other.history().single.itemId, 'keep');
  });
}
