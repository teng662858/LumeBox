import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
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
/// - **建连路径**：生产客户端**不许**装 `connectionFactory`（装了会把 https 变成明文，
///   见 `LumeNet._newClient` 的说明）——本文件用一条源码扫描守住这条纪律。
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

    test('关掉磁盘缓存的板块（漫画）：不读盘、也不落盘', () async {
      final library = await ReadingLibrary.open(Section.comic);
      final pipeline = SectionImagePipeline(
        cacheDir: library.imageCacheDir,
        memoryBudgetBytes: SectionImagePipeline.thumbnailBudgetBytes,
        // 漫画板块按用户要求关掉了图片缓存。
        diskCache: false,
      );
      addTearDown(pipeline.dispose);

      const url = 'https://example.com/cover.jpg';
      // 先手工落一份「旧缓存」：关掉磁盘缓存后它不该被读到。
      final target = pipeline.cachePathFor(url);
      File(target).parent.createSync(recursive: true);
      File(target).writeAsBytesSync(
        Uint8List.fromList(List<int>.generate(1024, (i) => i % 251)),
      );

      // 测试环境里一切真实网络请求都会失败（flutter_test 返回 400）：
      // 拿到 null 恰好证明**没有读盘**。
      final loaded = await pipeline.bytes(url);
      expect(loaded, isNull, reason: '关了磁盘缓存就不再读盘');

      // 再看一眼目录：看漫画不会往里新增文件。
      final dir = Directory(library.imageCacheDir);
      final before = dir.listSync(recursive: true).whereType<File>().length;
      await pipeline.bytes('https://example.com/another.jpg');
      final after = dir.listSync(recursive: true).whereType<File>().length;
      expect(after, before, reason: '关了磁盘缓存就不再落盘');
    });
  });

  group('建连路径（回归：DNS 缓存那层曾把 https 变成明文）', () {
    test('生产代码不装 connectionFactory', () {
      // 背景：dart:io 一旦设置了 connectionFactory，工厂返回的 socket 会被**原样**
      // 使用，TLS 握手不会发生——所有 https 请求变成「明文打到 443 端口」：
      // nginx 回 400（真机「拉取失败：HTTP 400」），或回一个指向自己的 302
      // （真机「Redirect loop detected」）。上一轮正是为 DNS 解析缓存装了这个工厂。
      // `flutter test` 里 HTTP 是被 mock 的（一律 400），环境测不出这类问题，
      // 因此用一条源码扫描把这条纪律钉住（说明见 LumeNet._newClient 的注释）。
      final offenders = <String>[];
      for (final entity in Directory('lib').listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final lines = entity.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          final code = lines[i].split('//').first;
          if (code.contains('connectionFactory')) {
            offenders.add('${entity.path}:${i + 1}');
          }
        }
      }
      expect(
        offenders,
        isEmpty,
        reason: '装了 connectionFactory 就等于关掉 TLS 握手：$offenders',
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

