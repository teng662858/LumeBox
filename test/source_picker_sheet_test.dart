import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/core/source/source_preferences.dart';
import 'package:lume_box/core/source/source_picker_groups.dart';
import 'package:lume_box/core/source/source_content_visibility.dart';
import 'package:lume_box/features/reading/source_bar.dart';
import 'package:lume_box/features/reading/section_toolbar.dart';
import 'package:lume_box/features/source/source_picker_sheet.dart';
import 'package:lume_box/features/settings/content_visibility_page.dart';

import 'support/fake_source_manager.dart';

void main() {
  late Directory root;
  setUp(() async {
    root = Directory.systemTemp.createTempSync('source-picker');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => root.path,
        );
    for (final section in [Section.novel, Section.comic, Section.video]) {
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

  for (final section in [Section.novel, Section.comic, Section.video]) {
    testWidgets('${section.label} 抽屉两列、独立操作菜单，浏览只选择目标源', (tester) async {
      final groups = SourcePickerGroups.forSection(section);
      await SourcePreferences(pickerGroup: groups.last.$1).save(section, 'b');
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
      expect(find.text(groups.first.$2), findsOneWidget);
      expect(find.text(groups.last.$2), findsOneWidget);
      expect(find.text('停用源'), findsNothing);
      final grid = tester.widget<GridView>(find.byType(GridView));
      final delegate =
          grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
      expect(delegate.crossAxisCount, 2);
      expect(delegate.crossAxisSpacing, 10);
      expect(delegate.mainAxisSpacing, 10);
      expect(grid.padding, const EdgeInsets.symmetric(horizontal: 16));
      expect(find.byType(CircleAvatar), findsNWidgets(2));

      final a = find.byKey(const ValueKey('picker-source-a'));
      final b = find.byKey(const ValueKey('picker-source-b'));
      expect(tester.getTopLeft(a).dx, lessThan(tester.getTopLeft(b).dx));
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
  testWidgets('长按源可设置分类并保存；单列与搜索可用', (tester) async {
    final manager = FakeSourceManager(
      sources: const [
        SourceDescriptor(id: 'a', name: '甲源', version: '1', enabled: true),
        SourceDescriptor(id: 'b', name: '乙源', version: '1', enabled: true),
      ],
    );
    await showBar(tester, Section.novel, manager, (_) {});
    await tester.tap(find.byKey(const ValueKey('picker-more-b')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('源设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, '有声小说'));
    await tester.tap(find.widgetWithText(TextButton, '保存'));
    await tester.pumpAndSettle();
    expect(SourcePreferences.read(Section.novel, 'b').pickerGroup, 'audiobook');
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('picker-source-b'))).dx,
      greaterThan(
        tester.getTopLeft(find.byKey(const ValueKey('picker-source-a'))).dx,
      ),
    );
    await tester.tap(find.byTooltip('切换为单列'));
    await tester.pumpAndSettle();
    expect(find.byType(GridView), findsNothing);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Divider &&
            widget.color == const Color(0xFFE5E5EA) &&
            widget.height == 1,
      ),
      findsOneWidget,
    );

    expect(
      tester.getTopLeft(find.byKey(const ValueKey('picker-source-b'))).dx,
      tester.getTopLeft(find.byKey(const ValueKey('picker-source-a'))).dx,
    );
    await tester.enterText(find.byType(TextField), '乙');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('picker-source-a')), findsNothing);
    expect(find.byKey(const ValueKey('picker-source-b')), findsOneWidget);
    expect(
      ReadingLibrary.find(Section.novel)!.setting('source.picker.columns'),
      'false',
    );
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
        SourceDescriptor(id: 'a', name: '甲源', version: '1', enabled: true),
      ],
    );
    var refreshes = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ReadingSourceBar(
            section: Section.novel,
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
    await tester.tap(find.widgetWithText(ChoiceChip, '有声小说'));
    await tester.tap(find.widgetWithText(TextButton, '保存'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expect(refreshes, 1);
  });
  testWidgets('设置提供六个独立显示开关', (tester) async {
    final controller = SourceContentVisibility();
    await tester.pumpWidget(
      MaterialApp(home: ContentVisibilityPage(controller: controller)),
    );
    expect(find.byType(SwitchListTile), findsNWidgets(6));
    await tester.tap(find.byKey(const ValueKey('content-visible-novel')));
    await tester.pumpAndSettle();
    expect(controller.isVisible('novel'), false);
    expect(controller.isVisible('audiobook'), true);
    controller.dispose();
  });
  test('归类遵从内容目录、人工设置优先；六类显示落库恢复', () async {
    const audio = SourceDescriptor(
      id: 'new-audio',
      name: '有声站',
      version: '1',
      enabled: true,
      originUrl: 'https://example.com/main/audiobook/有声站.js',
    );
    expect(SourcePickerGroups.groupFor(Section.novel, audio), 'audiobook');
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

    await const SourcePreferences(pickerGroup: 'novel')
        .save(Section.novel, audio.id);
    expect(SourcePickerGroups.groupFor(Section.novel, audio), 'novel');
    final file = File('${root.path}/separate.json');
    final first = SourceContentVisibility();
    await first.boot(file: file);
    for (final type in SourceContentVisibility.types) {
      first.setVisible(type.$1, false);
    }
    final second = SourceContentVisibility();
    await second.boot(file: file);
    expect(second.sectionVisible(Section.novel), false);
    expect(second.sectionVisible(Section.comic), false);
    expect(second.sectionVisible(Section.video), false);
    expect(second.sectionVisible(Section.cat), true);
    second.setVisible('audiobook', true);
    expect(second.sectionVisible(Section.novel), true);
    expect(second.isVisible('novel'), false);
    first.dispose();
    second.dispose();
  });
}
