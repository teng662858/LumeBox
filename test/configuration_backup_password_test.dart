import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/features/settings/configuration_settings_page.dart';

void main() {
  testWidgets(
    'Configuration export requires a matching password; cancellation creates no export',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: ConfigurationSettingsPage()),
      );
      await tester.tap(find.text('导出配置备份'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('设置备份密码'), findsOneWidget);
      final fields = find.byType(TextField);
      expect(fields, findsNWidgets(2));
      expect(tester.widget<TextField>(fields.first).obscureText, isTrue);
      expect(tester.widget<TextField>(fields.last).obscureText, isTrue);
      await tester.enterText(fields.first, 'long-password');
      await tester.enterText(fields.last, 'does-not-match');
      await tester.tap(find.text('继续'));
      await tester.pump();
      expect(find.text('密码至少 8 位，两次输入须一致'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('设置备份密码'), findsNothing);
    },
  );
}
