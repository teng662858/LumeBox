import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/core/session/privacy_settings.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/core/source/source_preferences.dart';
import 'package:lume_box/core/source/source_picker_groups.dart';
import 'package:lume_box/core/source/source_content_visibility.dart';
import 'package:lume_box/features/reading/source_bar.dart';
import 'package:lume_box/features/reading/section_toolbar.dart';
import 'package:lume_box/features/source/source_picker_sheet.dart';
import 'package:lume_box/features/settings/content_visibility_page.dart';

import 'support/fake_source_manager.dart';

import 'package:lume_box/shared/widgets/source_card_metrics.dart';
import 'package:lume_box/shared/widgets/source_icon.dart';

/// 模拟真实长按：按住超过 LongPress 阈值再拖到目标卡片上松开。
Future<void> longPressDrag(WidgetTester tester, Finder from, Finder to) async {
  final gesture = await tester.startGesture(tester.getCenter(from));
  await tester.pump(const Duration(milliseconds: 700));
  await gesture.moveTo(tester.getCenter(to));
  await tester.pump(const Duration(milliseconds: 100));
  await gesture.up();
  await tester.pumpAndSettle();
}

void main() {
  late Directory root;
  setUp(() async {
    root = Directory.systemTemp.createTempSync('source-picker');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => root.path,
        );
    for (final section in [
      Section.video,
      Section.comic,
      Section.video,
      Section.cat,
    ]) {
      await ReadingLibrary.open(section);
    }
    await SourceContentVisibility.instance.boot(
      file: File('${root.path}/visibility.json'),
    );
  });
  tearDown(() async {
    for (final type in SourceContentVisibility.types) {
      SourceContentVisibility.instance.setVisible(type.$1, true);
    }
    ReadingLibrary.disposeAll();
    ReadingStore.disposeAll();
    await SectionScope.closeAll();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    root.deleteSync(recursive: true);
  });
  Future<void> showBar(
    WidgetTester tester,
    Section section,
    FakeSourceManager manager,
    void Function(String) selected,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ReadingSourceBar(
            section: section,
            manager: manager,
            sources: manager.sources,
            currentId: manager.sources.first.id,
            onSelect: selected,
            onManage: () {},
            showManage: false,
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('open-source-picker')));
    await tester.pumpAndSettle();
  }

  for (final columns in [false, true]) {
    testWidgets('猫源${columns ? '双列' : '单列'}定位末尾当前源', (tester) async {
      final manager = FakeSourceManager(
        sources: [
          for (var i = 0; i < 80; i++)
            SourceDescriptor(
              id: 'cat-$i',
              name: '猫站$i',
              version: '1',
              enabled: true,
            ),
        ],
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SourcePickerSheet(
              section: Section.cat,
              sources: manager.sources,
              manager: manager,
              currentId: 'cat-79',
              initialColumns: columns,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final selected = find.byKey(const ValueKey('picker-source-cat-79'));
      final list = find.byKey(const ValueKey('picker-grouped-list'));
      expect(selected, findsOneWidget);
      expect(
        tester.getTopLeft(selected).dy,
        closeTo(tester.getTopLeft(list).dy, 1),
      );
      expect(tester.takeException(), isNull);
    });
  }

  for (final section in [Section.comic, Section.video]) {
    testWidgets('${section.label} 自动定位右列末尾当前源，搜索后不重新定位', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final groups = SourcePickerGroups.forSection(section);
      final manager = FakeSourceManager(
        sources: [
          for (var i = 0; i < 40; i++)
            SourceDescriptor(
              id: 'a$i',
              name: '甲$i',
              version: '1',
              enabled: true,
              group: groups.first.$2,
            ),
          for (var i = 0; i < 40; i++)
            SourceDescriptor(
              id: 'b$i',
              name: '乙$i',
              version: '1',
              enabled: true,
              group: groups[1].$2,
            ),
        ],
      );
      final order = manager.sources.map((source) => source.id).toList();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SourcePickerSheet(
              section: section,
              manager: manager,
              sources: manager.sources,
              currentId: 'b39',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      if (section != Section.cat) {
        final list = find.byKey(const ValueKey('picker-grouped-list'));
        expect(
          find.byKey(const ValueKey('picker-category-columns')),
          findsNothing,
        );
        expect(
          tester.getTopLeft(find.byKey(const ValueKey('picker-card-b39'))).dy,
          closeTo(tester.getTopLeft(list).dy, 1),
        );
        await tester.enterText(find.byType(TextField), '甲0');
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('picker-source-a0')), findsOneWidget);
        expect(manager.selectedIds, isEmpty);
        return;
      }
      final right = find.byKey(const PageStorageKey('picker-column-1'));
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('picker-card-b39'))).dy,
        closeTo(tester.getTopLeft(right).dy, 1),
      );
      ScrollPosition position(int lane) => tester
          .state<ScrollableState>(
            find.descendant(
              of: find.byKey(PageStorageKey('picker-column-$lane')),
              matching: find.byType(Scrollable),
            ),
          )
          .position;
      expect(position(0).pixels, 0);
      expect(manager.sources.map((source) => source.id).toList(), order);
      expect(manager.selectedIds, isEmpty);
      await tester.enterText(find.byType(TextField), '甲0');
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('picker-source-a0')), findsOneWidget);
      await tester.enterText(find.byType(TextField), '');
      await tester.pumpAndSettle();
      expect(position(1).pixels, 0);
      expect(manager.selectedIds, isEmpty);
    });

    testWidgets('${section.label} 抽屉两列、独立操作菜单，浏览只选择目标源', (tester) async {
      ReadingLibrary.find(section)!
          .setSetting('source.picker.columns', 'false');
      final groups = SourcePickerGroups.forSection(section);
      await SourcePreferences(pickerGroup: groups[1].$1).save(section, 'b');
      final manager = FakeSourceManager(
        sources: const [
          SourceDescriptor(id: 'a', name: '甲源', version: '1', enabled: true),
          SourceDescriptor(
            id: 'b',
            name: '乙源',
            version: '1',
            enabled: true,
            originUrl: 'https://example.com/b.js',
          ),
          SourceDescriptor(
            id: 'disabled',
            name: '停用源',
            version: '1',
            enabled: false,
          ),
        ],
      );
      String? selected;
      await showBar(tester, section, manager, (value) => selected = value);
      expect(find.text('停用源'), findsNothing);
      expect(find.byTooltip('切换为单列'), findsNothing);
      expect(find.byTooltip('切换为双列'), findsNothing);
      expect(find.byType(Scrollbar), findsNothing);
      expect(find.byType(GridView), findsNothing);
      expect(
        find.byKey(const ValueKey('picker-category-columns')),
        findsNothing,
      );
      expect(find.byType(SourceIcon), findsNWidgets(2));
      for (final icon in tester.widgetList<SourceIcon>(
        find.byType(SourceIcon),
      )) {
        expect(icon.size, SourceCardMetrics.iconSize);
        expect(icon.radius, 8);
        expect(icon.section, section);
        expect(icon.sourceId, isNotEmpty);
      }

      final a = find.byKey(const ValueKey('picker-source-a'));
      final b = find.byKey(const ValueKey('picker-source-b'));
      expect(tester.getSize(b).height, SourceCardMetrics.height);
      expect(tester.getSize(a).height, SourceCardMetrics.height);
      final icon = tester.getSize(find.byKey(const ValueKey('picker-icon-a')));
      expect(
        (icon.width, icon.height),
        (SourceCardMetrics.iconSize, SourceCardMetrics.iconSize),
      );
      final primary = Theme.of(
        tester.element(find.byKey(const ValueKey('picker-card-a'))),
      ).primaryColor;
      final selectedCard =
          tester
                  .widget<DecoratedBox>(
                    find.byKey(const ValueKey('picker-card-a')),
                  )
                  .decoration
              as BoxDecoration;
      final unselectedCard =
          tester
                  .widget<DecoratedBox>(
                    find.byKey(const ValueKey('picker-card-b')),
                  )
                  .decoration
              as BoxDecoration;
      expect(
        (unselectedCard.border! as Border).top.color,
        SourceCardMetrics.unselectedBorder,
        reason: '未选中卡片用 1px 浅灰描边',
      );
      expect(
        (selectedCard.border! as Border).top.color,
        primary,
        reason: '选中卡片边框读取当前主题色',
      );
      final more = tester.getRect(find.byKey(const ValueKey('picker-more-a')));
      expect(tester.getRect(a).right - more.right, 4);
      final panel = tester.getRect(
        find.byKey(const ValueKey('browse-right-drawer')),
      );
      if (section != Section.cat) {
        expect(tester.getTopLeft(a).dx, tester.getTopLeft(b).dx);
        expect(tester.getTopLeft(a).dy, lessThan(tester.getTopLeft(b).dy));
        expect(tester.getSize(a).width, panel.width - 28);
      } else {
        expect(tester.getTopLeft(a).dx, lessThan(tester.getTopLeft(b).dx));
        if (section != Section.comic) {
          expect(tester.getTopLeft(a).dy, tester.getTopLeft(b).dy);
        }
        expect(tester.getRect(a).left, panel.left + 14);
        expect(tester.getRect(b).right, panel.right - 14);
        expect(tester.getRect(b).left - tester.getRect(a).right, 8);
        expect(tester.getSize(a).width, (panel.width - 36) / 2);
      }
      await tester.tap(find.byKey(const ValueKey('picker-more-b')));
      await tester.pumpAndSettle();
      for (final label in ['置顶此源', '源设置', '浏览', '测试连通性', '更新订阅源']) {
        expect(find.text(label), findsOneWidget);
      }
      await tester.tap(find.text('浏览'));
      await tester.pumpAndSettle();
      expect(selected, 'b');
      expect(manager.testedIds, isEmpty);
      expect(manager.updatedIds, isEmpty);
      expect(find.byType(SourcePickerSheet), findsNothing);
    });
  }
  testWidgets('猫源极简卡片：名称居中、长按拖拽、左滑菜单、点击选中', (tester) async {
    final manager = FakeSourceManager(
      sources: const [
        SourceDescriptor(
          id: 'c1',
          name: '猫源站点甲',
          version: '1.0.0',
          enabled: true,
        ),
        SourceDescriptor(
          id: 'c2',
          name: '猫源站点乙',
          version: '1.0.0',
          enabled: true,
        ),
      ],
    );
    String? selected;
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: FilledButton(
                onPressed: () async {
                  selected = await showSourcePicker(
                    context: context,
                    section: Section.cat,
                    sources: manager.sources,
                    currentId: 'c1',
                    manager: manager,
                  );
                },
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    final card = find.byKey(const ValueKey('picker-source-c1'));
    final second = find.byKey(const ValueKey('picker-source-c2'));
    expect(tester.getSize(card).height, 55, reason: '单列卡片统一 55 高');
    // 单列铺满侧栏内容宽度，左缘仍与搜索框同基线。
    final panel = tester.getRect(
      find.byKey(const ValueKey('browse-right-drawer')),
    );
    expect(tester.getSize(card).width, panel.width - 32);
    expect(tester.getTopLeft(card).dx, panel.left + 16);
    final decoration =
        tester
                .widget<DecoratedBox>(
                  find.descendant(
                    of: card,
                    matching: find.byKey(const ValueKey('cat-site-card')),
                  ),
                )
                .decoration
            as BoxDecoration;
    final border = decoration.border! as Border;
    expect(border.top.width, 1);
    expect(
      border.top.color,
      Theme.of(tester.element(card)).primaryColor,
      reason: '选中的猫源卡片边框读取当前主题色',
    );
    final secondDecoration =
        tester
                .widget<DecoratedBox>(
                  find.descendant(
                    of: second,
                    matching: find.byKey(const ValueKey('cat-site-card')),
                  ),
                )
                .decoration
            as BoxDecoration;
    expect(
      (secondDecoration.border! as Border).top.color,
      SourceCardMetrics.unselectedBorder,
      reason: '未选中的猫源卡片用 1px 浅灰描边',
    );
    expect(decoration.boxShadow, isNotEmpty, reason: '沿用全局卡片柔和阴影');
    final material = tester.widget<Material>(
      find.descendant(of: card, matching: find.byType(Material)).first,
    );
    expect(material.shape, isNull, reason: '没有 Material 描边');
    expect(find.byType(SourceIcon), findsNothing);
    expect(find.byKey(const ValueKey('picker-more-c1')), findsNothing);
    expect(find.byKey(const ValueKey('picker-drag-c1')), findsOneWidget);
    expect(find.text('猫源站点甲'), findsOneWidget);
    expect(find.text('1.0.0'), findsNothing);
    expect(find.text('点击选择源，长按拖动排序，左滑打开设置/删除'), findsOneWidget);
    // 单列：名称水平、垂直都居中。
    expect(
      tester.getCenter(find.text('猫源站点甲')).dx,
      closeTo(tester.getCenter(card).dx, 1),
    );
    expect(
      tester.getCenter(find.text('猫源站点甲')).dy,
      closeTo(tester.getCenter(card).dy, 1),
    );

    // 单列左滑：露出设置 / 删除，删除走确认框。
    final closedX = tester.getTopLeft(card).dx;
    await tester.drag(card, const Offset(-90, 0));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(card).dx, lessThan(closedX));
    expect(find.text('设置').hitTestable(), findsOneWidget);
    expect(find.text('删除').hitTestable(), findsOneWidget);
    await tester.tap(find.text('删除').hitTestable());
    await tester.pumpAndSettle();
    expect(find.text('删除源'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    // 单列长按拖拽：把 c1 拖到 c2 之后。
    await longPressDrag(tester, card, second);
    expect(tester.getTopLeft(second).dy, lessThan(tester.getTopLeft(card).dy));

    // 切到双列：两列各 (390 - 32 - 8) / 2 = 175，高度同样 55；
    // 名称仍然居中。
    await tester.tap(find.byTooltip('切换为双列'));
    await tester.pumpAndSettle();
    expect(tester.getSize(card).width, (panel.width - 40) / 2);
    expect(tester.getSize(second).width, (panel.width - 40) / 2);
    expect(tester.getSize(card).height, 55);
    expect(tester.getSize(second).height, 55);
    // 单列拖动后 c2 在前，双列里应落在左侧。
    expect(tester.getTopLeft(second).dx, lessThan(tester.getTopLeft(card).dx));
    expect(tester.getTopLeft(second).dy, tester.getTopLeft(card).dy);
    expect(
      tester.getCenter(find.text('猫源站点乙')).dx,
      closeTo(tester.getCenter(second).dx, 1),
    );
    expect(
      tester.getCenter(find.text('猫源站点乙')).dy,
      closeTo(tester.getCenter(second).dy, 1),
    );

    // 双列左滑同样可用。
    final closedDoubleX = tester.getTopLeft(card).dx;
    await tester.drag(card, const Offset(-80, 0));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(card).dx, lessThan(closedDoubleX));
    expect(find.text('设置').hitTestable(), findsOneWidget);
    // 收起的起点必须落在卡片露出的前缘（滑开后中间已被操作区占据）。
    final slot = tester.getTopLeft(
      find.byKey(const ValueKey('picker-drag-c1')),
    );
    await tester.dragFrom(slot + const Offset(24, 32), const Offset(140, 0));
    await tester.pumpAndSettle();

    // 双列里同样支持长按拖动：把右侧的 c1 拖回左侧。
    await longPressDrag(tester, card, second);
    expect(tester.getTopLeft(card).dx, lessThan(tester.getTopLeft(second).dx));

    await tester.tap(card);
    await tester.pumpAndSettle();
    expect(selected, 'c1');
  });
  testWidgets('视频/漫画/视频：长按拖动排序仍然生效', (tester) async {
    final manager = FakeSourceManager(
      sources: const [
        SourceDescriptor(
          id: 'v1',
          name: '视频源甲',
          version: '1.0.0',
          enabled: true,
        ),
        SourceDescriptor(
          id: 'v2',
          name: '视频源乙',
          version: '1.0.0',
          enabled: true,
        ),
      ],
    );
    await showBar(tester, Section.video, manager, (_) {});
    final first = find.byKey(const ValueKey('picker-source-v1'));
    final second = find.byKey(const ValueKey('picker-source-v2'));
    expect(
      tester.getTopLeft(second).dy,
      greaterThan(tester.getTopLeft(first).dy),
    );
    await longPressDrag(tester, first, second);
    expect(tester.getTopLeft(second).dy, lessThan(tester.getTopLeft(first).dy));
  });
  testWidgets('固定 55 高：18 角标不撑高，窄屏两列不溢出', (tester) async {
    await SourcePreferences(pinned: true).save(Section.video, 'plain');
    await tester.runAsync(() => PrivacySettings.instance.setShowAdult(true));
    final manager = FakeSourceManager(
      sources: const [
        SourceDescriptor(
          id: 'plain',
          name: '普通源',
          version: '1.0.0',
          enabled: true,
        ),
        SourceDescriptor(
          id: 'adult',
          name: '成人内容示例源',
          version: '1.0.0',
          enabled: true,
        ),
      ],
    );
    tester.view.physicalSize = const Size(320, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: FilledButton(
                onPressed: () => showSourcePicker(
                  context: context,
                  section: Section.video,
                  sources: manager.sources,
                  currentId: 'adult',
                  manager: manager,
                ),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(find.byType(SourcePickerSheet), findsOneWidget);
    // Opening now locates the active second source. Return to the first row
    // before checking the dimensions of both cards and the pinned indicator.
    tester
        .state<ScrollableState>(
          find
              .descendant(
                of: find.byKey(const ValueKey('picker-grouped-list')),
                matching: find.byType(Scrollable),
              )
              .first,
        )
        .position
        .jumpTo(0);
    await tester.pumpAndSettle();
    for (final id in ['plain', 'adult']) {
      expect(
        tester.getSize(find.byKey(ValueKey('picker-source-$id'))).height,
        55,
      );
    }
    expect(find.text('18+'), findsOneWidget);
    expect(find.byIcon(Icons.push_pin), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.runAsync(() => PrivacySettings.instance.setShowAdult(false));
  });
  testWidgets('长按源可设置分类并保存；固定双栏与搜索可用', (tester) async {
    final manager = FakeSourceManager(
      sources: const [
        SourceDescriptor(
          id: 'a',
          name: '甲源',
          version: '1',
          enabled: true,
          runtimeKind: 'module',
        ),
        SourceDescriptor(
          id: 'b',
          name: '乙源',
          version: '1',
          enabled: true,
          runtimeKind: 'module',
        ),
      ],
    );
    await showBar(tester, Section.video, manager, (_) {});
    await tester.tap(find.byKey(const ValueKey('picker-more-b')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('源设置'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.widgetWithText(ChoiceChip, '影视'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(find.widgetWithText(ChoiceChip, '影视'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, '影视'));
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.tap(find.widgetWithText(TextButton, '保存'));
    await tester.pumpAndSettle();
    expect(SourcePreferences.read(Section.video, 'b').pickerGroup, 'movie');
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('picker-source-b'))).dx,
      tester.getBottomLeft(find.byKey(const ValueKey('picker-source-a'))).dx,
    );
    expect(find.byTooltip('切换为单列'), findsNothing);
    expect(find.byTooltip('切换为双列'), findsNothing);
    await tester.enterText(find.byType(TextField), '乙');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('picker-source-a')), findsNothing);
    expect(find.byKey(const ValueKey('picker-source-b')), findsOneWidget);
  });
  testWidgets('分类左右独立：组内纵向排列，搜索保留分类位置', (tester) async {
    final manager = FakeSourceManager(
      sources: const [
        SourceDescriptor(
          id: 'v1',
          name: '视频甲',
          version: '1',
          enabled: true,
          group: '视频',
        ),
        SourceDescriptor(
          id: 'm1',
          name: '影视甲',
          version: '1',
          enabled: true,
          group: '影视',
        ),
        SourceDescriptor(
          id: 'v2',
          name: '视频乙',
          version: '1',
          enabled: true,
          group: '视频',
        ),
      ],
    );
    await showBar(tester, Section.video, manager, (_) {});
    final first = find.byKey(const ValueKey('picker-source-v1'));
    final second = find.byKey(const ValueKey('picker-source-v2'));
    final movie = find.byKey(const ValueKey('picker-source-m1'));
    expect(tester.getTopLeft(first).dx, tester.getTopLeft(second).dx);
    expect(
      tester.getTopLeft(second).dy,
      greaterThan(tester.getBottomLeft(first).dy),
    );
    expect(tester.getTopLeft(movie).dx, tester.getTopLeft(first).dx);
    expect(
      tester.getTopLeft(movie).dy,
      greaterThan(tester.getTopLeft(second).dy),
    );
    await tester.enterText(find.byType(TextField), '影视甲');
    await tester.pumpAndSettle();
    expect(
      SourcePickerGroups.groupFor(Section.video, manager.sources.first),
      'video',
    );
    expect(find.text('暂无匹配的源'), findsNothing);
    expect(
      SourcePickerGroups.groupFor(Section.video, manager.sources[1]),
      'movie',
    );
    expect(find.byType(SourceIcon), findsOneWidget);
  });
  testWidgets('隐藏仅影响抽屉，聚合搜索保留全部站点', (tester) async {
    final manager = FakeSourceManager(
      sources: const [
        SourceDescriptor(
          id: 'comic-a',
          name: '漫画源',
          version: '1',
          enabled: true,
        ),
        SourceDescriptor(
          id: 'z8pt_comic',
          name: '美图源',
          version: '1',
          enabled: true,
        ),
      ],
    );
    SourceContentVisibility.instance.setVisible('photo', false);
    await showBar(tester, Section.comic, manager, (_) {});
    expect(
      find.byKey(const ValueKey('picker-source-z8pt_comic')),
      findsNothing,
    );
    final requests = <String>[];
    await AggregateSearch.run(
      sources: manager.sources,
      keyword: '测试',
      open: (id) async {
        requests.add(id);
        return null;
      },
    );
    expect(requests, ['comic-a', 'z8pt_comic']);
    SourceContentVisibility.instance.setVisible('photo', true);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('picker-source-z8pt_comic')),
      findsOneWidget,
    );
    expect(manager.removed, isEmpty);
    expect(manager.toggled, isEmpty);
  });
  testWidgets('关闭抽屉不重复刷新首页；源设置保存后只刷新一次', (tester) async {
    final manager = FakeSourceManager(
      sources: const [
        SourceDescriptor(
          id: 'a',
          name: '甲源',
          version: '1',
          enabled: true,
          runtimeKind: 'module',
        ),
      ],
    );
    var refreshes = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ReadingSourceBar(
            section: Section.video,
            manager: manager,
            sources: manager.sources,
            currentId: 'a',
            onSelect: (_) {},
            onManage: () {},
            onSourcesChanged: () async {
              refreshes++;
            },
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('open-source-picker')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expect(refreshes, 0);
    await tester.tap(find.byKey(const ValueKey('open-source-picker')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('picker-more-a')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('源设置'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.widgetWithText(ChoiceChip, '影视'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(find.widgetWithText(ChoiceChip, '影视'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, '影视'));
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.tap(find.widgetWithText(TextButton, '保存'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expect(refreshes, 1);
  });
  testWidgets('设置按板块提供各分类独立显示开关', (tester) async {
    final controller = SourceContentVisibility();
    await tester.pumpWidget(
      MaterialApp(home: ContentVisibilityPage(controller: controller)),
    );
    for (final type in SourceContentVisibility.types) {
      await tester.scrollUntilVisible(
        find.byKey(ValueKey('content-visible-${type.$1}')),
        180,
      );
      expect(
        find.byKey(ValueKey('content-visible-${type.$1}')),
        findsOneWidget,
      );
    }
    await tester.ensureVisible(
      find.byKey(const ValueKey('content-visible-video')),
    );
    await tester.tap(find.byKey(const ValueKey('content-visible-video')));
    await tester.pumpAndSettle();
    expect(controller.isVisible('video'), false);
    expect(controller.isVisible('movie'), true);
    controller.dispose();
  });
  test('归类遵从内容目录、人工设置优先；六类显示落库恢复', () async {
    const audio = SourceDescriptor(
      id: 'new-audio',
      name: '有声站',
      version: '1',
      enabled: true,
      originUrl: 'https://example.com/main/movie/有声站.js',
    );
    expect(SourcePickerGroups.groupFor(Section.video, audio), 'movie');
    expect(
      SourcePickerGroups.groupFor(
        Section.comic,
        const SourceDescriptor(
          id: 'z8pt_comic',
          name: '改名图库',
          version: '1',
          enabled: true,
          originUrl: 'https://example.com/main/comic/Z8PT图库.js',
        ),
      ),
      'photo',
    );
    expect(
      SourcePickerGroups.groupFor(
        Section.video,
        const SourceDescriptor(
          id: 'gztv5_video',
          name: '改名影视',
          version: '1',
          enabled: true,
          originUrl: 'https://example.com/main/video/瓜子影视.js',
        ),
      ),
      'movie',
    );

    await const SourcePreferences(pickerGroup: 'video')
        .save(Section.video, audio.id);
    expect(SourcePickerGroups.groupFor(Section.video, audio), 'video');
    final file = File('${root.path}/separate.json');
    final first = SourceContentVisibility();
    await first.boot(file: file);
    for (final type in SourceContentVisibility.types) {
      first.setVisible(type.$1, false);
    }
    final second = SourceContentVisibility();
    await second.boot(file: file);
    expect(second.sectionVisible(Section.video), false);
    expect(second.sectionVisible(Section.comic), false);
    expect(second.sectionVisible(Section.video), false);
    expect(second.sectionVisible(Section.cat), true);
    second.setVisible('movie', true);
    expect(second.sectionVisible(Section.video), true);
    expect(second.isVisible('video'), false);
    first.dispose();
    second.dispose();
  });
}
