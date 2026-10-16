import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/theme/glass_effects_settings.dart';
import 'package:lume_box/core/theme/floating_modules.dart';
import 'package:lume_box/shared/widgets/frosted_glass_widget.dart';
import 'package:lume_box/shared/widgets/liquid_glass_widget.dart';
import 'package:lume_box/shared/widgets/player_popup_glass.dart';
import 'package:lume_box/shared/widgets/module_glass_surface.dart';
import 'package:lume_box/core/theme/liquid_performance_guard.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;

  setUp(() async {
    directory = Directory.systemTemp.createTempSync('glass-effects-');
    await GlassEffectsSettings.instance.boot(directory: directory);
  });
  tearDown(() => directory.deleteSync(recursive: true));

  test('module overrides, speed and module switch survive reload', () async {
    final settings = GlassEffectsSettings.instance;
    await settings.setModule(
      GlassModule.all,
      GlassPart.cards,
      const GlassTuning(enabled: true, blur: 12, speed: .5),
    );
    await settings.setModule(
      GlassModule.comic,
      GlassPart.cards,
      const GlassTuning(enabled: true, liquid: true, blur: 28, speed: 1.75),
    );
    await settings.setModuleEnabled(GlassModule.comic, false);
    final restored = GlassEffectsSettings();
    await restored.boot(directory: directory);
    expect(restored.moduleTuning(GlassModule.video, GlassPart.cards).blur, 12);
    expect(
      restored.moduleTuning(GlassModule.comic, GlassPart.cards).enabled,
      false,
    );
    await restored.setModuleEnabled(GlassModule.comic, true);
    expect(
      restored.moduleTuning(GlassModule.comic, GlassPart.cards).speed,
      1.75,
    );
    await restored.resetModule(GlassModule.comic, GlassPart.cards);
    expect(restored.moduleTuning(GlassModule.comic, GlassPart.cards).speed, .5);
    restored.dispose();
  });

  testWidgets(
    'sustained slow frames fall back and recover without changing preferences',
    (tester) async {
      final guard = LiquidPerformanceGuard();
      guard.attach();
      final start = DateTime(2026);
      for (var i = 0; i < 10; i++) {
        guard.sample(buildMs: 45, rasterMs: 2, now: start);
      }
      expect(guard.quality, LiquidQuality.legacy);
      for (var i = 0; i < 150; i++) {
        guard.sample(
          buildMs: 3,
          rasterMs: 3,
          now: start.add(const Duration(seconds: 40)),
        );
      }
      expect(guard.quality, LiquidQuality.reduced);
      for (var i = 0; i < 150; i++) {
        guard.sample(
          buildMs: 3,
          rasterMs: 3,
          now: start.add(const Duration(seconds: 80)),
        );
      }
      expect(guard.quality, LiquidQuality.normal);
      guard.detach();
      await tester.pump();
      guard.dispose();
    },
  );

  test(
    'defaults, rapid writes and reload are independent of floating config',
    () async {
      final legacy = File('${directory.path}/floating_modules.json');
      const original = '{"dock":{"blur":3,"opacity":0.4},"custom":true}';
      legacy.writeAsStringSync(original);
      final settings = GlassEffectsSettings.instance;
      expect(settings.liquidEnabled, false);
      expect(settings.playerFrostedEnabled, true);
      await Future.wait([
        settings.setLiquidEnabled(true),
        settings.setPlayerFrostedEnabled(false),
        settings.setLiquidEnabled(false),
        settings.setLiquidEnabled(true),
      ]);
      final restored = GlassEffectsSettings();
      await restored.boot(directory: directory);
      expect(restored.liquidEnabled, true);
      expect(restored.playerFrostedEnabled, false);
      expect(legacy.readAsStringSync(), original);
      restored.dispose();
    },
  );

  test('per-area profiles persist independently; master off overrides every liquid area', () async {
    final settings = GlassEffectsSettings.instance;
    await settings.setArea(
      GlassArea.primaryControls,
      const GlassTuning(
        enabled: true,
        blur: 25,
        opacity: .2,
        radius: 18,
        highlight: .9,
        distort: .4,
      ),
    );
    await settings.setArea(
      GlassArea.videoSettings,
      const GlassTuning(
        enabled: true,
        blur: 30,
        opacity: .6,
        radius: 24,
        border: false,
      ),
    );
    expect(settings.active(GlassArea.primaryControls), false);
    await settings.setLiquidEnabled(true);
    expect(settings.active(GlassArea.primaryControls), true);
    expect(settings.active(GlassArea.utilityControls), false);
    final restored = GlassEffectsSettings();
    await restored.boot(directory: directory);
    expect(restored.tuning(GlassArea.primaryControls).blur, 25);
    expect(restored.tuning(GlassArea.videoSettings).border, false);
    await restored.setLiquidEnabled(false);
    expect(restored.active(GlassArea.primaryControls), false);
    restored.dispose();
  });

  testWidgets('module popup tuning still obeys the player frosted switch', (
    tester,
  ) async {
    final settings = GlassEffectsSettings.instance;
    await tester.runAsync(
      () => settings.setModule(
        GlassModule.video,
        GlassPart.panels,
        const GlassTuning(enabled: true),
      ),
    );
    const original = ColoredBox(color: Colors.red, child: Text('old popup'));
    await tester.pumpWidget(
      const MaterialApp(
        home: PlayerPopupGlass(
          area: GlassArea.videoSettings,
          legacy: original,
          child: Text('new popup'),
        ),
      ),
    );
    expect(find.byType(FrostedGlassWidget), findsOneWidget);
    await tester.runAsync(() => settings.setPlayerFrostedEnabled(false));
    await tester.pump();
    expect(find.byWidget(original), findsOneWidget);
    expect(find.byType(FrostedGlassWidget), findsNothing);
  });

  testWidgets('unsupported liquid preserves the original surface background', (
    tester,
  ) async {
    if (ui.ImageFilter.isShaderFilterSupported) return;
    final settings = GlassEffectsSettings.instance;
    await tester.runAsync(() async {
      await settings.setLiquidEnabled(true);
      await settings.setModule(
        GlassModule.comic,
        GlassPart.panels,
        const GlassTuning(enabled: true, liquid: true),
      );
    });
    const original = ColoredBox(
      color: Colors.red,
      child: Text('original frame'),
    );
    await tester.pumpWidget(
      const MaterialApp(
        home: ModuleGlassSurface(
          module: GlassModule.comic,
          part: GlassPart.panels,
          legacy: original,
          child: Text('transparent content'),
        ),
      ),
    );
    expect(find.byWidget(original), findsOneWidget);
    expect(find.text('transparent content'), findsNothing);
  });

  testWidgets('frosted area off returns the exact original popup subtree', (
    tester,
  ) async {
    const legacy = SizedBox(
      key: Key('exact-legacy-popup'),
      width: 100,
      height: 80,
    );
    await tester.pumpWidget(
      const MaterialApp(
        home: PlayerPopupGlass(
          area: GlassArea.videoSettings,
          legacy: legacy,
          child: Text('new-background'),
        ),
      ),
    );
    expect(find.byWidget(legacy), findsOneWidget);
    expect(find.byType(FrostedGlassWidget), findsNothing);
    await tester.runAsync(
      () => GlassEffectsSettings.instance.setArea(
        GlassArea.videoSettings,
        const GlassTuning(enabled: true),
      ),
    );
    await tester.pump();
    expect(find.byType(FrostedGlassWidget), findsOneWidget);
    await tester.runAsync(
      () => GlassEffectsSettings.instance.setPlayerFrostedEnabled(false),
    );
    await tester.pump();
    expect(find.byWidget(legacy), findsOneWidget);
    expect(find.byType(FrostedGlassWidget), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  test('malformed fields safely preserve independent defaults', () async {
    File('${directory.path}/${GlassEffectsSettings.fileName}')
        .writeAsStringSync(
          jsonEncode({'liquidEnabled': 'true', 'playerFrostedEnabled': null}),
        );
    await GlassEffectsSettings.instance.boot(directory: directory);
    expect(GlassEffectsSettings.instance.liquidEnabled, false);
    expect(GlassEffectsSettings.instance.playerFrostedEnabled, true);
  });

  testWidgets(
    'liquid off preserves legacy element, hit target and no effect layers',
    (tester) async {
      var taps = 0;
      final oldButton = SizedBox(
        width: 48,
        height: 48,
        child: IconButton(
          onPressed: () => taps++,
          icon: const Icon(Icons.play_arrow),
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: LiquidGlassWidget(
              blur: 40,
              highlight: 1,
              distort: 1,
              opacity: 1,
              child: oldButton,
            ),
          ),
        ),
      );
      expect(find.byWidget(oldButton), findsOneWidget);
      expect(find.byType(BackdropFilter), findsNothing);
      expect(find.byType(ClipRRect), findsNothing);
      expect(tester.getSize(find.byWidget(oldButton)), const Size(48, 48));
      await tester.tap(find.byType(IconButton));
      expect(taps, 1);
      if (!ui.ImageFilter.isShaderFilterSupported) {
        await tester.runAsync(
          () => GlassEffectsSettings.instance.setLiquidEnabled(true),
        );
        await tester.pump();
        expect(find.byWidget(oldButton), findsOneWidget);
        expect(find.byType(BackdropFilter), findsNothing);
      }
    },
  );

  testWidgets('frosted uses its parameters independent of old module sliders', (
    tester,
  ) async {
    FloatingModules.instance.set(
      FloatingModule.overlay,
      const FloatingStyle(blur: 1, opacity: .1),
    );
    await tester.pumpWidget(
      const MaterialApp(
        home: Center(
          child: FrostedGlassWidget(
            blur: 24,
            opacity: .6,
            radius: 14,
            border: false,
            child: SizedBox(width: 200, height: 100),
          ),
        ),
      ),
    );
    final filter = tester.widget<BackdropFilter>(find.byType(BackdropFilter));
    expect(filter.filter, ui.ImageFilter.blur(sigmaX: 24, sigmaY: 24));
    final box = tester.widget<DecoratedBox>(
      find.descendant(
        of: find.byType(FrostedGlassWidget),
        matching: find.byType(DecoratedBox),
      ),
    );
    expect((box.decoration as BoxDecoration).border, null);
    expect((box.decoration as BoxDecoration).boxShadow, isNotEmpty);
    final tint = tester.widget<ColoredBox>(
      find.descendant(
        of: find.byType(FrostedGlassWidget),
        matching: find.byType(ColoredBox),
      ),
    );
    expect(tint.color.a, closeTo(.6, .005));
    await tester.runAsync(
      () => GlassEffectsSettings.instance.setFrostedEnabled(false),
    );
    await tester.pump();
    expect(find.byType(BackdropFilter), findsNothing);
    final solid = tester.widget<ColoredBox>(
      find.descendant(
        of: find.byType(FrostedGlassWidget),
        matching: find.byType(ColoredBox),
      ),
    );
    expect(solid.color.a, 1);
    final shadow =
        tester
                .widget<DecoratedBox>(
                  find.descendant(
                    of: find.byType(FrostedGlassWidget),
                    matching: find.byType(DecoratedBox),
                  ),
                )
                .decoration
            as BoxDecoration;
    expect(shadow.border, isNull);
    expect(shadow.boxShadow, isNotEmpty);
    FloatingModules.instance.reset(FloatingModule.overlay);
  });

  testWidgets(
    'player switch returns actual old background and never a weakened new effect',
    (tester) async {
      const legacy = ColoredBox(color: Colors.red, child: Text('old player'));
      await tester.pumpWidget(
        const MaterialApp(
          home: Center(
            child: PlayerPopupGlass(legacy: legacy, child: Text('new player')),
          ),
        ),
      );
      expect(find.byType(FrostedGlassWidget), findsOneWidget);
      expect(find.text('new player'), findsOneWidget);
      await tester.runAsync(
        () => GlassEffectsSettings.instance.setPlayerFrostedEnabled(false),
      );
      await tester.pump();
      expect(find.byWidget(legacy), findsOneWidget);
      expect(find.byType(FrostedGlassWidget), findsNothing);
      expect(find.byType(BackdropFilter), findsNothing);
      expect(find.text('new player'), findsNothing);
      await tester.runAsync(
        () => GlassEffectsSettings.instance.setPlayerFrostedEnabled(true),
      );
      await tester.pump();
      expect(find.byType(FrostedGlassWidget), findsOneWidget);
    },
  );
}
