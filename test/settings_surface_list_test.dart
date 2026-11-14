import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/session/app_preferences.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/features/experience/experience_settings_page.dart';
import 'package:lume_box/features/experience/subtitle_center_page.dart';
import 'package:lume_box/shared/widgets/glass_card.dart';

void main() {
  testWidgets('字幕中心合并后可以保存文件，取消保存仍留在字幕中心', (tester) async {
    final dir = Directory.systemTemp.createTempSync('subtitle-export-');
    final captions = [
      for (final name in ['甲', '乙'])
        File('${dir.path}/$name.srt')
          ..writeAsStringSync('1\n00:00:01,000 --> 00:00:02,000\n$name\n'),
    ];
    final destination = File('${dir.path}/saved.vtt');
    const paths = MethodChannel('plugins.flutter.io/path_provider');
    const picker = MethodChannel('plugins.flutter.io/file_selector');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var cancelSave = false;
    messenger.setMockMethodCallHandler(paths, (_) async => dir.path);
    messenger.setMockMethodCallHandler(picker, (call) async {
      if (call.method == 'openFile') {
        expect(call.arguments['multiple'], true);
        expect(call.arguments['acceptedTypeGroups'].single['uniformTypeIdentifiers'],
            contains('public.data'));
        return captions.map((f) => f.path).toList();
      }
      expect(call.method, 'getSavePath');
      expect(call.arguments['suggestedName'], 'lumebox-bilingual.vtt');
      return cancelSave ? null : destination.path;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(paths, null);
      messenger.setMockMethodCallHandler(picker, null);
      dir.deleteSync(recursive: true);
    });
    await tester.pumpWidget(const MaterialApp(home: SubtitleCenterPage()));
    for (final cancel in [false, true]) {
      cancelSave = cancel;
      final status = find.text(cancel ? '已取消导出' : '字幕已导出');
      await tester.runAsync(() => tester.tap(find.text('选择两个本地字幕合成双语')));
      final timeout = Stopwatch()..start();
      while (status.evaluate().isEmpty && timeout.elapsed < const Duration(seconds: 3)) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump();
      }
      expect(status, findsOneWidget);
    }
    expect(destination.readAsStringSync(), contains('甲\n乙'));
  });
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
