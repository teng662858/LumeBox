import 'dart:ui' show SemanticsAction;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/features/comic/reader_interaction_surface.dart';

void main() {
  testWidgets(
    'short taps work; a hold and a small out-and-back drag do not open chrome',
    (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: ReaderInteractionSurface(
            onTapUp: (_) => taps++,
            child: const SizedBox.expand(),
          ),
        ),
      );
      await tester.tapAt(const Offset(200, 200));
      expect(taps, 1);
      final held = await tester.startGesture(const Offset(200, 200));
      await tester.pump(const Duration(milliseconds: 400));
      await held.up();
      expect(taps, 1);
      final moved = await tester.startGesture(const Offset(200, 200));
      await moved.moveBy(const Offset(10, 0));
      await moved.moveBy(const Offset(-10, 0));
      await moved.up();
      expect(taps, 1);
    },
  );

  testWidgets(
    'long press waits for the configured delay and movement cancels it',
    (tester) async {
      var menus = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: ReaderLongPressRegion(
            duration: const Duration(milliseconds: 800),
            onLongPress: () => menus++,
            child: const SizedBox.expand(),
          ),
        ),
      );
      final held = await tester.startGesture(const Offset(200, 200));
      await tester.pump(const Duration(milliseconds: 600));
      expect(menus, 0);
      await tester.pump(const Duration(milliseconds: 250));
      expect(menus, 1);
      await held.up();
      final dragged = await tester.startGesture(const Offset(200, 200));
      await dragged.moveBy(const Offset(10, 0));
      await tester.pump(const Duration(milliseconds: 850));
      await dragged.up();
      expect(menus, 1);
    },
  );

  testWidgets('stopping a scroll cannot also open chrome, a later tap can', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: ReaderInteractionSurface(
          onTapUp: (_) => taps++,
          child: ListView(children: const [SizedBox(height: 2400)]),
        ),
      ),
    );
    await tester.drag(find.byType(ListView), const Offset(0, -200));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(200, 200));
    expect(taps, 0);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tapAt(const Offset(200, 200));
    expect(taps, 1);
  });
  testWidgets(
    'accessibility activation remains available without a pointer gesture',
    (tester) async {
      final semantics = tester.ensureSemantics();
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: ReaderInteractionSurface(
            onTapUp: (_) => taps++,
            child: const SizedBox.expand(),
          ),
        ),
      );
      final node = tester.getSemantics(find.byType(ReaderInteractionSurface));
      node.owner!.performAction(node.id, SemanticsAction.tap);
      expect(taps, 1);
      semantics.dispose();
    },
  );
}
