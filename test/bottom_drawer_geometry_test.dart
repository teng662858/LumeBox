import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/shared/widgets/drawer_geometry.dart';
import 'package:lume_box/shared/widgets/column_list.dart';

void main() {
  for (final screen in [
    const Size(320, 667),
    const Size(390, 844),
    const Size(844, 390),
  ]) {
    testWidgets('all modal contents align to home search at $screen', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = screen;
      addTearDown(tester.view.reset);
      late BuildContext page;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              page = context;
              return const Scaffold(
                body: Stack(
                  children: [
                    Positioned(
                      top: 72,
                      right: 16,
                      child: DrawerSearchAnchor(
                        child: SizedBox(
                          key: ValueKey('home-search'),
                          width: 42,
                          height: 42,
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      );
      final searchBottom = tester
          .getBottomLeft(find.byKey(const ValueKey('home-search')))
          .dy;
      for (final content in [
        const Text('short menu'),
        ListView.builder(
          itemCount: 100,
          itemBuilder: (_, index) => ListTile(title: Text('row $index')),
        ),
      ]) {
        unawaited(
          showLumeBottomSheet<void>(context: page, builder: (_) => content),
        );
        await tester.pumpAndSettle();
        final frame = tester.getRect(
          find.byKey(const ValueKey('lume-bottom-drawer-frame')),
        );
        expect(frame.top, searchBottom);
        expect(frame.bottom, screen.height);
        expect(tester.takeException(), isNull);
        Navigator.pop(page);
        await tester.pumpAndSettle();
      }
    });
  }
  testWidgets(
    'two-column list uses horizontal rows and retains an odd final entry',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ColumnList(
              itemCount: 5,
              itemBuilder: (_, index) => SizedBox(
                key: ValueKey(index),
                height: 64,
                child: ListTile(title: Text('item $index')),
              ),
            ),
          ),
        ),
      );
      expect(find.byType(GridView), findsOneWidget);
      expect(
        tester.getTopLeft(find.byKey(const ValueKey(0))).dy,
        tester.getTopLeft(find.byKey(const ValueKey(1))).dy,
      );
      expect(
        tester.getTopLeft(find.byKey(const ValueKey(2))).dy,
        greaterThan(tester.getTopLeft(find.byKey(const ValueKey(0))).dy),
      );
      expect(find.text('item 4'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
