import 'package:flutter/material.dart';
import 'package:lume_box/shared/widgets/video_glass_surface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/player/player_factory.dart';
import 'package:lume_box/core/player/player_settings.dart';
import 'package:lume_box/features/video/player_kernel_picker.dart';

class _Catalog implements PlayerKernelCatalog {
  @override
  bool isAvailable(PlayerKernel kernel) => kernel != PlayerKernel.mdk;
  @override
  String? unavailableReason(PlayerKernel kernel) =>
      isAvailable(kernel) ? null : '此设备不可用';
}

void main() {
  testWidgets('内核使用倍速同宽竖向小菜单，禁用不可用项，选择后关闭', (tester) async {
    PlayerKernel? selected;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          useMaterial3: false,
          chipTheme: const ChipThemeData(
            color: WidgetStatePropertyAll(Colors.white),
          ),
        ),
        home: Scaffold(
          body: PlayerKernelButton(
            selected: PlayerKernel.avplayer,
            catalog: _Catalog(),
            onChanged: (value) => selected = value,
            builder: (open) =>
                TextButton(onPressed: open, child: const Text('打开')),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byKey(const Key('player-kernel-menu'))).width,
      128,
    );
    expect(find.text('MDK'), findsNothing);
    expect(find.text('AetherEngine'), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const Key('player-kernel-menu'))).height,
      lessThanOrEqualTo(160),
    );
    expect(
      tester
          .widget<VideoGlassSurface>(find.byType(VideoGlassSurface))
          .materialOpacity,
      VideoGlassSurface.panelOpacity,
    );

    final chipMaterials = tester.widgetList<Material>(
      find.descendant(
        of: find.byKey(const Key('player-kernel-menu')),
        matching: find.byType(Material),
      ),
    );
    expect(chipMaterials, isNotEmpty);
    final chipContext = tester.element(find.widgetWithText(ChoiceChip, 'MPV'));
    expect(Theme.of(chipContext).canvasColor, Colors.transparent);
    for (final material in chipMaterials) {
      expect(material.color == null || material.color!.a == 0, isTrue);
    }

    await tester.tap(find.widgetWithText(ChoiceChip, 'MPV'));
    await tester.pumpAndSettle();
    expect(selected, PlayerKernel.mpv);
    expect(find.byKey(const Key('player-kernel-menu')), findsNothing);
  });
}
