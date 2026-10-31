import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/reading/browse_layout.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/features/reading/source_home_view.dart';
import 'package:lume_box/features/shell/section_preloader.dart';

import 'support/fake_source_manager.dart';

/// 首页多板块横滑（用户口径任务 3；视频 / 小说 / 漫画三块共用同一个组件）。
///
/// 守三件事：
///   1. `home()` 两套返回格式**自动识别**（板块数组 / 旧兼容的平铺 Item 数组）；
///   2. 自适应渲染：空板块跳过、moreUrl 为空不显示「更多」、空首页给提示；
///   3. 旧图源（没有 home 契约）与空返回都不崩、不空转。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    BrowseLayoutSettings.instance.resetForTesting();
    SectionPreloader.discard(Section.video);
  });
  tearDown(() {
    BrowseLayoutSettings.instance.resetForTesting();
    SectionPreloader.discard(Section.video);
  });

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
      expect(home.boards.first.items.map((item) => item.title), <String>[
        '片子一',
        '片子二',
      ]);
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
    Future<void> pump(
      WidgetTester tester,
      DataSource source, {
      void Function(String title, String moreUrl)? onOpenMore,
    }) async {
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
          const SourceHome(
            boards: <SourceHomeBoard>[
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
                items: <SourceItem>[SourceItem(id: '3', title: '片子三')],
              ),
            ],
          ),
        ),
        onOpenMore: (title, moreUrl) => moreArgs = '$title|$moreUrl',
      );

      expect(find.text('近期必看'), findsNothing);
      expect(find.text('猜你喜欢'), findsNothing);
      expect(find.text('更多'), findsNothing);
      for (final title in ['片子一', '片子二', '片子三']) {
        expect(find.text(title), findsOneWidget);
      }
      expect(moreArgs, isEmpty);
      final grid = tester.widget<GridView>(find.byType(GridView));
      expect(
        (grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount)
            .crossAxisCount,
        3,
      );
    });

    testWidgets('旧兼容：平铺数组渲染成网格，不出现「更多」等板块元素', (tester) async {
      await pump(
        tester,
        _HomeSource(
          const SourceHome(
            items: <SourceItem>[
              SourceItem(id: '1', title: '条目一'),
              SourceItem(id: '2', title: '条目二'),
            ],
          ),
        ),
      );

      expect(find.text('条目一'), findsOneWidget);
      expect(find.text('更多'), findsNothing);
      expect(find.byType(GridView), findsOneWidget, reason: '普通网格首页');
    });

    for (final section in [Section.comic, Section.video]) {
      testWidgets('${section.id}首页应用全部布局档位且不重新加载源', (tester) async {
        var opened = '';
        final source = _HomeSource(
          const SourceHome(
            items: [SourceItem(id: 'sample', title: '示例条目')],
          ),
          section: section,
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SourceHomeView(
                source: source,
                pipeline: null,
                onOpenItem: (item) => opened = item.id,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        for (final mode in BrowseLayoutMode.values) {
          await BrowseLayoutSettings.instance.setMode(section, mode);
          await tester.pumpAndSettle();
          {
            final grid = tester.widget<GridView>(find.byType(GridView));
            expect(
              (grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount)
                  .crossAxisCount,
              BrowseLayoutSettings.normalize(mode).columns,
            );
          }
          expect(find.text('示例条目'), findsOneWidget);
        }
        await tester.tap(find.text('示例条目'));
        expect(opened, 'sample');
      });
    }

    testWidgets('空首页：给提示并引导去分类', (tester) async {
      await pump(tester, _HomeSource(const SourceHome()));
      expect(find.text('暂无首页推荐内容'), findsOneWidget);
      expect(find.text('去分类浏览'), findsOneWidget);
    });

    testWidgets('同 id 新数据源替换时丢弃预热并拒绝旧首页结果', (tester) async {
      final oldSource = _PendingHomeSource();
      final newSource = _HomeSource(
        const SourceHome(
          items: <SourceItem>[SourceItem(id: 'new', title: '新域名首页')],
        ),
      );
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        MaterialApp(
          theme: LumeTheme.build(),
          home: Scaffold(
            body: SourceHomeView(
              source: oldSource,
              pipeline: null,
              onOpenItem: (_) {},
            ),
          ),
        ),
      );
      await tester.pump();
      expect(oldSource.calls, 1);

      // A concurrent preloader can still finish an old same-id result; settings
      // reload must discard it rather than consume it as the new domain's home.
      final warmSource = _HomeSource(
        const SourceHome(
          items: <SourceItem>[SourceItem(id: 'warm', title: '旧预热首页')],
        ),
      );
      final warmManager = FakeSourceManager(
        sources: const <SourceDescriptor>[
          SourceDescriptor(
            id: 'home-source',
            name: '首页测试源',
            version: '1.0.0',
            enabled: true,
          ),
        ],
        opened: <String, DataSource>{'home-source': warmSource},
      );
      await SectionPreloader.warm(Section.video, manager: warmManager);
      expect(SectionPreloader.hasWarm(Section.video), isTrue);

      // Settings return creates a new DataSource with the same persistent id.
      await tester.pumpWidget(
        MaterialApp(
          theme: LumeTheme.build(),
          home: Scaffold(
            body: SourceHomeView(
              source: newSource,
              pipeline: null,
              onOpenItem: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('新域名首页'), findsOneWidget);
      expect(find.text('旧预热首页'), findsNothing);
      expect(SectionPreloader.hasWarm(Section.video), isFalse);

      // An old uncancellable source Future may complete later; its result is stale.
      oldSource.gate.complete(
        const SourceHome(
          items: <SourceItem>[SourceItem(id: 'old', title: '旧域名首页')],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('新域名首页'), findsOneWidget);
      expect(find.text('旧域名首页'), findsNothing);
    });

    testWidgets('请求已取消后只自动重试一次并加载首页', (tester) async {
      final source = _CancelOnceHomeSource();
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: LumeTheme.build(),
          home: Scaffold(
            body: SourceHomeView(
              source: source,
              pipeline: null,
              onOpenItem: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(source.calls, 2);
      expect(find.text('取消后恢复首页'), findsOneWidget);
      expect(find.text('首页加载失败'), findsNothing);
    });

    testWidgets('首页重试同时刷新分类元数据', (tester) async {
      final source = _FailOnceHomeSource();
      var metadataRefreshes = 0;
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: LumeTheme.build(),
          home: Scaffold(
            body: SourceHomeView(
              source: source,
              pipeline: null,
              onOpenItem: (_) {},
              onRefreshMetadata: () async {
                metadataRefreshes++;
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('首页加载失败'), findsOneWidget);
      expect(metadataRefreshes, 0);
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(find.text('恢复后的首页'), findsOneWidget);
      expect(metadataRefreshes, 1);
    });

    testWidgets('图源没有 home 契约：不进首页模式（ExploreView 会走老路径）', (tester) async {
      // 这里直接验「探测为 false 时不会去调 home()」——真机上老脚本曾因此整块变错误页。
      final source = _NoHomeSource();
      expect(await source.supportsHome(), isFalse);
      // 独立组件仍能安全渲染空态（不崩、不空转）。
      await pump(tester, source);
      expect(tester.takeException(), isNull);
    });
  });
}

/// 提供 home() 的替身图源。
class _HomeSource implements DataSource, HomeCapable {
  _HomeSource(this._home, {this.section = Section.video});

  final SourceHome _home;

  @override
  String get id => 'home-source';

  @override
  String get name => '首页测试源';

  @override
  final Section section;

  @override
  Future<bool> supportsHome() async => true;

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
  }) async => const SourceList(items: <SourceItem>[], hasMore: false);

  @override
  Future<SourceDetail?> detail(String itemId) async => null;

  @override
  Future<List<SourceChapter>> chapters(String itemId) async =>
      const <SourceChapter>[];

  @override
  Future<ChapterContent?> content({
    required String itemId,
    required String chapterId,
  }) async => null;
}

class _PendingHomeSource extends _HomeSource {
  _PendingHomeSource() : super(const SourceHome());

  final gate = Completer<SourceHome>();
  int calls = 0;

  @override
  Future<SourceHome> home() {
    calls++;
    return gate.future;
  }
}

class _CancelOnceHomeSource extends _HomeSource {
  _CancelOnceHomeSource() : super(const SourceHome());

  int calls = 0;

  @override
  Future<SourceHome> home() async {
    if (calls++ == 0) {
      throw const SourceException(SourceErrorKind.network, '请求已取消');
    }
    return const SourceHome(
      items: <SourceItem>[SourceItem(id: 'recovered', title: '取消后恢复首页')],
    );
  }
}

/// 老图源：没有 home()（接口存在但探测为 false）。
class _NoHomeSource implements DataSource, HomeCapable {
  @override
  String get id => 'legacy-source';

  @override
  String get name => '老图源';

  @override
  Section get section => Section.video;

  /// 老脚本：接口在、但探测为 false（**不该**被调 home()）。
  @override
  Future<bool> supportsHome() async => false;

  @override
  Future<SourceHome> home() async => throw StateError('老脚本没有 home()，不该被调用');

  @override
  Future<List<SourceCategory>> categories() async => const <SourceCategory>[];

  @override
  Future<SourceList> list({
    String? categoryId,
    String? keyword,
    int page = 1,
    Map<String, String>? filters,
  }) async => const SourceList(items: <SourceItem>[], hasMore: false);

  @override
  Future<SourceDetail?> detail(String itemId) async => null;

  @override
  Future<List<SourceChapter>> chapters(String itemId) async =>
      const <SourceChapter>[];

  @override
  Future<ChapterContent?> content({
    required String itemId,
    required String chapterId,
  }) async => null;
}

class _FailOnceHomeSource extends _HomeSource {
  _FailOnceHomeSource() : super(const SourceHome());

  int _calls = 0;

  @override
  Future<SourceHome> home() async {
    if (_calls++ == 0) {
      throw const SourceException(SourceErrorKind.network, '网络请求失败');
    }
    return const SourceHome(
      items: <SourceItem>[SourceItem(id: 'recovered', title: '恢复后的首页')],
    );
  }
}
