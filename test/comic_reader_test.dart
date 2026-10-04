import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:path/path.dart' as p;

import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/features/comic/comic_reader_page.dart';
import 'package:lume_box/features/comic/comic_settings.dart';

import 'support/fake_reading_source.dart';

/// 漫画阅读器的验证：三种模式、调节控件落库、翻页推进进度，以及图片内存策略。
///
/// 图片地址指向不可达域名，因此画面走的是占位与失败态——本文件验证的是
/// 「阅读器的行为与资源纪律」，不是「能不能真的下载到图」。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late ReadingLibrary library;

  const target = ReadingTarget(
    sourceId: 'fake-src',
    itemId: 'item-1',
    title: '测试漫画',
  );

  setUp(() async {
    root = Directory.systemTemp.createTempSync('lume_box_comic_reader');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => call.method == 'getApplicationSupportDirectory'
              ? root.path
              : null,
        );
    library = await ReadingLibrary.open(Section.comic);
  });

  tearDown(() async {
    ReadingLibrary.disposeAll();
    ReadingStore.disposeAll();
    await SectionScope.closeAll();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  List<SourceChapter> chapters(int count) => <SourceChapter>[
        for (var index = 1; index <= count; index++)
          SourceChapter(id: 'item-1-c$index', title: '第 $index 章'),
      ];

  Future<void> pumpReader(WidgetTester tester, {int imageCount = 6}) async {
    await tester.binding.setSurfaceSize(const Size(420, 880));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: ComicReaderPage(
          library: library,
          dataSource: FakeReadingDataSource(
            section: Section.comic,
            imageCount: imageCount,
          ),
          target: target,
          chapters: chapters(3),
          initialChapterIndex: 0,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openToolbar(WidgetTester tester) async {
    await tester.tapAt(const Offset(210, 440));
    await tester.pumpAndSettle();
  }

  testWidgets('打开即入架，并在第一页落下进度', (tester) async {
    await pumpReader(tester);

    expect(library.onShelf(target.itemId), isTrue);
    final progress = library.comicProgress(target.itemId);
    expect(progress, isNotNull);
    expect(progress!.chapterIndex, 0);
    expect(progress.page, 0);
    // 条漫瀑布流是默认模式。
    expect(ComicReaderSettings.load(library).mode, ComicReadingMode.waterfall);
  });

  testWidgets('三种阅读模式可切换并落库', (tester) async {
    await pumpReader(tester);
    // 默认条漫：纵向连续滚动。
    expect(find.byType(ListView), findsOneWidget);

    await openToolbar(tester);
    await tester.tap(find.text('单页左右翻页'));
    await tester.pumpAndSettle();
    expect(ComicReaderSettings.load(library).mode, ComicReadingMode.single);
    expect(find.byType(PageView), findsOneWidget);

    await tester.tap(find.text('双页跨页'));
    await tester.pumpAndSettle();
    expect(ComicReaderSettings.load(library).mode, ComicReadingMode.doublePage);
    expect(find.byType(PageView), findsOneWidget);
  });

  testWidgets('单页模式翻页推进页序号', (tester) async {
    const ComicReaderSettings(mode: ComicReadingMode.single).save(library);
    await pumpReader(tester);

    await tester.drag(find.byType(PageView), const Offset(-400, 0));
    await tester.pumpAndSettle();
    // 进度落库有去抖，推一格时钟。
    await tester.pump(const Duration(milliseconds: 900));

    final progress = library.comicProgress(target.itemId)!;
    expect(progress.page, 1);
    expect(progress.chapterIndex, 0);
  });

  testWidgets('调节控件：侧边距与双击放大都会落库', (tester) async {
    await pumpReader(tester);
    await openToolbar(tester);

    // 侧边距滑杆：面板里第一根滑杆就是它。
    await tester.drag(find.byType(Slider).first, const Offset(80, 0));
    await tester.pumpAndSettle();
    expect(
      ComicReaderSettings.load(library).marginRatio,
      greaterThan(0),
      reason: '侧边距要落库，重进阅读器仍然生效',
    );

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(ComicReaderSettings.load(library).doubleTapZoom, isTrue);
  });

  testWidgets('章节目录面板可跳章', (tester) async {
    await pumpReader(tester);
    await openToolbar(tester);

    await tester.tap(find.byIcon(Icons.list));
    await tester.pumpAndSettle();
    expect(find.text('目录'), findsOneWidget);

    await tester.tap(find.text('第 3 章').last);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 900));

    final progress = library.comicProgress(target.itemId)!;
    expect(progress.chapterIndex, 2);
    expect(progress.page, 0);
  });

  group('图片内存策略', () {
    Future<ui.Image> makeImage(int size) {
      final completer = Completer<ui.Image>();
      ui.decodeImageFromPixels(
        Uint8List(size * size * 4),
        size,
        size,
        ui.PixelFormat.rgba8888,
        completer.complete,
      );
      return completer.future;
    }

    testWidgets('按预算淘汰最久未使用，引用中与钉住的都不回收', (tester) async {
      await tester.runAsync(() async {
        // 10 × 10 的位图 = 400 字节，预算 800 字节（两张）。
        final cache = ImageMemoryCache(800);
        final a = await makeImage(10);
        final b = await makeImage(10);
        final c = await makeImage(10);
        final d = await makeImage(10);
        final e = await makeImage(10);

        cache.put('a', a);
        cache.put('b', b);
        expect(cache.bytes, 800);
        expect(cache.length, 2);

        // 超预算：淘汰最久未使用的 a。
        cache.put('c', c);
        expect(cache.get('a'), isNull);
        expect(cache.get('b'), isNotNull);
        expect(cache.get('c'), isNotNull);

        // 引用中的页（正在被展示）不能被淘汰，即使它不是最近使用的。
        cache.acquire('c');
        cache.get('b');
        cache.put('d', d);
        expect(cache.get('b'), isNull, reason: '无引用的 b 先被淘汰');
        expect(cache.get('c'), isNotNull, reason: '有引用的 c 必须留下');

        // 钉住的页（预加载窗口内）也不能被淘汰。
        cache.release('c');
        cache.retain(<String>{'c'});
        cache.put('e', e);
        expect(cache.get('c'), isNotNull, reason: '窗口内的图被钉住');
        expect(cache.get('d'), isNull);

        // 清空后计数归零，位图逐个释放。
        // clear 会逐个释放位图，因此这里不再手动 dispose（重复释放会断言失败）。
        cache.clear();
        expect(cache.length, 0);
        expect(cache.bytes, 0);
      });
    });

    testWidgets('预加载与淘汰走真实链路：磁盘缓存 → 解码 → 内存 LRU', (tester) async {
      await tester.runAsync(() async {
        final cacheDir = library.imageCacheDir;
        // 造三张真实 PNG 预置进本板块磁盘缓存：测试环境不发真实网络请求，
        // 于是这里走的是「磁盘缓存命中 → 解码 → 内存缓存」这条真实链路。
        const urls = <String>[
          'https://example.invalid/preload/a.png',
          'https://example.invalid/preload/b.png',
          'https://example.invalid/preload/c.png',
        ];
        for (var index = 0; index < urls.length; index++) {
          final png = await pngBytes(12, 12, Color(0xFF102030 + index));
          File(p.join(cacheDir, '${ReadingStore.cacheKey(urls[index])}.img'))
              .writeAsBytesSync(png);
        }

        // 预算 = 两张 12×12 位图（每张 12×12×4 = 576 字节）+ 一点余量。
        const budget = 12 * 12 * 4 * 2 + 64;
        final pipeline = SectionImagePipeline(
          cacheDir: cacheDir,
          memoryBudgetBytes: budget,
        );
        addTearDown(pipeline.dispose);

        // 1) 磁盘缓存命中即可解码，并进入内存缓存（引用由交付方持有）。
        final a = await pipeline.image(urls[0], targetWidth: 12);
        expect(a, isNotNull);
        expect(pipeline.memoryCount, 1);
        expect(pipeline.memoryBytes, 12 * 12 * 4);

        // 2) 同一 URL 再取：命中内存，不新增条目（多出的一次引用立刻归还）。
        expect(await pipeline.image(urls[0], targetWidth: 12), isNotNull);
        pipeline.release(urls[0], targetWidth: 12);
        expect(pipeline.memoryCount, 1);

        // 3) 预加载下一张：只进缓存、不持有引用。
        pipeline.preload(<String>[urls[1]], targetWidth: 12);
        await Future<void>.delayed(const Duration(milliseconds: 80));
        expect(pipeline.memoryCount, 2, reason: '预加载应真的把图拉进内存');

        // 4) 回归点：a 被引用、b 被钉住时再取第三张——刚交付的那张不会被
        //    它自己触发的那次淘汰回收（修复前它会被当场 dispose，调用方拿到的
        //    是已释放位图）。全部受保护时，预算暂时超一点是允许的。
        pipeline.retain(<String>[urls[1]], targetWidth: 12);
        final c = await pipeline.image(urls[2], targetWidth: 12);
        expect(c, isNotNull);
        expect(pipeline.memoryCount, 3, reason: '刚交付的图必须留在缓存里');

        // 5) 释放引用后立刻回落到预算内：最久未使用的 a 先走。
        pipeline.release(urls[0], targetWidth: 12);
        expect(pipeline.memoryCount, 2);
        expect(pipeline.memoryBytes, lessThanOrEqualTo(budget));

        // 6) 释放后不再接受新请求，也不抛错。
        pipeline.dispose();
        expect(pipeline.isDisposed, isTrue);
        expect(await pipeline.image(urls[0], targetWidth: 12), isNull);
        expect(await pipeline.bytes(urls[0]), isNull);
        expect(pipeline.memoryCount, 0);
      });
    });
  });
}

/// 生成一张真实 PNG 的字节：给管线喂「磁盘缓存」，让测试环境不必联网。
Future<Uint8List> pngBytes(int width, int height, Color color) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..color = color,
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  return data!.buffer.asUint8List();
}
