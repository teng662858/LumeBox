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
import 'package:lume_box/shared/widgets/notice_card.dart';

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

  /// 当前模拟的视口尺寸（[rotate] 会改它，[pumpReader] 建树时读它）。
  Size viewport = const Size(420, 880);

  /// 建阅读器。刻意包一层 MediaQuery：旋屏要改的正是它的 data。
  /// [runtimeAvailable] 默认 true：本文件跑在 Windows 上，平台检测必然为假，
  /// 而这里要测的是阅读器的**业务行为**。平台守卫本身另有用例专门覆盖
  /// （见「平台守卫」两条）。显式传参而不是依赖平台检测，也让断言不随开发机变。
  Widget readerApp({int imageCount = 6, bool runtimeAvailable = true}) => MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(size: viewport, devicePixelRatio: 1),
          child: ComicReaderPage(
            library: library,
            dataSource: FakeReadingDataSource(
              section: Section.comic,
              imageCount: imageCount,
            ),
            target: target,
            chapters: chapters(3),
            initialChapterIndex: 0,
            runtimeAvailable: runtimeAvailable,
          ),
        ),
      );

  Future<void> pumpReader(
    WidgetTester tester, {
    int imageCount = 6,
    Size surface = const Size(420, 880),
    bool runtimeAvailable = true,
  }) async {
    await tester.binding.setSurfaceSize(surface);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    viewport = surface;
    await tester.pumpWidget(
      readerApp(imageCount: imageCount, runtimeAvailable: runtimeAvailable),
    );
    await tester.pumpAndSettle();
  }

  /// 呼出工具栏（连带底部面板）。
  ///
  /// 点一下之后要**等过一个双击窗口**：呼出被刻意延后 260ms（用户口径：面板太容易
  /// 误触，双击放大时更要撤掉这次呼出），pending 的 Timer 不会让 pumpAndSettle
  /// 有事可做，所以这里显式推一下时间。
  Future<void> openToolbar(WidgetTester tester) async {
    await tester.tapAt(const Offset(210, 440));
    await tester.pump(const Duration(milliseconds: 320));
    await tester.pumpAndSettle();
  }

  /// 模拟旋屏：只换 MediaQuery 的尺寸，**保留同一个阅读器 State**。
  ///
  /// 两个坑（都实测过）：
  /// - `tester.binding.setSurfaceSize` 不触发 `didChangeDependencies`（尺寸变了但
  ///   依赖没变），测不到旋屏路径；
  /// - 重新 `pumpWidget` 一棵新树会**新建 State**（位置归零），测的是「重新打开」
  ///   而不是「旋屏」。真实旋屏是同一次挂载内 MediaQuery 变化，因此这里只在原树上
  ///   改 data —— widget 类型与 key 不变，State 被复用。
  Future<void> rotate(WidgetTester tester, Size size) async {
    viewport = size;
    await tester.pumpWidget(readerApp());
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

  testWidgets('旋屏后位置锚回同一页：瀑布流按新几何重建滚动位置', (tester) async {
    await pumpReader(tester); // 默认瀑布流

    // 先滚下去，让位置离开起点（瀑布流是 ListView.builder）。
    await tester.drag(find.byType(ListView), const Offset(0, -1200));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 900));

    double offsetNow() =>
        tester.widget<ListView>(find.byType(ListView)).controller!.offset;

    final before = offsetNow();
    expect(before, greaterThan(0), reason: '前置条件：已经滚离起点');
    final pageBefore = library.comicProgress(target.itemId)!.page;

    // 旋屏：宽高对调（420x880 → 880x420）。
    //
    // 用 MediaQuery 覆写而不是 `setSurfaceSize`：实测后者不会触发
    // `didChangeDependencies`（尺寸变了但依赖没变），因此测不到旋屏路径。
    // 真实设备旋屏会走 MediaQuery 变化 → didChangeDependencies，这正是被测逻辑。
    await rotate(tester, const Size(880, 420));

    // 瀑布流的每张图高度按屏宽等比放大，因此「同一页」在新几何下的偏移
    // 也应等比变大。若控制器仍沿用旧像素偏移，偏移会原地不动——那正是
    // 用户看到的「旋屏后跳到别处」。
    final after = offsetNow();
    expect(
      after,
      greaterThan(before * 1.5),
      reason: '旋屏后滚动位置要按新几何重算（旧偏移 $before，新偏移 $after）',
    );
    expect(
      library.comicProgress(target.itemId)!.page,
      pageBefore,
      reason: '锚定后仍应停在原来那一页',
    );
    expect(tester.takeException(), isNull, reason: '旋屏不应抛异常');
  });

  testWidgets('旋屏后单页模式仍停在原页', (tester) async {
    const ComicReaderSettings(mode: ComicReadingMode.single).save(library);
    await pumpReader(tester);

    // 翻到第 2 页。
    await tester.drag(find.byType(PageView), const Offset(-400, 0));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 900));
    final before = library.comicProgress(target.itemId)!.page;
    expect(before, 1);

    await rotate(tester, const Size(880, 420));

    expect(
      library.comicProgress(target.itemId)!.page,
      before,
      reason: '单页模式旋屏后应停在原页',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('调节控件：侧边距在底部面板、双击放大在阅读设置页，都会落库', (tester) async {
    await pumpReader(tester);
    await openToolbar(tester);

    // 侧边距滑杆：面板里第一根滑杆就是它（常用项留在面板）。
    await tester.drag(find.byType(Slider).first, const Offset(80, 0));
    await tester.pumpAndSettle();
    expect(
      ComicReaderSettings.load(library).marginRatio,
      greaterThan(0),
      reason: '侧边距要落库，重进阅读器仍然生效',
    );
    // 用户口径：面板里不再有「双击放大」这类不常用项。
    expect(find.byType(Switch), findsNothing, reason: '双击放大已搬去阅读设置页');

    // 顶栏 →「阅读设置」二级页：双击放大在这里。
    await tester.tap(find.byTooltip('阅读设置'));
    await tester.pumpAndSettle();
    expect(find.text('阅读设置'), findsWidgets);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(
      ComicReaderSettings.load(library).doubleTapZoom,
      isTrue,
      reason: '在阅读设置页改的开关同样立刻写回阅读器',
    );
  });

  testWidgets('阅读背景：切到纯白后落库，页面底色立即跟着换', (tester) async {
    await pumpReader(tester);
    expect(
      tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor,
      ComicReaderBackground.black.color,
      reason: '默认纯黑，与改动前一致',
    );

    await openToolbar(tester);
    await tester.tap(find.text('纯白'));
    await tester.pumpAndSettle();

    expect(
      ComicReaderSettings.load(library).background,
      ComicReaderBackground.white,
      reason: '背景要落库，重进阅读器仍然生效',
    );
    expect(
      tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor,
      const Color(0xFFFFFFFF),
    );
  });

  testWidgets('点击行为：分区点击翻页，中间仍是呼出工具栏', (tester) async {
    await pumpReader(tester);
    await openToolbar(tester);
    await tester.tap(find.text('单页左右翻页'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('点击翻页'));
    await tester.pumpAndSettle();
    expect(
      ComicReaderSettings.load(library).tapAction,
      ComicTapAction.pageTurn,
      reason: '点击行为要落库',
    );

    // 收起面板（分区模式下点中间 = 呼出 / 收起工具栏）。
    // 注意避开屏幕正中：加载失败的占位在那里画了「点击重试」按钮，
    // 会把正中点击吞掉（生产环境图能加载，不存在这个按钮）。
    await tester.tapAt(const Offset(210, 300));
    // 呼出面板延后一个双击窗口（见 openToolbar 的说明）。
    await tester.pump(const Duration(milliseconds: 320));
    await tester.pumpAndSettle();
    expect(find.byType(Slider), findsNothing);

    // 右 1/3：下一页。
    await tester.tapAt(const Offset(390, 440));
    // 呼出面板延后一个双击窗口（见 openToolbar 的说明）。
    await tester.pump(const Duration(milliseconds: 320));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 900));
    expect(library.comicProgress(target.itemId)!.page, 1);

    // 左 1/3：回上一页。
    await tester.tapAt(const Offset(30, 440));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 900));
    expect(library.comicProgress(target.itemId)!.page, 0);
  });

  testWidgets('点击翻页在瀑布流不生效：点哪里都是呼出工具栏', (tester) async {
    const ComicReaderSettings(tapAction: ComicTapAction.pageTurn).save(library);
    await pumpReader(tester);

    // 瀑布流没有「页」可翻：右 1/3 点击只呼出工具栏，进度不动。
    await tester.tapAt(const Offset(390, 440));
    // 呼出面板延后一个双击窗口（见 openToolbar 的说明）。
    await tester.pump(const Duration(milliseconds: 320));
    await tester.pumpAndSettle();
    expect(find.byType(Slider), findsWidgets);
    expect(library.comicProgress(target.itemId)!.page, 0);
  });

  testWidgets('小屏 / 横屏：设置面板超限时内部滚动，不溢出', (tester) async {
    // 双页跨页是最坏情况（多一行「跨页配对」）。
    const ComicReaderSettings(mode: ComicReadingMode.doublePage).save(library);
    await pumpReader(tester, surface: const Size(640, 360));
    await tester.tapAt(const Offset(320, 180));
    // 呼出面板延后一个双击窗口（见 openToolbar 的说明）。
    await tester.pump(const Duration(milliseconds: 320));
    await tester.pumpAndSettle();

    // 溢出会以 FlutterError 直接判失败；能走到这里说明面板被约束住了。
    expect(find.byType(SingleChildScrollView), findsWidgets);
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

  testWidgets('目录面板有恒定的关闭出口（章节多时也滚不掉）', (tester) async {
    await pumpReader(tester);
    await openToolbar(tester);

    await tester.tap(find.byIcon(Icons.list));
    await tester.pumpAndSettle();

    // 用户口径：不管滚到哪儿，目录面板都要有一个「关闭」能回阅读页。
    expect(find.byTooltip('关闭'), findsOneWidget);
    // 把列表滚一段，关闭按钮依旧在（它固定在列表之上，不随内容滚走）。
    await tester.drag(find.byType(ListView).last, const Offset(0, -260));
    await tester.pumpAndSettle();
    expect(find.byTooltip('关闭'), findsOneWidget);

    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expect(find.text('目录'), findsNothing, reason: '关闭后回到阅读页，面板消失');
  });

  testWidgets('平台守卫：无图源运行时时只渲染骨架，不取章节、不落进度', (tester) async {
    await pumpReader(tester, runtimeAvailable: false);

    // 只渲染骨架，没有阅读内容。
    expect(find.byType(SkeletonNotice), findsOneWidget);
    expect(find.byType(ListView), findsNothing);
    expect(find.byType(PageView), findsNothing);

    // 不落任何进度与书架记录（与板块入口的平台门同口径）。
    expect(library.comicProgress(target.itemId), isNull);
    expect(library.onShelf(target.itemId), isFalse);
  });

  testWidgets('平台守卫：可用时正常进入阅读（对照，防止守门过严）', (tester) async {
    await pumpReader(tester, runtimeAvailable: true);

    expect(find.byType(SkeletonNotice), findsNothing);
    expect(find.byType(ListView), findsOneWidget, reason: '默认瀑布流应正常渲染');
    expect(library.comicProgress(target.itemId), isNotNull);
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
