import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/core/shell/shell_settings.dart';
import 'package:lume_box/core/theme/floating_modules.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/features/settings/settings_page.dart';
import 'package:lume_box/features/settings/tab_bar_settings_page.dart';
import 'package:lume_box/features/shell/app_shell.dart';
import 'package:lume_box/features/shell/shell_dock.dart';
import 'package:lume_box/features/shell/shell_dock_bar.dart';
import 'package:lume_box/features/shell/dock_liquid_lens.dart';

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
      expect(settings.tabs.map((tab) => tab.id).toList(), <String>[
        'novel',
        'comic',
        'video',
        'cat',
        'settings',
      ]);
    });

    test('隐藏一个页签：只影响它自己', () {
      const settings = ShellSettings();
      final next = settings.withVisible('comic', false)!;
      expect(next.isVisible('comic'), isFalse);
      expect(next.isVisible('novel'), isTrue);
      expect(next.isVisible('settings'), isTrue);
      expect(next.visibleCount, 4);
      // 顺序不变（隐藏不等于移除）。
      expect(next.tabs.map((tab) => tab.id).toList(), <String>[
        'novel',
        'comic',
        'video',
        'cat',
        'settings',
      ]);
    });

    test('重新显示：回到原来的位置（顺序没被破坏）', () {
      const settings = ShellSettings();
      final hidden = settings.withVisible('video', false)!;
      final shown = hidden.withVisible('video', true)!;
      expect(shown, settings, reason: '关掉再打开应当回到完全一致的配置');
    });

    test('收起悬浮球默认极简线条，JSON 往返保留选择', () {
      expect(const ShellSettings().handleStyle, DockHandleStyle.lines);
      final arrow = const ShellSettings().withHandleStyle(
        DockHandleStyle.arrow,
      );
      expect(arrow.handleStyle, DockHandleStyle.arrow);
      expect(
        ShellSettings.fromJson(arrow.toJson()).handleStyle,
        DockHandleStyle.arrow,
      );
      final legacy = Map<String, Object?>.of(const ShellSettings().toJson())
        ..remove('handleStyle');
      expect(
        ShellSettings.fromJson(legacy).handleStyle,
        DockHandleStyle.lines,
        reason: '旧配置没有该字段时回退默认，不报错',
      );
    });
  });

  group('模型 · 外观参数', () {
    test('默认值就是上一轮精修后的取值', () {
      const a = DockAppearance.defaults;
      expect(a.horizontalMargin, 24);
      expect(a.height, 54);
      expect(a.safeGap, 4);
      expect(a.borderOpacity, .4);
      expect(a.shadowOpacity, .05);
      expect(a.animateSelection, isTrue);
      expect(a.animationMs, 250);
    });

    test('JSON 往返保留全部字段，越界值收敛到安全区间', () {
      const custom = DockAppearance(
        horizontalMargin: 32,
        height: 60,
        safeGap: 10,
        borderOpacity: .3,
        shadowOpacity: .1,
        animateSelection: false,
        animationMs: 300,
      );
      expect(DockAppearance.fromJson(custom.toJson()), custom);

      final clamped = DockAppearance.fromJson(<String, Object?>{
        'horizontalMargin': 999,
        'height': 1,
        'safeGap': -999,
        'borderOpacity': 5,
        'shadowOpacity': -1,
        'animationMs': 9999,
      });
      expect(clamped.horizontalMargin, 100);
      expect(clamped.height, 40);
      expect(clamped.safeGap, -50, reason: '负留白允许压进/越过安全区，最低 -50');
      expect(clamped.borderOpacity, 1);
      expect(clamped.shadowOpacity, 0);
      expect(clamped.animationMs, 2000);
      expect(clamped.animateSelection, isTrue, reason: '缺字段时动效默认开');

      final tall = DockAppearance.fromJson(<String, Object?>{
        'height': 999,
        'safeGap': 999,
      });
      expect(tall.height, 150, reason: '高度上限放开到 150');
      expect(tall.safeGap, 100, reason: '离底距离上限 100');
    });

    test('ShellSettings 往返带外观；旧配置缺字段回退默认；改页签不丢外观', () {
      final custom = const ShellSettings().withAppearance(
        const DockAppearance(height: 60, horizontalMargin: 32),
      );
      final back = ShellSettings.fromJson(custom.toJson());
      expect(back.appearance.height, 60);
      expect(back.appearance.horizontalMargin, 32);

      final legacy = Map<String, Object?>.of(const ShellSettings().toJson())
        ..remove('appearance');
      expect(
        ShellSettings.fromJson(legacy).appearance,
        DockAppearance.defaults,
      );

      final hidden = custom.withVisible('comic', false)!;
      expect(hidden.appearance, custom.appearance, reason: '改页签不该重置外观');
      expect(custom.withMove(0, 4).appearance, custom.appearance);
      expect(
        custom.withHandleStyle(DockHandleStyle.grid).appearance,
        custom.appearance,
      );
    });

    test('外观落盘：重启后仍是用户值；恢复默认只复位页签', () async {
      final controller = ShellSettingsController.instance;
      await controller.setAppearance(
        const DockAppearance(height: 60, horizontalMargin: 32, safeGap: 10),
      );
      await controller.setVisible('comic', false);
      await controller.boot();
      expect(controller.appearance.height, 60);
      expect(controller.appearance.horizontalMargin, 32);
      expect(controller.appearance.safeGap, 10);

      await controller.restoreDefaults();
      expect(controller.settings.visibleCount, 5);
      expect(
        controller.appearance.height,
        60,
        reason: '「恢复默认（全部显示）」不能顺手清掉调好的外观',
      );
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
      expect(moved.tabs.map((tab) => tab.id).toList(), <String>[
        'comic',
        'novel',
        'video',
        'cat',
        'settings',
      ]);
    });

    test('把小说挪到最后', () {
      const settings = ShellSettings();
      final moved = settings.withMove(0, 4);
      expect(moved.tabs.map((tab) => tab.id).toList(), <String>[
        'comic',
        'video',
        'cat',
        'settings',
        'novel',
      ]);
    });

    test('向上拖：把猫源挪到第 1 位', () {
      const settings = ShellSettings();
      final moved = settings.withMove(3, 1);
      expect(moved.tabs.map((tab) => tab.id).toList(), <String>[
        'novel',
        'cat',
        'comic',
        'video',
        'settings',
      ]);
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
      expect(
        ShellSettings.fromJson(<String, Object?>{}),
        ShellSettings.defaults,
      );
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
      expect(parsed.visibleCount, 5, reason: '「至少保留 1 个」是硬约束，坏配置也不能绕过它');
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

      final accepted = await ShellSettingsController.instance.setVisible(
        'comic',
        false,
      );
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

      expect(controller.settings, saved, reason: 'boot 必须把落盘的开关与顺序读回来');
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
        .widgetList<Text>(
          find.descendant(
            of: find.byKey(AppShell.dockKey),
            matching: find.byType(Text),
          ),
        )
        .map((text) => text.data)
        .whereType<String>()
        .toList();

    Finder dockCapsule() => find
        .descendant(
          of: find.byKey(AppShell.dockKey),
          matching: find.byType(ClipRRect),
        )
        .first;

    testWidgets('外观参数实时作用到 Dock：留白 / 高度 / 离底距离', (tester) async {
      await pumpShell(tester);

      await ShellSettingsController.instance.setAppearance(
        const DockAppearance(horizontalMargin: 32, height: 60, safeGap: 10),
      );
      await tester.pumpAndSettle();

      final capsule = tester.getRect(dockCapsule());
      expect(capsule.left, closeTo(32, .01));
      expect(capsule.width, closeTo(390 - 64, .01));
      expect(capsule.height, closeTo(60, .01));
      expect(844 - capsule.bottom, closeTo(10, .01));

      // 收窄/压扁之后每一项仍然点得到。
      final item = tester.getRect(
        find
            .descendant(
              of: find.byKey(AppShell.dockKey),
              matching: find.byType(InkWell),
            )
            .first,
      );
      expect(item.width, greaterThanOrEqualTo(44));
      expect(item.height, closeTo(60, .01));
    });

    testWidgets('默认五个页签都在', (tester) async {
      await pumpShell(tester);
      expect(dockLabels(tester), <String>['小说', '漫画', '视频', '猫源', '设置']);
    });

    testWidgets('隐藏一个页签：底部立刻少一个（实时生效，无需重启）', (tester) async {
      await pumpShell(tester);

      await ShellSettingsController.instance.setVisible('comic', false);
      await tester.pumpAndSettle();

      expect(dockLabels(tester), <String>[
        '小说',
        '视频',
        '猫源',
        '设置',
      ], reason: '隐藏后底部不该还有「漫画」');
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
        reason:
            '设置页是导航栏管理的唯一入口，隐藏它必须留恢复入口——'
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
        reason:
            'Dock 收起时恢复入口必须一起移出屏幕'
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
      expect(entry.overlaps(fabZone), isFalse, reason: '右下角是「+ 添加源」这类 FAB 的地盘');
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
      await tester.tap(
        find.descendant(
          of: find.byKey(AppShell.dockKey),
          matching: find.text('设置'),
        ),
      );
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

      expect(dockLabels(tester), <String>['小说', '漫画', '视频', '猫源', '设置']);
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
        MaterialApp(theme: LumeTheme.build(), home: const TabBarSettingsPage()),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('列出全部 5 个页签，各有独立开关', (tester) async {
      await pumpPage(tester);

      // 只数页签行：外观卡里的「真实 Dock 预览」也带着同一批文案，
      // 不能用全页 find.text 去数，否则会把预览里的页签算进来。
      for (final label in <String>['小说', '漫画', '视频', '猫源', '设置']) {
        expect(
          find.descendant(
            of: find.byType(ReorderableListView),
            matching: find.text(label),
          ),
          findsOneWidget,
        );
      }
      // 页签行里的开关固定 5 个（外观卡里还有一个「点击弹跳动效」开关，
      // 不能把它算进页签数）。
      expect(
        find.descendant(
          of: find.byType(ReorderableListView),
          matching: find.byType(Switch),
        ),
        findsNWidgets(5),
      );
      expect(find.textContaining('当前显示 5 个页签'), findsOneWidget);
    });

    testWidgets('外观卡：材质/尺寸/动效选项齐全，改动写回模型', (tester) async {
      await pumpPage(tester);

      final title = find.text('外观与材质');
      await tester.scrollUntilVisible(
        title,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(title, findsOneWidget);
      for (final label in <String>[
        '玻璃白度',
        '磨砂强度',
        '边缘高光',
        '阴影浓度',
        '左右留白',
        '导航栏高度',
        '离底部距离',
        '点击弹跳动效',
      ]) {
        expect(find.text(label), findsOneWidget, reason: '缺少「$label」选项');
      }

      // 页面是 behindBar（内容从玻璃顶栏下穿过），ensureVisible 会把目标贴到
      // 视口顶端、被顶栏盖住；这里统一滚到视口中间再点。
      Future<void> centerInView(Finder finder) async {
        await Scrollable.ensureVisible(tester.element(finder), alignment: .5);
        await tester.pumpAndSettle();
      }

      // 关闭动效：写回模型并立刻生效（时长滑块随之隐藏）。
      final animationSwitch = find.descendant(
        of: find
            .ancestor(of: find.text('点击弹跳动效'), matching: find.byType(Row))
            .first,
        matching: find.byType(Switch),
      );
      await centerInView(animationSwitch);
      await tester.tap(animationSwitch);
      await tester.pumpAndSettle();
      expect(
        ShellSettingsController.instance.appearance.animateSelection,
        isFalse,
      );
      expect(find.text('动效时长'), findsNothing);

      // 高度滑块拖到最右端 → 150pt（上限已放开）。
      final height = find.byKey(const ValueKey('dock-appearance-height'));
      await centerInView(height);
      final rect = tester.getRect(height);
      await tester.tapAt(Offset(rect.right - 4, rect.center.dy));
      await tester.pumpAndSettle();
      expect(ShellSettingsController.instance.appearance.height, 150);
    });

    testWidgets('透镜接入可调外观：滑块实时更新预览且重启后保留自定义值', (tester) async {
      await pumpPage(tester);
      final modules = FloatingModules.instance;
      await modules.boot();
      addTearDown(() => modules.reset(FloatingModule.dock));
      Future<void> slide(String id, double value) async {
        final finder = find.byKey(ValueKey('dock-appearance-$id'));
        await tester.scrollUntilVisible(
          finder,
          160,
          scrollable: find.byType(Scrollable).first,
        );
        await Scrollable.ensureVisible(tester.element(finder), alignment: .5);
        await tester.pumpAndSettle();
        final slider = tester.widget<Slider>(finder);
        final bounds = tester.getRect(finder);
        // Exercise the actual slider gesture; Flutter leaves 24pt for the thumb.
        final fraction = (value - slider.min) / (slider.max - slider.min);
        await tester.tapAt(
          Offset(
            bounds.left + 24 + (bounds.width - 48) * fraction,
            bounds.center.dy,
          ),
        );
        await tester.pumpAndSettle();
      }

      await slide('opacity', .31);
      await slide('blur', 9);
      await slide('border', .65);
      await slide('shadow', .12);
      await slide('margin', 32);
      await slide('height', 73);
      await slide('gap', -7);
      await slide('duration', 820);
      final appearance = ShellSettingsController.instance.appearance;
      final material = modules.style(FloatingModule.dock);
      expect(material.opacity, closeTo(.31, .02));
      expect(material.blur, closeTo(9, .6));
      expect(appearance.borderOpacity, closeTo(.65, .02));
      expect(appearance.shadowOpacity, closeTo(.12, .02));
      expect(appearance.horizontalMargin, closeTo(32, 2));
      expect(appearance.height, closeTo(73, 2));
      expect(appearance.safeGap, closeTo(-7, 2));
      expect(appearance.animationMs, closeTo(820, 30));
      // The preview owns the same production dock and optical overlay.
      final preview = find.byKey(const ValueKey('dock-appearance-preview'));
      await Scrollable.ensureVisible(tester.element(preview), alignment: .5);
      await tester.pumpAndSettle();
      final dock = tester.widget<ShellDockBar>(
        find.descendant(of: preview, matching: find.byType(ShellDockBar)),
      );
      final lens = tester.widget<DockLiquidLens>(
        find.descendant(of: preview, matching: find.byType(DockLiquidLens)),
      );
      expect(dock.appearance, appearance);
      expect(lens.highlight, appearance.borderOpacity);
      expect(
        tester
            .getSize(
              find.descendant(of: preview, matching: find.byType(ShellDockBar)),
            )
            .height,
        closeTo(appearance.height, .01),
      );
      await ShellSettingsController.instance.boot();
      await modules.boot();
      expect(ShellSettingsController.instance.appearance, appearance);
      expect(modules.style(FloatingModule.dock).opacity, material.opacity);
      expect(modules.style(FloatingModule.dock).blur, material.blur);
      expect(tester.takeException(), isNull);
    });

    testWidgets('液态细调从管理页进入、实时改变预览，并在重新加载后保留', (tester) async {
      await pumpPage(tester);
      final entry = find.byKey(const ValueKey('dock-liquid-open'));
      await Scrollable.ensureVisible(tester.element(entry), alignment: .5);
      await tester.pumpAndSettle();
      await tester.tap(entry);
      await tester.pumpAndSettle();
      expect(find.text('液态玻璃细调'), findsWidgets);
      final response = find.byKey(const ValueKey('dock-liquid-pressMs'));
      await Scrollable.ensureVisible(tester.element(response), alignment: .5);
      await tester.pumpAndSettle();
      final rect = tester.getRect(response);
      await tester.tapAt(Offset(rect.right - 24, rect.center.dy));
      await tester.pumpAndSettle();
      final controller = ShellSettingsController.instance;
      expect(
        controller.appearance.liquid.value(DockLiquidParameter.pressMs),
        greaterThan(300),
      );
      final effect = find.byKey(const ValueKey('dock-liquid-effect-lift'));
      await tester.scrollUntilVisible(
        effect,
        200,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.tap(
        find.descendant(of: effect, matching: find.byType(Switch)),
      );
      await tester.pumpAndSettle();
      expect(
        controller.appearance.liquid.enabled(DockLiquidEffect.lift),
        isFalse,
      );
      final dock = tester.widget<ShellDockBar>(find.byType(ShellDockBar).last);
      expect(dock.appearance.liquid, controller.appearance.liquid);
      final saved = controller.appearance;
      await controller.boot();
      expect(controller.appearance, saved);
      expect(tester.takeException(), isNull);
    });

    testWidgets('外观滑块范围：白度/高光/阴影 0–100%，磨砂 0–30，间距 -50–100', (tester) async {
      await pumpPage(tester);
      await tester.scrollUntilVisible(
        find.text('外观与材质'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();

      Slider slider(String key) =>
          tester.widget<Slider>(find.byKey(ValueKey<String>(key)));

      expect(slider('dock-appearance-opacity').min, 0);
      expect(slider('dock-appearance-opacity').max, 1);
      expect(slider('dock-appearance-blur').min, 0);
      expect(slider('dock-appearance-blur').max, 30);
      expect(slider('dock-appearance-border').min, 0);
      expect(slider('dock-appearance-border').max, 1);
      expect(slider('dock-appearance-shadow').min, 0);
      expect(slider('dock-appearance-shadow').max, 1);
      expect(slider('dock-appearance-margin').min, 0);
      expect(slider('dock-appearance-margin').max, 100);
      expect(slider('dock-appearance-height').min, 40);
      expect(slider('dock-appearance-height').max, 150);
      expect(slider('dock-appearance-gap').min, -50);
      expect(slider('dock-appearance-gap').max, 100);
      expect(slider('dock-appearance-duration').min, 100);
      expect(slider('dock-appearance-duration').max, 2000);
    });

    testWidgets('极限外观值：预览与真实 Dock 都不溢出', (tester) async {
      await pumpPage(tester);
      await tester.scrollUntilVisible(
        find.text('外观与材质'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();

      final modules = FloatingModules.instance;
      addTearDown(() => modules.reset(FloatingModule.dock));
      modules.set(
        FloatingModule.dock,
        modules.style(FloatingModule.dock).copyWith(opacity: 1, blur: 30),
      );
      await ShellSettingsController.instance.setAppearance(
        const DockAppearance(
          horizontalMargin: 100,
          height: 150,
          safeGap: -50,
          borderOpacity: 1,
          shadowOpacity: 1,
          animationMs: 2000,
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      final preview = find.byKey(const ValueKey('dock-appearance-preview'));
      expect(preview, findsOneWidget);
      // 预览高度会随「150pt 高」一起长，给胶囊留出完整空间。
      expect(tester.getSize(preview).height, greaterThan(200));
      final previewDock = find.descendant(
        of: preview,
        matching: find.byType(ShellDockBar),
      );
      expect(previewDock, findsOneWidget);
      expect(tester.getSize(previewDock).height, closeTo(150, .01));
      expect(tester.takeException(), isNull);
    });

    testWidgets('三种收起悬浮球可选：点击立即生效', (tester) async {
      await pumpPage(tester);

      // 外观卡把「收起悬浮球」推到了首屏之外：先滚到它，让 ListView 把它建出来。
      final arrow = find.byKey(const ValueKey('dock-handle-style-arrow'));
      await tester.scrollUntilVisible(
        arrow,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      // ensureVisible 只改滚动位置，要让下一帧重新布局后组件才真的在屏内。
      await tester.pumpAndSettle();
      for (final style in DockHandleStyle.values) {
        expect(find.text(style.label), findsOneWidget);
      }
      await tester.tap(arrow);
      await tester.pumpAndSettle();
      expect(
        ShellSettingsController.instance.handleStyle,
        DockHandleStyle.arrow,
      );
      expect(
        find.byKey(const ValueKey('dock-handle-style-arrow')),
        findsOneWidget,
      );
    });

    testWidgets('关掉一个：开关变化、计数更新、立刻写进配置', (tester) async {
      await pumpPage(tester);

      final comicSwitch = find.descendant(
        of: find.ancestor(of: find.text('漫画'), matching: find.byType(Row)),
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

      // 新增「收起悬浮球」设置后，底部说明卡需要滚动到可视区域。
      final restore = find.text('恢复默认（全部显示）');
      await tester.scrollUntilVisible(
        restore,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(OutlinedButton, '恢复默认（全部显示）'));
      await tester.pumpAndSettle();

      expect(ShellSettingsController.instance.settings.visibleCount, 5);
      // 滚回顶部确认界面也恢复了。
      await tester.scrollUntilVisible(
        find.textContaining('当前显示 5 个页签'),
        -300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
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
        .widgetList<Text>(
          find.descendant(
            of: find.byKey(AppShell.railKey),
            matching: find.byType(Text),
          ),
        )
        .map((text) => text.data)
        .whereType<String>()
        .toList();

    testWidgets('隐藏页签后：左侧栏仍显示全部 5 个（不跟随隐藏）', (tester) async {
      await pumpRail(tester);
      expect(railLabels(tester), <String>['小说', '漫画', '视频', '猫源', '设置']);

      await ShellSettingsController.instance.setVisible('comic', false);
      await tester.pumpAndSettle();

      expect(
        railLabels(tester),
        <String>['小说', '漫画', '视频', '猫源', '设置'],
        reason:
            '桌面端是左侧栏的标准布局，隐藏是移动端 Dock 的概念；'
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

      await tester.tap(
        find.descendant(
          of: find.byKey(AppShell.railKey),
          matching: find.text('设置'),
        ),
      );
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
      await tester.tap(
        find.descendant(
          of: find.byKey(AppShell.railKey),
          matching: find.text('漫画'),
        ),
      );
      await tester.pumpAndSettle();

      await ShellSettingsController.instance.setVisible('comic', false);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      // 桌面端「漫画」仍在 Rail 上、仍点得到，因此不该被强制跳到别的板块。
      expect(find.widgetWithText(AppBar, '漫画'), findsOneWidget);
    });
  });
}
