import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/features/comic/comic_bookmarks.dart';
import 'package:lume_box/features/comic/comic_reader_page.dart';

import 'support/fake_reading_source.dart';

/// 漫画书签：编解码 / 同位置覆盖 / 排序 / 坏数据，以及阅读器里的加、删、跳转。
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
    root = Directory.systemTemp.createTempSync('lume_box_comic_bookmarks');
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

  ComicBookmark makeBookmark({
    int chapterIndex = 0,
    int page = 0,
    String chapterTitle = '第 1 章',
  }) =>
      ComicBookmark(
        chapterIndex: chapterIndex,
        chapterId: 'item-1-c${chapterIndex + 1}',
        chapterTitle: chapterTitle,
        page: page,
        createdAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      );

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
          // 本文件跑在 Windows 上（平台检测必然为假），显式声明有运行时，
          // 测的是阅读器的业务行为；平台守卫本身由 comic_reader_test 覆盖。
          runtimeAvailable: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 呼出工具栏：点一下之后要等过**双击窗口**（呼出被刻意延后 260ms，
  /// 免得阅读时误触弹出底部面板）。
  Future<void> openToolbar(WidgetTester tester) async {
    await tester.tapAt(const Offset(210, 440));
    await tester.pump(const Duration(milliseconds: 320));
    await tester.pumpAndSettle();
  }

  /// 书签列表的入口现在在【阅读设置】二级页里（顶栏那个按钮已按用户口径移除）。
  Future<void> openBookmarkList(WidgetTester tester) async {
    await tester.tap(find.byTooltip('阅读设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '查看'));
    await tester.pumpAndSettle();
  }

  group('编解码与合并', () {
    test('往返：编码后解码得到同一条（含章标题、页与创建时间）', () {
      final list = <ComicBookmark>[
        makeBookmark(chapterIndex: 1, page: 3, chapterTitle: '第 2 章'),
      ];
      final decoded = ComicBookmarks.decode(ComicBookmarks.encode(list));
      expect(decoded.length, 1);
      expect(decoded.first.chapterIndex, 1);
      expect(decoded.first.page, 3);
      expect(decoded.first.chapterTitle, '第 2 章');
      expect(
        decoded.first.createdAt.millisecondsSinceEpoch,
        1700000000000,
      );
    });

    test('同一章同一页重复添加 = 覆盖，不产生两条', () {
      var list = <ComicBookmark>[];
      list = ComicBookmarks.add(list, makeBookmark(page: 2));
      list = ComicBookmarks.add(list, makeBookmark(page: 2));
      expect(list.length, 1);
      expect(list.first.page, 2);
    });

    test('按阅读顺序排序：先章后页', () {
      var list = <ComicBookmark>[];
      list = ComicBookmarks.add(list, makeBookmark(chapterIndex: 2, page: 1));
      list = ComicBookmarks.add(list, makeBookmark(page: 2));
      list = ComicBookmarks.add(list, makeBookmark(page: 0));
      expect(
        <String>[for (final item in list) item.key],
        <String>['0@0', '0@2', '2@1'],
      );
    });

    test('坏数据不炸：整段坏 / 单条缺字段都只当没有', () {
      expect(ComicBookmarks.decode(null), isEmpty);
      expect(ComicBookmarks.decode('不是 JSON'), isEmpty);
      expect(ComicBookmarks.decode('[{"chapterIndex":0}]'), isEmpty);
      expect(
        ComicBookmarks.decode(
          '[{"chapterIndex":0,"page":1},{"chapterIndex":"乱写"}]',
        ).length,
        1,
        reason: '坏条目丢弃，好条目保留',
      );
    });

    test('移除与「当前位置是否有书签」', () {
      final first = makeBookmark(page: 1);
      final second = makeBookmark(page: 4);
      var list = ComicBookmarks.add(
        ComicBookmarks.add(<ComicBookmark>[], first),
        second,
      );
      expect(
        ComicBookmarks.at(list, chapterIndex: 0, page: 4),
        isNotNull,
      );
      expect(ComicBookmarks.at(list, chapterIndex: 1, page: 4), isNull);

      list = ComicBookmarks.remove(list, second);
      expect(list.length, 1);
      expect(ComicBookmarks.at(list, chapterIndex: 0, page: 4), isNull);
    });

    test('展示文案：章标题 + 第 N 页（页序号从 0 起，文案从 1 起）', () {
      expect(
        makeBookmark(chapterIndex: 1, page: 3, chapterTitle: '第 2 章').describe(),
        '第 2 章 · 第 4 页',
      );
      expect(makeBookmark(page: 0, chapterTitle: '').describe(), '第 1 章 · 第 1 页');
    });
  });

  group('阅读器集成', () {
    testWidgets('顶栏书签按钮：加书签落库，再点即移除', (tester) async {
      await pumpReader(tester);
      await openToolbar(tester);

      expect(find.byIcon(Icons.bookmark_add_outlined), findsOneWidget);
      await tester.tap(find.byIcon(Icons.bookmark_add_outlined));
      await tester.pumpAndSettle();

      final stored = ComicBookmarks.decode(
        library.setting(ComicBookmarks.keyFor(target.itemId)),
      );
      expect(stored.length, 1);
      expect(stored.first.chapterIndex, 0);
      expect(stored.first.page, 0);
      // 有书签：按钮变实心。
      expect(find.byIcon(Icons.bookmark), findsOneWidget);

      await tester.tap(find.byIcon(Icons.bookmark));
      await tester.pumpAndSettle();
      expect(
        ComicBookmarks.decode(
          library.setting(ComicBookmarks.keyFor(target.itemId)),
        ),
        isEmpty,
      );
      expect(find.byIcon(Icons.bookmark_add_outlined), findsOneWidget);
    });

    testWidgets('书签列表：可见、删除即时生效、跨章跳回书签页', (tester) async {
      final seed = <ComicBookmark>[
        makeBookmark(page: 2, chapterTitle: '第 1 章'),
        makeBookmark(chapterIndex: 2, page: 3, chapterTitle: '第 3 章'),
      ];
      library.setSetting(
        ComicBookmarks.keyFor(target.itemId),
        ComicBookmarks.encode(seed),
      );
      await pumpReader(tester);
      await openToolbar(tester);

      await openBookmarkList(tester);
      expect(find.text('第 1 章 · 第 3 页'), findsOneWidget);
      expect(find.text('第 3 章 · 第 4 页'), findsOneWidget);

      // 删除第一条：面板里即时消失，并同步落库。
      await tester.tap(find.byTooltip('删除书签').first);
      await tester.pumpAndSettle();
      expect(find.text('第 1 章 · 第 3 页'), findsNothing);
      expect(
        ComicBookmarks.decode(
          library.setting(ComicBookmarks.keyFor(target.itemId)),
        ).length,
        1,
      );

      // 点第二条：跳到第 3 章第 4 页。
      await tester.tap(find.text('第 3 章 · 第 4 页'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 900));
      final progress = library.comicProgress(target.itemId)!;
      expect(progress.chapterIndex, 2);
      expect(progress.page, 3);
    });

    testWidgets('书签列表空态：给出添加指引而不是空白面板', (tester) async {
      await pumpReader(tester);
      await openToolbar(tester);
      await openBookmarkList(tester);
      // 两处都会说「还没有书签」：阅读设置页那行提示 + 列表面板自己的空态。
      expect(find.textContaining('还没有书签'), findsWidgets);
    });
  });
}
