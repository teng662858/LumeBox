import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/theme/frosted_settings.dart';
import 'package:lume_box/features/shell/dock_native_glass.dart';
import 'package:lume_box/features/video/danmaku/danmaku_panel.dart';
import 'package:lume_box/features/video/playback_glass.dart';
import 'package:lume_box/shared/widgets/frosted_glass_widget.dart';
import 'package:lume_box/shared/widgets/player_appearance_scope.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory settingsDirectory;
  setUpAll(() async {
    settingsDirectory = await Directory.systemTemp.createTemp(
      'drawer-settings-',
    );
    await FrostedSettings.instance.boot(directory: settingsDirectory);
  });
  tearDownAll(() async {
    await FrostedSettings.instance.save();
    await settingsDirectory.delete(recursive: true);
  });

  for (final landscape in [true, false]) {
    testWidgets('抽屉${landscape ? '从右侧' : '从底部'}进入，遮罩不随面板移动', (tester) async {
      tester.view.physicalSize = landscape
          ? const Size(932, 430)
          : const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showDanmakuPanel<void>(
                  context: context,
                  builder: (_) => const SizedBox.expand(key: Key('content')),
                ),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      final moving = tester.getRect(find.byKey(const Key('content')));
      final barrier = find.byType(ModalBarrier).last;
      expect(tester.getRect(barrier), Offset.zero & tester.view.physicalSize);
      await tester.pumpAndSettle();
      final settled = tester.getRect(find.byKey(const Key('content')));
      if (landscape) {
        expect(moving.left, greaterThan(settled.left));
        expect(moving.top, settled.top);
        expect(moving.height, settled.height);
        expect(settled.right, 932);
      } else {
        expect(moving.top, greaterThan(settled.top));
        expect(moving.left, settled.left);
      }
      // The entire area outside the drawer dismisses it.
      await tester.tapAt(const Offset(40, 100));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('content')), findsNothing);
      expect(PlayerPanelActivity.depth.value, 0);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('原生控制条在整个抽屉进退期间降级，嵌套只保留顶层原生材质', (tester) async {
    tester.view.physicalSize = const Size(932, 430);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final settings = FrostedSettings.instance;
    await tester.runAsync(() async {
      await settings.setPlayerNative(true);
    });
    addTearDown(() async {
      await settings.setPlayerNative(false);
    });
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      SystemChannels.platform_views,
      (_) async => null,
    );
    addTearDown(
      () => messenger.setMockMethodCallHandler(
        SystemChannels.platform_views,
        null,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerAppearanceScope(
          child: Scaffold(
            body: Column(
              children: [
                const PlaybackGlass(
                  enabled: false,
                  dark: true,
                  child: SizedBox(width: 600, height: 60, child: Text('顶部')),
                ),
                Builder(
                  builder: (context) => TextButton(
                    onPressed: () => showDanmakuPanel<void>(
                      context: context,
                      builder: (context) => Center(
                        child: TextButton(
                          onPressed: () => showDanmakuPanel<void>(
                            context: context,
                            builder: (_) => const Center(child: Text('二级内容')),
                          ),
                          child: const Text('二级抽屉'),
                        ),
                      ),
                    ),
                    child: const Text('打开'),
                  ),
                ),
                const PlaybackGlass(
                  enabled: false,
                  dark: true,
                  child: SizedBox(width: 600, height: 60, child: Text('底部')),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(UiKitView), findsNWidgets(2));
    final material = tester.widget<FrostedGlassWidget>(
      find.byType(FrostedGlassWidget).first,
    );
    expect(material.opacity, FrostedSettings.defaultPlayerGlassShade);
    expect(material.nativeBaseOpacity, FrostedSettings.defaultPlayerGlassShade);
    expect(material.nativeBrightness, Brightness.light);
    expect(material.color, Colors.black);
    final backdrop = tester.widget<DockNativeGlass>(
      find.byType(DockNativeGlass).first,
    );
    expect(backdrop.brightness, Brightness.light);
    expect(backdrop.materialOpacity, 1, reason: '深浅只调底色，保留系统折射和高光');
    await tester.tap(find.text('打开'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(find.byType(UiKitView), findsNothing);
    expect(PlayerPanelActivity.depth.value, 1);
    await tester.pumpAndSettle();
    expect(find.byType(UiKitView), findsOneWidget);
    await tester.tap(find.text('二级抽屉'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(find.byType(UiKitView), findsNothing);
    await tester.pumpAndSettle();
    expect(PlayerPanelActivity.depth.value, 2);
    expect(find.byType(UiKitView), findsOneWidget);
    final navigator = tester.state<NavigatorState>(
      find.byType(Navigator).first,
    );
    navigator.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(PlayerPanelActivity.depth.value, 2);
    expect(find.byType(UiKitView), findsNothing);
    await tester.pumpAndSettle();
    expect(PlayerPanelActivity.depth.value, 1);
    expect(find.byType(UiKitView), findsOneWidget);
    navigator.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(PlayerPanelActivity.depth.value, 1);
    expect(find.byType(UiKitView), findsNothing);
    await tester.pumpAndSettle();
    expect(PlayerPanelActivity.depth.value, 0);
    expect(find.byType(UiKitView), findsNWidgets(2));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('竖屏保留下滑关闭，减少动态效果时直接展示', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDanmakuPanel<void>(
                context: context,
                builder: (_) => const SizedBox.expand(key: Key('content')),
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pump();
    final content = find.byKey(const Key('content'));
    final route = ModalRoute.of(tester.element(content))!;
    expect(route.animation!.status, AnimationStatus.completed);
    await tester.dragFrom(tester.getCenter(content), const Offset(0, 100));
    await tester.pumpAndSettle();
    expect(content, findsNothing);
    expect(PlayerPanelActivity.depth.value, 0);
    expect(tester.takeException(), isNull);
  });
}
