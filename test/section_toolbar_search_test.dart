import 'dart:async';
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
import 'package:lume_box/features/reading/search_results_page.dart';
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

  /// 挂一个探索页（搜索用例的公共入口）。
  Future<void> pumpBrowse(WidgetTester tester, DataSource source) =>
      pumpExplore(tester, section: Section.video, source: source);

  /// 打开搜索行（默认范围 = 当前源搜索，不切模式）。
  Future<void> openSearchField(WidgetTester tester) async {
    await tester.tap(find.byTooltip('搜索'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('应用'));
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
      await tester.tap(find.text('应用'));
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
      await tester.tap(find.text('应用'));
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
    testWidgets('搜索后离开首页网格：结果在独立结果页，返回才回首页', (tester) async {
      final source = _SearchSource(
        section: Section.video,
        items: const <SourceItem>[SourceItem(id: 'v1', title: '命中影片')],
      );
      await pumpBrowse(tester, source);
      // 首页网格里先有一条推荐内容，用来证明搜索后确实离开了它。
      expect(find.text('首页推荐'), findsNothing);

      await openSearchField(tester);
      await tester.enterText(find.byType(TextField), '影片');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();

      expect(find.byType(SearchResultsPage), findsOneWidget, reason: '搜索必须跳到独立结果页');
      expect(find.text('命中影片'), findsOneWidget, reason: '结果页展示命中条目');
      expect(find.text('搜索 · 影片'), findsOneWidget, reason: '结果页抬头保留关键词');

      // 返回后回到探索页（首页网格还在）。
      await tester.tap(find.byTooltip('返回'));
      await tester.pumpAndSettle();
      expect(find.byType(SearchResultsPage), findsNothing);
    });

    testWidgets('搜不到：结果页清空并显示「未搜索到相关内容」', (tester) async {
      final source = _SearchSource(
        section: Section.video,
        items: const <SourceItem>[SourceItem(id: 'v1', title: '命中影片')],
        matchingKeyword: '别的词',
      );
      await pumpBrowse(tester, source);
      await openSearchField(tester);
      await tester.enterText(find.byType(TextField), '不存在的影片');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();

      expect(find.text('未搜索到相关内容'), findsOneWidget);
      expect(find.text('命中影片'), findsNothing, reason: '空结果页不许再显示旧内容');
    });

    testWidgets('加载中：请求在飞时结果页转圈，不闪空态', (tester) async {
      final gate = Completer<void>();
      final source = _SearchSource(
        section: Section.video,
        items: const <SourceItem>[SourceItem(id: 'v1', title: '命中影片')],
        gate: gate.future,
      );
      await pumpBrowse(tester, source);
      await openSearchField(tester);
      await tester.enterText(find.byType(TextField), '影片');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      // 不 settle：停在请求在飞的那一刻。
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      expect(find.text('正在加载…'), findsOneWidget, reason: '请求期间要有转圈');
      expect(find.text('未搜索到相关内容'), findsNothing, reason: '加载中不能先报空');

      gate.complete();
      await tester.pumpAndSettle();
      expect(find.text('命中影片'), findsOneWidget);
    });

    testWidgets('网络出错：结果页给错误提示 + 重试', (tester) async {
      final source = _SearchSource(
        section: Section.video,
        fail: const SourceException(SourceErrorKind.network, '连接超时'),
      );
      await pumpBrowse(tester, source);
      await openSearchField(tester);
      await tester.enterText(find.byType(TextField), '影片');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();

      expect(find.textContaining('连接超时'), findsOneWidget, reason: '要把错误原因说清楚');
      expect(find.text('重试'), findsWidgets, reason: '失败要有重试出口');
      expect(find.text('未搜索到相关内容'), findsNothing, reason: '失败不等于没结果');
    });

    testWidgets('搜索范围：点选项圆点当场移动，应用后标签与提示同步', (tester) async {
      await pumpBrowse(tester, _SearchSource(section: Section.video));
      await tester.tap(find.byTooltip('搜索'));
      await tester.pumpAndSettle();

      // 面板打开时按**当前模式**选中（默认当前源搜索）。
      expect(find.text('搜索范围'), findsOneWidget);
      expect(
        find.descendant(
          of: find.widgetWithText(ListTile, '当前源搜索'),
          matching: find.byIcon(Icons.check_circle),
        ),
        findsOneWidget,
        reason: '面板要跟着当前模式高亮，不能写死',
      );
      expect(
        find.descendant(
          of: find.widgetWithText(ListTile, '聚合搜索'),
          matching: find.byIcon(Icons.circle_outlined),
        ),
        findsOneWidget,
      );

      // 点聚合：圆点当场移过去，面板不关。
      await tester.tap(find.widgetWithText(ListTile, '聚合搜索'));
      await tester.pumpAndSettle();
      expect(find.text('搜索范围'), findsOneWidget, reason: '点选项不关面板');
      expect(
        find.descendant(
          of: find.widgetWithText(ListTile, '聚合搜索'),
          matching: find.byIcon(Icons.check_circle),
        ),
        findsOneWidget,
        reason: '单选按钮要真的能切换',
      );

      await tester.tap(find.text('应用'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('搜索全部已启用源'),
        findsOneWidget,
        reason: '输入框提示要跟着面板选择变',
      );
      expect(
        find.widgetWithText(TextButton, '聚合搜索'),
        findsOneWidget,
        reason: '输入框右侧标签要跟着面板选择变',
      );
    });

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
      await tester.tap(find.text('应用'));
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
      await tester.tap(find.text('应用'));
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
      await tester.tap(find.text('应用'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '影片');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();

      await tester.tap(find.text('影片 甲'));
      await tester.pumpAndSettle();

      expect(source.keywords, <String>['影片 甲'], reason: '点联想直接发起搜索');
    });

    testWidgets('点页面空白关闭联想弹窗；返回键也能关（用户点名）', (tester) async {
      final source = _SuggestSource(
        section: Section.video,
        suggestions: const <String>['影片 甲'],
      );
      await pumpExplore(tester, section: Section.video, source: source);

      await tester.tap(find.byTooltip('搜索'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('当前源搜索'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('应用'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '影片');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(find.text('影片 甲'), findsOneWidget);

      // 联想开着时，返回键先关弹窗而不是退出搜索（PopScope 不弹路由）。
      bool canPop() => tester
          .widget<PopScope<dynamic>>(
            find.byWidgetPredicate((widget) => widget is PopScope),
          )
          .canPop;
      expect(canPop(), isFalse, reason: '联想开着时先关它');

      // 点页面空白（列表区域的空白处）关掉它。
      await tester.tapAt(const Offset(450, 1200));
      await tester.pumpAndSettle();
      expect(find.text('影片 甲'), findsNothing, reason: '点空白关闭联想');

      // 关掉之后返回键恢复可用。
      expect(canPop(), isTrue);
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
    this.matchingKeyword,
    this.fail,
    this.gate,
  });

  @override
  final Section section;

  @override
  final String id;

  @override
  final String name;

  final List<SourceItem> items;

  /// 非空时：只有带这个关键词的搜索才返回 [items]（用来造「搜不到」）。
  final String? matchingKeyword;

  /// 非空时：列表请求抛这个异常（用来造网络错误）。
  final Object? fail;

  /// 非空时：列表请求等它放行（用来停在「加载中」）。
  final Future<void>? gate;

  final List<String> keywords = <String>[];

  @override
  Future<List<SourceCategory>> categories() async => const <SourceCategory>[];

  @override
  Future<SourceList> list({
    String? categoryId,
    String? keyword,
    int page = 1,
    Map<String, String>? filters,
  }) async {
    if (keyword != null && keyword.isNotEmpty) keywords.add(keyword);
    // 放行 / 失败 / 关键词过滤都只作用在**搜索请求**上：首页列表照常返回，
    // 否则探索页自己就卡在加载态，用例根本走不到搜索那一步。
    final isSearch = keyword != null && keyword.isNotEmpty;
    if (isSearch) {
      final gate = this.gate;
      if (gate != null) await gate;
      final failure = fail;
      if (failure != null) throw failure;
      final match = matchingKeyword;
      if (match != null && keyword != match) {
        return const SourceList(items: <SourceItem>[], hasMore: false);
      }
    }
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
