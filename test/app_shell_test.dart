import 'dart:async';

import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:lume_box/features/comic/comic_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/shell/shell_settings.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/features/shell/app_shell.dart';
import 'package:lume_box/features/shell/shell_dock.dart';
import 'package:lume_box/features/shell/shell_dock_bar.dart';
import 'package:lume_box/features/reading/compact_browse_header.dart';
import 'package:lume_box/shared/widgets/dock_handle_button.dart';
import 'package:lume_box/shared/widgets/glass_card.dart';

/// 主导航壳的验证：三页签的顺序与文案、移动端 Dock / 桌面端 NavigationRail
/// 两种排布、切页签保留页面状态，以及全屏页压栈时自动隐藏 Dock、出栈恢复。
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

  testWidgets('移动端：底部 Dock 四项，顺序为 漫画 / 视频 / 音乐 / 设置', (tester) async {
    await pumpShell(tester, desktopRail: false);

    expect(find.byKey(AppShell.dockKey), findsOneWidget);
    expect(find.byKey(AppShell.railKey), findsNothing);

    const expected = <String>['漫画', '视频', '音乐', '设置'];
    for (final label in expected) {
      expect(inDock(label), findsOneWidget, reason: 'Dock 缺少页签：$label');
    }

    // 顺序：从页签文字的横坐标判断（Dock 是等宽五格）。
    final xs = <double>[
      for (final label in expected) tester.getCenter(inDock(label)).dx,
    ];
    for (var i = 1; i < xs.length; i++) {
      expect(
        xs[i] > xs[i - 1],
        isTrue,
        reason: '${expected[i]} 应排在 ${expected[i - 1]} 右侧',
      );
    }
  });

  testWidgets('各板块底部右侧打开同一个全局搜索，返回后保留原页面', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: AppShell(
          controller: controller,
          desktopRail: false,
          pageBuilder: (id) =>
              GlassScaffold(title: id, child: Text('content-$id')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final comic = tester.element(find.text('content-comic'));
    expect(inDock('搜索'), findsNothing);
    for (final label in ['漫画', '视频', '音乐', '设置']) {
      await tester.tap(inDock(label));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('global-search-button')));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, '全局搜索'), findsOneWidget);
      expect(find.widgetWithText(ChoiceChip, '全部'), findsOneWidget);
      tester.state<NavigatorState>(find.byType(Navigator).first).pop();
      await tester.pumpAndSettle();
    }
    await tester.tap(inDock('漫画'));
    await tester.pumpAndSettle();
    expect(tester.element(find.text('content-comic')), same(comic));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('只把搜索交给当前可见的视频面，等待加载时可暂存一次搜索', (tester) async {
    var cat = false;
    final searches = <String>[];
    Widget scene() => MaterialApp(
      home: ShellDockScope(
        controller: controller,
        integratedSearch: true,
        child: Stack(
          fit: StackFit.expand,
          children: [
            TickerMode(
              enabled: !cat,
              child: BrowseSearchButton(
                onPressed: () => searches.add('ordinary'),
              ),
            ),
            TickerMode(
              enabled: cat,
              child: BrowseSearchButton(onPressed: () => searches.add('cat')),
            ),
          ],
        ),
      ),
    );
    controller.requestSearch();
    await tester.pumpWidget(scene());
    await tester.pumpAndSettle();
    expect(searches, ['ordinary']);
    cat = true;
    await tester.pumpWidget(scene());
    await tester.pumpAndSettle();
    controller.requestSearch();
    expect(searches, ['ordinary', 'cat']);
    cat = false;
    await tester.pumpWidget(scene());
    await tester.pumpAndSettle();
    controller.requestSearch();
    expect(searches, ['ordinary', 'cat', 'ordinary']);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('向上浏览收成左侧入口，向下浏览恢复四项导航', (tester) async {
    await pumpShell(tester, desktopRail: false);
    final pageContext = tester.element(find.byType(ComicPage));
    final metrics = FixedScrollMetrics(
      minScrollExtent: 0,
      maxScrollExtent: 1000,
      pixels: 200,
      viewportDimension: 600,
      axisDirection: AxisDirection.down,
      devicePixelRatio: 1,
    );
    UserScrollNotification(
      metrics: metrics,
      context: pageContext,
      direction: ScrollDirection.reverse,
    ).dispatch(pageContext);
    await tester.pumpAndSettle();
    expect(find.byTooltip('展开导航'), findsOneWidget);
    expect(inDock('漫画'), findsNothing);
    UserScrollNotification(
      metrics: metrics,
      context: pageContext,
      direction: ScrollDirection.forward,
    ).dispatch(pageContext);
    await tester.pumpAndSettle();
    expect(find.byTooltip('展开导航'), findsNothing);
    expect(inDock('漫画'), findsOneWidget);
  });

  testWidgets('旧图标偏好不覆盖当前板块入口，向右滑可展开 Dock', (tester) async {
    ShellSettingsController.instance.apply(
      const ShellSettings(handleStyle: DockHandleStyle.arrow),
    );
    addTearDown(ShellSettingsController.instance.resetForTesting);
    await pumpShell(tester, desktopRail: false);
    final pageContext = tester.element(find.byType(ComicPage));
    final metrics = FixedScrollMetrics(
      minScrollExtent: 0,
      maxScrollExtent: 1000,
      pixels: 200,
      viewportDimension: 600,
      axisDirection: AxisDirection.down,
      devicePixelRatio: 1,
    );
    UserScrollNotification(
      metrics: metrics,
      context: pageContext,
      direction: ScrollDirection.reverse,
    ).dispatch(pageContext);
    await tester.pumpAndSettle();

    final handle = find.byType(DockHandleButton);
    expect(handle, findsOneWidget);
    expect(
      tester.widget<DockHandleButton>(handle).style,
      DockHandleStyle.currentSection,
    );

    // 向右滑：展开 Dock，而不是点一下突然闪现。
    await tester.drag(handle, const Offset(64, 0));
    await tester.pumpAndSettle();
    expect(find.byTooltip('展开导航'), findsNothing);
    expect(inDock('漫画'), findsOneWidget);
  });

  testWidgets('收起入口按当前漫画、视频、设置切换图标，配置可还原', (tester) async {
    const settings = ShellSettings(handleStyle: DockHandleStyle.currentSection);
    ShellSettingsController.instance.apply(
      ShellSettings.fromJson(settings.toJson()),
    );
    addTearDown(ShellSettingsController.instance.resetForTesting);
    await pumpShell(tester, desktopRail: false);
    for (final entry in [
      ('comic', Icons.auto_stories_rounded),
      ('video', Icons.play_circle_fill_rounded),
      ('settings', Icons.settings_rounded),
    ]) {
      if (entry.$1 != 'comic') {
        await tester.tap(inDock(ShellTab.byId(entry.$1)!.label));
        await tester.pumpAndSettle();
      }
      final pageContext = tester.element(
        find.byKey(ValueKey<String>('shell-content-${entry.$1}')),
      );
      final capsule = tester.getRect(
        find.byKey(ShellDockBar.capsuleSurfaceKey),
      );
      UserScrollNotification(
        metrics: FixedScrollMetrics(
          minScrollExtent: 0,
          maxScrollExtent: 1000,
          pixels: 200,
          viewportDimension: 600,
          axisDirection: AxisDirection.down,
          devicePixelRatio: 1,
        ),
        context: pageContext,
        direction: ScrollDirection.reverse,
      ).dispatch(pageContext);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      final during = tester.getRect(find.byType(DockHandleButton));
      await tester.pumpAndSettle();
      final settled = tester.getRect(find.byType(DockHandleButton));
      expect(settled.width, closeTo(capsule.height, .01));
      expect(settled.height, closeTo(capsule.height, .01));
      expect(during.bottom, closeTo(settled.bottom, .01));
      expect(settled.bottom, closeTo(capsule.bottom, .01));
      final handle = tester.widget<DockHandleButton>(
        find.byType(DockHandleButton),
      );
      expect(handle.style, DockHandleStyle.currentSection);
      expect(handle.sectionId, entry.$1);
      expect(handle.sectionIcon, entry.$2);
      await tester.tap(find.byTooltip('展开导航'));
      await tester.pumpAndSettle();
    }
  });

  testWidgets('桌面端：自动切换为左侧 NavigationRail，页签一致', (tester) async {
    await pumpShell(tester, desktopRail: true);

    expect(find.byKey(AppShell.railKey), findsOneWidget);
    expect(find.byKey(AppShell.dockKey), findsNothing);
    for (final label in <String>['漫画', '视频', '音乐', '设置']) {
      expect(
        find.descendant(
          of: find.byKey(AppShell.railKey),
          matching: find.text(label),
        ),
        findsOneWidget,
      );
    }
  });

  testWidgets('切页签仅显示当前板块页面', (tester) async {
    await pumpShell(tester, desktopRail: false);

    // 启动落在第一个页签：漫画。
    expect(find.widgetWithText(AppBar, '漫画'), findsOneWidget);

    await tester.tap(inDock('漫画'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, '漫画'), findsOneWidget);

    await tester.tap(inDock('设置'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, '设置'), findsOneWidget);
  });

  testWidgets('切换页签保留已打开的页面及其进行中的加载', (tester) async {
    final pending = Completer<String>();
    await tester.pumpWidget(
      MaterialApp(
        home: AppShell(
          controller: controller,
          desktopRail: false,
          pageBuilder: (id) => id == 'comic'
              ? FutureBuilder<String>(
                  future: pending.future,
                  builder: (_, snapshot) => Text(snapshot.data ?? '漫画正在加载'),
                )
              : Text('page-$id'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final original = tester.element(find.text('漫画正在加载'));
    await tester.tap(inDock('设置'));
    await tester.pumpAndSettle();
    expect(find.text('漫画正在加载'), findsNothing);
    expect(find.text('漫画正在加载', skipOffstage: false), findsOneWidget);
    pending.complete('漫画内容');
    await tester.pump();
    await tester.tap(inDock('漫画'));
    await tester.pumpAndSettle();
    expect(find.text('漫画内容'), findsOneWidget);
    expect(tester.element(find.text('漫画内容')), same(original));
  });

  testWidgets('全屏页压栈隐藏 Dock，出栈恢复', (tester) async {
    await pumpShell(tester, desktopRail: false);
    expect(controller.visible, isTrue);

    final navigator = tester.state<NavigatorState>(
      find.byType(Navigator).first,
    );
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
          .widget<AnimatedSlide>(
            find.byType(AnimatedSlide, skipOffstage: false),
          )
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

  testWidgets('底栏收起后进入设置二级页，返回首页展开完整 TAB 栏', (tester) async {
    await pumpShell(tester, desktopRail: false);
    final pageContext = tester.element(find.byType(ComicPage));
    UserScrollNotification(
      metrics: FixedScrollMetrics(
        minScrollExtent: 0,
        maxScrollExtent: 1000,
        pixels: 200,
        viewportDimension: 600,
        axisDirection: AxisDirection.down,
        devicePixelRatio: 1,
      ),
      context: pageContext,
      direction: ScrollDirection.reverse,
    ).dispatch(pageContext);
    await tester.pumpAndSettle();
    expect(find.byType(DockHandleButton), findsOneWidget);
    final navigator = tester.state<NavigatorState>(
      find.byType(Navigator).first,
    );
    navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('二级设置')),
      ),
    );
    await tester.pumpAndSettle();
    navigator.pop();
    await tester.pumpAndSettle();
    expect(controller.visible, isTrue);
    expect(find.byType(DockHandleButton), findsNothing);
    expect(inDock('漫画'), findsOneWidget);
    expect(inDock('设置'), findsOneWidget);
    expect(tester.takeException(), isNull);
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
    expect(find.byTooltip('添加源'), findsNothing);

    await tester.tap(inDock(Section.video.label));
    await tester.pumpAndSettle();
    expect(find.byTooltip('添加源'), findsNothing);
  });
}
