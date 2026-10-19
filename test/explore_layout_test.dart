import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/reading/browse_layout.dart';
import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/features/reading/explore_view.dart';
import 'package:lume_box/features/reading/poster_card.dart';
import 'package:lume_box/features/reading/browse_layout_button.dart';

import 'support/fake_source_manager.dart';

/// 浏览页布局切换（三档：单列 / 双列 / 三列）与「按板块记住」。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('lume_box_layout');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => call.method == 'getApplicationSupportDirectory'
              ? root.path
              : null,
        );
    BrowseLayoutSettings.instance.resetForTesting();
    await BrowseLayoutSettings.instance.boot();
  });

  tearDown(() async {
    BrowseLayoutSettings.instance.resetForTesting();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<void> pumpExplore(
    WidgetTester tester,
    Section section, {
    ExploreLayout layout = ExploreLayout.list,
  }) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final cacheDir = Directory.systemTemp.createTempSync('lume_box_layout_img');
    addTearDown(() {
      if (cacheDir.existsSync()) cacheDir.deleteSync(recursive: true);
    });
    final pipeline = SectionImagePipeline(cacheDir: cacheDir.path);
    addTearDown(pipeline.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: LumeTheme.build(),
        home: ExploreView(
          section: section,
          pipeline: pipeline,
          layout: layout,
          manager: FakeSourceManager(
            sources: <SourceDescriptor>[
              const SourceDescriptor(
                id: 'a',
                name: '示例源',
                version: '1.0',
                enabled: true,
              ),
            ],
            opened: <String, DataSource>{'a': MockDataSource(section: section)},
          ),
          onOpenItem: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 当前网格的列数；不是网格则返回 null。
  int? gridColumns(WidgetTester tester) {
    final grid = find.byType(GridView);
    if (grid.evaluate().isEmpty) return null;
    final delegate = tester.widget<GridView>(grid.first).gridDelegate;
    return delegate is SliverGridDelegateWithFixedCrossAxisCount
        ? delegate.crossAxisCount
        : null;
  }

  /// 网格卡片的每一层裁切都必须是统一封面圆角：去掉文字白底后，卡片和
  /// 图片只要有一层还是直角，屏幕上下两角就会露出来。
  void expectPosterCorners(WidgetTester tester) {
    final card = find.byType(PosterCard).first;
    final clips = tester.widgetList<ClipRRect>(
      find.descendant(of: card, matching: find.byType(ClipRRect)),
    );
    expect(clips, isNotEmpty, reason: '网格卡片必须显式裁封面');
    for (final clip in clips) {
      expect(clip.borderRadius, kPosterCoverRadius);
    }
  }

  test('旧布局配置映射到保留的两档，四个板块独立保存', () async {
    File('${root.path}/browse_layout.json').writeAsStringSync(
      '{"compactHomeV1":"1","novel":"list","comic":"grid2","video":"grid4","cat":"grid5"}',
    );
    await BrowseLayoutSettings.instance.boot();
    expect(
      BrowseLayoutSettings.instance.modeFor(Section.novel),
      BrowseLayoutMode.list2,
    );
    for (final section in [Section.comic, Section.video, Section.cat]) {
      expect(
        BrowseLayoutSettings.instance.modeFor(section),
        BrowseLayoutMode.grid3,
      );
    }
    await BrowseLayoutSettings.instance.setMode(
      Section.cat,
      BrowseLayoutMode.list2,
    );
    BrowseLayoutSettings.instance.resetForTesting();
    await BrowseLayoutSettings.instance.boot();
    expect(
      BrowseLayoutSettings.instance.modeFor(Section.cat),
      BrowseLayoutMode.list2,
    );
    expect(
      BrowseLayoutSettings.instance.modeFor(Section.video),
      BrowseLayoutMode.grid3,
    );
  });

  testWidgets('默认档：小说单列（无网格），漫画三列网格', (tester) async {
    await pumpExplore(tester, Section.novel, layout: ExploreLayout.list);
    expect(gridColumns(tester), 3, reason: '小说首页统一三列封面');

    await pumpExplore(tester, Section.comic, layout: ExploreLayout.grid);
    expect(gridColumns(tester), 3, reason: '漫画默认三列网格');
    expectPosterCorners(tester);
  });

  testWidgets('布局菜单保留双列列表、三列网格，当场生效', (tester) async {
    await pumpExplore(tester, Section.comic, layout: ExploreLayout.grid);
    expect(gridColumns(tester), 3);

    // 走顶栏的显示模式入口（真机反馈「每个版块的显示模式找不到了」：
    // 悬浮顶栏那一版把入口藏了，这里改成从 UI 切，入口再丢就会失败）。
    await tester.tap(find.byTooltip('布局'));
    await tester.pumpAndSettle();
    for (final label in <String>['双列列表', '三列网格']) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.text('单列列表'), findsNothing);
    expect(find.text('双列网格'), findsNothing);
    expect(find.text('四列网格'), findsNothing);
    expect(find.text('五列网格'), findsNothing);
    await tester.tap(find.text('三列网格'));
    await tester.pumpAndSettle();
    expect(gridColumns(tester), 3);

    // 列数表与比例表一一对应（少一档都会在渲染时拿到错的比例）。
    for (final mode in BrowseLayoutMode.values) {
      if (mode == BrowseLayoutMode.list) {
        expect(mode.columns, 0);
        continue;
      }
      expect(mode.columns, greaterThanOrEqualTo(2));
      expect(mode.tileAspectRatio, greaterThan(0));
    }
  });

  testWidgets('双列列表使用横排封面文字，四版块分别保存', (tester) async {
    for (final section in Section.values) {
      await pumpExplore(tester, section);
      final layoutButton = find.byType(BrowseLayoutButton);
      final icon = tester.widget<Icon>(
        find
            .descendant(
              of: layoutButton,
              matching: find.byWidgetPredicate((w) => w is Icon),
            )
            .first,
      );
      expect(icon.icon, Icons.apps_outlined);
      expect(icon.size, 20);
      await tester.tap(find.byTooltip('布局'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('双列列表'));
      await tester.pumpAndSettle();
      expect(gridColumns(tester), 2);
      expect(find.byType(CompactSourceItemTile), findsWidgets);
      final coverClips = tester.widgetList<ClipRRect>(
        find.descendant(
          of: find.byKey(const ValueKey('source-tile-cover')).first,
          matching: find.byType(ClipRRect),
        ),
      );
      expect(coverClips, isNotEmpty);
      for (final clip in coverClips) {
        expect(
          clip.borderRadius,
          kPosterCoverRadius,
          reason: '${section.label}双列列表缩略图四角圆角',
        );
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    }
    BrowseLayoutSettings.instance.resetForTesting();
    await BrowseLayoutSettings.instance.boot();
    for (final section in Section.values) {
      expect(
        BrowseLayoutSettings.instance.modeFor(section),
        BrowseLayoutMode.list2,
      );
    }
  });

  testWidgets('切换布局：选双列当场变两列，并按板块记住', (tester) async {
    await pumpExplore(tester, Section.novel, layout: ExploreLayout.list);
    expect(gridColumns(tester), 3);

    await BrowseLayoutSettings.instance.setMode(
      Section.novel,
      BrowseLayoutMode.list2,
    );
    await tester.pumpAndSettle();

    expect(gridColumns(tester), 2, reason: '选双列后应当场变成双列列表');
    expect(find.byType(TwoColumnSourceItemTile), findsWidgets);
    expect(
      BrowseLayoutSettings.instance.modeFor(Section.novel),
      BrowseLayoutMode.list2,
    );

    // 别的板块不受影响（按板块分别记住）。
    expect(BrowseLayoutSettings.instance.modeFor(Section.comic), isNull);

    // 落盘：重开 store 仍读到（模拟下次进 App）。
    BrowseLayoutSettings.instance.resetForTesting();
    await BrowseLayoutSettings.instance.boot();
    expect(
      BrowseLayoutSettings.instance.modeFor(Section.novel),
      BrowseLayoutMode.list2,
      reason: '布局选择必须本地持久化',
    );
  });
  testWidgets('网格标题风格：默认遮罩内置；切成「外置独立」后封面不画遮罩、标题在图片下方', (tester) async {
    await pumpExplore(tester, Section.comic, layout: ExploreLayout.grid);
    // 默认：遮罩内置 → 标题是白色（压在封面上）。
    expect(BrowseLayoutSettings.instance.gridTitleStyle, GridTitleStyle.below);
    Text tileTitle() => tester.widget<Text>(
      find
          .descendant(
            of: find.byType(PosterCard).first,
            matching: find.byType(Text),
          )
          .first,
    );
    expect(tileTitle().style?.color, LumeTheme.textPrimary);

    // 切成外置独立（设置页那一行走的是同一个方法）。
    await BrowseLayoutSettings.instance.setGridTitleStyle(GridTitleStyle.below);
    await tester.pumpAndSettle();

    expect(
      tileTitle().style?.color,
      LumeTheme.textPrimary,
      reason: '外置标题落在卡片浅色底上，用主题主文字色（浅色主题=黑）',
    );
    // 卡片改成「封面 + 图片下方文字」的纵向结构。
    expect(find.byType(PosterCard), findsWidgets);

    // 再切回去，值可逆且落盘。
    await BrowseLayoutSettings.instance.setGridTitleStyle(
      GridTitleStyle.overlay,
    );
    await tester.pumpAndSettle();
    expect(tileTitle().style?.color, Colors.white);
  });
}
