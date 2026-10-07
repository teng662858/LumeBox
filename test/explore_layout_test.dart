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

  testWidgets('默认档：小说单列（无网格），漫画三列网格', (tester) async {
    await pumpExplore(tester, Section.novel, layout: ExploreLayout.list);
    expect(gridColumns(tester), isNull, reason: '小说默认单列列表');

    await pumpExplore(tester, Section.comic, layout: ExploreLayout.grid);
    expect(gridColumns(tester), 3, reason: '漫画默认三列网格');
  });

  testWidgets('切换布局：选双列当场变两列，并按板块记住', (tester) async {
    await pumpExplore(tester, Section.novel, layout: ExploreLayout.list);
    expect(gridColumns(tester), isNull);

    // 打开布局菜单（右上角入口）。
    await tester.tap(find.byTooltip('布局'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('双列网格'));
    await tester.pumpAndSettle();

    expect(gridColumns(tester), 2, reason: '选双列后应当场变成两列网格');
    expect(
      BrowseLayoutSettings.instance.modeFor(Section.novel),
      BrowseLayoutMode.grid2,
    );

    // 别的板块不受影响（按板块分别记住）。
    expect(BrowseLayoutSettings.instance.modeFor(Section.comic), isNull);

    // 落盘：重开 store 仍读到（模拟下次进 App）。
    BrowseLayoutSettings.instance.resetForTesting();
    await BrowseLayoutSettings.instance.boot();
    expect(
      BrowseLayoutSettings.instance.modeFor(Section.novel),
      BrowseLayoutMode.grid2,
      reason: '布局选择必须本地持久化',
    );
  });
}
