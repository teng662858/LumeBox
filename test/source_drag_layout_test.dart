import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/core/source/source_order.dart';
import 'package:lume_box/features/source/source_section_page.dart';
import 'package:lume_box/core/cat/cat_service.dart';
import 'package:lume_box/core/reading/browse_layout.dart';
import 'package:lume_box/features/cat/cat_page.dart';

import 'support/fake_source_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  setUp(() async {
    root = Directory.systemTemp.createTempSync('source-whole-tile-drag-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => root.path,
        );
    for (final section in Section.values) {
      await ReadingLibrary.open(section);
    }
  });
  tearDown(() async {
    ReadingLibrary.disposeAll();
    ReadingStore.disposeAll();
    await SectionScope.closeAll();
    root.deleteSync(recursive: true);
  });
  for (final section in Section.values) {
    for (final grid in [false, true]) {
      testWidgets('${section.label} ${grid ? '旧网格偏好回退列表' : '排列'}长按名称拖动，保存位置', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        ReadingLibrary.find(section)!
            .setSetting('source.manager.grid', '$grid');
        final manager = FakeSourceManager(
          sources: const [
            SourceDescriptor(id: 'a', name: '甲源', version: '1', enabled: true),
            SourceDescriptor(id: 'b', name: '乙源', version: '1', enabled: true),
          ],
        );
        await tester.pumpWidget(
          MaterialApp(
            home: SourceSectionPage(section: section, manager: manager),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byIcon(Icons.drag_handle), findsNothing);
        expect(find.byTooltip('切换为网格'), findsNothing);
        expect(find.byType(SliverGrid), findsNothing);

        final start = tester.getCenter(find.text('甲源'));
        final target = tester.getCenter(find.text('乙源'));
        final gesture = await tester.startGesture(start);
        await tester.pump(const Duration(milliseconds: 600));
        await gesture.moveTo(target);
        await tester.pump(const Duration(milliseconds: 100));
        await gesture.up();
        await tester.pumpAndSettle();
        expect(SourceOrder.read(section), ['b', 'a']);
        expect(find.text('重命名源'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpWidget(
          MaterialApp(
            home: SourceSectionPage(section: section, manager: manager),
          ),
        );
        await tester.pumpAndSettle();
        final a = tester.getTopLeft(find.text('甲源'));
        final b = tester.getTopLeft(find.text('乙源'));
        expect(b.dy < a.dy, isTrue);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
  testWidgets('猫源实际站点管理在排列及双/三列网格均可整条拖动', (tester) async {
    await tester.runAsync(CatService.instance.boot);
    tester.view.physicalSize = const Size(320, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(home: CatPage()));
    for (var i = 0; i < 12; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pumpAndSettle();
    final layoutIcon = tester.widget<Icon>(
      find
          .descendant(
            of: find.byTooltip('布局'),
            matching: find.byWidgetPredicate((widget) => widget is Icon),
          )
          .first,
    );
    expect(layoutIcon.icon, Icons.apps_outlined);
    expect(layoutIcon.size, 20);
    await tester.tap(find.byTooltip('布局'));
    await tester.pumpAndSettle();
    expect(find.text('单列列表'), findsNothing);
    expect(find.text('双列网格'), findsNothing);
    expect(find.text('三列网格'), findsOneWidget);
    await tester.tap(find.text('双列列表'));
    await tester.pumpAndSettle();
    expect(
      BrowseLayoutSettings.instance.modeFor(Section.cat),
      BrowseLayoutMode.list2,
    );
    final service = CatService.instance;
    final record = CatSubscription(
      id: 'demo',
      name: '演示订阅',
      url: 'https://example.test/source',
      automatic: false,
      sites: const [
        CatSite(subscriptionId: 'demo', key: 'a', name: '猫甲', api: '/a'),
        CatSite(subscriptionId: 'demo', key: 'b', name: '猫乙', api: '/b'),
      ],
    );
    service.subscriptions.add(record);
    for (final columns in [1, 2, 3]) {
      ReadingLibrary.find(Section.cat)!.setSetting(SourceOrder.key, '[]');
      service.siteColumns = columns;
      await tester.tap(find.byTooltip('源管理'));
      await tester.pumpAndSettle();
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('猫甲')),
      );
      await tester.pump(const Duration(milliseconds: 600));
      await gesture.moveTo(tester.getCenter(find.text('猫乙')));
      await tester.pump(const Duration(milliseconds: 100));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(SourceOrder.read(Section.cat), [
        record.sites[1].id,
        record.sites[0].id,
      ]);
      expect(find.text('猫甲 · 源设置'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
    }
    service.subscriptions.clear();
    await tester.pumpWidget(const SizedBox());
  });
}
