import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/core/theme/appearance.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/features/settings/display_settings_group.dart';
import 'package:lume_box/features/settings/settings_page.dart';
import 'package:lume_box/shared/widgets/glass_card.dart';

/// 设置页「显示」分组：外观（跟随系统 / 浅色 / 深色）+ 主题色（11 种）。
///
/// 用户要求：两项合并到同一个分组卡片（标题「显示」），组内两行；选择弹窗复用
/// 既有的底部 Sheet 交互，不另造一套。这里把这三件事钉住。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('lume_box_appearance');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => call.method == 'getApplicationSupportDirectory'
          ? root.path
          : null,
    );
    AppearanceSettingsStore.resetForTesting();
    AppearanceController.instance.resetForTesting();
    // 板块作用域要在真实时钟里先打开（设置页里的播放器内核区会读板块库；
    // 首次打开要做真实 IO，在 fake-async 的测试体里 await 等不到，
    // 加载态转圈会让 pumpAndSettle 永远settle不了）。
    for (final section in Section.values) {
      await SectionScope.open(section);
    }
  });

  tearDown(() async {
    AppearanceController.instance.resetForTesting();
    AppearanceSettingsStore.resetForTesting();
    ReadingLibrary.disposeAll();
    ReadingStore.disposeAll();
    await SectionScope.closeAll();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  group('主题色档位', () {
    test('11 种颜色，id 与展示名都在（用户点名的那一份）', () {
      expect(
        ThemeAccent.values.map((accent) => accent.label).toList(),
        <String>[
          '粉红色',
          '红宝石',
          '赤陶',
          '樱花',
          '靛蓝',
          '午夜',
          '薄荷',
          '日落',
          '紫水晶',
          '金色',
          '森林',
        ],
      );
      for (final accent in ThemeAccent.values) {
        expect(accent.id, isNotEmpty);
        // 落库标识是稳定 id，不是中文标签。
        expect(RegExp(r'^[a-z]+$').hasMatch(accent.id), isTrue);
      }
    });

    test('默认是品牌紫：升级后观感不变', () {
      expect(ThemeAccent.fallback, ThemeAccent.amethyst);
      expect(AppearanceSettings.defaults.accent, ThemeAccent.amethyst);
      expect(AppearanceSettings.defaults.mode, ThemeMode.system);
    });

    test('深色主题下主色提亮（同一色值在深底上会发闷）', () {
      for (final accent in ThemeAccent.values) {
        final light = accent.colorFor(Brightness.light);
        final dark = accent.colorFor(Brightness.dark);
        expect(light, Color(accent.argb), reason: '浅色主题直接用原值');
        expect(
          dark.computeLuminance(),
          greaterThan(light.computeLuminance()),
          reason: '${accent.label} 在深色主题下应当更亮',
        );
      }
    });

    test('未知 id 回退默认（库被改坏也不影响启动）', () {
      expect(ThemeAccent.fromId('nope'), ThemeAccent.amethyst);
      expect(ThemeAccent.fromId(null), ThemeAccent.amethyst);
      expect(ThemeAccent.fromId('forest'), ThemeAccent.forest);
    });
  });

  group('外观设置与落库', () {
    test('JSON 往返：模式与主题色各一项，坏值只影响那一项', () {
      const settings = AppearanceSettings(
        mode: ThemeMode.dark,
        accent: ThemeAccent.mint,
      );
      expect(AppearanceSettings.fromJson(settings.toJson()), settings);

      final broken = AppearanceSettings.fromJson(<String, Object?>{
        'mode': 'twilight',
        'accent': 'rainbow',
      });
      expect(broken, AppearanceSettings.defaults);

      // 只坏一项：另一项照常读出来。
      final half = AppearanceSettings.fromJson(<String, Object?>{
        'mode': 'light',
        'accent': 42,
      });
      expect(half.mode, ThemeMode.light);
      expect(half.accent, ThemeAccent.amethyst);
    });

    test('落盘 → 重开读回', () async {
      final store = await AppearanceSettingsStore.open();
      store.save(
        const AppearanceSettings(mode: ThemeMode.light, accent: ThemeAccent.gold),
      );

      AppearanceSettingsStore.resetForTesting();
      final reopened = await AppearanceSettingsStore.open();
      final loaded = reopened.load();
      expect(loaded.mode, ThemeMode.light);
      expect(loaded.accent, ThemeAccent.gold);
      expect(File(reopened.path).existsSync(), isTrue);
    });

    test('文件缺失 / 内容为空：回退默认，不抛异常', () async {
      final store = await AppearanceSettingsStore.open();
      expect(store.load(), AppearanceSettings.defaults);
      File(store.path).writeAsStringSync('   ');
      expect(store.load(), AppearanceSettings.defaults);
      File(store.path).writeAsStringSync('{ 不是 json');
      expect(store.load(), AppearanceSettings.defaults);
    });

    test('控制器：改一项立刻通知（主题要当场变）', () async {
      final controller = AppearanceController.instance;
      var notifications = 0;
      controller.addListener(() => notifications++);

      await controller.boot();
      controller.apply(
        controller.settings.copyWith(accent: ThemeAccent.forest),
      );
      expect(controller.accent, ThemeAccent.forest);
      expect(notifications, greaterThan(0));

      // 值没变就不通知（避免无意义的整树重建）。
      final before = notifications;
      controller.apply(controller.settings);
      expect(notifications, before);
    });

    test('主题色进色板：只换主色，结构不变', () {
      final light = LumeTheme.paletteOf(Brightness.light);
      final forest = light.withAccent(ThemeAccent.forest);
      expect(forest.accent, ThemeAccent.forest.colorFor(Brightness.light));
      expect(forest.base, light.base, reason: '底色不动');
      expect(forest.surface, light.surface, reason: '卡片底不动');
      expect(forest.textPrimary, light.textPrimary, reason: '文字色不动');

      // build() 之后静态色名也跟着走。
      LumeTheme.build(brightness: Brightness.light, accent: ThemeAccent.sunset);
      expect(LumeTheme.accent, ThemeAccent.sunset.colorFor(Brightness.light));
      // 复位，免得影响同进程的其它用例。
      LumeTheme.build(brightness: Brightness.light);
      expect(LumeTheme.accent, ThemeAccent.amethyst.colorFor(Brightness.light));
    });
  });

  group('设置页「显示」分组', () {
    Future<void> pumpSettings(WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: LumeTheme.build(),
          home: const SettingsPage(runtimeAvailable: true),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('「界面」分组里是两行（外观 / 主题色），且排在其余分组之前', (tester) async {
      await pumpSettings(tester);

      expect(find.byType(DisplaySettingsGroup), findsOneWidget);
      // 设置页重排后，这一组归到「界面」（外观 / 主题色 / 底部导航栏管理）。
      expect(find.text('界面'), findsOneWidget);
      expect(find.text('外观'), findsOneWidget);
      expect(find.text('主题色'), findsOneWidget);

      // 两行在同一个分组卡片里。
      expect(
        find.descendant(
          of: find.byType(DisplaySettingsGroup),
          matching: find.byType(GlassCard),
        ),
        findsOneWidget,
        reason: '两项收在一张卡里，不是两张卡',
      );

      // 分组在最上方（用户要求：其余条目位置顺序保持原样）。
      final groupY = tester.getTopLeft(find.byType(DisplaySettingsGroup)).dy;
      final navY = tester.getTopLeft(find.text('底部导航栏管理')).dy;
      expect(groupY, lessThan(navY));
    });

    testWidgets('通用分组里不再有独立的外观 / 主题条目', (tester) async {
      await pumpSettings(tester);

      // 「外观」「主题色」各只出现一次（分组内），不存在第二个同名入口。
      expect(find.text('外观'), findsOneWidget);
      expect(find.text('主题色'), findsOneWidget);
      expect(find.text('主题'), findsNothing, reason: '旧的独立「主题」条目已移除');
    });

    testWidgets('点「外观」：弹底部 Sheet，选深色后当场生效并落库', (tester) async {
      AppearanceSettingsStore.resetForTesting();
      await AppearanceController.instance.boot();
      await pumpSettings(tester);

      await tester.tap(find.text('外观'));
      await tester.pumpAndSettle();

      expect(find.byType(OptionSheet<ThemeMode>), findsOneWidget);
      expect(find.text('跟随系统'), findsWidgets);
      expect(find.text('浅色'), findsOneWidget);
      expect(find.text('深色'), findsOneWidget);

      await tester.tap(find.text('深色'));
      await tester.pumpAndSettle();

      expect(AppearanceController.instance.mode, ThemeMode.dark);
      expect(find.text('深色'), findsOneWidget, reason: '行内当前值跟着变');
    });

    testWidgets('点「主题色」：11 种颜色都在，选中后当场生效并落库', (tester) async {
      AppearanceSettingsStore.resetForTesting();
      await AppearanceController.instance.boot();
      await pumpSettings(tester);

      await tester.tap(find.text('主题色'));
      await tester.pumpAndSettle();

      expect(find.byType(OptionSheet<ThemeAccent>), findsOneWidget);
      for (final accent in ThemeAccent.values) {
        expect(find.text(accent.label), findsWidgets, reason: '${accent.label} 在列表里');
      }

      await tester.tap(find.text('森林'));
      await tester.pumpAndSettle();

      expect(AppearanceController.instance.accent, ThemeAccent.forest);
      expect(find.text('森林'), findsOneWidget, reason: '行内当前值跟着变');

      // 落库：重新读盘能读回。
      final store = await AppearanceSettingsStore.open();
      expect(store.load().accent, ThemeAccent.forest);
    });
  });
}
