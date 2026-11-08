import 'package:flutter/material.dart';
import 'package:lume_box/shared/widgets/video_glass_surface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/features/video/player_speed_button.dart';

void main() {
  for (final size in [const Size(320, 568), const Size(932, 430)]) {
    testWidgets('倍速磨砂菜单保留七档，竖向滑杆可选完整范围 $size', (tester) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      double? selected;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(useMaterial3: false),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.3)),
            child: child!,
          ),
          home: Scaffold(
            body: PlayerSpeedButton(
              speed: 1,
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
        tester
            .widget<VideoGlassSurface>(find.byType(VideoGlassSurface))
            .materialOpacity,
        VideoGlassSurface.panelOpacity,
      );
      final menuSize = tester.getSize(
        find.byKey(const Key('player-speed-menu')),
      );
      expect(menuSize.width, 184);
      expect(menuSize.height, lessThanOrEqualTo(264));

      expect(find.byType(ChoiceChip), findsNWidgets(7));
      expect(find.byType(Divider), findsNothing);
      expect(find.text('1× 常速'), findsNothing);
      expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '1×'))
            .selected,
        isTrue,
      );
      expect(find.widgetWithText(ChoiceChip, '0.25×'), findsNothing);
      expect(find.byType(BackdropFilter), findsOneWidget);
      expect(tester.takeException(), isNull);
      final slider = tester.widget<Slider>(find.byType(Slider));
      expect(slider.min, .25);
      expect(slider.max, 4);
      slider.onChanged!(2.25);
      await tester.pump();
      slider.onChangeEnd!(2.25);
      await tester.pumpAndSettle();
      expect(selected, 2.25);
      expect(find.byKey(const Key('player-speed-menu')), findsNothing);
    });
  }
}
