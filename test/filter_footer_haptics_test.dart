import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/session/app_preferences.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/features/reading/browse_choice_access.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final height in [667.0, 844.0]) {
    testWidgets('筛选页 $height 高度悬浮操作卡固定，末行标签可见', (tester) async {
      tester.view.physicalSize = Size(390, height);
      tester.view.devicePixelRatio = 1;
      tester.view.padding = const FakeViewPadding(bottom: 34);
      tester.view.viewPadding = const FakeViewPadding(bottom: 34);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showBrowseFilters(
                  context: context,
                  categories: [
                    for (var i = 0; i < 100; i++)
                      SourceCategory(id: '$i', title: '分类$i'),
                  ],
                  groups: const [],
                  category: null,
                  filters: const {},
                ),
                child: const Text('筛选'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('筛选'));
      await tester.pumpAndSettle();
      final actions = find.byKey(const Key('filter-actions'));
      final options = find.byKey(const Key('filter-options'));
      final before = tester.getRect(actions);
      final footer = tester.getRect(find.byKey(const Key('filter-footer')));
      expect(before.left, 24);
      expect(
        before.right,
        tester
                .getRect(find.byKey(const Key('classification-drawer-frame')))
                .right -
            24,
      );
      expect(height - footer.bottom, 34);
      expect(footer.height, 64);
      expect(before.top - tester.getRect(options).bottom, 8);
      await tester.ensureVisible(find.text('分类99'));
      await tester.pumpAndSettle();
      expect(tester.getRect(actions), before);
      expect(
        tester.getRect(find.text('分类99')).bottom,
        lessThanOrEqualTo(tester.getRect(options).bottom),
      );
      final beforeKeyboard = tester.getRect(actions);
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      await tester.pumpAndSettle();
      expect(beforeKeyboard.bottom - tester.getRect(actions).bottom, 280);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('应用筛选'));
      await tester.pumpAndSettle();
      expect(find.text('分类与筛选'), findsNothing);
    });
  }
  test('触感三档调用对应原生反馈、关闭无反馈且强度本地保存', () async {
    final root = Directory.systemTemp.createTempSync('haptic-strength-');
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => root.path,
        );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'HapticFeedback.vibrate') {
            calls.add(call.arguments as String);
          }
          return null;
        });
    try {
      final preferences = AppPreferences();
      await preferences.boot();
      preferences.haptics = true;
      for (final strength in HapticStrength.values) {
        preferences.hapticStrength = strength;
        await preferences.selectionFeedback();
      }
      expect(calls, [
        'HapticFeedbackType.lightImpact',
        'HapticFeedbackType.mediumImpact',
        'HapticFeedbackType.heavyImpact',
      ]);
      preferences.save();
      final reopened = AppPreferences();
      await reopened.boot();
      expect(reopened.haptics, isTrue);
      expect(reopened.hapticStrength, HapticStrength.strong);
      reopened.haptics = false;
      await reopened.selectionFeedback();
      expect(calls.length, 3);
    } finally {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
      root.deleteSync(recursive: true);
    }
  });
}
