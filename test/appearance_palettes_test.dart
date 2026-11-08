import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/theme/appearance.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/features/settings/display_settings_group.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  setUp(() async {
    root = Directory.systemTemp.createTempSync('appearance-palettes-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => root.path,
        );
    AppearanceSettingsStore.resetForTesting();
    AppearanceController.instance.resetForTesting();
    await AppearanceController.instance.boot();
  });
  tearDown(() {
    AppearanceController.instance.resetForTesting();
    AppearanceSettingsStore.resetForTesting();
    root.deleteSync(recursive: true);
    LumeTheme.build();
  });
  testWidgets('主题色网格不重复添加 iPhone 顶部安全区', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: LumeTheme.build(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            padding: const EdgeInsets.only(top: 59, bottom: 34),
            viewPadding: const EdgeInsets.only(top: 59, bottom: 34),
          ),
          child: child!,
        ),
        home: const AppearancePalettePage(),
      ),
    );
    await tester.pumpAndSettle();
    final grid = find.byType(GridView);
    final firstCard = find
        .descendant(of: grid, matching: find.byType(InkWell))
        .first;
    expect(
      tester.getTopLeft(firstCard).dy,
      closeTo(tester.getTopLeft(grid).dy, 1),
    );
    expect(tester.takeException(), isNull);
  });
  test('旧配色保持默认，自定义底色分别进入实际亮暗主题', () {
    final old = AppearanceSettings.fromJson({
      'accent': 'mint',
      'background': 'f5f5f5',
    });
    expect(old.lightBackgroundArgb, isNull);
    expect(old.darkBackgroundArgb, isNull);
    final settings = old.copyWith(
      lightBackgroundArgb: 0xFFFFF4E6,
      darkBackgroundArgb: 0xFF000000,
    );
    expect(
      LumeTheme.build(
        background: settings.background,
        lightBackground: Color(settings.lightBackgroundArgb!),
      ).scaffoldBackgroundColor,
      const Color(0xFFFFF4E6),
    );
    expect(
      LumeTheme.build(
        brightness: Brightness.dark,
        darkBackground: Color(settings.darkBackgroundArgb!),
      ).scaffoldBackgroundColor,
      Colors.black,
    );
    expect(AppearanceSettings.fromJson(settings.toJson()), settings);
  });
  test('错误明暗与透明颜色仍保证正文可读，非法持久化值回落', () {
    final settings = AppearanceSettings.defaults.copyWith(
      lightBackgroundArgb: 0x00000000,
      darkBackgroundArgb: 0xFFFFFFFF,
    );
    expect(
      LumeTheme.contrast(
        const Color(0xFF1A1A1A),
        Color(settings.lightBackgroundArgb!),
      ),
      greaterThanOrEqualTo(4.5),
    );
    expect(
      LumeTheme.contrast(Colors.white, Color(settings.darkBackgroundArgb!)),
      greaterThanOrEqualTo(4.5),
    );
    final bad = AppearanceSettings.fromJson({
      'lightBackgroundArgb': 'wrong',
      'darkBackgroundArgb': -1,
    });
    expect(bad.lightBackgroundArgb, isNull);
    expect(bad.darkBackgroundArgb, isNull);
  });
  test('整套配色保存重启可恢复，应用不改字体或模式，同名覆盖不增加数量', () async {
    final c = AppearanceController.instance;
    c.apply(
      c.settings.copyWith(
        accent: ThemeAccent.mint,
        lightBackgroundArgb: 0xFFFFF4E6,
        darkBackgroundArgb: 0xFF000000,
      ),
    );
    c.savePalette('夜间薄荷');
    c.savePalette('夜间薄荷');
    expect(c.settings.savedPalettes, hasLength(1));
    c.apply(
      c.settings.copyWith(
        accent: ThemeAccent.ruby,
        mode: ThemeMode.dark,
        fontItalic: true,
        resetLightBackground: true,
        resetDarkBackground: true,
      ),
    );
    c.applyPalette(c.settings.savedPalettes.single);
    expect(c.settings.accent, ThemeAccent.mint);
    expect(c.settings.darkBackgroundArgb, 0xFF000000);
    expect(c.settings.mode, ThemeMode.dark);
    expect(c.settings.fontItalic, isTrue);
    final store = await AppearanceSettingsStore.open();
    expect(store.load(), c.settings);
    c.removePalette('夜间薄荷');
    expect(c.settings.savedPalettes, isEmpty);
  });
  testWidgets('底色界面能取消取色和命名方案，取消不改变现有颜色', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: LumeTheme.build(),
        home: const AppearancePalettePage(backgroundOnly: true),
      ),
    );
    await tester.pumpAndSettle();
    final before = AppearanceController.instance.settings;
    await tester.ensureVisible(find.byKey(const ValueKey('background-light')));
    await tester.tap(find.byKey(const ValueKey('background-light')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('取消自定义颜色'));
    await tester.pumpAndSettle();
    expect(AppearanceController.instance.settings, before);
    await tester.ensureVisible(
      find.byKey(const Key('save-appearance-palette')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('save-appearance-palette')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '我的配色');
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存').last);
    await tester.pumpAndSettle();
    expect(
      AppearanceController.instance.settings.savedPalettes.single.name,
      '我的配色',
    );
    expect(tester.takeException(), isNull);
  });
}
