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

  test(
    'page background persists with backward compatible defaults and dark mode',
    () async {
      expect(
        AppearanceSettings.fromJson({'accent': 'mint'}).background,
        ThemeBackground.grouped,
      );
      final store = await AppearanceSettingsStore.open();
      for (final background in ThemeBackground.values) {
        final settings = AppearanceSettings.defaults.copyWith(
          background: background,
        );
        store.save(settings);
        expect(store.load(), settings);
        expect(AppearanceSettings.fromJson(settings.toJson()), settings);
        final light = LumeTheme.build(background: background);
        expect(light.scaffoldBackgroundColor, background.color);
        expect(LumeTheme.background.color, background.color);
        final lightKey = LumeTheme.themeId;
        final dark = LumeTheme.build(
          brightness: Brightness.dark,
          background: background,
        );
        expect(dark.scaffoldBackgroundColor, LumePalette.dark.base);
        expect(LumeTheme.themeId, isNot(lightKey));
      }
      LumeTheme.build();
    },
  );

  testWidgets('浅色底色预设保持兼容，可与自定义深色底色并存', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: LumeTheme.build(),
        home: const Scaffold(body: DisplaySettingsGroup()),
      ),
    );
    await tester.tap(find.text('页面底色'));
    await tester.pumpAndSettle();
    expect(find.text('#FFFFFF'), findsNothing);
    expect(
      AppearanceSettings.fromJson({'background': 'white'}).background,
      ThemeBackground.grouped,
    );
    await tester.ensureVisible(find.text('#F2F2F7').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('#F2F2F7').last);
    await tester.pumpAndSettle();
    expect(
      AppearanceController.instance.settings.background,
      ThemeBackground.grouped,
    );
    await tester.ensureVisible(find.text('#F5F5F5'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('#F5F5F5'));
    await tester.pumpAndSettle();
    expect(
      AppearanceController.instance.settings.background,
      ThemeBackground.neutral,
    );
    expect(tester.takeException(), isNull);
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
        const AppearanceSettings(
          mode: ThemeMode.light,
          accent: ThemeAccent.gold,
        ),
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
      expect(
        forest.accent,
        LumeTheme.readableForeground(
          ThemeAccent.forest.colorFor(Brightness.light),
          light.surfaceAlt,
        ),
      );
      expect(forest.base, light.base, reason: '底色不动');
      expect(forest.surface, light.surface, reason: '卡片底不动');
      expect(forest.textPrimary, light.textPrimary, reason: '文字色不动');

      // build() 之后静态色名也跟着走。
      LumeTheme.build(brightness: Brightness.light, accent: ThemeAccent.sunset);
      expect(
        LumeTheme.accent,
        LumeTheme.readableForeground(
          ThemeAccent.sunset.colorFor(Brightness.light),
          light.surfaceAlt,
        ),
      );
      // 复位，免得影响同进程的其它用例。
      LumeTheme.build(brightness: Brightness.light);
      expect(
        LumeTheme.accent,
        LumeTheme.readableForeground(
          ThemeAccent.amethyst.colorFor(Brightness.light),
          light.surfaceAlt,
        ),
      );
    });
  });

  group('设置页外观二级页', () {
    Future<void> open(WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: LumeTheme.build(),
          home: const SettingsPage(runtimeAvailable: true),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(DisplaySettingsGroup), findsNothing);
      await tester.tap(find.text('个性与界面'));
      await tester.pumpAndSettle();
    }

    testWidgets('外观收进二级页，短选项直接切换不打开抽屉', (tester) async {
      await open(tester);
      expect(find.byType(DisplaySettingsGroup), findsOneWidget);
      expect(find.text('页面底色'), findsOneWidget);
      await tester.tap(find.text('深色'));
      await tester.pumpAndSettle();
      expect(AppearanceController.instance.mode, ThemeMode.dark);
      expect(find.byType(BottomSheet), findsNothing);
    });
    testWidgets('主题色独立色板页实时应用并保存', (tester) async {
      await open(tester);
      await tester.tap(find.text('主题色'));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
      for (final accent in ThemeAccent.values) {
        expect(find.text(accent.label), findsOneWidget);
      }
      await tester.tap(find.text('薄荷'));
      await tester.pumpAndSettle();
      expect(AppearanceController.instance.accent, ThemeAccent.mint);
    });
  });
}
