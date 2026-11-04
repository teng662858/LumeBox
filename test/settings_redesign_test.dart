import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/theme/frosted_settings.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/features/settings/settings_page.dart';
import 'package:lume_box/features/settings/display_settings_group.dart';
import 'package:lume_box/features/settings/liquid_glass_settings_page.dart';
import 'package:lume_box/features/settings/configuration_settings_page.dart';
import 'package:lume_box/features/settings/experience_settings_card.dart';
import 'package:lume_box/shared/widgets/frosted_glass_widget.dart';
import 'package:lume_box/shared/widgets/module_glass_scope.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  setUp(() async {
    directory = Directory.systemTemp.createTempSync('lume-settings-redesign');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => directory.path,
        );
    await FrostedSettings.instance.boot(directory: directory);
  });
  tearDown(() async {
    await FrostedSettings.instance.save();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    directory.deleteSync(recursive: true);
  });
  test('原生材质参数持久化且收敛无效值', () async {
    final settings = FrostedSettings.instance;
    await settings.setNative(
      const NativeGlassStyle(
        clear: true,
        tint: 0xFF147EFB,
        tintOpacity: .2,
        radiusScale: 1.2,
      ),
    );
    final restored = FrostedSettings();
    await restored.boot(directory: directory);
    expect(restored.native.toJson(), settings.native.toJson());
    expect(
      NativeGlassStyle.fromJson({'tintOpacity': double.nan, 'radiusScale': 999})
          .radiusScale,
      1.5,
    );
    expect(
      NativeGlassStyle.fromJson({'tintOpacity': double.nan}).tintOpacity,
      0,
    );
    restored.dispose();
  });
  test('材质继承、模块覆盖、重置与备份文件往返，越界值收敛', () async {
    final c = FrostedSettings.instance;
    await c.setStyle(
      GlassModule.all,
      null,
      const LiquidGlassStyle().withValue(GlassParameter.blur, 22),
    );
    expect(
      c.style(GlassModule.video, GlassPart.cards).value(GlassParameter.blur),
      22,
    );
    await c.setStyle(
      GlassModule.video,
      GlassPart.cards,
      c
          .style(GlassModule.video, GlassPart.cards)
          .withValue(GlassParameter.opacity, .45),
    );
    expect(
      c
          .style(GlassModule.settings, GlassPart.cards)
          .value(GlassParameter.opacity),
      GlassParameter.opacity.fallback,
    );
    final restored = FrostedSettings();
    await restored.boot(directory: directory);
    expect(
      restored
          .style(GlassModule.video, GlassPart.cards)
          .value(GlassParameter.opacity),
      .45,
    );
    await restored.resetStyle(GlassModule.video, GlassPart.cards);
    expect(
      restored
          .style(GlassModule.video, GlassPart.cards)
          .value(GlassParameter.blur),
      22,
    );
    expect(
      LiquidGlassStyle.fromJson({'blur': 999, 'opacity': -2})
          .value(GlassParameter.blur),
      30,
    );
    expect(
      LiquidGlassStyle.fromJson({'blur': double.nan})
          .value(GlassParameter.blur),
      GlassParameter.blur.fallback,
    );
    restored.dispose();
  });
  testWidgets('材质参数进入真实表面，高对比度自动使用实色', (tester) async {
    await FrostedSettings.instance.setStyle(
      GlassModule.video,
      GlassPart.cards,
      const LiquidGlassStyle().withValue(GlassParameter.opacity, .25),
    );
    Widget scene(bool contrast) => MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(highContrast: contrast),
        child: const Center(
          child: ModuleGlassScope(
            module: GlassModule.video,
            part: GlassPart.cards,
            child: FrostedGlassWidget(child: SizedBox(width: 200, height: 100)),
          ),
        ),
      ),
    );
    await tester.pumpWidget(scene(false));
    await tester.pumpAndSettle();
    final fill = find.descendant(
      of: find.byType(FrostedGlassWidget),
      matching: find.byType(ColoredBox),
    );
    expect(
      tester.widget<ColoredBox>(fill).color.a,
      closeTo(.72 * .25 / .68, .001),
    );
    expect(find.byType(BackdropFilter), findsOneWidget);
    await tester.pumpWidget(scene(true));
    await tester.pumpAndSettle();
    expect(tester.widget<ColoredBox>(fill).color.a, 1);
    expect(find.byType(BackdropFilter), findsNothing);
  });

  for (final width in [320.0, 430.0]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('一级二级与配色页适配宽度 $width 字号 $scale', (tester) async {
        tester.view.physicalSize = Size(width, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          MaterialApp(
            theme: LumeTheme.build(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: const SettingsPage(runtimeAvailable: true),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(DisplaySettingsGroup), findsNothing);
        await tester.tap(find.text('个性与界面'));
        await tester.pumpAndSettle();
        expect(find.byType(DisplaySettingsGroup), findsOneWidget);
        await tester.scrollUntilVisible(
          find.text('页面底色').hitTestable(),
          180,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.tap(find.text('页面底色'));
        await tester.pumpAndSettle();
        expect(find.byType(BottomSheet), findsNothing);
        await tester.scrollUntilVisible(
          find.text('柔灰').hitTestable(),
          180,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.tap(find.text('柔灰'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      });
    }
  }
  testWidgets('首页搜索定位功能，使用体验从配置备份移至阅读播放', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: LumeTheme.build(),
        home: const SettingsPage(runtimeAvailable: true),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('settings-search')),
      '后台播放',
    );
    await tester.pumpAndSettle();
    expect(find.text('阅读与播放'), findsOneWidget);
    await tester.tap(find.text('阅读与播放'));
    await tester.pumpAndSettle();
    expect(find.byType(ExperienceSettingsCard), findsOneWidget);
    await tester.scrollUntilVisible(find.text('播放器设置'), 250);
    await tester.tap(find.text('播放器设置'));
    await tester.pumpAndSettle();
    expect(find.text('后台播放'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await tester.pumpWidget(
      MaterialApp(
        theme: LumeTheme.build(),
        home: const ConfigurationSettingsPage(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('后台播放'), findsNothing);
  });
  testWidgets('原生管理只展示系统材质参数，修改染色并保存', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: LumeTheme.build(),
        home: const LiquidGlassSettingsPage(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('启用系统玻璃'), findsNothing);
    expect(find.text('底栏尺寸与位置'), findsNothing);
    expect(find.text('材质风格'), findsOneWidget);
    expect(find.text('调整范围'), findsNothing);
    expect(find.byKey(const ValueKey('glass-blur')), findsNothing);
    expect(find.text('悬浮模块'), findsNothing);
    expect(find.text('导航栏高度'), findsNothing);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('native-glass-tint')),
      240,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.drag(
      find.byKey(const ValueKey('native-glass-tint')),
      const Offset(40, 0),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(() => FrostedSettings.instance.save());
    expect(FrostedSettings.instance.native.tintOpacity, greaterThan(0));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
}
