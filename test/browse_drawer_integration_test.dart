import 'package:lume_box/features/reading/source_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/reading/browse_layout.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/features/reading/explore_view.dart';
import 'package:lume_box/features/shell/section_preloader.dart';

import 'support/fake_source_manager.dart';

void main() {
  setUp(() {
    BrowseLayoutSettings.instance.resetForTesting();
    SectionPreloader.discard(Section.comic);
    SectionPreloader.discard(Section.video);
  });
  tearDown(() {
    BrowseLayoutSettings.instance.resetForTesting();
    SectionPreloader.discard(Section.comic);
    SectionPreloader.discard(Section.video);
  });

  Future<void> mount(
    WidgetTester tester,
    FakeSourceManager manager, {
    Section section = Section.comic,
  }) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ExploreView(
            section: section,
            manager: manager,
            onOpenItem: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  FakeSourceManager manager(_Source a, _Source b) => FakeSourceManager(
    sources: [
      SourceDescriptor(id: a.id, name: a.name, version: '1', enabled: true),
      SourceDescriptor(id: b.id, name: b.name, version: '1', enabled: true),
    ],
    opened: {a.id: a, b.id: b},
  );

  Future<void> pick(WidgetTester tester, String id) async {
    // Selection must preserve the current scroll offset even when the toolbar
    // is collapsed. Drawer gestures and cards are covered independently above.
    tester.widget<ReadingSourceBar>(find.byType(ReadingSourceBar)).onSelect(id);
    await tester.pumpAndSettle();
  }

  for (final section in [Section.comic, Section.video]) {
    testWidgets('${section.label}：左右边缘都开源选择，再划相同边缘收回，筛选仍用按钮', (tester) async {
      final a = _Source('a', section: section),
          b = _Source('b', section: section);
      await mount(tester, manager(a, b), section: section);
      expect(a.homeCalls, 1);
      expect(a.listCalls, 0, reason: '首页源不并发请求分类列表');
      await tester.dragFrom(const Offset(200, 400), const Offset(-100, 0));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('browse-right-drawer')), findsNothing);
      await tester.dragFrom(const Offset(389, 400), const Offset(-270, 0));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('browse-right-drawer')), findsOneWidget);
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
      expect(a.homeCalls, 1);
      await tester.dragFrom(const Offset(1, 400), const Offset(270, 0));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('browse-left-drawer')), findsOneWidget);
      expect(find.text('选择${section.label}源'), findsOneWidget);
      expect(find.text('分类与筛选'), findsNothing);
      await tester.dragFrom(const Offset(1, 400), const Offset(120, 0));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('browse-left-drawer')), findsNothing);
      expect(a.homeCalls, 1);
      await tester.tap(find.byTooltip('展开全部分类'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, '分类甲'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('browse-left-drawer')), findsNothing);
      expect(a.lastCategory, 'category-a');
    });
  }

  testWidgets('切源回来保留分类、已加载结果和滚动位置，配置变化不复用旧结果', (tester) async {
    final a = _Source('a'), b = _Source('b');
    final sources = manager(a, b);
    await mount(tester, sources);
    await tester.tap(find.byTooltip('展开全部分类'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, '分类甲'));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(GridView).last, const Offset(0, -700));
    await tester.pumpAndSettle();
    final grid = find.byType(GridView).last;
    final scrollable = find
        .descendant(of: grid, matching: find.byType(Scrollable))
        .first;
    final before = tester.state<ScrollableState>(scrollable).position.pixels;
    expect(before, greaterThan(300));
    final calls = a.listCalls;
    await pick(tester, 'b');
    await pick(tester, 'a');
    expect(a.listCalls, calls);
    expect(a.lastCategory, 'category-a');
    final restored = find
        .descendant(
          of: find.byType(GridView).last,
          matching: find.byType(Scrollable),
        )
        .first;
    expect(
      tester.state<ScrollableState>(restored).position.pixels,
      closeTo(before, 1),
    );
    await pick(tester, 'b');
    final replacement = _Source('a');
    sources.opened['a'] = replacement;
    await pick(tester, 'a');
    expect(replacement.homeCalls, 1);
    expect(replacement.lastCategory, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('视频宿主通知切源时也恢复原首页，不误当成源配置更新', (tester) async {
    final a = _Source('a', section: Section.video);
    final b = _Source('b', section: Section.video);
    final sources = manager(a, b);
    var revision = 0;
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return Scaffold(
              body: ExploreView(
                section: Section.video,
                manager: sources,
                selectionRevision: revision,
                onOpenItem: (_) {},
              ),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(a.homeCalls, 1);
    await sources.select('b');
    update(() => revision++);
    await tester.pumpAndSettle();
    expect(b.homeCalls, 1);
    await sources.select('a');
    update(() => revision++);
    await tester.pumpAndSettle();
    expect(a.homeCalls, 1);
    expect(tester.takeException(), isNull);
  });
}

class _Source extends MockDataSource implements HomeCapable {
  _Source(this.id, {super.section = Section.comic});
  @override
  final String id;
  @override
  String get name => '源$id';
  int homeCalls = 0, listCalls = 0;
  String? lastCategory;
  List<SourceItem> get rows =>
      List.generate(100, (i) => SourceItem(id: '$id-$i', title: '$id 测试条目 $i'));
  @override
  Future<bool> supportsHome() async => true;
  @override
  Future<SourceHome> home() async {
    homeCalls++;
    return SourceHome(items: rows);
  }

  @override
  Future<List<SourceCategory>> categories() async => const [
    SourceCategory(id: 'category-a', title: '分类甲'),
  ];
  @override
  Future<SourceList> list({
    String? categoryId,
    String? keyword,
    int page = 1,
    Map<String, String>? filters,
  }) async {
    listCalls++;
    lastCategory = categoryId;
    return SourceList(items: rows, hasMore: false);
  }
}
