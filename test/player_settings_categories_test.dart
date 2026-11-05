import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/player/player_capabilities.dart';
import 'package:lume_box/core/player/player_factory.dart';
import 'package:lume_box/core/player/player_settings.dart';
import 'package:lume_box/features/video/danmaku/danmaku_settings.dart';
import 'package:lume_box/features/video/player_settings_sheet.dart';

class _Catalog implements PlayerKernelCatalog {
  const _Catalog();
  @override
  bool isAvailable(PlayerKernel kernel) => true;
  @override
  String? unavailableReason(PlayerKernel kernel) => null;
}

void main() {
  for (final size in [const Size(390, 844), const Size(932, 430)]) {
    testWidgets('分类导航在横竖屏和大字下可跳转，切分类保留设置 $size', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      var settings = const PlayerSettings();
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.3)),
            child: child!,
          ),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showPlayerSettingsSheet(
                  context: context,
                  settings: settings,
                  capabilities: PlayerCapabilities.of(PlayerKernel.avplayer),
                  onChanged: (next) => settings = next,
                  catalog: const _Catalog(),
                  danmaku: DanmakuSettings.defaults,
                  onDanmakuChanged: (_) {},
                ),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.widgetWithText(ChoiceChip, '2x'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, '2x'));
      await tester.pumpAndSettle();
      expect(settings.speed, 2);
      for (final group in [
        ('advanced', '内核与网络'),
        ('picture', '画面与显示'),
        ('audio', '声音与字幕'),
        ('danmaku', '弹幕与匹配'),
        ('controls', '手势与外观'),
        ('playback', '播放与选集'),
      ]) {
        await tester.ensureVisible(
          find.byKey(ValueKey('player-category-${group.$1}')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(ValueKey('player-category-${group.$1}')));
        await tester.pumpAndSettle();
        final heading = tester.getRect(find.text(group.$2));
        expect(heading.top, greaterThan(0));
        expect(heading.bottom, lessThan(size.height));
      }
      expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '2x'))
            .selected,
        isTrue,
      );
      expect(settings.speed, 2);
      expect(tester.takeException(), isNull);
    });
  }
}
