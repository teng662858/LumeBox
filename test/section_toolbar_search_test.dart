import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/features/reading/explore_view.dart';
import 'package:lume_box/features/reading/section_toolbar.dart';

import 'support/fake_source_manager.dart';

/// 浏览页顶部工具栏与搜索（真机反馈的改造）：
///
/// - 工具栏**一行完整控件，顺序固定**：源下拉 → 排序 → 布局 → 搜索 → 筛选（三板块一致）；
/// - 搜索拆两种模式：聚合（跨全部已启用源）/ 当前源；
/// - 联想词：优先图源 `suggest`，没有就用本地搜索历史；空输入不弹；最多 10 条；
/// - 结果页：顶部保留关键词，行内给「时长 / 来源 / 更新时间」。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('lume_box_toolbar');
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
  });

  tearDown(() async {
    ReadingLibrary.disposeAll();
    ReadingStore.disposeAll();
    await SectionScope.closeAll();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<SectionImagePipeline> openPipeline(Section section) async {
    final library = await ReadingLibrary.open(section);
    return SectionImagePipeline(
      cacheDir: library.imageCacheDir,
      memoryBudgetBytes: SectionImagePipeline.thumbnailBudgetBytes,
    );
  }

  Future<void> pumpExplore(
    WidgetTester tester, {
    required Section section,
    required DataSource source,
    String sourceName = '测试源',
  }) async {
    final pipeline = await openPipeline(section);
    addTearDown(pipeline.dispose);
    await tester.binding.setSurfaceSize(const Size(900, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: LumeTheme.build(),
        home: Scaffold(
          body: ExploreView(
            section: section,
            pipeline: pipeline,
            layout: ExploreLayout.list,
            manager: FakeSourceManager(
              sources: <SourceDescriptor>[
                SourceDescriptor(
                  id: source.id,
                  name: sourceName,
                  version: '1',
                  enabled: true,
                ),
              ],
              opened: <String, DataSource>{source.id: source},
            ),
            onOpenItem: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('工具栏（三板块同一套）', () {
    for (final section in <Section>[Section.novel, Section.comic, Section.video]) {
      testWidgets('${section.label}：一行五个控件，顺序固定', (tester) async {
        final source = _SearchSource(section: section);
        await pumpExplore(tester, section: section, source: source);

        final toolbar = find.byType(SectionToolbar);
        expect(toolbar, findsOneWidget);

        // 顺序：源下拉 → 排序 → 布局 → 搜索 → 筛选。
        for (final tooltip in <String>['排序', '布局', '搜索', '筛选']) {
          expect(
            find.descendant(of: toolbar, matching: find.byTooltip(tooltip)),
            findsOneWidget,
            reason: '工具栏缺少「$tooltip」',
          );
        }
        expect(find.descendant(of: toolbar, matching: find.byTooltip('源管理')), findsOneWidget);

        final centers = <String, double>{
          for (final tooltip in <String>['排序', '布局', '搜索', '筛选'])
            tooltip: tester
                .getTopLeft(
                  find.descendant(of: toolbar, matching: find.byTooltip(tooltip)),
                )
                .dx,
        };
        expect(centers['排序']!, lessThan(centers['布局']!), reason: '排序在布局左边');
        expect(centers['布局']!, lessThan(centers['搜索']!), reason: '布局在搜索左边');
        expect(centers['搜索']!, lessThan(centers['筛选']!), reason: '搜索在筛选左边');
      });
    }

    testWidgets('排序：菜单可选，选中后列表按该字段重排', (tester) async {
      final source = _SearchSource(
        section: Section.video,
        items: const <SourceItem>[
          SourceItem(id: 'b', title: 'B 条目', duration: Duration(minutes: 3)),
          SourceItem(id: 'a', title: 'A 条目', duration: Duration(minutes: 9)),
        ],
      );
      await pumpExplore(tester, section: Section.video, source: source);

      await tester.tap(find.byTooltip('排序'));
      await tester.pumpAndSettle();
      expect(find.text('时长'), findsOneWidget);
      await tester.tap(find.text('时长'));
      await tester.pumpAndSettle();

      // 按标题排：A 在 B 前（默认顺序是 B、A）。
      await tester.tap(find.byTooltip('排序'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('标题'));
      await tester.pumpAndSettle();

      final first = tester.getTopLeft(find.text('A 条目')).dy;
      final second = tester.getTopLeft(find.text('B 条目')).dy;
      expect(first, lessThan(second), reason: '标题升序');
    });
  });

  group('搜索：两种模式', () {
    testWidgets('点搜索先选范围：聚合 / 当前源两个选项都在', (tester) async {
      await pumpExplore(
        tester,
        section: Section.video,
        source: _SearchSource(section: Section.video),
      );

      await tester.tap(find.byTooltip('搜索'));
      await tester.pumpAndSettle();

      expect(find.text('聚合搜索'), findsOneWidget);
      expect(find.text('当前源搜索'), findsOneWidget);
      expect(find.textContaining('跨本板块全部已启用源'), findsOneWidget);
    });

    testWidgets('当前源搜索：只问当前源，结果页保留关键词且行内给出时长 / 来源 / 更新时间', (tester) async {
      final first = _SearchSource(
        section: Section.video,
        name: '甲源',
        items: <SourceItem>[
          SourceItem(
            id: 'm1',
            title: '命中影片',
            duration: const Duration(minutes: 12, seconds: 34),
            updatedAt: DateTime(2026, 10, 5),
          ),
        ],
      );
      final second = _SearchSource(
        section: Section.video,
        id: 'source-b',
        name: '乙源',
        items: const <SourceItem>[SourceItem(id: 'm2', title: '乙源影片')],
      );
      final pipeline = await openPipeline(Section.video);
      addTearDown(pipeline.dispose);
      await tester.binding.setSurfaceSize(const Size(900, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: LumeTheme.build(),
          home: Scaffold(
            body: ExploreView(
              section: Section.video,
              pipeline: pipeline,
              layout: ExploreLayout.list,
              manager: FakeSourceManager(
                sources: const <SourceDescriptor>[
                  SourceDescriptor(id: 'source-a', name: '甲源', version: '1', enabled: true),
                  SourceDescriptor(id: 'source-b', name: '乙源', version: '1', enabled: true),
                ],
                opened: <String, DataSource>{'source-a': first, 'source-b': second},
              ),
              onOpenItem: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('搜索'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('当前源搜索'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '影片');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();

      expect(find.text('命中影片'), findsOneWidget);
      expect(find.text('乙源影片'), findsNothing, reason: '当前源搜索不跨源');
      expect(first.keywords, <String>['影片']);
      expect(second.keywords, isEmpty);
      // 行内元信息：时长 / 更新时间（来源在单源模式下不显示）。
      expect(find.textContaining('时长 12:34'), findsOneWidget);
      expect(find.textContaining('更新 2026-10-05'), findsOneWidget);
    });

    testWidgets('聚合搜索：并发问所有已启用源，结果标注来源', (tester) async {
      final first = _SearchSource(
        section: Section.video,
        name: '甲源',
        items: const <SourceItem>[SourceItem(id: 'm1', title: '甲的影片')],
      );
      final second = _SearchSource(
        section: Section.video,
        id: 'source-b',
        name: '乙源',
        items: const <SourceItem>[SourceItem(id: 'm2', title: '乙的影片')],
      );
      final pipeline = await openPipeline(Section.video);
      addTearDown(pipeline.dispose);
      await tester.binding.setSurfaceSize(const Size(900, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: LumeTheme.build(),
          home: Scaffold(
            body: ExploreView(
              section: Section.video,
              pipeline: pipeline,
              layout: ExploreLayout.list,
              manager: FakeSourceManager(
                sources: const <SourceDescriptor>[
                  SourceDescriptor(id: 'source-a', name: '甲源', version: '1', enabled: true),
                  SourceDescriptor(id: 'source-b', name: '乙源', version: '1', enabled: true),
                ],
                opened: <String, DataSource>{'source-a': first, 'source-b': second},
              ),
              onOpenItem: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('搜索'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('聚合搜索'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '影片');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();

      expect(find.text('甲的影片'), findsOneWidget);
      expect(find.text('乙的影片'), findsOneWidget, reason: '聚合搜索跨源');
      expect(first.keywords, <String>['影片']);
      expect(second.keywords, <String>['影片']);
      expect(find.textContaining('来源 甲源'), findsOneWidget);
      expect(find.textContaining('来源 乙源'), findsOneWidget);
    });
  });

  group('搜索联想词', () {
    testWidgets('图源给 suggest：用服务端联想词', (tester) async {
      final source = _SuggestSource(
        section: Section.video,
        suggestions: const <String>['影片 甲', '影片 乙', '影片 丙'],
      );
      await pumpExplore(tester, section: Section.video, source: source);

      await tester.tap(find.byTooltip('搜索'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('当前源搜索'));
      await tester.pumpAndSettle();

      // 空输入不弹（用户点名）。
      expect(find.text('影片 甲'), findsNothing);

      await tester.enterText(find.byType(TextField), '影片');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();

      expect(source.suggestKeywords, <String>['影片']);
      expect(find.text('影片 甲'), findsOneWidget);
      expect(find.text('影片 丙'), findsOneWidget);
    });

    testWidgets('图源没有 suggest：退回本地搜索历史', (tester) async {
      final library = await ReadingLibrary.open(Section.video);
      SearchHistoryStore(Section.video, library).remember('历史关键词');

      final source = _SearchSource(section: Section.video); // 不给 suggestions
      await pumpExplore(tester, section: Section.video, source: source);

      await tester.tap(find.byTooltip('搜索'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('当前源搜索'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '历史');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();

      // 这个替身没有实现 SuggestCapable：联想只能来自本地历史。
      expect(source, isNot(isA<SuggestCapable>()));
      expect(find.text('历史关键词'), findsOneWidget, reason: '用本地历史兜底');
    });

    testWidgets('点联想条目：填入关键词并发起搜索', (tester) async {
      final source = _SuggestSource(
        section: Section.video,
        suggestions: const <String>['影片 甲'],
      );
      await pumpExplore(tester, section: Section.video, source: source);

      await tester.tap(find.byTooltip('搜索'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('当前源搜索'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '影片');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();

      await tester.tap(find.text('影片 甲'));
      await tester.pumpAndSettle();

      expect(source.keywords, <String>['影片 甲'], reason: '点联想直接发起搜索');
    });

    test('联想候选：最多 10 条 / 空输入不给 / 去重且必须含关键词', () async {
      const suggestions = SearchSuggestions(source: null, history: <String>[]);
      expect(await suggestions.forKeyword(''), isEmpty);

      final many = SearchSuggestions(
        source: null,
        history: <String>[for (var i = 0; i < 20; i++) '影片 $i'],
      );
      final limited = await many.forKeyword('影片');
      expect(limited, hasLength(SearchSuggestions.maxEntries));
      expect(SearchSuggestions.maxEntries, 10);

      final noisy = SearchSuggestions(
        source: null,
        history: const <String>['影片', '影片 甲', '影片 甲', '别的'],
      );
      expect(await noisy.forKeyword('影片'), <String>['影片 甲'], reason: '去重 + 排除关键词本身 + 必须含关键词');
    });

    test('搜索历史：去重、最新在前、上限 20 条', () async {
      final library = await ReadingLibrary.open(Section.novel);
      final store = SearchHistoryStore(Section.novel, library);
      store.clear();
      for (var i = 0; i < 25; i++) {
        store.remember('关键词 $i');
      }
      final history = store.load();
      expect(history, hasLength(SearchHistoryStore.maxEntries));
      expect(history.first, '关键词 24', reason: '最新在前');

      store.remember('关键词 10');
      expect(store.load().first, '关键词 10', reason: '重复搜索提到最前而不是留两条');

      // 板块隔离：视频板块的历史不受影响。
      final video = SearchHistoryStore(
        Section.video,
        await ReadingLibrary.open(Section.video),
      );
      expect(video.load(), isEmpty);
      store.clear();
    });
  });
}

/// 搜索用图源替身：记录关键词、可按页给条目，可选提供 suggest。
class _SearchSource implements DataSource {
  _SearchSource({
    required this.section,
    this.id = 'source-a',
    this.name = '测试源',
    this.items = const <SourceItem>[],
  });

  @override
  final Section section;

  @override
  final String id;

  @override
  final String name;

  final List<SourceItem> items;

  final List<String> keywords = <String>[];

  @override
  Future<List<SourceCategory>> categories() async => const <SourceCategory>[];

  @override
  Future<SourceList> list({String? categoryId, String? keyword, int page = 1}) async {
    if (keyword != null && keyword.isNotEmpty) keywords.add(keyword);
    return SourceList(items: items, hasMore: false);
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

/// 实现了 `suggest` 能力的图源替身（服务端联想词）。
class _SuggestSource extends _SearchSource implements SuggestCapable {
  _SuggestSource({
    required super.section,
    super.id,
    super.name,
    super.items,
    required this.suggestions,
  });

  final List<String> suggestions;
  final List<String> suggestKeywords = <String>[];

  @override
  Future<List<String>> suggest(String keyword) async {
    suggestKeywords.add(keyword);
    return suggestions;
  }
}
