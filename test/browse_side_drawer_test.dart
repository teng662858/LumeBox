import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/features/source/video_source_scope.dart';
import 'package:lume_box/features/shell/shell_dock.dart';
import 'package:lume_box/shared/widgets/browse_side_drawer.dart';

void main() {
  Future<void> mount(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            Future<void> open(
              BrowseDrawerSide side, [
              BrowseDrawerMotion? motion,
            ]) async {
              await showBrowseSideDrawer<void>(
                context: context,
                side: side,
                motion: motion,
                edgeToggle: true,
                builder: (context) => Column(
                  children: [
                    Text(side == BrowseDrawerSide.left ? '左侧测试内容' : '右侧测试内容'),
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('选择并关闭'),
                    ),
                  ],
                ),
              );
            }

            return SourcePickerEdgeSwipe(
              onOpen: () => open(BrowseDrawerSide.right),
              onOpenLeft: (motion) => open(BrowseDrawerSide.left, motion),
              onOpenRight: (motion) => open(BrowseDrawerSide.right, motion),
              child: Scaffold(
                body: Center(
                  child: TextButton(
                    onPressed: () => open(BrowseDrawerSide.right),
                    child: const Text('切换源'),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  testWidgets('抽屉期间隐藏底栏，关闭后仅释放自己的隐藏请求', (tester) async {
    final dock = ShellDockController();
    await tester.pumpWidget(
      MaterialApp(
        home: ShellDockScope(
          controller: dock,
          child: Builder(
            builder: (context) => TextButton(
              onPressed: () => showBrowseSideDrawer<void>(
                context: context,
                side: BrowseDrawerSide.right,
                builder: (context) => TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('关闭'),
                ),
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(dock.visible, isFalse);
    final otherOwner = Object();
    dock.hide(otherOwner);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(dock.visible, isFalse);
    dock.show(otherOwner);
    expect(dock.visible, isTrue);
  });
  testWidgets('双侧面板拖动中就跟手，松手后展开', (tester) async {
    await mount(tester);
    final pointer = await tester.startGesture(const Offset(1, 300));
    await pointer.moveBy(const Offset(110, 0));
    await tester.pump();
    final left = find.byKey(const ValueKey('browse-left-drawer'));
    expect(left, findsOneWidget);
    expect(tester.getTopLeft(left).dx, lessThan(0));
    expect(tester.getTopLeft(left).dx, greaterThan(-300));
    await pointer.moveBy(const Offset(150, 0));
    await pointer.up();
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(left).dx, closeTo(0, 1));
    expect(tester.getSize(left).width, 390);
    expect(tester.getBottomRight(left).dx, closeTo(390, 1));
    await tester.tap(find.text('选择并关闭'));
    await tester.pumpAndSettle();
    await tester.dragFrom(const Offset(389, 300), const Offset(-260, 0));
    await tester.pumpAndSettle();
    expect(find.text('右侧测试内容'), findsOneWidget);
    expect(find.text('左侧测试内容'), findsNothing);
  });

  testWidgets('短拖回弹，取消手势不打开，点击和返回均可关闭', (tester) async {
    await mount(tester);
    await tester.dragFrom(const Offset(1, 300), const Offset(50, 0));
    await tester.pumpAndSettle();
    expect(find.text('左侧测试内容'), findsNothing);
    final pointer = await tester.startGesture(const Offset(389, 300));
    await pointer.moveBy(const Offset(-110, 0));
    await tester.pump();
    await pointer.cancel();
    await tester.pumpAndSettle();
    expect(find.text('右侧测试内容'), findsNothing);
    await tester.tap(find.text('切换源'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(8, 50));
    await tester.pumpAndSettle();
    expect(find.text('右侧测试内容'), findsNothing);
    await tester.tap(find.text('切换源'));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('右侧测试内容'), findsNothing);
  });

  for (final left in [true, false]) {
    testWidgets('${left ? '左' : '右'}边缘慢划 80 点即可展开，无需划过半屏', (tester) async {
      await mount(tester);
      final pointer = await tester.startGesture(Offset(left ? 1 : 389, 300));
      await pointer.moveBy(Offset(left ? 80 : -80, 0));
      await tester.pump(const Duration(milliseconds: 400));
      await pointer.up();
      await tester.pumpAndSettle();
      final drawer = find.byKey(
        ValueKey(left ? 'browse-left-drawer' : 'browse-right-drawer'),
      );
      expect(drawer, findsOneWidget);
      expect(tester.getTopLeft(drawer).dx, closeTo(0, 1));
      await tester.tap(find.text('选择并关闭'));
      await tester.pumpAndSettle();
    });
  }

  testWidgets('反向收回可拖回取消，快速反向甩动关闭', (tester) async {
    await mount(tester);
    await tester.tap(find.text('切换源'));
    await tester.pumpAndSettle();
    final pointer = await tester.startGesture(const Offset(90, 400));
    await pointer.moveBy(const Offset(120, 0));
    await tester.pump();
    await pointer.moveBy(const Offset(-110, 0));
    await tester.pump(const Duration(milliseconds: 100));
    await pointer.up();
    await tester.pumpAndSettle();
    expect(find.text('右侧测试内容'), findsOneWidget);
    await tester.flingFrom(const Offset(80, 400), const Offset(120, 0), 1000);
    await tester.pumpAndSettle();
    expect(find.text('右侧测试内容'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('单次大位移事件也计入收回距离，不丢掉首个拖动事件', (tester) async {
    await mount(tester);
    await tester.tap(find.text('切换源'));
    await tester.pumpAndSettle();
    final pointer = await tester.startGesture(const Offset(65, 500));
    await pointer.moveBy(const Offset(270, 0));
    await pointer.up();
    await tester.pumpAndSettle();
    expect(find.text('右侧测试内容'), findsNothing);
  });

  for (final openLeft in [true, false]) {
    for (final closeLeft in [true, false]) {
      testWidgets(
        '从${openLeft ? '左' : '右'}侧打开后，再划${closeLeft ? '左' : '右'}边缘收回',
        (tester) async {
          await mount(tester);
          await tester.dragFrom(
            Offset(openLeft ? 1 : 389, 400),
            Offset(openLeft ? 270 : -270, 0),
          );
          await tester.pumpAndSettle();
          expect(find.text(openLeft ? '左侧测试内容' : '右侧测试内容'), findsOneWidget);
          await tester.dragFrom(
            Offset(closeLeft ? 1 : 389, 400),
            Offset(closeLeft ? 120 : -120, 0),
          );
          await tester.pumpAndSettle();
          expect(find.text('左侧测试内容'), findsNothing);
          expect(find.text('右侧测试内容'), findsNothing);
        },
      );
    }
  }
}
