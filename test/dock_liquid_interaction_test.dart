import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/shell/shell_settings.dart';
import 'package:lume_box/core/theme/floating_modules.dart';
import 'package:lume_box/features/shell/shell_dock_bar.dart';

void main() {
  const entries = [
    ShellDockEntry(
      id: 'a',
      label: 'A',
      icon: Icons.home_outlined,
      selectedIcon: Icons.home,
    ),
    ShellDockEntry(
      id: 'b',
      label: 'B',
      icon: Icons.book_outlined,
      selectedIcon: Icons.book,
    ),
    ShellDockEntry(
      id: 'c',
      label: 'C',
      icon: Icons.settings_outlined,
      selectedIcon: Icons.settings,
    ),
  ];

  Future<void> scene(
    WidgetTester tester,
    ValueChanged<String> onSelect, {
    bool reduced = false,
    DockAppearance appearance = const DockAppearance(),
  }) async {
    await tester.binding.setSurfaceSize(const Size(440, 400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(
            size: const Size(440, 400),
            disableAnimations: reduced,
          ),
          child: Scaffold(
            body: Align(
              alignment: Alignment.center,
              child: ShellDockBar(
                entries: entries,
                activeId: 'a',
                onSelect: onSelect,
                appearance: appearance,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('按住预览不切页，触摸被系统取消后水滴与胶囊均回原位', (tester) async {
    final selections = <String>[];
    await scene(tester, selections.add);
    final pill = find.byKey(ShellDockBar.selectionPillKey);
    final original = tester.getRect(pill);
    final gesture = await tester.startGesture(tester.getCenter(find.text('C')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(
      tester.getRect(pill).center.dx,
      greaterThan(original.center.dx + 100),
    );
    expect(selections, isEmpty, reason: '按下仅预览，不能提前打开其他页面');
    await gesture.cancel();
    await tester.pumpAndSettle();
    expect(selections, isEmpty, reason: '系统取消手势不能触发切页');
    expect(tester.getRect(pill).left, closeTo(original.left, .01));
    expect(tester.getRect(pill).height, closeTo(original.height, .01));
    expect(tester.takeException(), isNull);
  });

  testWidgets('减少动态效果时不膨胀，仍能点击切换一次', (tester) async {
    final selections = <String>[];
    await scene(tester, selections.add, reduced: true);
    final pill = find.byKey(ShellDockBar.selectionPillKey);
    final before = tester.getRect(pill);
    final gesture = await tester.startGesture(before.center);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.getRect(pill), before);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(selections, ['a']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('按压材质变化保留白度滑杆的全透和全白两个端点', (tester) async {
    final modules = FloatingModules.instance;
    final original = modules.style(FloatingModule.dock);
    addTearDown(() => modules.set(FloatingModule.dock, original));
    for (final opacity in [0.0, 1.0]) {
      modules.set(FloatingModule.dock, original.copyWith(opacity: opacity));
      await scene(tester, (_) {});
      Color fill() {
        final filter = tester.widget<BackdropFilter>(
          find.byKey(ShellDockBar.capsuleFilterKey),
        );
        return ((filter.child! as DecoratedBox).decoration as BoxDecoration)
            .color!;
      }

      final idleAlpha = fill().a;
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(ShellDockBar.selectionPillKey)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(fill().a, idleAlpha);
      await gesture.up();
      await tester.pumpAndSettle();
    }
  });
  test('旧外观配置自动补齐液态参数，越界和坏值恢复有效范围', () {
    final legacy = DockAppearance.fromJson({'height': 68, 'animationMs': 1010});
    expect(legacy.height, 68);
    expect(legacy.liquid, const DockLiquidSettings());
    final configured = legacy.copyWith(
      liquid: legacy.liquid
          .withValue(DockLiquidParameter.pressMs, 300)
          .withEnabled(DockLiquidEffect.clarity, false),
    );
    expect(DockAppearance.fromJson(configured.toJson()), configured);
    final broken = DockLiquidSettings.fromJson({
      'values': {'lift': 99, 'spread': double.nan},
      'disabled': ['clarity', 'unknown'],
    });
    expect(
      broken.value(DockLiquidParameter.lift),
      DockLiquidParameter.lift.max,
    );
    expect(
      broken.value(DockLiquidParameter.spread),
      DockLiquidParameter.spread.initial,
    );
    expect(broken.enabled(DockLiquidEffect.clarity), isFalse);
  });

  testWidgets('液态滑杆全部拉满仍可按住拖动，不产生非法透明度或布局错误', (tester) async {
    var liquid = const DockLiquidSettings();
    for (final p in DockLiquidParameter.values) {
      liquid = liquid.withValue(p, p.max);
    }
    await scene(
      tester,
      (_) {},
      appearance: DockAppearance(liquid: liquid, height: 40),
    );
    final gesture = await tester.startGesture(tester.getCenter(find.text('A')));
    await tester.pump(const Duration(milliseconds: 500));
    await gesture.moveBy(const Offset(110, -12));
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull);
    await gesture.up();
    await tester.pumpAndSettle();
  });
}
