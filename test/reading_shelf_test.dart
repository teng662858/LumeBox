import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/features/comic/comic_explore_page.dart';
import 'package:lume_box/features/comic/comic_page.dart';
import 'package:lume_box/features/comic/comic_shelf_page.dart';
import 'package:lume_box/features/novel/novel_shelf_page.dart';

import 'support/fake_reading_source.dart';
import 'support/fake_source_manager.dart';

/// 书架与探索页面的验证：未读角标、进度文案、图源下拉与筛选入口。
///
/// 书架对着**真实阅读库**（临时目录里的 sqlite）断言，图源侧用替身端口驱动，
/// 因此这些断言覆盖的是页面行为，而不是替身行为。
///
/// 注意：阅读库必须在 [setUp] 里打开。`testWidgets` 的测试体跑在 fake-async
/// 时钟里，而打开阅读库要经 path_provider 的方法通道（真实异步），
/// 在测试体里 await 它会永远等不到——setUp 运行在真实时钟下，正好合适。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late ReadingLibrary comicLibrary;
  late ReadingLibrary novelLibrary;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('lume_box_shelf');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => call.method == 'getApplicationSupportDirectory'
          ? root.path
          : null,
    );
    comicLibrary = await ReadingLibrary.open(Section.comic);
    novelLibrary = await ReadingLibrary.open(Section.novel);
  });

  tearDown(() async {
    ReadingLibrary.disposeAll();
    ReadingStore.disposeAll();
    await SectionScope.closeAll();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  SectionImagePipeline createPipeline(ReadingLibrary library) =>
      SectionImagePipeline(
        cacheDir: library.imageCacheDir,
        memoryBudgetBytes: 0,
      );

  Future<void> pump(WidgetTester tester, Widget child) async {
    await tester.binding.setSurfaceSize(const Size(420, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(theme: LumeTheme.build(), home: Scaffold(body: child)),
    );
    await tester.pumpAndSettle();
  }

  group('漫画书架', () {
    testWidgets('卡片右上角显示未读章节角标', (tester) async {
      final library = comicLibrary;
      library.shelve(
        sourceId: 'src',
        itemId: 'fresh',
        title: '没读过的书',
        chapterCount: 10,
      );
      library.shelve(
        sourceId: 'src',
        itemId: 'reading',
        title: '读到一半的书',
        chapterCount: 10,
      );
      library.saveProgress(
        ComicProgress(
          section: Section.comic,
          itemId: 'reading',
          chapterIndex: 6,
          chapterId: 'c6',
          chapterTitle: '第 7 章',
          updatedAt: DateTime.now(),
          page: 3,
        ),
      );
      final pipeline = createPipeline(library);
      addTearDown(pipeline.dispose);

      await pump(
        tester,
        ComicShelfPage(
          library: library,
          pipeline: pipeline,
          manager: FakeSourceManager(),
        ),
      );

      expect(find.text('没读过的书'), findsOneWidget);
      expect(find.text('读到一半的书'), findsOneWidget);
      // 未读：10 章全未读 → 10；已读到第 7 章 → 10 - 6 - 1 = 3。
      expect(find.text('10'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
      // 有进度的卡片顺带展示读到哪里。
      expect(find.text('第 7 章 · 第 4 页'), findsOneWidget);
    });

    testWidgets('读完的书不显示角标', (tester) async {
      final library = comicLibrary;
      library.shelve(
        sourceId: 'src',
        itemId: 'done',
        title: '读完的书',
        chapterCount: 5,
      );
      library.saveProgress(
        ComicProgress(
          section: Section.comic,
          itemId: 'done',
          chapterIndex: 4,
          chapterId: 'c4',
          chapterTitle: '第 5 章',
          updatedAt: DateTime.now(),
          page: 0,
        ),
      );
      final pipeline = createPipeline(library);
      addTearDown(pipeline.dispose);

      await pump(
        tester,
        ComicShelfPage(
          library: library,
          pipeline: pipeline,
          manager: FakeSourceManager(),
        ),
      );

      expect(find.text('读完的书'), findsOneWidget);
      expect(find.text('0'), findsNothing);
      expect(find.text('99+'), findsNothing);
    });

    testWidgets('空书架给出引导', (tester) async {
      final library = comicLibrary;
      final pipeline = createPipeline(library);
      addTearDown(pipeline.dispose);

      await pump(
        tester,
        ComicShelfPage(
          library: library,
          pipeline: pipeline,
          manager: FakeSourceManager(),
        ),
      );

      expect(find.text('书架还是空的'), findsOneWidget);
      expect(find.text('去探索'), findsOneWidget);
    });
  });

  group('小说书架', () {
    testWidgets('展示阅读进度与续读入口', (tester) async {
      final library = novelLibrary;
      library.shelve(
        sourceId: 'src',
        itemId: 'novel-1',
        title: '测试小说',
        chapterCount: 20,
      );
      library.saveProgress(
        NovelProgress(
          section: Section.novel,
          itemId: 'novel-1',
          chapterIndex: 2,
          chapterId: 'c2',
          chapterTitle: '第 3 章',
          updatedAt: DateTime.now(),
          charOffset: 2500,
          chapterLength: 5000,
        ),
      );
      final pipeline = createPipeline(library);
      addTearDown(pipeline.dispose);

      await pump(
        tester,
        NovelShelfPage(
          library: library,
          pipeline: pipeline,
          manager: FakeSourceManager(),
        ),
      );

      expect(find.text('测试小说'), findsOneWidget);
      // 进度口径：章节 + 章节内百分比（字符偏移 / 章节长度）。
      expect(find.text('第 3 章 · 50%'), findsOneWidget);
      expect(find.text('续读'), findsOneWidget);
    });
  });

  group('探索页', () {
    testWidgets('没有图源时提示去图源管理', (tester) async {
      final library = comicLibrary;
      final pipeline = createPipeline(library);
      addTearDown(pipeline.dispose);

      await pump(
        tester,
        ComicExplorePage(
          library: library,
          pipeline: pipeline,
          manager: FakeSourceManager(sources: const <SourceDescriptor>[]),
        ),
      );

      expect(find.text('暂无源'), findsOneWidget);
      expect(find.text('源管理'), findsWidgets);
      expect(find.text('筛选'), findsNothing);
    });

    testWidgets('顶部图源下拉列出本板块已启用图源，内容按海报网格展示', (tester) async {
      final library = comicLibrary;
      final pipeline = createPipeline(library);
      addTearDown(pipeline.dispose);

      final manager = FakeSourceManager(
        sources: const <SourceDescriptor>[
          SourceDescriptor(id: 'a', name: '启用源', version: '1.0', enabled: true),
          SourceDescriptor(id: 'b', name: '停用源', version: '1.0', enabled: false),
        ],
        opened: <String, DataSource>{
          'a': FakeReadingDataSource(section: Section.comic),
        },
      );

      await pump(
        tester,
        ComicExplorePage(
          library: library,
          pipeline: pipeline,
          manager: manager,
        ),
      );

      // 下拉里是当前图源；条目来自数据源；停用图源不进候选。
      expect(find.text('启用源'), findsOneWidget);
      expect(find.text('测试作品 1'), findsOneWidget);
      expect(manager.openedIds, contains('a'));

      await tester.tap(find.byIcon(Icons.expand_more));
      await tester.pumpAndSettle();
      expect(find.text('停用源'), findsNothing);
    });

    testWidgets('筛选抽屉里能选分类并重新取列表', (tester) async {
      final library = comicLibrary;
      final pipeline = createPipeline(library);
      addTearDown(pipeline.dispose);

      final manager = FakeSourceManager(
        sources: const <SourceDescriptor>[
          SourceDescriptor(id: 'a', name: '启用源', version: '1.0', enabled: true),
        ],
        opened: <String, DataSource>{
          'a': FakeReadingDataSource(section: Section.comic),
        },
      );

      await pump(
        tester,
        ComicExplorePage(
          library: library,
          pipeline: pipeline,
          manager: manager,
        ),
      );

      await tester.tap(find.byIcon(Icons.filter_list));
      await tester.pumpAndSettle();
      expect(find.text('分类一'), findsOneWidget);

      await tester.tap(find.text('分类一'));
      await tester.pumpAndSettle();
      // 抽屉关闭，列表仍在（分类只影响取数条件）。
      expect(find.text('筛选'), findsNothing);
      expect(find.text('测试作品 1'), findsOneWidget);
    });
  });

  testWidgets(
    '非 iOS 平台进入漫画板块只显示骨架，不进阅读业务界面',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(500, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(theme: LumeTheme.build(), home: const ComicPage()),
      );
      await tester.pumpAndSettle();

      expect(find.text('当前平台在 Phase1 仅保留页面骨架'), findsOneWidget);
      // 骨架页不进入阅读体系：没有书架 / 探索页签，也不打开本板块阅读库。
      expect(find.text('书架'), findsNothing);
      expect(find.text('探索'), findsNothing);
      expect(
        find.byType(ComicShelfPage),
        findsNothing,
        reason: '非 iOS 平台不应进入阅读业务界面',
      );
    },
    skip: Platform.isIOS,
  );
}
