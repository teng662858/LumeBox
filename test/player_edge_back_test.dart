import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/features/video/player_edge_back.dart';

void main() {
  Future<void> showPlayer(WidgetTester tester, {bool enabled = true}) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            return TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => Scaffold(
                    body: PlayerEdgeBack(
                      enabled: enabled,
                      child: const Center(child: Text('player')),
                    ),
                  ),
                ),
              ),
              child: const Text('open'),
            );
          },
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('both portrait edges return', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final left in [true, false]) {
      await showPlayer(tester);
      await tester.dragFrom(
        Offset(left ? 10 : 390, 400),
        Offset(left ? 150 : -150, 0),
      );
      await tester.pumpAndSettle();
      expect(find.text('player'), findsNothing);
    }
  });

  testWidgets(
    'center, wrong direction, short swipe and disabled stay on page',
    (tester) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await showPlayer(tester);
      for (final pair in [
        (const Offset(200, 400), const Offset(150, 0)),
        (const Offset(10, 400), const Offset(-150, 0)),
        (const Offset(10, 400), const Offset(40, 0)),
      ]) {
        await tester.dragFrom(pair.$1, pair.$2);
        await tester.pumpAndSettle();
        expect(find.text('player'), findsOneWidget);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await showPlayer(tester, enabled: false);
      await tester.dragFrom(const Offset(10, 400), const Offset(150, 0));
      await tester.pumpAndSettle();
      expect(find.text('player'), findsOneWidget);
    },
  );

  testWidgets('landscape does not return', (tester) async {
    tester.view.physicalSize = const Size(800, 400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await showPlayer(tester);
    await tester.dragFrom(const Offset(10, 200), const Offset(150, 0));
    await tester.pumpAndSettle();
    expect(find.text('player'), findsOneWidget);
  });
}
