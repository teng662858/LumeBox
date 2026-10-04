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

  testWidgets('漫画详情：点章节进阅读器，并把作品留在书架上', (tester) async {
    await pump(
      tester,
      ComicDetailPage(
        library: comicLibrary,
        manager: managerFor(Section.comic),
        target: comicTarget,
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
}
