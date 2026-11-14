import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/shared/widgets/browse_side_drawer.dart';
import 'package:lume_box/shared/widgets/drawer_geometry.dart';

void main() {
  for (final inset in [0.0, 24.0, 59.0, 62.0]) {
    for (final side in BrowseDrawerSide.values) {
      testWidgets(
        '${side.name} source/filter drawer follows system safe top $inset even inside SafeArea',
        (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = const Size(390, 844);
          tester.view.padding = FakeViewPadding(top: inset, bottom: 34);
          tester.view.viewPadding = FakeViewPadding(top: inset, bottom: 34);
          addTearDown(tester.view.reset);
          late BuildContext page;
          double? contentTop;
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: SafeArea(
                  child: Builder(
                    builder: (context) {
                      page = context;
                      return const DrawerSearchAnchor(
                        child: SizedBox(width: 100, height: 200),
                      );
                    },
                  ),
                ),
              ),
            ),
          );
          unawaited(
            showBrowseSideDrawer<void>(
              context: page,
              side: side,
              builder: (context) {
                contentTop = DrawerGeometry.top(context);
                return SizedBox(
                  height: DrawerGeometry.height(context),
                  child: const Text('drawer content'),
                );
              },
            ),
          );
          await tester.pumpAndSettle();
          final bounds = tester.getRect(
            find.byKey(ValueKey('browse-${side.name}-drawer')),
          );
          expect(bounds.top, inset + 4);
          expect(bounds.bottom, 844);
          expect(contentTop, inset + 4);
          expect(tester.takeException(), isNull);
          Navigator.pop(page);
          await tester.pumpAndSettle();
        },
      );
    }
  }
  testWidgets(
    'edge gesture preview and committed drawer share the same island inset',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      tester.view.padding = const FakeViewPadding(top: 59, bottom: 34);
      tester.view.viewPadding = const FakeViewPadding(top: 59, bottom: 34);
      addTearDown(tester.view.reset);
      late BuildContext page;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              page = context;
              return const Scaffold();
            },
          ),
        ),
      );
      final motion = BrowseDrawerMotion()..update(.5);
      final result = showBrowseSideDrawer<void>(
        context: page,
        side: BrowseDrawerSide.right,
        motion: motion,
        builder: (context) => SizedBox(
          height: DrawerGeometry.height(context),
          child: const Text('preview'),
        ),
      );
      await tester.pump();
      final frame = find.byKey(const ValueKey('browse-right-drawer'));
      expect(tester.getTopLeft(frame).dy, 63);
      motion.settle(true);
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(frame).dy, 63);
      Navigator.pop(page);
      await tester.pumpAndSettle();
      await result;
      motion.dispose();
    },
  );
}
