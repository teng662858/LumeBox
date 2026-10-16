import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/features/reading/browse_choice_access.dart';

void main() {
  for (final brightness in Brightness.values) {
    testWidgets(
      '$brightness: all filter labels override inherited white text',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(
              useMaterial3: true,
              brightness: brightness,
              chipTheme: const ChipThemeData(
                labelStyle: TextStyle(color: Colors.white),
              ),
            ),
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  child: const Text('打开'),
                  onPressed: () => showBrowseFilters(
                    context: context,
                    categories: const [SourceCategory(id: 'a', title: '电影')],
                    groups: [
                      for (final name in ['类型', '地区', '年份'])
                        SourceFilterGroup(
                          id: name,
                          title: name,
                          options: [
                            SourceFilterOption(id: name, title: '$name选项'),
                          ],
                        ),
                    ],
                    category: null,
                    filters: const {},
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('打开'));
        await tester.pumpAndSettle();
        for (final label in ['电影', '类型选项', '地区选项', '年份选项']) {
          final finder = find.widgetWithText(ChoiceChip, label);
          await tester.ensureVisible(finder);
          final idle = tester.widget<ChoiceChip>(finder);
          expect(idle.labelStyle!.color, const Color(0xFF333333));
          expect((idle.label as Text).style!.color, const Color(0xFF333333));
          expect(idle.backgroundColor, const Color(0xFFF2F2F7));
          await tester.tap(finder);
          await tester.pumpAndSettle();
          final selected = tester.widget<ChoiceChip>(finder);
          expect(selected.selected, isTrue);
          expect(selected.labelStyle!.color, Colors.white);
          expect(selected.selectedColor, const Color(0xFF6C5CE7));
          expect(selected.checkmarkColor, Colors.white);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets('筛选操作栏固定并保留34px安全区及上下16px留白', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(bottom: 34);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPadding);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showBrowseFilters(
                context: context,
                categories: [
                  for (var i = 0; i < 60; i++)
                    SourceCategory(id: '$i', title: '分类$i'),
                ],
                groups: const [],
                category: null,
                filters: const {},
              ),
              child: const Text('筛选'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('筛选'));
    await tester.pumpAndSettle();
    final apply = tester.getRect(find.widgetWithText(FilledButton, '应用筛选'));
    final reset = tester.getRect(find.widgetWithText(TextButton, '重置'));
    expect(apply.bottom, 844 - 34 - 16);
    final footer = tester.getRect(find.byKey(const Key('filter-footer')));
    expect(footer.height, 80);
    expect(apply.height, 48);
    expect(apply.top - footer.top, 16);
    await tester.drag(
      find.byKey(const Key('filter-options')),
      const Offset(0, -240),
    );
    await tester.pumpAndSettle();
    expect(tester.getRect(find.widgetWithText(FilledButton, '应用筛选')), apply);
    expect(reset.center.dy, apply.center.dy);
    await tester.tap(find.widgetWithText(FilledButton, '应用筛选'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
  testWidgets('长分类固定入口、搜索末尾选项与全部重置，不需横向拖动', (tester) async {
    tester.view.physicalSize = const Size(375, 812);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    String? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, set) => Align(
              alignment: Alignment.topCenter,
              child: BrowseChoiceAccess(
                choices: [
                  for (var i = 0; i < 100; i++)
                    SourceCategory(id: '$i', title: '分类$i'),
                ],
                selectedId: selected,
                onSelected: (id) => set(() => selected = id),
                child: SizedBox(
                  height: 34,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    children: [
                      for (var i = 0; i < 100; i++)
                        SizedBox(width: 80, child: Text('快捷$i')),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('展开全部分类'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '分类99');
    await tester.pump();
    expect(find.widgetWithText(TextButton, '分类99'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, '分类99'));
    await tester.pumpAndSettle();
    expect(selected, '99');
    expect(find.text('分类99'), findsNothing);
    expect(find.byIcon(Icons.tune), findsOneWidget);
    await tester.tap(find.byTooltip('展开全部分类'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('全部'));
    await tester.pumpAndSettle();
    expect(selected, isNull);
    expect(tester.takeException(), isNull);
  });
}
