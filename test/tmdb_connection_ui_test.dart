import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lume_box/core/tmdb/tmdb.dart';
import 'package:lume_box/features/settings/tmdb_settings_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  setUp(() async {
    root = Directory.systemTemp.createTempSync('tmdb-connection-ui');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => root.path,
        );
    await TmdbSettings.instance.boot();
  });
  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });
  testWidgets('官方 API 测试显示具体 DNS 诊断，失败后按钮恢复可重试', (tester) async {
    await tester.binding.setSurfaceSize(const Size(500, 1100));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    TmdbSettings.instance.enabled = true;
    await tester.pumpWidget(
      MaterialApp(
        home: TmdbSettingsPage(
          clientFactory: (settings) => TmdbClient(
            settings,
            client: MockClient(
              (_) async => throw http.ClientException('Failed host lookup'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final testApi = find.widgetWithText(OutlinedButton, '测试 API 连接');
    await tester.scrollUntilVisible(
      testApi.hitTestable(),
      200,
      scrollable: find.ancestor(of: testApi, matching: find.byType(Scrollable)).first,
    );
    await tester.tap(testApi);
    await tester.pumpAndSettle();
    expect(find.textContaining('DNS 解析失败'), findsOneWidget);
    expect(find.textContaining('TMDB 官方API地址'), findsOneWidget);
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<OutlinedButton>(
            find.widgetWithText(OutlinedButton, '测试 API 连接'),
          )
          .onPressed,
      isNotNull,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    var flushed = false;
    TmdbSettings.instance.flush().then((_) => flushed = true);
    for (var i = 0; i < 60 && !flushed; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    expect(flushed, isTrue);
  });
}
