import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/theme/frosted_settings.dart';
import 'package:lume_box/shared/widgets/frosted_glass_widget.dart';
import 'package:lume_box/features/settings/liquid_glass_settings_page.dart';
import 'package:lume_box/features/comic/comic_glass_backdrop.dart';
import 'package:lume_box/features/shell/dock_native_glass.dart';
import 'package:lume_box/shared/widgets/glass_card.dart';
import 'package:lume_box/shared/widgets/native_glass_controls.dart';
import 'package:lume_box/shared/widgets/native_glass_preview.dart';
import 'package:lume_box/shared/widgets/native_glass_surfaces.dart';
import 'package:lume_box/shared/widgets/video_glass_surface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  setUp(() async {
    directory = Directory.systemTemp.createTempSync('lume-frosted');
    await FrostedSettings.instance.boot(directory: directory);
  });
  tearDown(() => directory.deleteSync(recursive: true));
  test(
    'lightweight mode persists without overwriting transparency preferences',
    () async {
      final settings = FrostedSettings.instance;
      await settings.setLightweight(true);
      expect(settings.reduceTransparency, true);
      final restored = FrostedSettings();
      await restored.boot(directory: directory);
      expect(restored.lightweight, true);
      await restored.setLightweight(false);
      expect(restored.reduceTransparency, false);
      expect(restored.frostedEnabled, true);
      restored.dispose();
    },
  );

  test('only the ordinary blur preference migrates and persists', () async {
    await File('${directory.path}/glass_effects_settings.json').writeAsString(
      jsonEncode({
        'frostedEnabled': false,
        'liquidEnabled': true,
        'playerFrostedEnabled': true,
        'modules': {
          'all.cards': {'liquid': true},
        },
      }),
    );
    final restored = FrostedSettings();
    await restored.boot(directory: directory);
    expect(restored.frostedEnabled, false);
    await restored.setFrostedEnabled(true);
    final saved = jsonDecode(
      await File('${directory.path}/${FrostedSettings.fileName}')
          .readAsString(),
    );
    expect(saved['frostedEnabled'], true);
    expect(saved['styles'], isEmpty);
    restored.dispose();
  });

  test('native preview defaults off and restores independently', () async {
    final settings = FrostedSettings.instance;
    expect(settings.nativePreview, isFalse);
    await settings.setNativePreview(true);
    final restored = FrostedSettings();
    addTearDown(restored.dispose);
    await restored.boot(directory: directory);
    expect(restored.nativePreview, isTrue);
    await restored.setNativePreview(false);
    await settings.boot(directory: directory);
    expect(settings.nativePreview, isFalse);
    expect(settings.frostedEnabled, isTrue);
  });

  testWidgets(
    'native preview switches chrome and controls while keeping cards',
    (tester) async {
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
          builder: (context, child) => NativeGlassPreview(child: child!),
          home: Scaffold(
            appBar: const GlassAppBar(title: Text('标题')),
            body: Column(
              children: [
                const GlassCard(child: Text('内容卡片')),
                const ComicGlassBackdrop(radius: 18, child: Text('漫画工具栏')),
                const VideoGlassSurface(child: Text('播放操作')),
                NativeGlassSlider(value: .4, onChanged: (_) {}),
                Builder(
                  builder: (context) => TextButton(
                    onPressed: () => showGlassModalBottomSheet<void>(
                      context: context,
                      builder: (_) =>
                          const SizedBox(height: 80, child: Text('选项')),
                    ),
                    child: const Text('打开选项'),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      expect(find.byType(UiKitView), findsNothing);

      await tester.runAsync(
        () => FrostedSettings.instance.setNativePreview(true),
      );
      await tester.pumpAndSettle();
      expect(find.byType(DockNativeGlass), findsNWidgets(3));
      expect(find.byType(NativeGlassControl), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(GlassCard),
          matching: find.byType(UiKitView),
        ),
        findsNothing,
      );
      await tester.tap(find.text('打开选项'));
      await tester.pumpAndSettle();
      expect(
        find.ancestor(
          of: find.text('选项'),
          matching: find.byType(FrostedGlassWidget),
        ),
        findsOneWidget,
      );
      tester.state<NavigatorState>(find.byType(Navigator)).pop();
      await tester.pumpAndSettle();

      await tester.runAsync(
        () => FrostedSettings.instance.setNativePreview(false),
      );
      await tester.pumpAndSettle();
      expect(find.byType(UiKitView), findsNothing);
      expect(find.text('内容卡片'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );
  testWidgets('ordinary blur off retains solid fill, shadows and no border', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Center(
          child: FrostedGlassWidget(child: SizedBox(width: 200, height: 100)),
        ),
      ),
    );
    expect(find.byType(BackdropFilter), findsOneWidget);
    await tester.runAsync(
      () => FrostedSettings.instance.setFrostedEnabled(false),
    );
    await tester.pump();
    expect(find.byType(BackdropFilter), findsNothing);
    final finder = find.descendant(
      of: find.byType(FrostedGlassWidget),
      matching: find.byType(DecoratedBox),
    );
    final decoration =
        tester.widget<DecoratedBox>(finder).decoration as BoxDecoration;
    expect(decoration.boxShadow, isNotEmpty);
    expect(decoration.border, isNull);
    final fill = tester.widget<ColoredBox>(
      find.descendant(
        of: find.byType(FrostedGlassWidget),
        matching: find.byType(ColoredBox),
      ),
    );
    expect(fill.color.a, 1);
  });
  testWidgets(
    'floating settings keep ordinary controls without the removed player switch',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: LiquidGlassSettingsPage()),
      );
      await tester.pumpAndSettle();
      expect(find.text('启用系统玻璃'), findsNothing);
      expect(find.text('减少透明效果'), findsNothing);
      expect(find.text('材质风格'), findsOneWidget);
      expect(find.text('播放器弹窗使用新毛玻璃'), findsNothing);
      expect(find.text('动态液态玻璃效果'), findsNothing);
      expect(find.text('玻璃效果作用部位与强度'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
