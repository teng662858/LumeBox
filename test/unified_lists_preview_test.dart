import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/reading/browse_layout.dart';

import '../tool/lists_preview.dart';

void main() {
  for (final dark in [false, true]) {
    testWidgets('all five real list previews at 320px, dark=$dark', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 844);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(const ListsPreview());
      if (dark) {
        await tester.tap(find.byTooltip('切换亮暗模式'));
        await tester.pumpAndSettle();
      }
      for (final name in ['源选择', '猫源', '猫源内容', '历史', '收藏']) {
        await tester.tap(find.widgetWithText(FilledButton, name));
        await tester.pumpAndSettle();
        final collection = name == '历史' || name == '收藏';
        if (collection) {
          await tester.tap(find.byTooltip('显示模式'));
          await tester.pumpAndSettle();
          await tester.tap(
            find.widgetWithText(CheckedPopupMenuItem<BrowseLayoutMode>, '双列列表'),
          );
          await tester.pumpAndSettle();
        }
        if (name == '源选择') {
          expect(find.byType(GridView), findsNothing);
          expect(
            find.byKey(const ValueKey('picker-category-columns')),
            findsOneWidget,
          );
        } else {
          final grid = tester.widget<GridView>(find.byType(GridView));
          final delegate =
              grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
          expect(delegate.crossAxisCount, 2);
          expect(delegate.mainAxisSpacing, 10);
          expect(delegate.crossAxisSpacing, 10);
        }
        expect(tester.takeException(), isNull, reason: name);
        if (collection) {
          await tester.tap(find.byTooltip('显示模式'));
          await tester.pumpAndSettle();
          await tester.tap(
            find.widgetWithText(CheckedPopupMenuItem<BrowseLayoutMode>, '单列列表'),
          );
        } else if (name == '源选择') {
          expect(find.byTooltip('切换为单列'), findsNothing);
          Navigator.of(
            tester.element(
              find.byKey(const ValueKey('lume-bottom-drawer-frame')),
            ),
          ).pop();
          await tester.pumpAndSettle();
          continue;
        } else {
          await tester.tap(find.text('单列列表'));
        }
        await tester.pumpAndSettle();
        expect(find.byType(GridView), findsNothing);
        expect(
          find.byWidgetPredicate(
            (widget) =>
                widget is Divider &&
                widget.color == const Color(0xFFE5E5EA) &&
                widget.height == 1,
          ),
          findsWidgets,
        );
        expect(tester.takeException(), isNull, reason: name);
        Navigator.of(
          tester.element(
            find.byKey(const ValueKey('lume-bottom-drawer-frame')),
          ),
        ).pop();
        await tester.pumpAndSettle();
      }
    });
  }
}
