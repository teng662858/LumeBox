import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:lume_box/core/intro/intro_store.dart';
import 'package:lume_box/features/video/player_settings_panel.dart';
import 'package:lume_box/features/video/intro_settings_page.dart';
import 'package:lume_box/features/video/danmaku/danmaku_sources_page.dart';

void main() {
  late IntroStore store;
  late Map<String, String> stored;
  setUp(() {
    store = IntroStore(sqlite3.openInMemory());
    stored = {
      'profilesJson': jsonEncode([
        {
          'id': 'cf',
          'name': '外置CF服务器',
          'type': 'logvar',
          'url': 'https://fixture.test/prefix',
        },
      ]),
      'activeId': 'cf',
    };
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(DanmakuSourcesStore.channel, (
      call,
    ) async {
      if (call.method == 'read') return stored;
      if (call.method == 'write') {
        stored = Map<String, String>.from(call.arguments as Map);
      }
      return null;
    });
  });
  tearDown(() {
    store.dispose();
    store.db.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(DanmakuSourcesStore.channel, null);
  });

  Future<void> open(
    WidgetTester tester,
    Widget page, {
    double scale = 1,
  }) async {
    tester.view.physicalSize = const Size(956, 440);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            backgroundColor: Colors.black,
            body: Center(
              child: TextButton(
                onPressed: () => showPlayerSettingsPanel<void>(
                  context: context,
                  builder: (_) => page,
                ),
                child: const Text('打开设置'),
              ),
            ),
          ),
        ),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
      ),
    );
    await tester.tap(find.text('打开设置'));
    await tester.pumpAndSettle();
  }

  testWidgets('横屏设置保持右侧有限宽面板，三级日志返回上一级，旋转不丢配置', (tester) async {
    await open(tester, IntroSettingsPage(store: store));
    final frame = find.byKey(const ValueKey('danmaku-panel-frame'));
    expect(tester.getSize(frame).width, closeTo(956 * .4, .01));
    expect(tester.getTopLeft(frame).dx, closeTo(956 * .6, .01));
    expect(tester.getSize(frame).height, 440);
    expect(tester.getTopLeft(frame).dy, 0);
    await tester.tap(find.widgetWithText(SwitchListTile, '启用识别'));
    await tester.pumpAndSettle();
    expect(store.value.active, isFalse);
    await tester.ensureVisible(find.text('记录'));
    await tester.tap(find.text('记录'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('查看识别日志'));
    await tester.pumpAndSettle();
    expect(find.text('识别日志'), findsOneWidget);
    expect(tester.getSize(frame).width, closeTo(956 * .4, .01));
    await tester.drag(
      find.byKey(const ValueKey('player-panel-back-edge')),
      const Offset(100, 0),
    );
    await tester.pumpAndSettle();
    expect(find.text('片头片尾识别'), findsOneWidget);
    tester.view.physicalSize = const Size(440, 956);
    await tester.pumpAndSettle();
    expect(find.text('查看识别日志'), findsOneWidget);
    expect(store.value.active, isFalse);
    await tester.tap(find.byTooltip('关闭设置'));
    await tester.pumpAndSettle();
    expect(frame, findsNothing);
    expect(find.text('打开设置'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('弹幕服务的三级编辑留在面板内，键盘避让且可保存到原全局存储', (tester) async {
    await open(tester, const DanmakuSourcesPage());
    await tester.tap(find.byTooltip('编辑弹幕源'));
    await tester.pumpAndSettle();
    expect(find.text('编辑弹幕服务'), findsOneWidget);
    final field = find.widgetWithText(TextField, '名称（可不填）');
    await tester.enterText(field, '我的弹幕服务');
    tester.view.viewInsets = const FakeViewPadding(bottom: 180);
    await tester.pumpAndSettle();
    final frame = find.byKey(const ValueKey('danmaku-panel-frame'));
    expect(tester.getBottomRight(frame).dy, lessThanOrEqualTo(260));
    final save = find.text('保存');
    await tester.scrollUntilVisible(
      save,
      100,
      scrollable: find.descendant(
        of: find.byKey(const ValueKey('danmaku-service-form')),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is Scrollable &&
              widget.axisDirection == AxisDirection.down,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(save);
    await tester.pumpAndSettle();
    tester.view.viewInsets = FakeViewPadding.zero;
    await tester.pumpAndSettle();
    expect(find.text('我的弹幕服务'), findsOneWidget);
    expect(DanmakuSourcesStore.profiles(stored).single['name'], '我的弹幕服务');
    expect(tester.takeException(), isNull);
  });

  testWidgets('大字模式的片头片尾分组和优先级可滚动，无布局溢出', (tester) async {
    await open(tester, IntroSettingsPage(store: store), scale: 2);
    await tester.tap(find.text('识别策略'));
    await tester.pumpAndSettle();
    expect(find.text('识别优先级'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('一级设置既有 pop 回调会关闭整个面板，点击视频区域也可关闭', (tester) async {
    await open(
      tester,
      Builder(
        builder: (context) => Center(
          child: TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('完成'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('danmaku-panel-frame')), findsNothing);
    await tester.tap(find.text('打开设置'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(100, 180));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('danmaku-panel-frame')), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
