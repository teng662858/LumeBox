import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/media/media_library.dart';
import 'package:lume_box/core/net/network_queue.dart';
import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/features/comic/comic_detail_page.dart';
import 'package:lume_box/features/comic/comic_reader_page.dart';
import 'package:lume_box/shared/widgets/source_translation.dart';

import 'support/fake_reading_source.dart';
import 'support/fake_source_manager.dart';

class MixedTitleComicSource extends CompactComicSource {
  @override
  Future<List<SourceChapter>> chapters(String itemId) async => const [
    SourceChapter(id: 'one', title: '第1话'),
    SourceChapter(id: 'extra', title: '特别篇'),
    SourceChapter(id: 'long', title: '这是一段超过十八个字的章节标题，也应保持统一的方格选集'),
  ];
}

class CompactComicSource extends FakeReadingDataSource {
  CompactComicSource({this.gallery = false})
    : super(
        section: Section.comic,
        chapterCount: gallery ? 1 : 30,
        imageCount: 8,
      );
  final bool gallery;
  int contentCalls = 0;
  @override
  Future<SourceDetail?> detail(String id) async => SourceDetail(
    mediaType: 'comic',
    id: id,
    title: '星河漫游',
    author: '示例作者',
    status: '连载中',
    tags: const ['科幻', '冒险'],
    description: List.filled(8, '来自源的真实简介字段，用于验证两行摘要与展开。').join(),
  );
  @override
  Future<ChapterContent?> content({
    required String itemId,
    required String chapterId,
  }) async {
    contentCalls++;
    return super.content(itemId: itemId, chapterId: chapterId);
  }
}

class LoadingAudioSource extends CompactComicSource {
  final pending = Completer<List<SourceChapter>>();
  @override
  Future<SourceDetail?> detail(String id) async =>
      SourceDetail(id: id, title: '有声作品');
  @override
  Future<List<SourceChapter>> chapters(String itemId) => pending.future;
}

