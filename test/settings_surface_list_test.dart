import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/session/app_preferences.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/features/experience/experience_settings_page.dart';
import 'package:lume_box/features/experience/subtitle_center_page.dart';
import 'package:lume_box/shared/widgets/glass_card.dart';

void main() {
  for (final brightness in Brightness.values) {
    testWidgets('输入框只有一层卡面，聚焦有提示，实心按钮不再套卡片 $brightness', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: LumeTheme.build(brightness: brightness),
          home: Scaffold(
            body: SettingsSurfaceList(
              children: [
                const TextField(decoration: InputDecoration(labelText: '订阅地址')),
                FilledButton(onPressed: () {}, child: const Text('导入')),
                OutlinedButton(onPressed: () {}, child: const Text('导出')),
              ],
            ),
          ),
        ),
      );
      final field = find.byType(TextField);
      expect(
        find.ancestor(of: field, matching: find.byType(GlassCard)),
        findsOneWidget,
      );
      final decorator = find.descendant(
        of: field,
        matching: find.byType(InputDecorator),
      );
      expect(
        tester.widget<InputDecorator>(decorator).decoration.filled,
        isFalse,
      );
      expect(
        tester.widget<InputDecorator>(decorator).decoration.enabledBorder,
        InputBorder.none,
      );
      await tester.tap(field);
      await tester.pumpAndSettle();
      expect(
        tester.widget<InputDecorator>(decorator).decoration.focusedBorder,
        isA<UnderlineInputBorder>(),
      );
      expect(
        find.ancestor(of: find.text('导入'), matching: find.byType(GlassCard)),
        findsNothing,
      );
      expect(
        find.ancestor(of: find.text('导出'), matching: find.byType(GlassCard)),
        findsOneWidget,
      );
      await tester.enterText(field, 'https://example.test/subscription');
      expect(find.text('https://example.test/subscription'), findsOneWidget);
    });
  }
  setUp(() {
    AppPreferences.instance.file = null;
    AppPreferences.instance.experience = {};
  });
  for (final brightness in Brightness.values) {
    testWidgets('增强与字幕内部控件使用悬浮卡片，窄屏大字可操作 $brightness', (tester) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      Future<void> show(Widget page) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: LumeTheme.build(brightness: brightness),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: const TextScaler.linear(1.3)),
              child: child!,
            ),
            home: page,
          ),
        );
        await tester.pumpAndSettle();
      }

      await show(const ExperienceSettingsPage());
      expect(
        find.ancestor(of: find.text('字幕中心'), matching: find.byType(GlassCard)),
        findsOneWidget,
      );
      final toggle = find.widgetWithText(SwitchListTile, '回到前台自动检查更新');
      await tester.scrollUntilVisible(toggle, 150);
      expect(
        find.ancestor(of: toggle, matching: find.byType(GlassCard)),
        findsOneWidget,
      );
      final before = tester.widget<SwitchListTile>(toggle).value;
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(toggle).value, !before);
      expect(tester.takeException(), isNull);
      await show(const SubtitleCenterPage());
      expect(
        find.ancestor(
          of: find.byType(TextField).first,
          matching: find.byType(GlassCard),
        ),
        findsOneWidget,
      );
      await tester.enterText(find.byType(TextField).first, '测试作品');
      expect(find.text('测试作品'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
