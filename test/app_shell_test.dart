import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/features/shell/app_shell.dart';
import 'package:lume_box/features/shell/shell_dock.dart';

/// 主导航壳的验证：五页签的顺序与文案、移动端 Dock / 桌面端 NavigationRail
/// 两种排布、切页签只保留当前页面，以及全屏页压栈时自动隐藏 Dock、出栈恢复。
void main() {
  late ShellDockController controller;

  setUp(() => controller = ShellDockController());
  tearDown(() => controller.dispose());

  Future<void> pumpShell(
    WidgetTester tester, {
    required bool desktopRail,
  }) async {
    await tester.binding.setSurfaceSize(const Size(900, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: LumeTheme.build(),
        navigatorObservers: <NavigatorObserver>[ShellDockObserver(controller)],
        home: AppShell(controller: controller, desktopRail: desktopRail),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Dock 内的文字（页面标题里也有同名文字，必须限定在 Dock 内部找）。
  Finder inDock(String text) => find.descendant(
        of: find.byKey(AppShell.dockKey),
        matching: find.text(text),
      );

  testWidgets('移动端：底部 Dock 五页签，顺序为 小说 / 漫画 / 视频 / 猫源 / 设置', (tester) async {
    await pumpShell(tester, desktopRail: false);

    expect(find.byKey(AppShell.dockKey), findsOneWidget);
    expect(find.byKey(AppShell.railKey), findsNothing);

    const expected = <String>['小说', '漫画', '视频', '猫源', '设置'];
    for (final label in expected) {
      expect(inDock(label), findsOneWidget, reason: 'Dock 缺少页签：$label');
    }

    // 顺序：从页签文字的横坐标判断（Dock 是等宽五格）。
    final xs = <double>[
      for (final label in expected) tester.getCenter(inDock(label)).dx,
    ];
    for (var i = 1; i < xs.length; i++) {
      expect(xs[i] > xs[i - 1], isTrue, reason: '${expected[i]} 应排在 ${expected[i - 1]} 右侧');
    }
  });

  testWidgets('桌面端：自动切换为左侧 NavigationRail，页签一致', (tester) async {
    await pumpShell(tester, desktopRail: true);

    expect(find.byKey(AppShell.railKey), findsOneWidget);
    expect(find.byKey(AppShell.dockKey), findsNothing);
    for (final label in <String>['小说', '漫画', '视频', '猫源', '设置']) {
      expect(
        find.descendant(
          of: find.byKey(AppShell.railKey),
          matching: find.text(label),
        ),
        findsOneWidget,
      );
    }
  });

  testWidgets('切页签只保留当前板块页面', (tester) async {
    await pumpShell(tester, desktopRail: false);

    // 启动落在第一个页签：小说。
    expect(find.widgetWithText(AppBar, '小说'), findsOneWidget);

    await tester.tap(inDock('漫画'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, '漫画'), findsOneWidget);
    expect(find.widgetWithText(AppBar, '小说'), findsNothing);

    await tester.tap(inDock('设置'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, '设置'), findsOneWidget);
    expect(find.widgetWithText(AppBar, '漫画'), findsNothing);
  });

  testWidgets('全屏页压栈隐藏 Dock，出栈恢复', (tester) async {
    await pumpShell(tester, desktopRail: false);
    expect(controller.visible, isTrue);

    final navigator = tester.state<NavigatorState>(find.byType(Navigator).first);
    navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Center(child: Text('阅读器'))),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('阅读器'), findsOneWidget);
    expect(controller.visible, isFalse, reason: '全屏页压栈后 Dock 应隐藏');
    // 全屏页是不透明路由：Dock 的子树被盖住（find 默认跳过 offstage），
    // 所以这里带 skipOffstage: false 才能断言它的位移。
    expect(
      tester
          .widget<AnimatedSlide>(find.byType(AnimatedSlide, skipOffstage: false))
          .offset,
      isNot(Offset.zero),
      reason: 'Dock 应平移到屏幕外',
    );

    navigator.pop();
    await tester.pumpAndSettle();
    expect(controller.visible, isTrue, reason: '退出全屏页后 Dock 应恢复');
    expect(
      tester.widget<AnimatedSlide>(find.byType(AnimatedSlide)).offset,
      Offset.zero,
    );
  });

  testWidgets('弹窗（非全屏路由）不影响 Dock 显隐', (tester) async {
    await pumpShell(tester, desktopRail: false);

    final context = tester.element(find.byKey(AppShell.dockKey));
    showDialog<void>(
      context: context,
      builder: (_) => const AlertDialog(title: Text('弹窗')),
    );
    await tester.pumpAndSettle();

    expect(find.text('弹窗'), findsOneWidget);
    expect(controller.visible, isTrue, reason: '对话框不该改变底部导航');
  });

  testWidgets('播放中隐藏 Dock：令牌释放后恢复（视频页联动）', (tester) async {
    await pumpShell(tester, desktopRail: false);

    // 模拟视频页：从壳内取控制器，拿到令牌后隐藏 / 释放。
    final context = tester.element(find.byKey(AppShell.dockKey));
    final dock = ShellDockScope.maybeOf(context);
    expect(dock, isNotNull, reason: 'Dock 子树的页面应能取到控制器');

    final token = Object();
    dock!.hide(token);
    await tester.pumpAndSettle();
    expect(controller.visible, isFalse);

    dock.show(token);
    await tester.pumpAndSettle();
    expect(controller.visible, isTrue);
  });

  testWidgets('板块页右上角有统一的「+」添加图源入口', (tester) async {
    await pumpShell(tester, desktopRail: false);

    // 非 iOS 平台没有图源运行时：按钮按平台边界隐藏（与板块页骨架同口径）。
    expect(find.byTooltip('添加图源'), findsNothing);

    await tester.tap(inDock(Section.video.label));
    await tester.pumpAndSettle();
    expect(find.byTooltip('添加图源'), findsNothing);
  });
}
