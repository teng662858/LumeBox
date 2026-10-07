import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/features/reading/source_home_view.dart';

/// 首页多板块横滑（用户口径任务 3；视频 / 小说 / 漫画三块共用同一个组件）。
///
/// 守三件事：
///   1. `home()` 两套返回格式**自动识别**（板块数组 / 旧兼容的平铺 Item 数组）；
///   2. 自适应渲染：空板块跳过、moreUrl 为空不显示「更多」、空首页给提示；
///   3. 旧图源（没有 home 契约）与空返回都不崩、不空转。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('两套格式自动识别', () {
    test('板块数组 → 多板块模式（title / moreUrl / items）', () {
      final home = SourceHome.parse(<Object?>[
        <String, Object?>{
          'title': '近期必看',
          'moreUrl': 'hot',
          'items': <Object?>[
            <String, Object?>{'id': '1', 'title': '片子一'},
            <String, Object?>{'id': '2', 'title': '片子二'},
          ],
        },
        <String, Object?>{
          'title': '猜你喜欢',
          'items': <Object?>[
            <String, Object?>{'id': '3', 'title': '片子三'},
          ],
        },
      ]);

      expect(home.isBoards, isTrue);
      expect(home.boards.length, 2);
      expect(home.boards.first.title, '近期必看');
      expect(home.boards.first.moreUrl, 'hot');
      expect(home.boards.first.items.map((item) => item.title), <String>['片子一', '片子二']);
      expect(home.boards.last.moreUrl, isNull, reason: '没给 moreUrl 就是 null');
    });

    test('平铺 Item 数组 → 旧兼容模式（不出现任何板块）', () {
      final home = SourceHome.parse(<Object?>[
        <String, Object?>{'id': '1', 'title': '条目一'},
        <String, Object?>{'id': '2', 'title': '条目二'},
      ]);
      expect(home.isBoards, isFalse);
      expect(home.items.length, 2);
      expect(home.isEmpty, isFalse);
    });

    test('空数组 / 认不出 → isEmpty（页面给「暂无首页推荐内容」）', () {
      expect(SourceHome.parse(const <Object?>[]).isEmpty, isTrue);
      expect(SourceHome.parse(null).isEmpty, isTrue);
      expect(SourceHome.parse('nonsense').isEmpty, isTrue);
    });

    test('空 items 的板块整块跳过（不留空占位）', () {
      final home = SourceHome.parse(<Object?>[
        <String, Object?>{'title': '空板块', 'items': <Object?>[]},
        <String, Object?>{
          'title': '正常板块',
          'items': <Object?>[
            <String, Object?>{'id': '1', 'title': '片子'},
          ],
        },
      ]);
      expect(home.boards.map((board) => board.title), <String>['正常板块']);
    });
  });

  group('渲染', () {
    Future<void> pump(WidgetTester tester, DataSource source,
        {void Function(String title, String moreUrl)? onOpenMore}) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: LumeTheme.build(),
          home: Scaffold(
            body: SourceHomeView(
              source: source,
              pipeline: null, // 测试不加载封面（管线为空时出纯色占位）。
              onOpenItem: (_) {},
              onOpenMore: onOpenMore,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('多板块：标题来自图源、有 moreUrl 才出现「更多」', (tester) async {
      var moreArgs = '';
      await pump(
        tester,
        _HomeSource(
          const SourceHome(boards: <SourceHomeBoard>[
            SourceHomeBoard(
              title: '近期必看',
              moreUrl: 'hot',
              items: <SourceItem>[
                SourceItem(id: '1', title: '片子一'),
                SourceItem(id: '2', title: '片子二'),
              ],
            ),
            SourceHomeBoard(
              title: '猜你喜欢',
              items: <SourceItem>[
                SourceItem(id: '3', title: '片子三'),
              ],
            ),
          ]),
        ),
        onOpenMore: (title, moreUrl) => moreArgs = '$title|$moreUrl',
      );

      expect(find.text('近期必看'), findsOneWidget);
      expect(find.text('猜你喜欢'), findsOneWidget);
      expect(find.text('更多'), findsOneWidget, reason: '只有带 moreUrl 的那块有「更多」');
      expect(find.text('片子一'), findsOneWidget);

      await tester.tap(find.text('更多'));
      await tester.pumpAndSettle();
      expect(moreArgs, '近期必看|hot', reason: '把 moreUrl 交给宿主去加载分页');
    });

    testWidgets('旧兼容：平铺数组渲染成网格，不出现「更多」等板块元素', (tester) async {
      await pump(
        tester,
        _HomeSource(const SourceHome(items: <SourceItem>[
          SourceItem(id: '1', title: '条目一'),
          SourceItem(id: '2', title: '条目二'),
        ])),
      );

      expect(find.text('条目一'), findsOneWidget);
      expect(find.text('更多'), findsNothing);
      expect(find.byType(GridView), findsOneWidget, reason: '普通网格首页');
    });

    testWidgets('空首页：给提示并引导去分类', (tester) async {
      await pump(tester, _HomeSource(const SourceHome()));
      expect(find.text('暂无首页推荐内容'), findsOneWidget);
      expect(find.text('去分类浏览'), findsOneWidget);
    });

    testWidgets('图源没有 home 契约：同样走「暂无首页推荐内容」，不崩', (tester) async {
      await pump(tester, _NoHomeSource());
      expect(find.text('暂无首页推荐内容'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}

/// 提供 home() 的替身图源。
class _HomeSource implements DataSource, HomeCapable {
  _HomeSource(this._home);

  final SourceHome _home;

  @override
  String get id => 'home-source';

  @override
  String get name => '首页测试源';

  @override
  Section get section => Section.video;

  @override
  Future<SourceHome> home() async => _home;

  @override
  Future<List<SourceCategory>> categories() async => const <SourceCategory>[];

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

/// 老图源：没有 HomeCapable。
class _NoHomeSource implements DataSource {
  @override
  String get id => 'legacy-source';

  @override
  String get name => '老图源';

  @override
  Section get section => Section.novel;

  @override
  Future<List<SourceCategory>> categories() async => const <SourceCategory>[];

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
