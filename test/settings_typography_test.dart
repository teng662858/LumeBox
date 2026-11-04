import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/features/settings/configuration_settings_page.dart';
import 'package:lume_box/features/settings/settings_ui.dart';
import 'package:lume_box/shared/widgets/glass_card.dart';

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

  testWidgets(
    'settings text follows dark mode and the regular weight preference',
    (tester) async {
      for (final brightness in Brightness.values) {
        LumeTheme.applyBrightness(brightness);
        await tester.pumpWidget(
          MaterialApp(
            key: ValueKey(brightness),
            theme: LumeTheme.build(brightness: brightness, fontBold: false),
            home: const GlassScaffold(
              effectModule: GlassModule.settings,
              child: Column(
                children: [
                  SettingsPageIntro(title: '页面标题', description: '页面说明'),
                  ListTile(title: Text('设置标题'), subtitle: Text('设置说明')),
                  SettingsFooterNote('底部说明'),
                ],
              ),
            ),
          ),
        );
        final title = tester.widget<Text>(find.text('页面标题'));
        expect(title.style!.fontSize, 24);
        expect(title.style!.fontWeight, FontWeight.w400);
        final tileTheme = Theme.of(tester.element(find.text('设置标题')))
            .listTileTheme;
        expect(tileTheme.titleTextStyle!.fontSize, 16);
        expect(tileTheme.titleTextStyle!.fontWeight, FontWeight.w400);
        expect(tileTheme.subtitleTextStyle!.fontSize, 12);
        final footer = tester.widget<Text>(find.text('底部说明'));
        expect(footer.style!.fontSize, 12);
        expect(
          footer.style!.color,
          brightness == Brightness.light
              ? const Color(0xFF8E8E93)
              : const Color(0xFFAEAEB2),
        );
      }
      LumeTheme.applyBrightness(Brightness.light);
    },
  );

  testWidgets('settings form labels stay inside their fields with large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = TextEditingController(text: '已填写内容');
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: LumeTheme.build(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: GlassScaffold(
          effectModule: GlassModule.settings,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: controller,
              decoration: const InputDecoration(labelText: '上色提示词'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(
      tester.getRect(find.text('上色提示词')).top,
      greaterThanOrEqualTo(tester.getRect(find.byType(TextField)).top),
    );
    expect(find.text('已填写内容'), findsOneWidget);
  });

  testWidgets('grouped settings keep one separator between options', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: LumeTheme.build(),
        home: const GlassScaffold(
          effectModule: GlassModule.settings,
          child: SettingsGroupCard(
            children: [
              ListTile(title: Text('第一项')),
              ListTile(title: Text('第二项')),
              ListTile(title: Text('第三项')),
            ],
          ),
        ),
      ),
    );
    expect(find.byType(SettingsDivider), findsNWidgets(2));
    expect(find.text('第一项'), findsOneWidget);
    expect(find.text('第三项'), findsOneWidget);
    expect(tester.takeException(), isNull);
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
        final subtitleStyle = tester
            .widget<Text>(find.text('使用密码加密全局设置、各版块偏好与源配置'))
            .style!;
        expect(subtitleStyle.fontSize, 12);
        expect(subtitleStyle.color, const Color(0xFF8E8E93));
        expect(subtitleStyle.height, 1.5);
        expect(tester.takeException(), isNull);
        expect(find.text('后台播放'), findsNothing);
        await tester.scrollUntilVisible(find.text('自动备份'), 180);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });
    }
  }
}
