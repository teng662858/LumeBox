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
import 'package:lume_box/features/video/player_settings_sheet.dart';
import 'package:lume_box/core/player/player_capabilities.dart';
import 'package:lume_box/core/player/player_settings.dart';

/// 播放方向偏好（用户要求）：
/// - 全局设置里的「横屏播放」开关；
/// - 播放器设置弹窗里的「方向锁定」（自动 / 强制横屏 / 强制竖屏）；
/// 两者写的是**同一份**应用级偏好，落盘一个小 JSON，坏值回退「自动」。
///
/// 播放器页自己的行为（按视频宽高比自动选方向、锁定覆盖自动判断）在
/// `player_full_feature_test.dart` 里验证——那里有真实的播放器替身与平台通道。
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

  group('全局设置：横屏播放', () {
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
      await tester.ensureVisible(find.text('画面与显示'));
      await tester.tap(find.text('画面与显示'));
      await tester.pumpAndSettle();
    }

    testWidgets('画面分类统一设置方向，强制横屏与自动写入同一偏好', (tester) async {
      await pumpSettings(tester);
      expect(find.text('横屏播放'), findsNothing, reason: '避免重复的两档方向开关');
      await tester.tap(find.widgetWithText(ChoiceChip, '强制横屏'));
      await tester.pumpAndSettle();
      expect(
        PlaybackOrientationController.instance.orientation,
        PlaybackOrientation.landscape,
      );
      await tester.tap(find.widgetWithText(ChoiceChip, '自动'));
      await tester.pumpAndSettle();
      expect(
        PlaybackOrientationController.instance.orientation,
        PlaybackOrientation.auto,
      );
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
