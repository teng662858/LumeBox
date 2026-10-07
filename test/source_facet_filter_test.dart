import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/features/reading/source_filter_page.dart';

/// 分页跳转筛选（用户要求：三板块共用；标签实时抓取 + 短时缓存）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('短时缓存：TTL 内命中不再问脚本，过期后重取', () {
    var now = DateTime(2026, 10, 8, 12);
    final cache = SourceFilterCache(
      ttl: const Duration(minutes: 5),
      clock: () => now,
    );
    final groups = <SourceFilterGroup>[
      const SourceFilterGroup(
        id: 'type',
        title: '剧集类型',
        options: <SourceFilterOption>[
          SourceFilterOption(id: '1', title: '国产剧'),
        ],
      ),
    ];

    expect(cache.read('src'), isNull, reason: '没写过就没有');
    cache.write('src', groups);
    expect(cache.read('src'), groups, reason: 'TTL 内命中');
    now = now.add(const Duration(minutes: 6));
    expect(cache.read('src'), isNull, reason: '过期即失效');
  });

  test('契约解析：宽容认形状（缺 id / 缺选项的组跳过，字符串选项也认）', () {
    final groups = SourceFilterGroup.parseAll(<Object?>[
      <String, Object?>{
        'id': 'type',
        'title': '剧集类型',
        'options': <Object?>[
          <String, Object?>{'id': '1', 'title': '国产剧'},
          '悬疑',
        ],
      },
      <String, Object?>{'id': 'area', 'title': '地区', 'options': <Object?>[]},
      <String, Object?>{'title': '没有 id'},
      <String, Object?>{
        'id': 'year',
        'title': '年份',
        'options': <Object?>[
          <String, Object?>{'value': '2024', 'label': '2024'},
        ],
      },
    ]);
    expect(groups.map((group) => group.id), <String>['type', 'year']);
    expect(groups.first.options.map((option) => option.id), <String>['1', '悬疑']);
    expect(groups.last.options.single.title, '2024');
  });

  testWidgets('筛选子页：一行一组横向标签，多选叠加，应用回传组合条件', (tester) async {
    SourceFilterSelection? applied;
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: LumeTheme.build(),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () async {
                  applied =
                      await Navigator.of(context).push<SourceFilterSelection>(
                    MaterialPageRoute<SourceFilterSelection>(
                      builder: (_) => SourceFilterPage(
                        source: _FacetSource(),
                        categoryId: 'movie',
                        categoryTitle: '电影',
                        cache: SourceFilterCache(),
                      ),
                    ),
                  );
                },
                child: const Text('打开筛选'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开筛选'));
    await tester.pumpAndSettle();

    expect(find.text('筛选 · 电影'), findsOneWidget);
    expect(find.text('剧集类型'), findsOneWidget);
    expect(find.byType(ChoiceChip), findsNWidgets(6), reason: '2 + 2 + 2 个标签');

    await tester.tap(find.widgetWithText(ChoiceChip, '喜剧'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, '悬疑'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, '大陆'));
    await tester.pumpAndSettle();

    await tester.tap(find.textContaining('应用筛选'));
    await tester.pumpAndSettle();

    expect(applied, isNotNull);
    expect(applied!.categoryId, 'movie');
    expect(applied!.filters['type'], 'comedy,mystery');
    expect(applied!.filters['area'], 'cn');
  });

  testWidgets('筛选第一层：只列一级大分类，点分类进子页，应用后整条链路返回', (tester) async {
    SourceFilterSelection? applied;
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: LumeTheme.build(),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () async {
                  applied =
                      await Navigator.of(context).push<SourceFilterSelection>(
                    MaterialPageRoute<SourceFilterSelection>(
                      builder: (_) => SourceFilterCategoryPage(
                        source: _FacetSource(),
                        cache: SourceFilterCache(),
                      ),
                    ),
                  );
                },
                child: const Text('筛选入口'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('筛选入口'));
    await tester.pumpAndSettle();

    expect(find.text('筛选'), findsOneWidget);
    expect(find.text('电影'), findsOneWidget);
    expect(find.byType(ChoiceChip), findsNothing, reason: '第一层不放标签');

    await tester.tap(find.text('电影'));
    await tester.pumpAndSettle();
    expect(find.text('筛选 · 电影'), findsOneWidget);

    await tester.tap(find.widgetWithText(ChoiceChip, '喜剧'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('应用筛选'));
    await tester.pumpAndSettle();

    expect(applied, isNotNull);
    expect(applied!.categoryId, 'movie');
    expect(applied!.filters['type'], 'comedy');
  });

  testWidgets('图源没提供 filters 契约：给可读说明，不是空白', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: LumeTheme.build(),
        home: SourceFilterPage(
          source: _NoFacetSource(),
          categoryId: 'movie',
          categoryTitle: '电影',
          cache: SourceFilterCache(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('本源不支持筛选'), findsOneWidget);
  });
}

/// 提供筛选标签的替身图源（三组）。
class _FacetSource implements DataSource, FilterCapable {
  @override
  String get id => 'facet-source';

  @override
  String get name => '筛选测试源';

  @override
  Section get section => Section.video;

  @override
  Future<List<SourceFilterGroup>> filters() async => <SourceFilterGroup>[
        const SourceFilterGroup(
          id: 'type',
          title: '剧集类型',
          options: <SourceFilterOption>[
            SourceFilterOption(id: 'comedy', title: '喜剧'),
            SourceFilterOption(id: 'mystery', title: '悬疑'),
          ],
        ),
        const SourceFilterGroup(
          id: 'area',
          title: '地区',
          options: <SourceFilterOption>[
            SourceFilterOption(id: 'cn', title: '大陆'),
            SourceFilterOption(id: 'hk', title: '香港'),
          ],
        ),
        const SourceFilterGroup(
          id: 'year',
          title: '年份',
          options: <SourceFilterOption>[
            SourceFilterOption(id: '2024', title: '2024'),
            SourceFilterOption(id: '2023', title: '2023'),
          ],
        ),
      ];

  @override
  Future<List<SourceCategory>> categories() async =>
      const <SourceCategory>[SourceCategory(id: 'movie', title: '电影')];

  @override
  Future<SourceList> list({
    String? categoryId,
    String? keyword,
    int page = 1,
    Map<String, String>? filters,
  }) async =>
      const SourceList(items: <SourceItem>[], hasMore: false);

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

/// 不支持筛选的替身图源（没有 FilterCapable 能力）。
class _NoFacetSource implements DataSource {
  @override
  String get id => 'no-facet-source';

  @override
  String get name => '无筛选测试源';

  @override
  Section get section => Section.video;

  @override
  Future<List<SourceCategory>> categories() async =>
      const <SourceCategory>[SourceCategory(id: 'movie', title: '电影')];

  @override
  Future<SourceList> list({
    String? categoryId,
    String? keyword,
    int page = 1,
    Map<String, String>? filters,
  }) async =>
      const SourceList(items: <SourceItem>[], hasMore: false);

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
