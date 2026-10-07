import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/core/shell/shell_settings.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/features/settings/settings_page.dart';
import 'package:lume_box/features/shell/app_shell.dart';

/// 底部导航栏开关（用户要求：设置页可切换底部 5 个 Tab 的显示/隐藏）。
///
/// ## 最要紧的一条不变式：**关得掉，也回得来**
///
/// 5 个 Tab 是 App 的顶层导航。把它整块藏掉而不给回来的路，用户会被困在当前
/// 板块里——在小说页就再也点不到设置、换不了板块。因此本组用例的核心不是
/// 「能关掉」，而是**「关掉之后一定存在恢复入口，且它真的能把导航栏召唤回来」**。
///
/// ## 作用范围
///
/// 只作用于移动端底部 Dock。桌面端用左侧 NavigationRail（桌面端标准布局），
/// 不受本开关影响——有用例钉住。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('lume_box_shell');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => call.method == 'getApplicationSupportDirectory'
          ? root.path
          : null,
    );
    ShellSettingsController.instance.resetForTesting();
    // 设置页里的「播放器内核」逃生入口会打开视频板块的库：板块作用域必须在
    // **真实时钟**里先建好（testWidgets 的测试体跑在 fake-async 时钟里，
    // 首次打开要创建目录，在测试体里 await 会等不到）。
    for (final section in Section.values) {
      await SectionScope.open(section);
    }
  });

  tearDown(() async {
    ShellSettingsController.instance.resetForTesting();
    ReadingLibrary.disposeAll();
    ReadingStore.disposeAll();
    await SectionScope.closeAll();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<void> pumpShell(
    WidgetTester tester, {
    bool desktopRail = false,
  }) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: LumeTheme.build(),
        home: AppShell(desktopRail: desktopRail),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('设置模型与落盘', () {
    test('默认显示（与历史行为一致）', () {
      expect(const ShellSettings().dockEnabled, isTrue);
      expect(ShellSettingsController.instance.dockEnabled, isTrue);
    });

    test('落盘往返', () async {
      final store = await ShellSettingsStore.open();
      store.save(const ShellSettings(dockEnabled: false));

      ShellSettingsStore.resetForTesting();
      final reopened = await ShellSettingsStore.open();
      expect(reopened.load().dockEnabled, isFalse);
    });

    test('缺项 / 损坏 / 脏值一律回退「显示」', () async {
      final store = await ShellSettingsStore.open();
      // 坏 JSON。
      File(store.path).writeAsStringSync('{ 不是 JSON');
      expect(store.load().dockEnabled, isTrue);
      // 缺字段。
      File(store.path).writeAsStringSync('{}');
      expect(store.load().dockEnabled, isTrue);
      // 脏值（非布尔）按「不是 false 就是显示」处理。
      File(store.path).writeAsStringSync('{"dockEnabled": "yes"}');
      expect(store.load().dockEnabled, isTrue);
      // 明确 false 才关。
      File(store.path).writeAsStringSync('{"dockEnabled": false}');
      expect(store.load().dockEnabled, isFalse);
    });

    test('切换会通知监听者（壳层据此重建）', () async {
      var notified = 0;
      void listener() => notified++;
      ShellSettingsController.instance.addListener(listener);
      addTearDown(() => ShellSettingsController.instance.removeListener(listener));

      await ShellSettingsController.instance.setDockEnabled(false);
      expect(notified, 1);
      expect(ShellSettingsController.instance.dockEnabled, isFalse);

      // 重复设同值不再通知（避免无谓重建）。
      await ShellSettingsController.instance.setDockEnabled(false);
      expect(notified, 1);
    });

    test('写盘失败时本次运行仍按新值生效（开关不会看起来「点了没反应」）', () async {
      // 把应用目录指到不可写的位置，逼 save 抛错。
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async => null,
      );
      ShellSettingsStore.resetForTesting();

      await ShellSettingsController.instance.setDockEnabled(false);
      expect(
        ShellSettingsController.instance.dockEnabled,
        isFalse,
        reason: '写盘失败不该让开关失效',
      );
    });
  });

  group('壳层：关得掉，也回得来', () {
    testWidgets('默认显示底部导航栏，且没有恢复按钮', (tester) async {
      await pumpShell(tester);

      expect(find.byKey(AppShell.dockKey), findsOneWidget);
      expect(
        find.byKey(AppShell.dockRestoreKey),
        findsNothing,
        reason: '导航栏在的时候不需要恢复入口',
      );
      // 五个页签都在。
      for (final label in <String>['小说', '漫画', '视频', '猫源', '设置']) {
        expect(find.text(label), findsWidgets);
      }
    });

    testWidgets('关掉导航栏：Dock 消失，但恢复入口出现（不会被困住）', (tester) async {
      await pumpShell(tester);

      ShellSettingsController.instance.applyForTesting(
        const ShellSettings(dockEnabled: false),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(AppShell.dockKey), findsNothing, reason: '导航栏应当消失');
      expect(
        find.byKey(AppShell.dockRestoreKey),
        findsOneWidget,
        reason: '关掉导航栏必须留恢复入口——否则用户被困在当前板块，'
            '再也点不到设置、换不了板块',
      );
    });

    testWidgets('点恢复入口：导航栏回来，恢复入口自己消失', (tester) async {
      await pumpShell(tester);
      ShellSettingsController.instance.applyForTesting(
        const ShellSettings(dockEnabled: false),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(AppShell.dockRestoreKey));
      await tester.pumpAndSettle();

      expect(ShellSettingsController.instance.dockEnabled, isTrue);
      expect(find.byKey(AppShell.dockKey), findsOneWidget);
      expect(find.byKey(AppShell.dockRestoreKey), findsNothing);
    });

    testWidgets('关掉后仍可切板块：恢复 → 点设置 → 进入设置页', (tester) async {
      await pumpShell(tester);
      ShellSettingsController.instance.applyForTesting(
        const ShellSettings(dockEnabled: false),
      );
      await tester.pumpAndSettle();

      // 走完整路径：恢复导航栏 → 点「设置」→ 设置页打开。
      await tester.tap(find.byKey(AppShell.dockRestoreKey));
      await tester.pumpAndSettle();
      await tester.tap(find.text('设置'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, '设置'), findsOneWidget);
    });

    testWidgets('恢复入口不与页面右下角的 FAB 重叠', (tester) async {
      // 实测教训：恢复按钮最初放右下角，与源总管理 / 漫画仓库页的「+」FAB
      // 位置相交（FAB rect 318..374 × 772..828，恢复按钮 344..366 × 798..820）。
      // 因此改放左下角；这条用例把「不许回到右下」钉住。
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: LumeTheme.build(),
          home: const AppShell(desktopRail: false),
        ),
      );
      await tester.pumpAndSettle();
      ShellSettingsController.instance.applyForTesting(
        const ShellSettings(dockEnabled: false),
      );
      await tester.pumpAndSettle();

      final restore = tester.getRect(find.byKey(AppShell.dockRestoreKey));
      // 右下角 FAB 的典型占位（56×56 + 16 边距）。
      final fabZone = Rect.fromLTWH(
        tester.view.physicalSize.width / tester.view.devicePixelRatio - 72,
        tester.view.physicalSize.height / tester.view.devicePixelRatio - 72,
        72,
        72,
      );
      expect(
        restore.overlaps(fabZone),
        isFalse,
        reason: '恢复入口不能落在右下角的 FAB 区域（那里是「+ 添加源」的地盘）',
      );
    });

    testWidgets('桌面端：左侧栏不受开关影响', (tester) async {
      await pumpShell(tester, desktopRail: true);
      expect(find.byKey(AppShell.railKey), findsOneWidget);

      ShellSettingsController.instance.applyForTesting(
        const ShellSettings(dockEnabled: false),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(AppShell.railKey),
        findsOneWidget,
        reason: '桌面端用左侧 NavigationRail，是桌面端的标准布局，不该被这个开关影响',
      );
    });
  });

  group('设置页开关', () {
    Future<void> pumpSettings(WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: LumeTheme.build(),
          home: const SettingsPage(runtimeAvailable: true),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('设置页有「显示底部导航栏」开关，默认开', (tester) async {
      await pumpSettings(tester);

      expect(find.text('显示底部导航栏'), findsOneWidget);
      final tile = tester.widget<SwitchListTile>(find.byType(SwitchListTile).first);
      expect(tile.value, isTrue);
    });

    testWidgets('拨动开关：设置真的被改掉并落盘', (tester) async {
      await pumpSettings(tester);

      await tester.tap(find.byType(SwitchListTile).first);
      await tester.pumpAndSettle();

      expect(ShellSettingsController.instance.dockEnabled, isFalse);
      final tile = tester.widget<SwitchListTile>(find.byType(SwitchListTile).first);
      expect(tile.value, isFalse);

      // 落盘：重开 store 读到的是关。
      ShellSettingsStore.resetForTesting();
      final store = await ShellSettingsStore.open();
      expect(store.load().dockEnabled, isFalse);
    });

    testWidgets('说明文案写清了「关掉后怎么回来」', (tester) async {
      await pumpSettings(tester);
      expect(
        find.textContaining('恢复按钮'),
        findsOneWidget,
        reason: '要让用户知道关掉不会把自己锁死',
      );
    });
  });
}
