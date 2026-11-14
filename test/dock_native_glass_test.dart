import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/features/shell/dock_native_glass.dart';
import 'package:lume_box/shared/widgets/frosted_glass_widget.dart';
import 'package:lume_box/shared/widgets/native_glass_surfaces.dart';
import 'package:lume_box/shared/widgets/native_glass_controls.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/core/theme/floating_modules.dart';
import 'package:lume_box/core/shell/shell_settings.dart';
import 'package:lume_box/shared/widgets/glass_card.dart';
import 'package:lume_box/shared/widgets/dock_handle_button.dart';

void main() {
  testWidgets('顶部透明度作用于实际材质，收起圆圈无主题色边框且不重复衰减', (tester) async {
    FloatingModules.instance.set(
      FloatingModule.home,
      const FloatingStyle(opacity: .35),
    );
    addTearDown(() => FloatingModules.instance.reset(FloatingModule.home));
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              GlassPanel(module: FloatingModule.home, child: Text('顶部')),
              DockHandleButton(
                style: DockHandleStyle.currentSection,
                size: 86,
                materialOpacity: .4,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final top = tester.widget<FrostedGlassWidget>(
      find
          .descendant(
            of: find.byType(GlassPanel),
            matching: find.byType(FrostedGlassWidget),
          )
          .first,
    );
    expect(top.opacity, closeTo(.35, .005));
    final handle = find.byType(DockHandleButton);
    expect(tester.getSize(handle), const Size(86, 86));
    final surface = tester.widget<Material>(
      find.descendant(of: handle, matching: find.byType(Material)).first,
    );
    expect(surface.type, MaterialType.transparency);
    expect(find.byType(DockNativeGlass), findsNothing);
    expect(
      find.descendant(of: handle, matching: find.byType(FrostedGlassWidget)),
      findsNothing,
    );
    expect(
      tester
          .widget<Opacity>(
            find.descendant(of: handle, matching: find.byType(Opacity)).first,
          )
          .opacity,
      1,
    );
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('普通卡片按钮控件不创建平台视图，弹层只有一个原生表面', (tester) async {
    final messenger = tester.binding.defaultBinaryMessenger;
    var creations = 0;
    messenger.setMockMethodCallHandler(SystemChannels.platform_views, (
      call,
    ) async {
      if (call.method == 'create') creations++;
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(
        SystemChannels.platform_views,
        null,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: LumeTheme.build(),
        home: Scaffold(
          body: ListView(
            children: [
              for (var i = 0; i < 12; i++)
                FrostedGlassWidget(child: Text('卡片 $i')),
              NativeSwitchListTile.adaptive(value: true, onChanged: (_) {}),
              NativeGlassSlider(value: .5, onChanged: (_) {}),
              Builder(
                builder: (context) => TextButton(
                  onPressed: () => showGlassDialog<void>(
                    context: context,
                    builder: (_) => const AlertDialog(content: Text('普通确认')),
                  ),
                  child: const Text('普通弹窗'),
                ),
              ),
              Builder(
                builder: (context) => FilledButton(
                  onPressed: () => showGlassDialog<void>(
                    nativeGlass: true,
                    context: context,
                    builder: (_) => const AlertDialog(
                      content: FrostedGlassWidget(child: Text('弹层内容')),
                    ),
                  ),
                  child: const Text('打开弹层'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(creations, 0);
    expect(find.byType(DockNativeGlass), findsNothing);
    expect(find.byType(BackdropFilter), findsNothing);
    await tester.tap(find.text('普通弹窗'));
    await tester.pumpAndSettle();
    expect(creations, 0);
    tester.state<NavigatorState>(find.byType(Navigator).first).pop();
    await tester.pumpAndSettle();
    expect(tester.binding.hasScheduledFrame, false);
    await tester.tap(find.text('打开弹层'));
    await tester.pumpAndSettle();
    expect(creations, 1);
    expect(find.byType(DockNativeGlass), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
  testWidgets('全局玻璃使用系统底座，键盘变化保持编辑器与平台视图', (tester) async {
    final messenger = tester.binding.defaultBinaryMessenger;
    var creations = 0;
    messenger.setMockMethodCallHandler(SystemChannels.platform_views, (
      call,
    ) async {
      if (call.method == 'create') creations++;
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(
        SystemChannels.platform_views,
        null,
      ),
    );
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 300,
            height: 160,
            child: FrostedGlassWidget(nativeGlass: true, child: TextField()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(DockNativeGlass), findsOneWidget);
    expect(find.byType(BackdropFilter), findsNothing);
    await tester.tap(find.byType(TextField));
    await tester.pump();
    final editor = tester.state<EditableTextState>(find.byType(EditableText));
    tester.view.viewInsets = const FakeViewPadding(bottom: 250);
    await tester.pumpAndSettle();
    expect(editor.mounted, isTrue);
    expect(editor.widget.focusNode.hasFocus, isTrue);
    expect(creations, 1);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
  testWidgets('原生底座创建期间修改配置，完成后同步最新圆角与主题', (tester) async {
    final gate = Completer<void>();
    final updates = <Map<Object?, Object?>>[];
    final messenger = tester.binding.defaultBinaryMessenger;
    MethodChannel? updateChannel;
    Map<Object?, Object?>? initial;
    messenger.setMockMethodCallHandler(SystemChannels.platform_views, (
      call,
    ) async {
      if (call.method == 'create') {
        final args = call.arguments as Map;
        initial = const StandardMessageCodec().decodeMessage(
          ByteData.sublistView(args['params'] as Uint8List),
        ) as Map<Object?, Object?>;
        updateChannel = MethodChannel('lumebox/glass_backdrop_${args['id']}');
        messenger.setMockMethodCallHandler(updateChannel!, (call) async {
          updates.add(Map<Object?, Object?>.from(call.arguments as Map));
          return null;
        });
        await gate.future;
      }
      return null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(SystemChannels.platform_views, null);
      if (updateChannel != null) {
        messenger.setMockMethodCallHandler(updateChannel!, null);
      }
    });
    Widget scene(double radius, Brightness brightness, bool reduced) =>
        MaterialApp(
          theme: ThemeData(brightness: brightness),
          themeAnimationDuration: Duration.zero,
          home: Center(
            child: SizedBox(
              width: 300,
              height: 64,
              child: DockNativeGlass(
                borderRadius: BorderRadius.circular(radius),
                cornerRadius: radius,
                reduceTransparency: reduced,
              ),
            ),
          ),
        );
    await tester.pumpWidget(scene(32, Brightness.light, false));
    expect(initial?['cornerRadius'], 32);
    await tester.pumpWidget(scene(24, Brightness.dark, true));
    gate.complete();
    await tester.pumpAndSettle();
    expect(updates.last, {
      'style': 'regular',
      'cornerRadius': 24.0,
      'brightness': 'dark',
      'reduceTransparency': true,
      'tintColor': Colors.white.toARGB32(),
      'tintOpacity': .06,
      'materialOpacity': 1.0,
    });
    final count = updates.length;
    await tester.pumpWidget(scene(24, Brightness.dark, true));
    expect(updates.length, count, reason: '相同配置不重复重建系统材质');
    await tester.pumpWidget(scene(30, Brightness.light, false));
    await tester.pumpAndSettle();
    expect(updates.last['cornerRadius'], 30);
    expect(updates.last['brightness'], 'light');
    expect(updates.last['reduceTransparency'], false);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('普通弹窗覆盖时保留底层玻璃，关闭后不重建平台视图', (tester) async {
    final messenger = tester.binding.defaultBinaryMessenger;
    var creations = 0;
    messenger.setMockMethodCallHandler(SystemChannels.platform_views, (
      call,
    ) async {
      if (call.method == 'create') creations++;
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(
        SystemChannels.platform_views,
        null,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              const SizedBox(
                width: 200,
                height: 60,
                child: FrostedGlassWidget(nativeGlass: true, child: Text('玻璃')),
              ),
              Builder(
                builder: (context) => TextButton(
                  onPressed: () => showGlassDialog<void>(
                    context: context,
                    builder: (_) => const AlertDialog(content: Text('输入表单')),
                  ),
                  child: const Text('打开'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(UiKitView), findsOneWidget);
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(find.byType(UiKitView), findsOneWidget);
    tester.state<NavigatorState>(find.byType(Navigator).first).pop();
    await tester.pumpAndSettle();
    expect(find.byType(UiKitView), findsOneWidget);
    expect(creations, 1);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  test('修改任一玻璃效果开关保留降低透明度偏好', () {
    final settings = const DockLiquidSettings().withReduceTransparency(true);
    for (final effect in DockLiquidEffect.values) {
      expect(settings.withEnabled(effect, false).reduceTransparency, isTrue);
    }
  });
}
