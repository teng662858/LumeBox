import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/theme/frosted_settings.dart';
import 'package:lume_box/shared/widgets/player_appearance_scope.dart';
import 'package:lume_box/shared/widgets/native_glass_surfaces.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory settingsDirectory;
  setUpAll(() async {
    settingsDirectory = await Directory.systemTemp.createTemp(
      'appearance-settings-',
    );
    await FrostedSettings.instance.boot(directory: settingsDirectory);
  });
  tearDownAll(() async {
    await FrostedSettings.instance.save();
    await settingsDirectory.delete(recursive: true);
  });
  test('经典版默认启用，原生玻璃选择独立保存，不改变全局材质', () async {
    final directory = await Directory.systemTemp.createTemp(
      'player-appearance-',
    );
    try {
      final settings = FrostedSettings();
      await settings.boot(directory: directory);
      expect(settings.playerNative, false);
      await settings.setPlayerNative(true);
      final restored = FrostedSettings();
      await restored.boot(directory: directory);
      expect(restored.playerNative, true);
      expect(restored.nativePreview, false);
      await restored.setPlayerNative(false);
      await settings.boot(directory: directory);
      expect(settings.playerNative, false);
    } finally {
      await directory.delete(recursive: true);
    }
  });
  testWidgets('播放器模式仅作用于标记区域', (tester) async {
    final values = <bool?>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Column(
          children: [
            Builder(
              builder: (context) {
                values.add(PlayerAppearanceScope.nativeOf(context));
                return const SizedBox();
              },
            ),
            PlayerAppearanceScope(
              child: Builder(
                builder: (context) {
                  values.add(PlayerAppearanceScope.nativeOf(context));
                  return const SizedBox();
                },
              ),
            ),
          ],
        ),
      ),
    );
    expect(values, [null, false]);
  });
  testWidgets('控制条深浅实时调整、独立保存，经典外观隐藏调节项', (tester) async {
    final settings = FrostedSettings.instance;
    await tester.runAsync(() async {
      await settings.setPlayerNative(true);
    });
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: PlayerAppearanceControl())),
    );
    final slider = find.byKey(const ValueKey('player-glass-shade'));
    expect(tester.widget<Slider>(slider).value, .12);
    await tester.runAsync(
      () => tester.tapAt(
        tester.getTopLeft(slider) +
            Offset(tester.getSize(slider).width * .75, 24),
      ),
    );
    await tester.pump();
    final updated = settings.playerGlassShade;
    expect(updated, greaterThan(.25));
    expect(tester.widget<Slider>(slider).value, updated);
    await tester.runAsync(() async {
      await settings.save();
      final restored = FrostedSettings();
      await restored.boot(directory: settingsDirectory);
      expect(restored.playerGlassShade, updated);
      expect(restored.native.tintOpacity, 0);
      await settings.setPlayerGlassShade(10);
      expect(settings.playerGlassShade, .5);
      await settings.setPlayerGlassShade(-1);
      expect(settings.playerGlassShade, 0);
      await settings.setPlayerGlassShade(double.nan);
      expect(settings.playerGlassShade, 0);
      await settings.setPlayerNative(false);
    });
    await tester.pumpAndSettle();
    expect(slider, findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      await settings.setPlayerGlassShade(
        FrostedSettings.defaultPlayerGlassShade,
      );
    });
  });
  testWidgets('root navigator dialogs retain the player appearance scope', (
    tester,
  ) async {
    bool? dialogMode;
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerAppearanceScope(
          child: Builder(
            builder: (context) => TextButton(
              onPressed: () => showGlassDialog<void>(
                context: context,
                builder: (context) {
                  dialogMode = PlayerAppearanceScope.nativeOf(context);
                  return const AlertDialog(content: Text('player dialog'));
                },
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(dialogMode, false);
    expect(find.text('player dialog'), findsOneWidget);
  });
}
