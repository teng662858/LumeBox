import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/theme/frosted_settings.dart';
import 'package:lume_box/shared/widgets/frosted_glass_widget.dart';
import 'package:lume_box/features/settings/floating_settings_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  setUp(() async {
    directory = Directory.systemTemp.createTempSync('lume-frosted');
    await FrostedSettings.instance.boot(directory: directory);
  });
  tearDown(() => directory.deleteSync(recursive: true));
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
    expect(saved, {'frostedEnabled': true});
    restored.dispose();
  });
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
      await tester.pumpWidget(const MaterialApp(home: FloatingSettingsPage()));
      expect(find.text('毛玻璃'), findsOneWidget);
      expect(find.text('播放器弹窗使用新毛玻璃'), findsNothing);
      expect(find.text('动态液态玻璃效果'), findsNothing);
      expect(find.text('玻璃效果作用部位与强度'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
