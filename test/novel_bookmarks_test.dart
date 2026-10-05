import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/features/novel/novel_bookmarks.dart';
import 'package:lume_box/features/novel/novel_reader_page.dart';
import 'package:lume_box/core/theme/lume_theme.dart';

/// 小说书签、章节内查找与自动翻页（Phase2 阅读体系补齐）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('lume_box_novel_bookmarks');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => call.method == 'getApplicationSupportDirectory'
          ? root.path
          : null,
    );
    await ReadingLibrary.open(Section.novel);
  });

  tearDown(() async {
    ReadingLibrary.disposeAll();
    ReadingStore.disposeAll();
    await SectionScope.closeAll();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  group('书签模型', () {
    test('编解码往返（含摘录与创建时间）', () {
      final bookmark = NovelBookmark(
        chapterIndex: 3,
        chapterId: 'c4',
        chapterTitle: '第四章',
        charOffset: 1200,
        createdAt: DateTime(2026, 1, 2, 3, 4),
        excerpt: '他推开门，看见',
      );
      final restored = NovelBookmarks.decode(
        NovelBookmarks.encode(<NovelBookmark>[bookmark]),
      ).single;
      expect(restored.chapterIndex, 3);
      expect(restored.charOffset, 1200);
      expect(restored.chapterTitle, '第四章');
      expect(restored.excerpt, '他推开门，看见');
      expect(restored.createdAt, DateTime(2026, 1, 2, 3, 4));
    });

    test('同一位置重复添加 = 覆盖（不产生两条）', () {
      final first = NovelBookmark(
        chapterIndex: 1,
        chapterId: 'c2',
        chapterTitle: '第二章',
        charOffset: 100,
        createdAt: DateTime(2026, 1, 1),
        excerpt: '旧摘录',
      );
      final second = NovelBookmark(
        chapterIndex: 1,
        chapterId: 'c2',
        chapterTitle: '第二章',
        charOffset: 100,
        createdAt: DateTime(2026, 1, 2),
        excerpt: '新摘录',
      );

      var list = NovelBookmarks.add(const <NovelBookmark>[], first);
      list = NovelBookmarks.add(list, second);
      expect(list.length, 1, reason: '同章节同偏移视为同一条');
      expect(list.single.excerpt, '新摘录');
    });

    test('按阅读顺序排序（章 → 偏移）', () {
      NovelBookmark at(int chapter, int offset) => NovelBookmark(
            chapterIndex: chapter,
            chapterId: 'c$chapter',
            chapterTitle: '第 $chapter 章',
            charOffset: offset,
            createdAt: DateTime.now(),
          );
      final list = NovelBookmarks.decode(
        NovelBookmarks.encode(<NovelBookmark>[
          at(2, 50),
          at(0, 900),
          at(2, 10),
          at(1, 100),
        ]),
      );
      expect(
        list.map((item) => '${item.chapterIndex}@${item.charOffset}'),
        <String>['0@900', '1@100', '2@10', '2@50'],
      );
    });

    test('坏数据不炸：返回空列表', () {
      expect(NovelBookmarks.decode(null), isEmpty);
      expect(NovelBookmarks.decode(''), isEmpty);
      expect(NovelBookmarks.decode('不是 JSON'), isEmpty);
      expect(NovelBookmarks.decode('{"a":1}'), isEmpty);
      expect(NovelBookmarks.decode('[{"chapterIndex":"x"}]'), isEmpty);
      // 混合数据：好的留下，坏的丢掉。
      final mixed = NovelBookmarks.decode(
        '[{"chapterIndex":0,"charOffset":5,"chapterTitle":"一"},{"bad":1}]',
      );
      expect(mixed.length, 1);
    });

    test('移除与「当前位置是否有书签」', () {
      final bookmark = NovelBookmark(
        chapterIndex: 1,
        chapterId: 'c',
        chapterTitle: '章',
        charOffset: 42,
        createdAt: DateTime.now(),
      );
      var list = NovelBookmarks.add(const <NovelBookmark>[], bookmark);
      expect(
        NovelBookmarks.at(list, chapterIndex: 1, charOffset: 42),
        isNotNull,
      );
      expect(
        NovelBookmarks.at(list, chapterIndex: 1, charOffset: 43),
        isNull,
        reason: '偏移不同就是不同位置',
      );
      list = NovelBookmarks.remove(list, bookmark);
      expect(list, isEmpty);
    });

    test('展示文案：章节 + 摘录', () {
      final withExcerpt = NovelBookmark(
        chapterIndex: 11,
        chapterId: 'c',
        chapterTitle: '第十二章',
        charOffset: 0,
        createdAt: DateTime.now(),
        excerpt: '正文片段',
      );
      expect(withExcerpt.describe(), '第十二章 · 正文片段');

      final withoutTitle = NovelBookmark(
        chapterIndex: 0,
        chapterId: 'c',
        chapterTitle: '',
        charOffset: 0,
        createdAt: DateTime.now(),
      );
      expect(withoutTitle.describe(), '第 1 章');
    });
  });

  group('阅读器集成', () {
    /// 足够长的正文，保证能分成多页。
    String chapterText(int chapter) =>
        '第 $chapter 章正文。${'这是一段用来分页的测试文本。' * 200}';

    Future<void> pumpReader(WidgetTester tester) async {
      final library = await ReadingLibrary.open(Section.novel);
      await tester.binding.setSurfaceSize(const Size(420, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: LumeTheme.build(),
          home: NovelReaderPage(
            library: library,
            dataSource: _NovelSource(chapterText),
            target: const ReadingTarget(
              sourceId: 'novel-1',
              itemId: 'book-1',
              title: '测试书',
            ),
            chapters: const <SourceChapter>[
              SourceChapter(id: 'c1', title: '第一章'),
              SourceChapter(id: 'c2', title: '第二章'),
            ],
            initialChapterIndex: 0,
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('顶部书签按钮：添加后再点即移除，并落库', (tester) async {
      await pumpReader(tester);

      // 呼出工具栏（点中间区域）。
      await tester.tapAt(const Offset(210, 400));
      await tester.pumpAndSettle();

      expect(find.byTooltip('添加书签'), findsOneWidget);
      await tester.tap(find.byTooltip('添加书签'));
      await tester.pumpAndSettle();

      final library = await ReadingLibrary.open(Section.novel);
      var stored = NovelBookmarks.decode(
        library.setting(NovelBookmarks.keyFor('book-1')),
      );
      expect(stored.length, 1, reason: '书签要落库');
      expect(stored.single.chapterIndex, 0);

      // 再点一次：变成移除。
      expect(find.byTooltip('移除书签'), findsOneWidget);
      await tester.tap(find.byTooltip('移除书签'));
      await tester.pumpAndSettle();
      stored = NovelBookmarks.decode(
        library.setting(NovelBookmarks.keyFor('book-1')),
      );
      expect(stored, isEmpty);
    });

    testWidgets('书签面板：列表可见、可跳转、可删除', (tester) async {
      final library = await ReadingLibrary.open(Section.novel);
      library.setSetting(
        NovelBookmarks.keyFor('book-1'),
        NovelBookmarks.encode(<NovelBookmark>[
          NovelBookmark(
            chapterIndex: 1,
            chapterId: 'c2',
            chapterTitle: '第二章',
            charOffset: 0,
            createdAt: DateTime.now(),
            excerpt: '第二章开头',
          ),
        ]),
      );
      await pumpReader(tester);

      await tester.tapAt(const Offset(210, 400));
      await tester.pumpAndSettle();
      await tester.tap(find.text('书签'));
      await tester.pumpAndSettle();

      expect(find.textContaining('第二章开头'), findsOneWidget);

      // 删除这条书签。
      await tester.tap(find.byTooltip('移除').first);
      await tester.pumpAndSettle();
      expect(
        NovelBookmarks.decode(
          library.setting(NovelBookmarks.keyFor('book-1')),
        ),
        isEmpty,
      );
    });

    testWidgets('章节内查找：命中计数与结果', (tester) async {
      await pumpReader(tester);

      await tester.tapAt(const Offset(210, 400));
      await tester.pumpAndSettle();
      await tester.tap(find.text('书签'));
      await tester.pumpAndSettle();

      // 输入一个正文里存在的词。
      await tester.enterText(find.byType(TextField).first, '分页');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(find.textContaining('/'), findsWidgets, reason: '显示 命中序号/总数');
    });

    testWidgets('章节内查找：无结果时如实说「无结果」', (tester) async {
      await pumpReader(tester);

      await tester.tapAt(const Offset(210, 400));
      await tester.pumpAndSettle();
      await tester.tap(find.text('书签'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).first, '这个词一定不存在xyz');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(find.text('无结果'), findsOneWidget);
    });

    testWidgets('自动翻页：开关与间隔选择都在面板里', (tester) async {
      await pumpReader(tester);

      await tester.tapAt(const Offset(210, 400));
      await tester.pumpAndSettle();
      await tester.tap(find.text('书签'));
      await tester.pumpAndSettle();

      expect(find.text('自动翻页'), findsOneWidget);
      expect(find.byType(Switch), findsOneWidget);
      expect(find.text('15 秒'), findsOneWidget, reason: '默认间隔');
    });
  });
}

/// 小说数据源替身：每章给一段可重复的长文本。
class _NovelSource implements DataSource {
  _NovelSource(this.textForChapter);

  final String Function(int chapter) textForChapter;

  @override
  final Section section = Section.novel;

  @override
  String get id => 'novel-1';

  @override
  String get name => '小说源';

  @override
  Future<List<SourceCategory>> categories() async => const <SourceCategory>[];

  @override
  Future<SourceList> list({
    String? categoryId,
    String? keyword,
    int page = 1,
  }) async =>
      const SourceList();

  @override
  Future<SourceDetail?> detail(String itemId) async => null;

  @override
  Future<List<SourceChapter>> chapters(String itemId) async =>
      const <SourceChapter>[
        SourceChapter(id: 'c1', title: '第一章'),
        SourceChapter(id: 'c2', title: '第二章'),
      ];

  @override
  Future<ChapterContent?> content({
    required String itemId,
    required String chapterId,
  }) async {
    final index = chapterId == 'c1' ? 0 : 1;
    return TextContent(textForChapter(index));
  }
}
