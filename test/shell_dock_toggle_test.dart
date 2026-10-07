import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/core/shell/shell_settings.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/features/settings/settings_page.dart';
import 'package:lume_box/features/settings/tab_bar_settings_page.dart';
import 'package:lume_box/features/shell/app_shell.dart';
import 'package:lume_box/features/shell/shell_dock.dart';

/// 底部导航栏管理：**每个页签独立开关 + 拖拽排序**。
///
/// ## 三条最要紧的性质
///
/// 1. **至少保留 1 个页签**——全部关掉导航栏就空了，用户再也点不到任何入口。
///    模型层拒绝（返回 null 且配置一字未改），界面层把最后一颗开关置灰并说明原因。
/// 2. **隐藏「设置」不会把自己锁死**——设置页是进入本管理页的唯一入口。
///    把它藏起来之后壳层必须留一个设置入口，否则用户再也改不回导航栏
///    （「至少保留 1 个」拦不住这种锁死：另外 4 个板块还在，但没有一个能进设置）。
/// 3. **改动实时生效**——壳层监听配置，开关/拖拽后底部立刻变，不需要重启。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('lume_box_tabbar');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => call.method == 'getApplicationSupportDirectory'
          ? root.path
          : null,
    );
    ShellSettingsController.instance.resetForTesting();
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

  // ==========================================================================
  // 模型：开关、排序、最少保留
  // ==========================================================================

  group('模型 · 逐项开关', () {
    test('默认全部显示、顺序为规范顺序', () {
      const settings = ShellSettings();
      expect(settings.visibleCount, 5);
      expect(
        settings.tabs.map((tab) => tab.id).toList(),
        <String>['novel', 'comic', 'video', 'cat', 'settings'],
      );
    });

    test('隐藏一个页签：只影响它自己', () {
      const settings = ShellSettings();
      final next = settings.withVisible('comic', false)!;
      expect(next.isVisible('comic'), isFalse);
      expect(next.isVisible('novel'), isTrue);
      expect(next.isVisible('settings'), isTrue);
      expect(next.visibleCount, 4);
      // 顺序不变（隐藏不等于移除）。
      expect(
        next.tabs.map((tab) => tab.id).toList(),
        <String>['novel', 'comic', 'video', 'cat', 'settings'],
      );
    });

    test('重新显示：回到原来的位置（顺序没被破坏）', () {
      const settings = ShellSettings();
      final hidden = settings.withVisible('video', false)!;
      final shown = hidden.withVisible('video', true)!;
      expect(shown, settings, reason: '关掉再打开应当回到完全一致的配置');
    });
  });

  group('模型 · 至少保留 1 个页签（硬约束）', () {
    test('关到只剩 1 个：允许', () {
      var settings = const ShellSettings();
      for (final id in <String>['comic', 'video', 'cat']) {
        settings = settings.withVisible(id, false)!;
      }
      expect(settings.visibleCount, 2); // novel + settings
      settings = settings.withVisible('settings', false)!;
      expect(settings.visibleCount, 1);
      expect(settings.isVisible('novel'), isTrue);
    });

    test('关最后一个：被拒绝，且配置一字未改', () {
      var settings = const ShellSettings();
      for (final id in <String>['comic', 'video', 'cat', 'settings']) {
        settings = settings.withVisible(id, false)!;
      }
      expect(settings.visibleCount, 1);

      final rejected = settings.withVisible('novel', false);
      expect(rejected, isNull, reason: '最后一个可见页签不能被关掉');
      expect(settings.visibleCount, 1);
      expect(settings.isVisible('novel'), isTrue);
    });

    test('canHide 只在「最后一个可见项」时为 false', () {
      var settings = const ShellSettings();
      expect(settings.canHide('novel'), isTrue, reason: '还有 5 个，随便关');

      for (final id in <String>['comic', 'video', 'cat']) {
        settings = settings.withVisible(id, false)!;
      }
      expect(settings.canHide('settings'), isTrue, reason: '还有 2 个');

      settings = settings.withVisible('settings', false)!;
      expect(settings.canHide('novel'), isFalse, reason: '只剩它自己了');
      expect(settings.canHide('comic'), isTrue, reason: '已隐藏的项，再关是幂等的');
    });

    test('拒绝时的提示文案可读', () {
      expect(ShellSettings.lastTabMessage, contains('至少'));
      expect(ShellSettings.lastTabMessage, contains('1 个'));
    });
  });

  group('模型 · 拖拽排序', () {
    test('把小说往后挪一位（最终下标语义）', () {
      const settings = ShellSettings();
      final moved = settings.withMove(0, 1);
      expect(
        moved.tabs.map((tab) => tab.id).toList(),
        <String>['comic', 'novel', 'video', 'cat', 'settings'],
      );
    });

    test('把小说挪到最后', () {
      const settings = ShellSettings();
      final moved = settings.withMove(0, 4);
      expect(
        moved.tabs.map((tab) => tab.id).toList(),
        <String>['comic', 'video', 'cat', 'settings', 'novel'],
      );
    });

    test('向上拖：把猫源挪到第 1 位', () {
      const settings = ShellSettings();
      final moved = settings.withMove(3, 1);
      expect(
        moved.tabs.map((tab) => tab.id).toList(),
        <String>['novel', 'cat', 'comic', 'video', 'settings'],
      );
    });

    test('拖到原位 / 越界：不改动或夹到边界', () {
      const settings = ShellSettings();
      expect(settings.withMove(2, 2), settings, reason: '拖到原位应无变化');

      final clamped = settings.withMove(0, 99);
      expect(clamped.visibleCount, 5);
      expect(clamped.tabs.last.id, 'novel', reason: '越界夹到最后一位');

      final negative = settings.withMove(4, -5);
      expect(negative.tabs.first.id, 'settings', reason: '越界夹到第一位');

      expect(settings.withMove(99, 0), settings, reason: '来源越界应无变化');
    });

    test('排序不影响可见性', () {
      final settings = const ShellSettings().withVisible('comic', false)!;
      final moved = settings.withMove(0, 3);
      expect(moved.isVisible('comic'), isFalse, reason: '排序不该把隐藏的项显出来');
      expect(moved.visibleCount, 4);
    });

    test('隐藏的页签也能拖（顺序对以后重新显示有意义）', () {
      final settings = const ShellSettings().withVisible('cat', false)!;
      final moved = settings.withMove(3, 0);
      expect(moved.tabs.first.id, 'cat');
      expect(moved.isVisible('cat'), isFalse);
      final shown = moved.withVisible('cat', true)!;
      expect(shown.tabs.first.id, 'cat');
    });
  });

  group('模型 · 落盘与容错', () {
    test('落盘往返：顺序与可见性都保住', () async {
      final settings = const ShellSettings()
          .withVisible('comic', false)!
          .withMove(3, 0);
      final store = await ShellSettingsStore.open();
      store.save(settings);

      ShellSettingsStore.resetForTesting();
      final reopened = await ShellSettingsStore.open();
      expect(reopened.load(), settings);
    });

    test('旧格式（上一版的 dockEnabled）：回退默认而不是报错', () {
      // 上一版只有一个总开关；与现在的「逐项 + 顺序」不同构，无法迁移。
      final parsed = ShellSettings.fromJson(<String, Object?>{
        'dockEnabled': false,
      });
      expect(parsed.visibleCount, 5, reason: '读不懂就回默认（全部显示）');
    });

    test('损坏 JSON / 缺字段 / 空列表：一律回退默认', () {
      expect(ShellSettings.fromJson('不是 JSON'), ShellSettings.defaults);
      expect(ShellSettings.fromJson(<String, Object?>{}), ShellSettings.defaults);
      expect(
        ShellSettings.fromJson(<String, Object?>{'tabs': <Object?>[]}),
        ShellSettings.defaults,
      );
    });

    test('全部隐藏的坏配置：回退默认（不出现空导航栏）', () {
      final parsed = ShellSettings.fromJson(<String, Object?>{
        'tabs': <Object?>[
          for (final tab in ShellTab.all)
            <String, Object?>{'id': tab.id, 'visible': false},
        ],
      });
      expect(
        parsed.visibleCount,
        5,
        reason: '「至少保留 1 个」是硬约束，坏配置也不能绕过它',
      );
    });

    test('未知 id 被过滤，缺失的页签被补全，重复项去重', () {
      final parsed = ShellSettings.fromJson(<String, Object?>{
        'tabs': <Object?>[
          <String, Object?>{'id': 'novel', 'visible': true},
          <String, Object?>{'id': 'unknown-tab', 'visible': true},
          <String, Object?>{'id': 'novel', 'visible': false},
        ],
      });
      final ids = parsed.tabs.map((tab) => tab.id).toList();
      expect(ids, isNot(contains('unknown-tab')), reason: '陌生 id 要忽略');
      expect(ids.toSet().length, ids.length, reason: '重复 id 要去重');
      expect(
        ids,
        containsAll(<String>['novel', 'comic', 'video', 'cat', 'settings']),
      );
      expect(parsed.isVisible('novel'), isTrue, reason: '重复项认第一次出现');
    });

    test('写盘失败不影响本次运行（内存里已生效）', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async => null,
      );
      ShellSettingsStore.resetForTesting();

      final accepted =
          await ShellSettingsController.instance.setVisible('comic', false);
      expect(accepted, isTrue);
      expect(
        ShellSettingsController.instance.settings.isVisible('comic'),
        isFalse,
      );
    });
  });

  // ==========================================================================
  // 重启：boot() 复现落盘配置
  //
  // 这一组补的是「顺序记忆，重启 App 顺序不变」这条验收口径的**端到端**链路：
  // 上面那组只验了 store 的读写往返，而真机上的「重启」走的是
  // `main()` → `ShellSettingsController.boot()` → 读盘 → 通知壳层 这条路径。
  // 只测 store 的用例证明不了 boot 接线是否接上（boot 里漏一次 apply 就全白改）。
  // ==========================================================================

  group('重启', () {
    test('boot() 之后：内存里就是落盘那份配置', () async {
      final controller = ShellSettingsController.instance;
      // 改三样：隐藏漫画、隐藏猫源、把设置拖到最前。
      await controller.setVisible('comic', false);
      await controller.setVisible('cat', false);
      await controller.move(4, 0);
      final saved = controller.settings;

      // 模拟进程重启：丢掉内存态与 store 实例缓存（磁盘文件保留）。
      controller.resetForTesting();
      expect(
        controller.settings,
        ShellSettings.defaults,
        reason: '复位后应当回到默认（否则下面测不出 boot 的效果）',
      );

      await controller.boot();

      expect(
        controller.settings,
        saved,
        reason: 'boot 必须把落盘的开关与顺序读回来',
      );
      expect(controller.visibleTabIds, <String>['settings', 'novel', 'video']);
    });

    test('boot() 读不到文件：回默认，不抛异常', () async {
      final controller = ShellSettingsController.instance;
      // 指向一个不存在的目录：读盘必然失败/落空。
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async => call.method == 'getApplicationSupportDirectory'
            ? '${root.path}/definitely-missing'
            : null,
      );
      ShellSettingsStore.resetForTesting();

      await controller.boot();

      expect(controller.settings, ShellSettings.defaults);
    });
  });

  // ==========================================================================
  // 壳层：实时生效 + 不锁死
  // ==========================================================================

  group('壳层', () {
    Future<void> pumpShell(WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: LumeTheme.build(),
          home: const AppShell(desktopRail: false),
        ),
      );
      await tester.pumpAndSettle();
    }

    /// Dock 里的页签文案（按显示顺序）。
    List<String> dockLabels(WidgetTester tester) => tester
        .widgetList<Text>(find.descendant(
          of: find.byKey(AppShell.dockKey),
          matching: find.byType(Text),
        ))
        .map((text) => text.data)
        .whereType<String>()
        .toList();

    testWidgets('默认五个页签都在', (tester) async {
      await pumpShell(tester);
      expect(
        dockLabels(tester),
        <String>['小说', '漫画', '视频', '猫源', '设置'],
      );
    });

    testWidgets('隐藏一个页签：底部立刻少一个（实时生效，无需重启）', (tester) async {
      await pumpShell(tester);

      await ShellSettingsController.instance.setVisible('comic', false);
      await tester.pumpAndSettle();

      expect(
        dockLabels(tester),
        <String>['小说', '视频', '猫源', '设置'],
        reason: '隐藏后底部不该还有「漫画」',
      );
    });

    testWidgets('排序实时生效：底部页签顺序跟着变', (tester) async {
      await pumpShell(tester);

      // 把「设置」拖到最前。
      await ShellSettingsController.instance.move(4, 0);
      await tester.pumpAndSettle();

      expect(dockLabels(tester).first, '设置', reason: '设置应排到第一位');
    });

    testWidgets('当前页签被隐藏：自动落到仍可见的页签上', (tester) async {
      await pumpShell(tester);
      await tester.tap(find.text('漫画'));
      await tester.pumpAndSettle();

      await ShellSettingsController.instance.setVisible('comic', false);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(dockLabels(tester), isNot(contains('漫画')));
    });

    testWidgets('隐藏「设置」：左下角出现设置入口（不会被锁死）', (tester) async {
      await pumpShell(tester);

      await ShellSettingsController.instance.setVisible('settings', false);
      await tester.pumpAndSettle();

      expect(dockLabels(tester), isNot(contains('设置')));
      expect(
        find.byKey(AppShell.settingsEntryKey),
        findsOneWidget,
        reason: '设置页是导航栏管理的唯一入口，隐藏它必须留恢复入口——'
            '否则用户再也改不回导航栏',
      );
    });

    testWidgets('Dock 收起时（播放中）：左下角恢复入口一并收起', (tester) async {
      await pumpShell(tester);
      await ShellSettingsController.instance.setVisible('settings', false);
      await tester.pumpAndSettle();

      final entry = find.byKey(AppShell.settingsEntryKey);
      final shownBottom = tester.getRect(entry).bottom;

      // 模拟视频播放中隐藏 Dock（视频页就是这么做的：拿令牌调 hide）。
      final token = Object();
      final dock = ShellDockScope.maybeOf(
        tester.element(find.byKey(AppShell.dockKey)),
      )!;
      dock.hide(token);
      await tester.pumpAndSettle();

      // 收起后：整块移出屏幕下沿。这条守的是「播放中左下角是亮度手势区」——
      // 一个浮在那里的齿轮既挡画面又抢手势。
      expect(
        tester.getRect(entry).top,
        greaterThanOrEqualTo(844),
        reason: 'Dock 收起时恢复入口必须一起移出屏幕'
            '（实际 top=${tester.getRect(entry).top}，收起前 bottom=$shownBottom）',
      );

      dock.show(token);
      await tester.pumpAndSettle();
      expect(
        tester.getRect(entry).bottom,
        shownBottom,
        reason: 'Dock 恢复后入口也要回到原位（不能一去不返）',
      );
    });

    testWidgets('点左下角设置入口：进入设置页', (tester) async {
      await pumpShell(tester);
      await ShellSettingsController.instance.setVisible('settings', false);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(AppShell.settingsEntryKey));
      await tester.pumpAndSettle();

      expect(find.widgetWithText(AppBar, '设置'), findsOneWidget);
    });

    testWidgets('设置入口不与右下角 FAB 重叠', (tester) async {
      await pumpShell(tester);
      await ShellSettingsController.instance.setVisible('settings', false);
      await tester.pumpAndSettle();

      final entry = tester.getRect(find.byKey(AppShell.settingsEntryKey));
      final size = tester.view.physicalSize / tester.view.devicePixelRatio;
      final fabZone = Rect.fromLTWH(size.width - 72, size.height - 72, 72, 72);
      expect(
        entry.overlaps(fabZone),
        isFalse,
        reason: '右下角是「+ 添加源」这类 FAB 的地盘',
      );
    });

    testWidgets('只剩 1 个页签：导航栏仍显示那一项，不空也不消失', (tester) async {
      await pumpShell(tester);
      for (final id in <String>['comic', 'video', 'cat', 'settings']) {
        await ShellSettingsController.instance.setVisible(id, false);
      }
      await tester.pumpAndSettle();

      expect(find.byKey(AppShell.dockKey), findsOneWidget);
      expect(dockLabels(tester), <String>['小说']);
    });

    testWidgets('隐藏设置 → 走恢复入口 → 在设置页里改配置：不被弹出去', (tester) async {
      await pumpShell(tester);

      // 这是本轮修掉的真 bug 的回归：设置被隐藏时，它不在 Dock 上，
      // 「当前页签不可达就落到第一个可见页签」那条逻辑会把停在设置页的用户
      // 弹回小说板块——于是用户在管理页里每改一次配置就被踢出去一次，
      // **永远改不完**。设置页恒为可达（左下角有恢复入口），才拦得住。
      await ShellSettingsController.instance.setVisible('settings', false);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(AppShell.settingsEntryKey));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, '设置'), findsOneWidget);

      // 在设置页里再改一个页签：页面必须原地不动。
      await ShellSettingsController.instance.setVisible('comic', true);
      await tester.pumpAndSettle();
      expect(
        find.widgetWithText(AppBar, '设置'),
        findsOneWidget,
        reason: '用户正在设置页改配置，不该被弹到别的板块',
      );

      // 连改两次也不该被弹走（幂等：状态不会「第二次才炸」）。
      await ShellSettingsController.instance.setVisible('video', false);
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, '设置'), findsOneWidget);
    });

    testWidgets('设置可见时改别的页签：也不会被弹走', (tester) async {
      await pumpShell(tester);
      await tester.tap(find.descendant(
        of: find.byKey(AppShell.dockKey),
        matching: find.text('设置'),
      ));
      await tester.pumpAndSettle();

      await ShellSettingsController.instance.setVisible('cat', false);
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, '设置'), findsOneWidget);
    });

    testWidgets('恢复默认：隐藏的全部回来、顺序复原', (tester) async {
      await pumpShell(tester);
      await ShellSettingsController.instance.setVisible('comic', false);
      await ShellSettingsController.instance.move(4, 0);
      await tester.pumpAndSettle();

      await ShellSettingsController.instance.restoreDefaults();
      await tester.pumpAndSettle();

      expect(
        dockLabels(tester),
        <String>['小说', '漫画', '视频', '猫源', '设置'],
      );
    });
  });

  // ==========================================================================
  // 管理页
  // ==========================================================================

  group('管理页', () {
    Future<void> pumpPage(WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: LumeTheme.build(),
          home: const TabBarSettingsPage(),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('列出全部 5 个页签，各有独立开关', (tester) async {
      await pumpPage(tester);

      for (final label in <String>['小说', '漫画', '视频', '猫源', '设置']) {
        expect(find.text(label), findsOneWidget);
      }
      expect(find.byType(Switch), findsNWidgets(5));
      expect(find.textContaining('当前显示 5 个页签'), findsOneWidget);
    });

    testWidgets('关掉一个：开关变化、计数更新、立刻写进配置', (tester) async {
      await pumpPage(tester);

      final comicSwitch = find.descendant(
        of: find.ancestor(
          of: find.text('漫画'),
          matching: find.byType(Row),
        ),
        matching: find.byType(Switch),
      );
      await tester.tap(comicSwitch);
      await tester.pumpAndSettle();

      expect(
        ShellSettingsController.instance.settings.isVisible('comic'),
        isFalse,
      );
      expect(find.textContaining('当前显示 4 个页签'), findsOneWidget);
    });

    testWidgets('只剩 1 个时：最后一颗开关置灰，并说明原因', (tester) async {
      for (final id in <String>['comic', 'video', 'cat', 'settings']) {
        await ShellSettingsController.instance.setVisible(id, false);
      }
      await pumpPage(tester);

      expect(find.textContaining('当前显示 1 个页签'), findsOneWidget);
      expect(
        find.textContaining('最后一个显示的页签，不能关掉'),
        findsOneWidget,
        reason: '要让用户知道为什么这开关点不动，而不是以为界面坏了',
      );
      final disabled = tester
          .widgetList<Switch>(find.byType(Switch))
          .where((widget) => widget.onChanged == null)
          .toList();
      expect(disabled, hasLength(1), reason: '只有最后一个可见项应当被禁用');
    });

    testWidgets('隐藏设置后：页面提示说明怎么回去', (tester) async {
      await ShellSettingsController.instance.setVisible('settings', false);
      await pumpPage(tester);

      expect(
        find.textContaining('左下角'),
        findsWidgets,
        reason: '要告诉用户「隐藏设置不会把自己锁死」（提示卡与说明卡各一处）',
      );
    });

    testWidgets('恢复默认按钮可用', (tester) async {
      await ShellSettingsController.instance.setVisible('comic', false);
      await pumpPage(tester);

      await tester.tap(find.text('恢复默认（全部显示）'));
      await tester.pumpAndSettle();

      expect(ShellSettingsController.instance.settings.visibleCount, 5);
      expect(find.textContaining('当前显示 5 个页签'), findsOneWidget);
    });

    testWidgets('拖拽手柄存在（每一行一个）', (tester) async {
      await pumpPage(tester);
      expect(find.byIcon(Icons.drag_handle), findsNWidgets(5));
    });

    testWidgets('真的能拖：把小说往下拖一格，顺序随之变化并落库', (tester) async {
      await pumpPage(tester);
      expect(
        ShellSettingsController.instance.tabs.map((tab) => tab.id).toList(),
        <String>['novel', 'comic', 'video', 'cat', 'settings'],
      );

      // 拖第一行的手柄到第三行的位置（真手势，不是调模型方法——
      // 手柄接线断掉时这条会失败，而只调模型的用例不会）。
      final handles = find.byIcon(Icons.drag_handle);
      final start = tester.getCenter(handles.at(0));
      final target = tester.getCenter(handles.at(2));

      final gesture = await tester.startGesture(start);
      await tester.pump(kLongPressTimeout);
      await gesture.moveTo(Offset(start.dx, target.dy));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(
        ShellSettingsController.instance.tabs.map((tab) => tab.id).toList(),
        <String>['comic', 'novel', 'video', 'cat', 'settings'],
        reason: '拖拽要真的改到顺序（手柄接线是否接通就看这条）',
      );
      // 落库：重开 store 读到的是新顺序。
      ShellSettingsStore.resetForTesting();
      final store = await ShellSettingsStore.open();
      expect(store.load().tabs.first.id, 'comic');
    });

    testWidgets('设置页有入口能进本页', (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: LumeTheme.build(),
          home: const SettingsPage(runtimeAvailable: true),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('底部导航栏管理'), findsOneWidget);
      await tester.tap(find.text('底部导航栏管理'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, '底部导航栏管理'), findsOneWidget);
    });
  });

  // ==========================================================================
  // 桌面端：隐藏页签不能把用户锁死
  // ==========================================================================

  group('桌面端左侧栏', () {
    Future<void> pumpRail(WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: LumeTheme.build(),
          home: const AppShell(desktopRail: true),
        ),
      );
      await tester.pumpAndSettle();
    }

    /// 左侧栏里的页签文案（按显示顺序）。
    List<String> railLabels(WidgetTester tester) => tester
        .widgetList<Text>(find.descendant(
          of: find.byKey(AppShell.railKey),
          matching: find.byType(Text),
        ))
        .map((text) => text.data)
        .whereType<String>()
        .toList();

    testWidgets('隐藏页签后：左侧栏仍显示全部 5 个（不跟随隐藏）', (tester) async {
      await pumpRail(tester);
      expect(
        railLabels(tester),
        <String>['小说', '漫画', '视频', '猫源', '设置'],
      );

      await ShellSettingsController.instance.setVisible('comic', false);
      await tester.pumpAndSettle();

      expect(
        railLabels(tester),
        <String>['小说', '漫画', '视频', '猫源', '设置'],
        reason: '桌面端是左侧栏的标准布局，隐藏是移动端 Dock 的概念；'
            'Rail 上少了页签会让人以为界面坏了',
      );
    });

    testWidgets('隐藏「设置」后仍能进设置（桌面端不会被锁死）', (tester) async {
      await pumpRail(tester);
      await ShellSettingsController.instance.setVisible('settings', false);
      await tester.pumpAndSettle();

      // 这是本轮修掉的真 bug：Rail 原先按可见性过滤，而恢复入口只做在移动端
      // Dock 上，于是「隐藏设置」会把桌面用户永久锁死——再也进不去设置页，
      // 也就再也改不回导航栏。Rail 始终显示全部页签，这条路就断不了。
      expect(
        railLabels(tester),
        contains('设置'),
        reason: '设置页是导航栏管理自己的入口，Rail 上必须留着它',
      );

      await tester.tap(find.descendant(
        of: find.byKey(AppShell.railKey),
        matching: find.text('设置'),
      ));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, '设置'), findsOneWidget);
    });

    testWidgets('顺序跟随配置：拖拽后左侧栏顺序跟着变', (tester) async {
      await pumpRail(tester);
      await ShellSettingsController.instance.move(4, 0);
      await tester.pumpAndSettle();

      expect(railLabels(tester).first, '设置');
    });

    testWidgets('隐藏当前页签：桌面端不把用户赶走（它还在 Rail 上）', (tester) async {
      await pumpRail(tester);
      await tester.tap(find.descendant(
        of: find.byKey(AppShell.railKey),
        matching: find.text('漫画'),
      ));
      await tester.pumpAndSettle();

      await ShellSettingsController.instance.setVisible('comic', false);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      // 桌面端「漫画」仍在 Rail 上、仍点得到，因此不该被强制跳到别的板块。
      expect(find.widgetWithText(AppBar, '漫画'), findsOneWidget);
    });
  });
}
