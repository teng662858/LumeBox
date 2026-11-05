import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/net/private_github_subscription.dart';
import 'package:lume_box/features/settings/private_subscription_settings_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'readonly token is saved separately and never displayed when reopening',
    (tester) async {
      const channel = MethodChannel('lumebox/source_repository');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      String saved = '';
      final methods = <String>[];
      PrivateGithubSubscription.resetForTesting();
      messenger.setMockMethodCallHandler(channel, (call) async {
        methods.add(call.method);
        if (call.method == 'privateRead') return saved;
        if (call.method == 'privateWrite') {
          saved = call.arguments as String;
          return null;
        }
        fail('unexpected write credential method');
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(channel, null);
        PrivateGithubSubscription.resetForTesting();
      });
      await tester.pumpWidget(
        const MaterialApp(home: PrivateSubscriptionSettingsPage()),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Contents: read Token'),
        'only-read-token',
      );
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(jsonDecode(saved)['token'], 'only-read-token');
      expect(methods, contains('privateWrite'));
      expect(methods, isNot(contains('write')));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(
        const MaterialApp(home: PrivateSubscriptionSettingsPage()),
      );
      await tester.pumpAndSettle();
      final field = tester.widget<TextField>(
        find.widgetWithText(TextField, 'Contents: read Token'),
      );
      expect(field.controller!.text, isEmpty);
      expect(field.obscureText, true);
      expect(find.text('已保存；留空保持原 Token'), findsOneWidget);
      await tester.tap(find.text('移除授权'));
      await tester.pumpAndSettle();
      expect(saved, isEmpty);
    },
  );
}
