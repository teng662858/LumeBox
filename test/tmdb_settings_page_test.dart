import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/core/tmdb/tmdb.dart';
import 'package:lume_box/features/settings/tmdb_settings_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  setUp(() async {
    root = Directory.systemTemp.createTempSync('tmdb-ui');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => root.path,
        );
    final settings = TmdbSettings.instance;
    await settings.boot();
    await settings.disconnect();
    settings.posterStyle = TmdbPosterStyle.fixed;
  });
  tearDown(() async {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });
  testWidgets('本地开关、样式、输入清除与确认断开连接', (tester) async {
    await tester.binding.setSurfaceSize(const Size(500, 1100));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(theme: LumeTheme.build(), home: const TmdbSettingsPage()),
    );
    await tester.pumpAndSettle();
    expect(find.text('TMDB配置'), findsOneWidget);
    final appearance = tester.widget<ExpansionTile>(
      find.byKey(const Key('tmdb-appearance-section')),
    );
    expect(appearance.tilePadding, const EdgeInsets.symmetric(horizontal: 16));
    expect(
      appearance.childrenPadding,
      const EdgeInsets.fromLTRB(16, 0, 16, 12),
    );
    // 全局表单兜底：浅色输入框纯白底 + 浅灰边框；切换器同款。
    final theme = Theme.of(tester.element(find.byType(TmdbSettingsPage)));
    expect(theme.inputDecorationTheme.fillColor, Colors.white);
    expect(
      (theme.inputDecorationTheme.enabledBorder! as OutlineInputBorder)
          .borderSide
          .color,
      LumeTheme.inputBorder,
    );
    expect(find.byType(SegmentedButton<TmdbPosterStyle>), findsOneWidget);
    expect(
      find.byType(DropdownButtonFormField<String>),
      findsNWidgets(TmdbImageKind.values.length),
    );
    expect(
      tester
          .widget<OutlinedButton>(
            find.widgetWithText(OutlinedButton, '测试 API 连接'),
          )
          .onPressed,
      isNull,
    );
    await tester.tap(find.byType(Switch).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('随机'));
    await tester.pumpAndSettle();
    expect(TmdbSettings.instance.posterStyle, TmdbPosterStyle.random);
    Finder input(String label) => find.byWidgetPredicate(
      (widget) => widget is TextField && widget.decoration?.labelText == label,
    );
    await tester.enterText(input('API Key'), 'fixture-key');
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('清除 API Key'));
    await tester.pumpAndSettle();
    expect(TmdbSettings.instance.apiKey, isEmpty);
    await tester.enterText(input('API Key'), 'fixture-key');
    await tester.enterText(input('API代理地址'), 'proxy.test');
    await tester.enterText(input('图片代理地址'), 'https://images.test/t/p');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('断开连接'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('断开连接'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(TmdbSettings.instance.enabled, isTrue);
    expect(TmdbSettings.instance.apiKey, 'fixture-key');
    await tester.tap(find.text('断开连接'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '断开'));
    await tester.pumpAndSettle();
    expect(TmdbSettings.instance.enabled, isFalse);
    expect(TmdbSettings.instance.apiKey, isEmpty);
    expect(TmdbSettings.instance.apiProxy, isEmpty);
    expect(TmdbSettings.instance.imageProxy, isEmpty);
    var flushed = false;
    TmdbSettings.instance.flush().then((_) => flushed = true);
    for (var i = 0; i < 60 && !flushed; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    expect(flushed, isTrue);
    final reopened = TmdbSettings();
    await tester.runAsync(reopened.boot);
    expect(reopened.enabled, isFalse);
    expect(reopened.apiKey, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
