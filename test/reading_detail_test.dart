import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/features/comic/comic_detail_page.dart';
import 'package:lume_box/features/comic/comic_reader_page.dart';
import 'package:lume_box/features/novel/novel_catalog_page.dart';
import 'package:lume_box/shared/widgets/glass_card.dart';
import 'package:lume_box/features/novel/novel_detail_page.dart';
import 'package:lume_box/features/novel/novel_reader_page.dart';

import 'support/fake_reading_source.dart';
import 'support/fake_source_manager.dart';

/// 详情页与目录页的验证：元信息、章节正序 / 倒序切换、进阅读器与入架。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late ReadingLibrary comicLibrary;
  late ReadingLibrary novelLibrary;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('lume_box_detail');
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

  FakeSourceManager managerFor(Section section) => FakeSourceManager(
        sources: const <SourceDescriptor>[
          SourceDescriptor(id: 'a', name: '测试源', version: '1.0', enabled: true),
        ],
        opened: <String, DataSource>{
          'a': FakeReadingDataSource(section: section, chapterCount: 3),
        },
      );

  Future<void> pump(WidgetTester tester, Widget child) async {
    await tester.binding.setSurfaceSize(const Size(420, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(theme: LumeTheme.build(), home: child),
    );
    await tester.pumpAndSettle();
  }

  const comicTarget = ReadingTarget(
    sourceId: 'a',
    itemId: 'item-1',
    title: '测试漫画',
  );
  const novelTarget = ReadingTarget(
    sourceId: 'a',
    itemId: 'item-1',
    title: '测试小说',
  );

  testWidgets('漫画详情：元信息、章节列表与倒序切换', (tester) async {
    await pump(
      tester,
      ComicDetailPage(
        library: comicLibrary,
        manager: managerFor(Section.comic),
        target: comicTarget,
        runtimeAvailable: true,
      ),
    );

    expect(find.text('测试作品 item-1'), findsWidgets);
    expect(find.text('共 3 章'), findsOneWidget);
    expect(find.text('开始阅读'), findsOneWidget);
    expect(find.text('加入书架'), findsOneWidget);

    // 正序：第 1 章在上。
    expect(
      tester.getTopLeft(find.text('第 1 章')).dy,
      lessThan(tester.getTopLeft(find.text('第 3 章')).dy),
    );

    await tester.tap(find.text('正序'));
    await tester.pumpAndSettle(); // 切到倒序
    expect(find.text('倒序'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('第 3 章')).dy,
      lessThan(tester.getTopLeft(find.text('第 1 章')).dy),
      reason: '倒序后最后一章排在最前',
    );
  });

  testWidgets('漫画详情：章节条目的触摸区与行距（移动端点得准）', (tester) async {
    await pump(
      tester,
      ComicDetailPage(
        library: comicLibrary,
        manager: managerFor(Section.comic),
        target: comicTarget,
        runtimeAvailable: true,
      ),
    );

    // 章节行 = 含「第 N 章」文字的 GlassCard；量它们的矩形。
    final rects = <Rect>[];
    for (final element in find.byType(GlassCard).evaluate()) {
      final hasTitle = find
          .descendant(
            of: find.byWidget(element.widget),
            matching: find.textContaining(RegExp(r'^第 \d+ 章$')),
          )
          .evaluate()
          .isNotEmpty;
      if (hasTitle) rects.add(tester.getRect(find.byWidget(element.widget)));
    }
    expect(rects.length, greaterThanOrEqualTo(3), reason: '三个章节行都该被量到');

    // 触摸区：整行高度要达到 iOS 的最小触摸目标 44pt（原先约 24pt）。
    for (final rect in rects) {
      expect(
        rect.height,
        greaterThanOrEqualTo(44.0),
        reason: '章节条目高度 ${rect.height}pt 小于 44pt，手指要瞄着点',
      );
    }
    // 行距：相邻两行之间要留间隔，避免点串行。
    for (var i = 1; i < rects.length; i++) {
      final gap = rects[i].top - rects[i - 1].bottom;
      expect(
        gap,
        greaterThanOrEqualTo(8.0),
        reason: '相邻章节之间只有 ${gap}pt 间隔，容易误点相邻行',
      );
    }
    // 字号不动（这次只改触摸区与行距，没有放大文字）。
    final title = tester.widget<Text>(find.text('第 1 章'));
    expect(title.style?.fontSize, 14);
  });

  testWidgets('漫画详情：点章节进阅读器，并把作品留在书架上', (tester) async {
    await pump(
      tester,
      ComicDetailPage(
        library: comicLibrary,
        manager: managerFor(Section.comic),
        target: comicTarget,
        runtimeAvailable: true,
      ),
    );

    await tester.tap(find.text('第 2 章'));
    await tester.pumpAndSettle();

    expect(find.byType(ComicReaderPage), findsOneWidget);
    expect(comicLibrary.onShelf('item-1'), isTrue);
    final progress = comicLibrary.comicProgress('item-1')!;
    expect(progress.chapterIndex, 1);
  });

  testWidgets('小说详情：元信息 + 完整目录入口', (tester) async {
    await pump(
      tester,
      NovelDetailPage(
        library: novelLibrary,
        manager: managerFor(Section.novel),
        target: novelTarget,
      ),
    );

    expect(find.text('测试作品 item-1'), findsWidgets);
    expect(find.text('共 3 章'), findsOneWidget);
    expect(find.text('完整目录'), findsOneWidget);

    await tester.tap(find.text('完整目录'));
    await tester.pumpAndSettle();
    expect(find.byType(NovelCatalogPage), findsOneWidget);
    expect(find.text('第 1 章'), findsOneWidget);
  });

  testWidgets('小说目录页：倒序切换与点章进阅读器', (tester) async {
    final source = FakeReadingDataSource(section: Section.novel, chapterCount: 3);
    await pump(
      tester,
      NovelCatalogPage(
        library: novelLibrary,
        dataSource: source,
        target: novelTarget,
        chapters: await source.chapters('item-1'),
        initialChapterIndex: 0,
      ),
    );

    expect(find.text('第 1 章'), findsOneWidget);
    await tester.tap(find.text('正序'));
    await tester.pumpAndSettle();
    expect(find.text('倒序'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('第 3 章')).dy,
      lessThan(tester.getTopLeft(find.text('第 1 章')).dy),
    );

    await tester.tap(find.text('第 2 章'));
    await tester.pumpAndSettle();
    expect(find.byType(NovelReaderPage), findsOneWidget);
    expect(novelLibrary.novelProgress('item-1')!.chapterIndex, 1);
  });

  testWidgets('小说目录页：搜索章节标题，只留命中项', (tester) async {
    final source = FakeReadingDataSource(section: Section.novel, chapterCount: 5);
    await pump(
      tester,
      NovelCatalogPage(
        library: novelLibrary,
        dataSource: source,
        target: novelTarget,
        chapters: await source.chapters('item-1'),
        initialChapterIndex: 0,
      ),
    );

    // 搜索框默认收起（不挤占目录可视区）。
    expect(find.byType(TextField), findsNothing);

    await tester.tap(find.byTooltip('搜索章节'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);

    // 假数据源的章节标题形如「第 N 章」：搜「3」应只剩第 3 章。
    await tester.enterText(find.byType(TextField), '3');
    await tester.pumpAndSettle();

    expect(find.text('第 3 章'), findsOneWidget);
    expect(find.text('第 1 章'), findsNothing);
    expect(find.text('第 2 章'), findsNothing);
    expect(find.text('第 4 章'), findsNothing);
  });

  testWidgets('小说目录页：搜不到时给空态提示，不是白屏', (tester) async {
    final source = FakeReadingDataSource(section: Section.novel, chapterCount: 3);
    await pump(
      tester,
      NovelCatalogPage(
        library: novelLibrary,
        dataSource: source,
        target: novelTarget,
        chapters: await source.chapters('item-1'),
        initialChapterIndex: 0,
      ),
    );

    await tester.tap(find.byTooltip('搜索章节'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '不存在的章节名');
    await tester.pumpAndSettle();

    expect(find.text('没有匹配的章节'), findsOneWidget);
    expect(find.text('第 1 章'), findsNothing);
  });

  testWidgets('小说目录页：搜索与倒序正交，可叠加', (tester) async {
    final source = FakeReadingDataSource(section: Section.novel, chapterCount: 5);
    await pump(
      tester,
      NovelCatalogPage(
        library: novelLibrary,
        dataSource: source,
        target: novelTarget,
        chapters: await source.chapters('item-1'),
        initialChapterIndex: 0,
      ),
    );

    // 先倒序，再搜索：命中的多项应按倒序排列。
    await tester.tap(find.text('正序'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('搜索章节'));
    await tester.pumpAndSettle();
    // 搜「章」命中全部 5 章（标题都含「章」），倒序下第 5 章应在最上。
    await tester.enterText(find.byType(TextField), '章');
    await tester.pumpAndSettle();

    expect(
      tester.getTopLeft(find.text('第 5 章')).dy,
      lessThan(tester.getTopLeft(find.text('第 1 章')).dy),
      reason: '搜索应保留倒序，两者叠加而不是互相覆盖',
    );
  });

  testWidgets('小说目录页：清空搜索与收起搜索都恢复完整目录', (tester) async {
    final source = FakeReadingDataSource(section: Section.novel, chapterCount: 3);
    await pump(
      tester,
      NovelCatalogPage(
        library: novelLibrary,
        dataSource: source,
        target: novelTarget,
        chapters: await source.chapters('item-1'),
        initialChapterIndex: 0,
      ),
    );

    await tester.tap(find.byTooltip('搜索章节'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '2');
    await tester.pumpAndSettle();
    expect(find.text('第 1 章'), findsNothing);

    // 清空按钮：恢复完整目录。
    await tester.tap(find.byTooltip('清空'));
    await tester.pumpAndSettle();
    expect(find.text('第 1 章'), findsOneWidget);
    expect(find.text('第 3 章'), findsOneWidget);

    // 收起搜索：同样恢复，且搜索框消失。
    await tester.tap(find.byTooltip('收起搜索'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    expect(find.text('第 1 章'), findsOneWidget);
  });

  testWidgets('小说目录页：搜索结果里点章进阅读器，落的是正序下标', (tester) async {
    final source = FakeReadingDataSource(section: Section.novel, chapterCount: 5);
    await pump(
      tester,
      NovelCatalogPage(
        library: novelLibrary,
        dataSource: source,
        target: novelTarget,
        chapters: await source.chapters('item-1'),
        initialChapterIndex: 0,
      ),
    );

    await tester.tap(find.byTooltip('搜索章节'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '4');
    await tester.pumpAndSettle();

    await tester.tap(find.text('第 4 章'));
    await tester.pumpAndSettle();

    expect(find.byType(NovelReaderPage), findsOneWidget);
    expect(
      novelLibrary.novelProgress('item-1')!.chapterIndex,
      3,
      reason: '搜索只筛显示行，下标仍是正序（第 4 章 → 下标 3）',
    );
  });
}
