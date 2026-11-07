import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lume_box/shared/widgets/frosted_glass_widget.dart';
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

  testWidgets('常用入口最多四项，取消不更改，保存写入偏好文件', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('edit-settings-shortcuts')));
    await tester.pumpAndSettle();
    final fourth = find.widgetWithText(CheckboxListTile, '网络');
    expect(tester.widget<CheckboxListTile>(fourth).onChanged, isNotNull);
    await tester.tap(fourth);
    await tester.pumpAndSettle();
    expect(find.text('选择 1–4 项，按选择顺序排列（4/4）'), findsOneWidget);
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expect(
      AppPreferences.instance.settingsShortcuts,
      AppPreferences.defaultSettingsShortcuts,
    );
    await tester.tap(find.byKey(const ValueKey('edit-settings-shortcuts')));
    await tester.pumpAndSettle();
    await tester.tap(fourth);
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(AppPreferences.instance.settingsShortcuts, [
      'appearance',
      'sources',
      'player',
      'network',
    ]);
    expect(
      (jsonDecode(AppPreferences.instance.file!.readAsStringSync())
          as Map)['settingsShortcuts'],
      ['appearance', 'sources', 'player', 'network'],
    );
    final boxes = <Rect>[];
    for (final id in AppPreferences.instance.settingsShortcuts) {
      final finder = find.byKey(ValueKey('settings-shortcut-$id'));
      boxes.add(tester.getRect(finder));
      expect(
        find.descendant(of: finder, matching: find.byType(FrostedGlassWidget)),
        findsNothing,
      );
    }
    expect(
      tester
          .widget<FrostedGlassWidget>(
            find.byKey(const ValueKey('settings-shortcuts-glass')),
          )
          .nativeGlass,
      isTrue,
    );
    expect(boxes.map((r) => r.top).toSet(), hasLength(1), reason: '四项在同一行');
    expect(boxes[0].left, lessThan(boxes[1].left));
    expect(boxes[2].left, lessThan(boxes[3].left));
    expect(tester.takeException(), isNull);
  });

  test('四个入口从偏好文件恢复时不截断，顺序不变', () async {
    final file = AppPreferences.instance.file!;
    file.writeAsStringSync(
      jsonEncode({
        'settingsShortcuts': ['network', 'player', 'sources', 'appearance'],
      }),
    );
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    messenger.setMockMethodCallHandler(channel, (_) async => root.path);
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final restored = AppPreferences();
    await restored.boot();
    expect(restored.settingsShortcuts, [
      'network',
      'player',
      'sources',
      'appearance',
    ]);
  });

  for (final size in [(320.0, 1.0), (320.0, 2.0), (430.0, 2.0)]) {
    testWidgets('目录与常用入口适配宽 ${size.$1} 字号 ${size.$2}', (tester) async {
      AppPreferences.instance.settingsShortcuts = [
        'appearance',
        'sources',
        'player',
        'network',
      ];
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
