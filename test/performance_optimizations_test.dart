import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/net/dns_cache.dart';
import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/features/shell/section_preloader.dart';

import 'support/fake_source_manager.dart';

/// 性能优化三件事的单元校验（真机反馈：切板块 / 封面 / 代理都慢）。
///
/// - **章节详情与封面**：磁盘缓存命中即不再发网络（用「没有网络的测试环境」证明）；
/// - **切板块预加载**：[SectionPreloader] 的预热结果能被页面取走、过期即失效、
///   下拉刷新会丢弃；
/// - **网络链路**：[DnsCache] 的 TTL 与「失败即失效重解析」。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('lume_box_perf');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => call.method == 'getApplicationSupportDirectory'
          ? root.path
          : null,
    );
    for (final section in Section.values) {
      await SectionScope.open(section);
    }
    SectionPreloader.discard();
  });

  tearDown(() async {
    SectionPreloader.discard();
    ReadingLibrary.disposeAll();
    ReadingStore.disposeAll();
    await SectionScope.closeAll();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  group('封面磁盘缓存', () {
    test('已经下载过的封面：直接读本地，不再发网络请求', () async {
      final library = await ReadingLibrary.open(Section.comic);
      final pipeline = SectionImagePipeline(
        cacheDir: library.imageCacheDir,
        memoryBudgetBytes: SectionImagePipeline.thumbnailBudgetBytes,
      );
      addTearDown(pipeline.dispose);

      const url = 'https://example.com/cover.jpg';
      // 预热前先落盘一份（模拟「上次已经加载过」）。
      final cacheDir = Directory(library.imageCacheDir);
      cacheDir.createSync(recursive: true);
      final bytes = Uint8List.fromList(List<int>.generate(2048, (i) => i % 251));
      final target = pipeline.cachePathFor(url);
      File(target).parent.createSync(recursive: true);
      File(target).writeAsBytesSync(bytes);

      // 测试环境里一切真实网络请求都会失败（flutter_test 返回 400）：
      // 能拿到字节就说明走的是磁盘缓存这条路径。
      final loaded = await pipeline.bytes(url);
      expect(loaded, isNotNull, reason: '磁盘缓存命中');
      expect(loaded, equals(bytes));
    });

    test('缓存路径按 URL 稳定推导（同 URL 命中同一份文件）', () {
      final pipeline = SectionImagePipeline(
        cacheDir: root.path,
        memoryBudgetBytes: SectionImagePipeline.thumbnailBudgetBytes,
      );
      addTearDown(pipeline.dispose);
      expect(
        pipeline.cachePathFor('https://example.com/a.jpg'),
        pipeline.cachePathFor('https://example.com/a.jpg'),
      );
      expect(
        pipeline.cachePathFor('https://example.com/a.jpg'),
        isNot(pipeline.cachePathFor('https://example.com/b.jpg')),
      );
    });
  });

  group('切板块预加载', () {
    test('预热结果能被子页面取走（同一源 / 分类 / 关键词才算命中）', () async {
      final source = _WarmSource();
      final manager = FakeSourceManager(
        sources: const <SourceDescriptor>[
          SourceDescriptor(
            id: 'warm-source',
            name: '预热源',
            version: '1',
            enabled: true,
          ),
        ],
        opened: <String, DataSource>{'warm-source': source},
      );
      var libraryOpened = false;

      await SectionPreloader.warm(
        Section.video,
        manager: manager,
        openLibrary: () async => libraryOpened = true,
      );

      expect(libraryOpened, isTrue, reason: '预热要顺手把阅读库打开');
      expect(source.listCalls, <int>[1], reason: '预热取了第一页');
      expect(SectionPreloader.hasWarm(Section.video), isTrue);

      final warm = SectionPreloader.takeWarmPage(
        Section.video,
        sourceId: 'warm-source',
      );
      expect(warm, isNotNull);
      expect(warm!.items, hasLength(2));
      // 取走即失效：同一份预热不会喂给两个页面。
      expect(SectionPreloader.hasWarm(Section.video), isFalse);
    });

    test('源不一致 / 刷新丢弃：不命中', () async {
      final source = _WarmSource();
      final manager = FakeSourceManager(
        sources: const <SourceDescriptor>[
          SourceDescriptor(
            id: 'warm-source',
            name: '预热源',
            version: '1',
            enabled: true,
          ),
        ],
        opened: <String, DataSource>{'warm-source': source},
      );
      await SectionPreloader.warm(Section.video, manager: manager);

      expect(
        SectionPreloader.takeWarmPage(
          Section.video,
          sourceId: 'another-source',
        ),
        isNull,
        reason: '换源后不同源不能用同一份预热',
      );
      expect(
        SectionPreloader.takeWarmPage(
          Section.video,
          sourceId: 'warm-source',
          categoryId: 'c1',
        ),
        isNull,
        reason: '换分类不算命中',
      );

      // 预热还在（前两次都没命中），discard 之后就没了。
      expect(SectionPreloader.hasWarm(Section.video), isTrue);
      SectionPreloader.discard(Section.video);
      expect(SectionPreloader.hasWarm(Section.video), isFalse);
    });

    test('预热失败不影响任何事（不抛异常、不设错误态）', () async {
      final manager = FakeSourceManager(
        sources: const <SourceDescriptor>[
          SourceDescriptor(
            id: 'broken',
            name: '坏源',
            version: '1',
            enabled: true,
          ),
        ],
        // 未登记 → open 返回 null → 预热到此为止。
        opened: const <String, DataSource>{},
      );
      await SectionPreloader.warm(Section.novel, manager: manager);
      expect(SectionPreloader.hasWarm(Section.novel), isFalse);
    });
  });

  group('DNS 缓存', () {
    test('TTL 内命中缓存，过期后重新解析', () async {
      var lookups = 0;
      final cache = DnsCache(
        ttl: const Duration(minutes: 5),
        lookup: (host) async {
          lookups++;
          return <InternetAddress>[InternetAddress('10.0.0.$lookups')];
        },
      );
      final start = DateTime(2026, 10, 7, 12);

      final first = await cache.resolve('example.com', start);
      expect(first.address, '10.0.0.1');
      expect(lookups, 1);

      // TTL 内：不再解析。
      final second = await cache.resolve(
        'example.com',
        start.add(const Duration(minutes: 4)),
      );
      expect(second.address, '10.0.0.1');
      expect(lookups, 1, reason: '5 分钟内用缓存');

      // 过期：重新解析。
      final third = await cache.resolve(
        'example.com',
        start.add(const Duration(minutes: 6)),
      );
      expect(third.address, '10.0.0.2');
      expect(lookups, 2);
      expect(cache.hits, 1);
      expect(cache.misses, 2);
    });

    test('失败即失效：调用方可以立刻重新解析（CDN 换 IP 的兜底）', () async {
      var lookups = 0;
      final cache = DnsCache(
        lookup: (host) async {
          lookups++;
          return <InternetAddress>[InternetAddress('10.0.1.$lookups')];
        },
      );
      final now = DateTime(2026, 10, 7);
      await cache.resolve('cdn.example.com', now);
      expect(cache.size, 1);

      cache.invalidate('cdn.example.com');
      expect(cache.size, 0, reason: '失效后下一次必然重新解析');
      final next = await cache.resolve('cdn.example.com', now);
      expect(next.address, '10.0.1.2');
      expect(lookups, 2);
    });

    test('解析结果为空：如实报域名解析失败', () async {
      final cache = DnsCache(lookup: (host) async => <InternetAddress>[]);
      await expectLater(
        cache.resolve('nowhere.example', DateTime(2026, 10, 7)),
        throwsA(isA<SocketException>()),
      );
    });
  });
}

/// 预热用图源替身：记录请求的页码。
class _WarmSource implements DataSource {
  final List<int> listCalls = <int>[];

  @override
  String get id => 'warm-source';

  @override
  String get name => '预热源';

  @override
  Section get section => Section.video;

  @override
  Future<List<SourceCategory>> categories() async => const <SourceCategory>[];

  @override
  Future<SourceList> list({String? categoryId, String? keyword, int page = 1}) async {
    listCalls.add(page);
    return SourceList(
      items: const <SourceItem>[
        SourceItem(id: 'w1', title: '预热条目一'),
        SourceItem(id: 'w2', title: '预热条目二'),
      ],
      hasMore: true,
    );
  }

  @override
  Future<SourceDetail?> detail(String itemId) async => null;

  @override
  Future<List<SourceChapter>> chapters(String itemId) async =>
      const <SourceChapter>[];

  @override
  Future<ChapterContent?> content({
    required String itemId,
    required String chapterId,
  }) async =>
      null;
}
