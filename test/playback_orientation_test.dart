import 'dart:io';

import 'package:lume_box/core/reading/reading.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/player/playback_orientation.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/features/settings/settings_page.dart';
import 'package:lume_box/features/video/native_video_settings_page.dart';
import 'package:lume_box/features/video/player_settings_sheet.dart';
import 'package:lume_box/core/player/player_capabilities.dart';
import 'package:lume_box/core/player/player_settings.dart';

/// 兼容旧面板的方向偏好，并验证正式设置入口只展示原生播放器使用的参数。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;

  void mockPathProvider(String? path) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async =>
              call.method == 'getApplicationSupportDirectory' ? path : null,
        );
  }

  setUp(() async {
    root = Directory.systemTemp.createTempSync('lume_box_orientation');
    mockPathProvider(root.path);
    PlaybackOrientationStore.resetForTesting();
    PlaybackOrientationController.instance.resetForTesting();
    await SectionScope.open(Section.video);
    await ReadingLibrary.open(Section.video);
  });

  tearDown(() async {
    PlaybackOrientationController.instance.resetForTesting();
    PlaybackOrientationStore.resetForTesting();
    ReadingLibrary.disposeAll();
    ReadingStore.disposeAll();
    await SectionScope.closeAll();
    mockPathProvider(null);
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  group('方向偏好的落盘（应用级 JSON）', () {
    test('缺文件 = 默认「自动」；写读一致', () async {
      final store = await PlaybackOrientationStore.open();
      expect(store.load(), PlaybackOrientation.auto, reason: '没存过就是自动');

      store.save(PlaybackOrientation.landscape);
      expect(store.load(), PlaybackOrientation.landscape);

      store.save(PlaybackOrientation.portrait);
      expect(store.load(), PlaybackOrientation.portrait);
    });

    test('坏值 / 坏文件只回退默认，不抛异常', () async {
      final store = await PlaybackOrientationStore.open();
      File(store.path).writeAsStringSync('{ this is not json');
      expect(store.load(), PlaybackOrientation.auto);

      File(store.path).writeAsStringSync('{"orientation":"sideways"}');
      expect(store.load(), PlaybackOrientation.auto, reason: '认不出的档位回退自动');
    });

    test('控制器：启动读盘、apply 落盘、通知监听者', () async {
      final store = await PlaybackOrientationStore.open();
      store.save(PlaybackOrientation.portrait);

      final controller = PlaybackOrientationController.instance;
      var notified = 0;
      controller.addListener(() => notified++);
      await controller.boot();
      expect(
        controller.orientation,
        PlaybackOrientation.portrait,
        reason: '启动读盘',
      );
      expect(notified, 1);

      controller.apply(PlaybackOrientation.landscape);
      expect(notified, 2);
      expect(store.load(), PlaybackOrientation.landscape, reason: 'apply 落盘');
    });
  });

  group('全局播放器设置', () {
    Future<void> pumpSettings(WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: LumeTheme.build(),
          home: const SettingsPage(runtimeAvailable: true),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('阅读与播放'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('播放器设置'));
      await tester.pumpAndSettle();
    }

    testWidgets('进入原生播放器设置时不显示旧版方向控件', (tester) async {
      await pumpSettings(tester);
      expect(find.byType(NativeVideoSettingsPage), findsOneWidget);
      expect(find.text('默认播放内核'), findsOneWidget);
      expect(find.text('画面与显示'), findsNothing);
      expect(find.text('横屏播放'), findsNothing);
    });
  });

  group('播放器设置弹窗：方向锁定', () {
    Future<void> pumpSheet(WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: LumeTheme.build(),
          home: Scaffold(
            // 内嵌面板本身不再自带滚动视图（滚动由宿主页面提供），
            // 测试里补一个——与全局设置页同构。
            body: SingleChildScrollView(
              child: PlayerSettingsSheet(
                settings: const PlayerSettings(),
                capabilities: PlayerCapabilities.of(PlayerKernel.avplayer),
                onChanged: (_) {},
                embedded: true,
                orientation: PlaybackOrientationController.instance.orientation,
                onOrientationChanged:
                    PlaybackOrientationController.instance.apply,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('三档芯片：点击写入应用级偏好（与「横屏播放」同一份）', (tester) async {
      await pumpSheet(tester);

      expect(find.text('方向锁定'), findsWidgets);
      for (final mode in PlaybackOrientation.values) {
        expect(find.widgetWithText(ChoiceChip, mode.label), findsOneWidget);
      }

      await tester.ensureVisible(find.widgetWithText(ChoiceChip, '强制横屏'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, '强制横屏'));
      await tester.pumpAndSettle();
      expect(
        PlaybackOrientationController.instance.orientation,
        PlaybackOrientation.landscape,
      );

      await tester.tap(find.widgetWithText(ChoiceChip, '强制竖屏'));
      await tester.pumpAndSettle();
      expect(
        PlaybackOrientationController.instance.orientation,
        PlaybackOrientation.portrait,
      );
      expect(find.textContaining('竖屏全屏'), findsWidgets, reason: '说明文案跟着档位');
    });
  });
}
