import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/features/source/video_source_scope.dart';

void main() {
  testWidgets('right-edge left swipe opens the source picker', (tester) async {
    var opens = 0;
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: SourcePickerEdgeSwipe(
          onOpen: () async {
            opens++;
          },
          child: const Scaffold(body: SizedBox.expand()),
        ),
      ),
    );

    await tester.dragFrom(const Offset(389, 300), const Offset(-100, 0));
    expect(opens, 1);
  });

  testWidgets('other directions and non-edge drags do not open the picker', (
    tester,
  ) async {
    var opens = 0;
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: SourcePickerEdgeSwipe(
          onOpen: () async {
            opens++;
          },
          child: const Scaffold(body: SizedBox.expand()),
        ),
      ),
    );

    await tester.dragFrom(const Offset(389, 300), const Offset(100, 0));
    await tester.dragFrom(const Offset(200, 300), const Offset(-100, 0));
    await tester.dragFrom(const Offset(389, 300), const Offset(-10, 100));
    await tester.dragFrom(const Offset(389, 300), const Offset(-40, 0));
    final cancelled = await tester.startGesture(const Offset(389, 300));
    await cancelled.moveBy(const Offset(-100, 0));
    await cancelled.cancel();
    expect(opens, 0);
  });

  testWidgets('edge taps and vertical scrolling still reach the page', (
    tester,
  ) async {
    var taps = 0;
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: SourcePickerEdgeSwipe(
          onOpen: () async =>
              fail('Vertical scrolling must not open the picker'),
          child: Scaffold(
            body: ListView(
              controller: scroll,
              children: [
                SizedBox(
                  height: 100,
                  child: TextButton(
                    onPressed: () => taps++,
                    child: const Text('item'),
                  ),
                ),
                const SizedBox(height: 1600),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.tapAt(const Offset(380, 50));
    expect(taps, 1);
    await tester.dragFrom(const Offset(380, 600), const Offset(0, -200));
    await tester.pumpAndSettle();
    expect(scroll.offset, greaterThan(0));
  });

  testWidgets('middle horizontal swipes still reach child controls', (
    tester,
  ) async {
    var drags = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: SourcePickerEdgeSwipe(
          onOpen: () async => fail('Middle swipe must not open the picker'),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragUpdate: (_) => drags++,
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );
    await tester.dragFrom(const Offset(200, 300), const Offset(-100, 0));
    expect(drags, greaterThan(0));
  });

  testWidgets('one picker stays open until dismissed, then can open again', (
    tester,
  ) async {
    var opens = 0;
    var dismissed = Completer<void>();
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: SourcePickerEdgeSwipe(
          onOpen: () async {
            opens++;
            await dismissed.future;
          },
          child: const Scaffold(body: SizedBox.expand()),
        ),
      ),
    );
    await tester.dragFrom(const Offset(389, 300), const Offset(-100, 0));
    await tester.dragFrom(const Offset(389, 300), const Offset(-100, 0));
    expect(opens, 1);
    dismissed.complete();
    await tester.pump();
    dismissed = Completer<void>();
    await tester.dragFrom(const Offset(389, 300), const Offset(-100, 0));
    expect(opens, 2);
    dismissed.complete();
    await tester.pump();
  });
}
