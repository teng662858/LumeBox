import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/session/app_preferences.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/features/settings/settings_ui.dart';
import 'package:lume_box/shared/widgets/glass_card.dart';

void main() {
  late List<String> oldShortcuts;
  late File? oldFile;
  late Directory root;
  setUp(() {
    oldShortcuts = AppPreferences.instance.settingsShortcuts;
    oldFile = AppPreferences.instance.file;
    root = Directory.systemTemp.createTempSync('settings-directory');
    AppPreferences.instance.file = File('${root.path}/app_preferences.json');
    AppPreferences.instance.settingsShortcuts = List.of(
      AppPreferences.defaultSettingsShortcuts,
    );
  });
  tearDown(() {
    AppPreferences.instance.settingsShortcuts = oldShortcuts;
    AppPreferences.instance.file = oldFile;
    root.deleteSync(recursive: true);
  });

  Future<void> pump(
    WidgetTester tester, {
    double width = 390,
    double scale = 1,
  }) async {
    tester.view.physicalSize = Size(width, 900);
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
        home: GlassScaffold(
          title: '设置',
          child: SettingsHome(
            categories: [
              SettingsCategory('阅读与播放', '阅读偏好', Icons.menu_book, [
                const SettingsGroupTitle('阅读'),
                SettingsEntryCard(
                  icon: Icons.menu_book,
                  title: '小说设置',
                  onTap: () {},
                ),
                const SettingsGroupTitle('播放'),
                SettingsEntryCard(
                  icon: Icons.play_arrow,
                  title: '播放器设置',
                  onTap: () {},
                ),
              ]),
            ],
            shortcuts: [
              for (final entry in [
                ('appearance', '外观'),
                ('sources', '源管理'),
                ('player', '播放器'),
                ('network', '网络'),
              ])
                SettingsShortcut(entry.$1, entry.$2, Icons.settings, () {}),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('分类进入独立页面，返回后首页不残留展开设置', (tester) async {
    await pump(tester);
    expect(find.text('小说设置'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('settings-category-阅读与播放')));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsCategoryPage), findsOneWidget);
    expect(find.text('小说设置'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('小说设置'), findsNothing);
    expect(
      find.byKey(const ValueKey('edit-settings-shortcuts')),
      findsOneWidget,
    );
  });

  testWidgets('常用入口最多三项，取消不更改，保存写入偏好文件', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('edit-settings-shortcuts')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<CheckboxListTile>(find.widgetWithText(CheckboxListTile, '网络'))
          .onChanged,
      isNull,
    );
    await tester.tap(find.widgetWithText(CheckboxListTile, '源管理'));
    await tester.pump();
    await tester.tap(find.widgetWithText(CheckboxListTile, '网络'));
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expect(AppPreferences.instance.settingsShortcuts, [
      'appearance',
      'sources',
      'player',
    ]);
    await tester.tap(find.byKey(const ValueKey('edit-settings-shortcuts')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(CheckboxListTile, '源管理'));
    await tester.pump();
    await tester.tap(find.widgetWithText(CheckboxListTile, '网络'));
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('settings-shortcut-network')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('settings-shortcut-sources')),
      findsNothing,
    );
    final stored =
        jsonDecode(AppPreferences.instance.file!.readAsStringSync()) as Map;
    expect(stored['settingsShortcuts'], ['appearance', 'player', 'network']);
    await tester.pumpWidget(const SizedBox());
  });

  for (final size in [(320.0, 1.0), (320.0, 2.0), (430.0, 2.0)]) {
    testWidgets('目录与常用入口适配宽 ${size.$1} 字号 ${size.$2}', (tester) async {
      await pump(tester, width: size.$1, scale: size.$2);
      await tester.tap(find.byKey(const ValueKey('settings-category-阅读与播放')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('edit-settings-shortcuts')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
