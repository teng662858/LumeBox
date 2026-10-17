import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/features/settings/configuration_settings_page.dart';

void main() {
  test('light and dark themes preserve the title / description hierarchy', () {
    for (final brightness in Brightness.values) {
      final theme = LumeTheme.build(brightness: brightness);
      expect(theme.textTheme.titleLarge!.fontSize, 20);
      expect(theme.textTheme.headlineSmall!.fontSize, 18);
      expect(theme.textTheme.headlineSmall!.fontWeight, FontWeight.w700);
      expect(theme.listTileTheme.titleTextStyle!.fontSize, 16);
      expect(theme.listTileTheme.subtitleTextStyle!.fontSize, 12);
      expect(
        theme.listTileTheme.subtitleTextStyle!.color,
        brightness == Brightness.light
            ? const Color(0xFF8E8E93)
            : const Color(0xFFAEAEB2),
      );
      expect(
        theme.listTileTheme.subtitleTextStyle!.fontWeight,
        FontWeight.w400,
      );
      expect(theme.listTileTheme.subtitleTextStyle!.height, 1.5);
      expect(theme.textTheme.labelSmall!.fontSize, 12);
    }
  });

  test('off switches have visible tracks and thumbs in both themes', () {
    for (final brightness in Brightness.values) {
      final theme = LumeTheme.build(brightness: brightness);
      final track = theme.switchTheme.trackColor!.resolve({})!;
      final thumb = theme.switchTheme.thumbColor!.resolve({})!;
      expect(
        LumeTheme.contrast(track, theme.scaffoldBackgroundColor),
        greaterThanOrEqualTo(3),
      );
      expect(LumeTheme.contrast(thumb, track), greaterThanOrEqualTo(3));
      for (final states in [
        <WidgetState>{WidgetState.selected},
        <WidgetState>{WidgetState.disabled},
        <WidgetState>{WidgetState.disabled, WidgetState.selected},
      ]) {
        expect(theme.switchTheme.trackColor!.resolve(states)!.a, 1);
        expect(theme.switchTheme.thumbColor!.resolve(states)!.a, 1);
      }
    }
  });

  for (final width in [320.0, 430.0]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('configuration page fits width $width at text scale $scale', (
        tester,
      ) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          MaterialApp(
            theme: LumeTheme.build(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: const ConfigurationSettingsPage(previewIcons: true),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('App 图标'), findsOneWidget);
        expect(find.text('导出配置备份'), findsOneWidget);
        final subtitleStyle = DefaultTextStyle.of(
          tester.element(find.text('全局设置、各版块偏好与源配置')),
        ).style;
        expect(subtitleStyle.fontSize, 12);
        expect(subtitleStyle.color, const Color(0xFF8E8E93));
        expect(subtitleStyle.height, 1.5);
        expect(tester.takeException(), isNull);
        await tester.scrollUntilVisible(find.text('后台播放'), 180);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });
    }
  }
}