class LoadingNovelSource extends LoadingAudioSource {
  int detailCalls = 0;
  @override
  Future<SourceDetail?> detail(String id) async {
    detailCalls++;
    return SourceDetail(id: id, title: '小说作品', mediaType: 'novel');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late ReadingLibrary library;
  late SectionImagePipeline pipeline;
  const target = ReadingTarget(sourceId: 'a', itemId: 'book', title: '星河漫游');
  setUp(() async {
    root = Directory.systemTemp.createTempSync('comic-compact');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => root.path,
        );
    await MediaLibrary.instance.boot();
    library = await ReadingLibrary.open(Section.comic);
    final bytes = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jN1sAAAAASUVORK5CYII=',
    );
    pipeline = SectionImagePipeline(
      cacheDir: library.imageCacheDir,
      diskCache: false,
      requestSender: (_) async => NetworkResponse(
        statusCode: 200,
        body: bytes,
        headers: const {'content-type': 'image/png'},
      ),
    );
  });
  tearDown(() async {
    pipeline.dispose();
    ReadingLibrary.disposeAll();
    ReadingStore.disposeAll();
    await SectionScope.closeAll();
    root.deleteSync(recursive: true);
  });
  Future<void> open(
    WidgetTester tester,
    CompactComicSource source, {
    double scale = 1,
    double width = 440,
    bool dark = false,
  }) async {
    await tester.binding.setSurfaceSize(Size(width, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final manager = FakeSourceManager(
      sources: [
        SourceDescriptor(
          id: 'a',
          name: '示例源',
          version: '1',
          enabled: true,
          group: source.gallery ? '美图' : '漫画',
        ),
      ],
      opened: {'a': source},
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.deepPurple,
            brightness: dark ? Brightness.dark : Brightness.light,
          ),
        ),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: ComicDetailPage(
          library: library,
          manager: manager,
          target: target,
          imagePipeline: pipeline,
          runtimeAvailable: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('有声源目录尚未加载时显示有声详情与收听入口', (tester) async {
    final source = LoadingAudioSource();
    await tester.pumpWidget(
      MaterialApp(
        home: ComicDetailPage(
          library: library,
          manager: FakeSourceManager(
            sources: const [
              SourceDescriptor(
                id: 'a',
                name: '听书源',
                version: '1',
                enabled: true,
                mediaKind: 'audio',
              ),
            ],
            opened: {'a': source},
          ),
          target: target,
          imagePipeline: pipeline,
          runtimeAvailable: true,
        ),
      ),
    );
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('有声详情'), findsOneWidget);
    expect(find.text('开始收听'), findsOneWidget);
    expect(find.text('漫画详情'), findsNothing);
    expect(find.text('开始阅读'), findsNothing);
    expect(find.text('章节加载中…'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    source.pending.complete([]);
    await tester.pumpAndSettle();
  });

  testWidgets('小说源目录未完成前直接进入小说详情且只请求一次详情', (tester) async {
    final source = LoadingNovelSource();
    await tester.pumpWidget(
      MaterialApp(
        home: ComicDetailPage(
          library: library,
          manager: FakeSourceManager(
            sources: const [
              SourceDescriptor(
                id: 'a',
                name: '小说源',
                version: '1',
                enabled: true,
                mediaKind: 'novel',
              ),
            ],
            opened: {'a': source},
          ),
          target: target,
          imagePipeline: pipeline,
          runtimeAvailable: true,
        ),
      ),
    );
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('小说详情'), findsOneWidget);
    expect(find.text('漫画详情'), findsNothing);
    expect(source.detailCalls, 1);
    await tester.pumpWidget(const SizedBox());
    source.pending.complete([]);
    await tester.pumpAndSettle();
  });

  test('扩展详情只解析源提供的元信息，旧格式保持兼容', () {
    final metadata = SourceDetail.parse({
      'id': 'b',
      'title': '书名',
      'authors': ['作者甲', '作者乙'],
      'status': '连载中',
      'tags': ['冒险', ' '],
      'updatedAt': '2026-10-24',
      'related': [
        {'id': 'r', 'title': '同源作品'},
      ],
    })!;
    expect(metadata.author, '作者甲、作者乙');
    expect(metadata.tags, ['冒险']);
    expect(metadata.updatedAt!.day, 24);
    expect(metadata.related.single.id, 'r');
    expect(SourceDetail.parse({'id': 'b', 'title': '旧源'})!.author, isNull);
  });
  testWidgets('紧凑版有番外或长标题也使用统一方格，放大文字不退回整行列表', (tester) async {
    await open(tester, MixedTitleComicSource(), width: 390, scale: 1.5);
    expect(find.byType(SliverGrid), findsOneWidget);
    final first = find.byKey(const ValueKey('comic-detail-chapter-0'));
    await tester.ensureVisible(first);
    await tester.pumpAndSettle();
    final second = find.byKey(const ValueKey('comic-detail-chapter-1'));
    expect(tester.getRect(first).top, closeTo(tester.getRect(second).top, .1));
    expect(tester.getSize(first).width, lessThan(195));
    expect(find.text('特别篇'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('新版摘要、搜索与两版切换共享状态且记住选择', (tester) async {
    final source = CompactComicSource();
    await open(tester, source);
    expect(find.byKey(const Key('comic-detail-compact')), findsOneWidget);
    expect(find.text('作者 · 示例作者'), findsOneWidget);
    expect(source.contentCalls, 0, reason: '漫画详情不预读正文');
    final description = find.byKey(const Key('comic-detail-description'));
    expect(
      tester
          .widget<SourceText>(
            find.descendant(of: description, matching: find.byType(SourceText)),
          )
          .maxLines,
      2,
    );
    await tester.tap(description);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<SourceText>(
            find.descendant(of: description, matching: find.byType(SourceText)),
          )
          .maxLines,
      isNull,
    );
    await tester.ensureVisible(
      find.byKey(const Key('comic-detail-chapter-search')),
    );
    await tester.enterText(
      find.byKey(const Key('comic-detail-chapter-search')),
      '第 12 章',
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('comic-detail-chapter-11')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('comic-detail-chapter-0')), findsNothing);
    await tester.tap(find.byKey(const Key('comic-detail-layout')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('原版详情页'));
    await tester.tap(
      find.ancestor(
        of: find.text('原版详情页'),
        matching: find.byType(CheckedPopupMenuItem<bool>),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('comic-detail-compact')), findsNothing);
    expect(library.setting('comic.detail.compactLayout'), 'false');
    await tester.tap(find.byKey(const Key('comic-detail-layout')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('紧凑版（新版）'));
    await tester.tap(
      find.ancestor(
        of: find.text('紧凑版（新版）'),
        matching: find.byType(CheckedPopupMenuItem<bool>),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('comic-detail-chapter-11')),
      findsOneWidget,
    );
    expect(library.setting('comic.detail.compactLayout'), 'true');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('定位进度不改章节ID，继续阅读恢复真实章节和页码', (tester) async {
    library.saveProgress(
      ComicProgress(
        section: Section.comic,
        itemId: 'book',
        chapterIndex: 11,
        chapterId: 'book-c12',
        chapterTitle: '第 12 章',
        updatedAt: DateTime.now(),
        page: 7,
      ),
    );
    await open(tester, CompactComicSource());
    await tester.ensureVisible(find.byTooltip('定位上次阅读'));
    await tester.tap(find.byTooltip('定位上次阅读'));
    await tester.pumpAndSettle();
    expect(find.text('上次阅读 · 第 12 章'), findsOneWidget);
    expect(find.byKey(const ValueKey('comic-detail-chapter-0')), findsNothing);
    await tester.ensureVisible(find.byKey(const Key('comic-detail-read')));
    await tester.tap(find.byKey(const Key('comic-detail-read')));
    await tester.pumpAndSettle();
    final reader = tester.widget<ComicReaderPage>(find.byType(ComicReaderPage));
    expect(reader.initialChapterIndex, 11);
    expect(reader.initialPage, 7);
    expect(reader.chapters[11].id, 'book-c12');
    expect(library.onShelf('book'), false);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('图集仅预取真实首组内容，显示图片数量和六张预览', (tester) async {
    final source = CompactComicSource(gallery: true);
    await open(tester, source);
    expect(find.text('浏览图集'), findsOneWidget);
    expect(find.text('共 8 张图片'), findsOneWidget);
    expect(source.contentCalls, 1);
    expect(
      find.byKey(const Key('comic-detail-gallery-preview')),
      findsOneWidget,
    );
    expect(library.progress('book'), isNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('窄屏大字体与深色布局不溢出', (tester) async {
    await open(tester, CompactComicSource(), scale: 2, width: 320, dark: true);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
